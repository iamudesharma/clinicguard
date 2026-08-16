/// LLM interface + OpenAI-compatible HTTP implementation (and a mock for tests).
library;

import 'dart:convert';
import 'dart:math';

import 'package:http/http.dart' as http;

/// Random UUID v4 (OpenCode Zen wants per-request x-opencode-* ids).
String _uuidV4() {
  final rng = Random.secure();
  final bytes = List<int>.generate(16, (_) => rng.nextInt(256));
  bytes[6] = (bytes[6] & 0x0f) | 0x40; // version 4
  bytes[8] = (bytes[8] & 0x3f) | 0x80; // variant
  final hex = bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  return '${hex.substring(0, 8)}-${hex.substring(8, 12)}-'
      '${hex.substring(12, 16)}-${hex.substring(16, 20)}-${hex.substring(20)}';
}

/// Crash-proof log: piped stdout can throw "StreamSink is bound to a stream"
/// under backpressure; never let a log line break the turn flow.
void _safeLog(String message) {
  try {
    print(message);
  } catch (_) {}
}

/// A chat message in the agent's conversation history.
///
/// Roles: system | user | assistant | tool.
/// [toolCalls] is set on assistant messages that requested function calls;
/// [toolCallId] links a `tool`-role result to the call it answers.
class ChatMessage {
  final String role;
  final String content;
  final List<LlmToolCall>? toolCalls;
  final String? toolCallId;

  const ChatMessage(this.role, this.content,
      {this.toolCalls, this.toolCallId});
}

/// An OpenAI-style function/tool definition (JSON-schema parameters).
class ToolDef {
  final String name;
  final String description;
  final Map<String, dynamic> parameters;

  const ToolDef({
    required this.name,
    required this.description,
    required this.parameters,
  });

  Map<String, dynamic> toJson() => {
        'type': 'function',
        'function': {
          'name': name,
          'description': description,
          'parameters': parameters,
        },
      };
}

/// A function call requested by the model.
class LlmToolCall {
  final String id;
  final String name;
  final Map<String, dynamic> arguments;

  const LlmToolCall({
    required this.id,
    required this.name,
    required this.arguments,
  });
}

/// A model reply: spoken content and/or tool calls.
class LlmReply {
  final String? content;
  final List<LlmToolCall> toolCalls;

  const LlmReply({this.content, this.toolCalls = const []});
}

/// Minimal LLM contract: prompt -> text reply (plus optional tool calling).
abstract interface class VoicepipeLlm {
  Future<String> reply(List<ChatMessage> history);

  /// Like [reply] but offers [tools] to the model. The reply may contain
  /// tool calls instead of (or in addition to) spoken content.
  Future<LlmReply> replyWithTools(List<ChatMessage> history,
      {List<ToolDef>? tools});
}

/// OpenAI-compatible chat completions (Groq, OpenRouter, OpenCode Zen, ...).
class OpenAiCompatibleLlm implements VoicepipeLlm {
  final String baseUrl;
  final String apiKey;
  final String model;
  final double temperature;
  final Duration timeout;
  final String name;
  final Map<String, String> _extraHeaders;
  final String _sessionId;
  final String _projectId;
  final http.Client _client;

  OpenAiCompatibleLlm({
    required String baseUrl,
    required this.apiKey,
    required this.model,
    this.temperature = 0.3,
    this.timeout = const Duration(seconds: 45),
    String? name,
    Map<String, String>? extraHeaders,
    http.Client? client,
  })  : _client = client ?? http.Client(),
        // Strip trailing slashes: providers document base URLs like
        // ".../v1beta/openai/" and appending "/chat/completions" would 404.
        baseUrl = baseUrl.replaceFirst(RegExp(r'/+$'), ''),
        name = (name == null || name.isEmpty) ? model : name,
        _extraHeaders = extraHeaders ?? const {},
        _sessionId = _uuidV4(),
        _projectId = _uuidV4();

  /// OpenCode Zen routes/validates requests by these client headers; without
  /// them it answers `FreeUsageLimitError` even with a valid key.
  static const _opencodeHeaders = {
    'x-opencode-client': 'cli',
    'User-Agent': 'opencode/latest/cli',
  };

  Map<String, String> _headers() {
    final headers = <String, String>{
      'Authorization': 'Bearer $apiKey',
      'Content-Type': 'application/json',
      ..._extraHeaders,
    };
    if (baseUrl.contains('opencode.ai')) {
      headers.addAll({
        ..._opencodeHeaders,
        'x-opencode-session': _sessionId,
        'x-opencode-project': _projectId,
        'x-opencode-request': _uuidV4(),
      });
    }
    return headers;
  }

  @override
  Future<String> reply(List<ChatMessage> history) async {
    final r = await replyWithTools(history);
    final text = r.content;
    if (text == null || text.isEmpty) {
      throw LlmException('empty completion');
    }
    return text;
  }

  @override
  Future<LlmReply> replyWithTools(List<ChatMessage> history,
      {List<ToolDef>? tools}) async {
    final sw = Stopwatch()..start();
    final uri = Uri.parse('$baseUrl/chat/completions');
    final res = await _client
        .post(
          uri,
          headers: _headers(),
          body: jsonEncode({
            'model': model,
            'temperature': temperature,
            if (tools != null && tools.isNotEmpty)
              'tools': [for (final t in tools) t.toJson()],
            'messages': [
              for (final m in history) _messageToJson(m),
            ],
          }),
        )
        .timeout(timeout);
    sw.stop();

    if (res.statusCode != 200) {
      throw LlmException('${res.statusCode}: '
          '${res.body.length > 200 ? res.body.substring(0, 200) : res.body}');
    }
    var data = jsonDecode(res.body) as Map<String, dynamic>;
    // Cline wraps the standard OpenAI response in a "data" object.
    if (data['choices'] == null && data['data'] is Map<String, dynamic>) {
      data = data['data'] as Map<String, dynamic>;
    }
    final choices = data['choices'] as List<dynamic>;
    final message = choices.first['message'] as Map<String, dynamic>;
    final content = message['content'];
    final toolCalls = <LlmToolCall>[];
    final rawCalls = message['tool_calls'];
    if (rawCalls is List) {
      for (final raw in rawCalls) {
        final call = raw as Map<String, dynamic>;
        final fn = call['function'] as Map<String, dynamic>;
        toolCalls.add(LlmToolCall(
          id: call['id'] as String? ?? '',
          name: fn['name'] as String? ?? '',
          arguments: _parseArguments(fn['arguments']),
        ));
      }
    }
    _safeLog('[voice_forge] llm: $name -> ${sw.elapsedMilliseconds}ms '
        '(${toolCalls.length} tool call(s), ${history.length} messages)');
    return LlmReply(
      content: content is String && content.isNotEmpty ? content.trim() : null,
      toolCalls: toolCalls,
    );
  }

  Map<String, dynamic> _messageToJson(ChatMessage m) {
    final msg = <String, dynamic>{'role': m.role};
    if (m.toolCalls == null || m.toolCalls!.isEmpty || m.content.isNotEmpty) {
      msg['content'] = m.content;
    }
    if (m.toolCalls != null && m.toolCalls!.isNotEmpty) {
      msg['tool_calls'] = [
        for (final c in m.toolCalls!)
          {
            'id': c.id,
            'type': 'function',
            'function': {'name': c.name, 'arguments': jsonEncode(c.arguments)},
          },
      ];
    }
    if (m.toolCallId != null) {
      msg['tool_call_id'] = m.toolCallId;
    }
    return msg;
  }

  Map<String, dynamic> _parseArguments(Object? raw) {
    if (raw is String && raw.isNotEmpty) {
      try {
        final decoded = jsonDecode(raw);
        if (decoded is Map<String, dynamic>) return decoded;
      } catch (_) {}
    }
    return {};
  }
}

/// Fixed-reply LLM for offline tests and demos without an API key.
class EchoLlm implements VoicepipeLlm {
  final String replyText;
  EchoLlm([this.replyText = 'I am your triage assistant. Please tell me your symptoms.']);

  @override
  Future<String> reply(List<ChatMessage> history) async => replyText;

  @override
  Future<LlmReply> replyWithTools(List<ChatMessage> history,
      {List<ToolDef>? tools}) async =>
      LlmReply(content: replyText);
}

/// Provider failover: [primary] is used by default; after [failureThreshold]
/// consecutive failures it is marked down for [cooldown] and [fallback] takes
/// over. A single failure falls through to [fallback] for that call without
/// switching (mirrors the Python control plane's LLM_FALLBACK_BACKEND).
class FallbackLlm implements VoicepipeLlm {
  final VoicepipeLlm primary;
  final VoicepipeLlm fallback;
  final int failureThreshold;
  final Duration cooldown;

  int _consecutiveFailures = 0;
  DateTime? _primaryDownUntil;
  Duration _rateLimitCooldown = const Duration(minutes: 5);

  FallbackLlm({
    required this.primary,
    required this.fallback,
    this.failureThreshold = 3,
    this.cooldown = const Duration(seconds: 60),
  });

  /// 429 / quota errors mean the provider is down for a while (daily limits);
  /// skip retrying it for a much longer window instead of paying a wasted
  /// round trip every turn. Repeated rate limits back off exponentially
  /// (5m -> 10m -> 20m -> ... capped at 60m) so a provider that is exhausted
  /// for the day stops costing latency on every call.
  static final RegExp _rateLimit = RegExp(
      r'429|rate.?limit|quota', caseSensitive: false);

  bool get _primaryDown =>
      _primaryDownUntil != null && DateTime.now().isBefore(_primaryDownUntil!);

  Future<T> _run<T>(
      Future<T> Function(VoicepipeLlm llm) call, Future<T> Function() onFallback) async {
    if (_primaryDown) return onFallback();
    final sw = Stopwatch()..start();
    try {
      final result = await call(primary);
      _consecutiveFailures = 0;
      _rateLimitCooldown = const Duration(minutes: 5); // provider recovered
      return result;
    } catch (e) {
      sw.stop();
      _consecutiveFailures++;
      _safeLog('[voice_forge] LLM call failed after ${sw.elapsedMilliseconds}ms: $e');
      final rateLimited = _rateLimit.hasMatch('$e');
      if (rateLimited && _consecutiveFailures < 2) {
        // Transient burst quota (e.g. Google's 429s recover in seconds):
        // retry the primary once before treating it as exhausted. A second
        // consecutive 429 falls through to the existing mark-down logic.
        _safeLog('[voice_forge] LLM 429 (transient?), retrying primary...');
        await Future<void>.delayed(const Duration(milliseconds: 1500));
        return _run(call, onFallback);
      }
      if (rateLimited || _consecutiveFailures >= failureThreshold) {
        // Rate limits mark the provider down immediately (longer cooldown);
        // other errors wait for failureThreshold consecutive failures.
        if (rateLimited) {
          _primaryDownUntil = DateTime.now().add(_rateLimitCooldown);
          if (_rateLimitCooldown < const Duration(minutes: 60)) {
            _rateLimitCooldown *= 2;
          }
        } else {
          _primaryDownUntil = DateTime.now().add(cooldown);
        }
        _consecutiveFailures = 0;
        _safeLog('[voice_forge] LLM provider down after ${sw.elapsedMilliseconds}ms'
            '${rateLimited ? ' (rate limited)' : ''}; switching to fallback '
            'for ${(rateLimited ? _rateLimitCooldown ~/ 2 : cooldown).inSeconds}s');
      }
      return onFallback();
    }
  }

  @override
  Future<String> reply(List<ChatMessage> history) =>
      _run((llm) => llm.reply(history), () => fallback.reply(history));

  @override
  Future<LlmReply> replyWithTools(List<ChatMessage> history,
          {List<ToolDef>? tools}) =>
      _run((llm) => llm.replyWithTools(history, tools: tools),
          () => fallback.replyWithTools(history, tools: tools));
}

class LlmException implements Exception {
  final String message;
  LlmException(this.message);
  @override
  String toString() => 'LlmException: $message';
}

VoicepipeLlm _openAiCompatible(Map<String, String> env, String base,
    String key, String model,
    {double temperature = 0.3}) {
  final timeoutSeconds =
      int.tryParse(env['VOICE_FORGE_LLM_TIMEOUT_SECONDS'] ?? '') ?? 45;
  return OpenAiCompatibleLlm(
    baseUrl: base,
    apiKey: key,
    model: model,
    temperature: temperature,
    timeout: Duration(seconds: timeoutSeconds),
  );
}

/// Build the agent's LLM from environment variables.
///
/// Default provider order (unless the explicit `VOICE_FORGE_LLM_*` trio is set):
///   1. Cline (`CLINE_API_KEY`, `CLINE_MODEL`, default
///      `poolside/laguna-s-2.1:free`, base https://api.cline.bot/api/v1);
///   2. OpenCode Zen (`OPENCODE_API_KEY`, `OPENCODE_BASE_URL`, `OPENCODE_MODEL`),
///      free tier first to keep testing cheap;
///   3. OpenCode Go (`OPENCODE_GO_API_KEY`, `OPENCODE_GO_MODEL`, default
///      `kimi-k3`, base https://opencode.ai/zen/go/v1 — paid tier, no rate
///      limits) — LAST of the opencode providers so billing only starts when
///      the free ones fail;
///   4. Gemini (`GEMINI_API_KEY`, `GEMINI_MODEL`, default `gemini-3.7-flash`,
///      OpenAI-compatible endpoint);
///   5. OpenRouter (`OPENROUTER_API_KEY`, `OPENROUTER_MODEL`) as automatic
///      fallback when the primary fails;
///   6. Groq / OpenAI if present (last resort fallback chain);
///   7. [EchoLlm] when no key is configured (offline demo mode).
/// `VOICE_FORGE_LLM_TIMEOUT_SECONDS` (default 45) raises the per-call timeout —
/// needed for slow free-tier providers (e.g. OpenRouter `:free` models).
VoicepipeLlm llmFromEnv(Map<String, String> env) {
  final explicit = env['VOICE_FORGE_LLM_API_KEY'] != null;
  if (explicit) {
    final base = env['VOICE_FORGE_LLM_BASE_URL'] ?? '';
    if (base.isEmpty) return EchoLlm();
    return _openAiCompatible(
      env,
      base,
      env['VOICE_FORGE_LLM_API_KEY'] ?? '',
      env['VOICE_FORGE_LLM_MODEL'] ?? '',
    );
  }
  final opencodeKey = env['OPENCODE_API_KEY'];
  final openrouterKey = env['OPENROUTER_API_KEY'];
  final groqKey = env['GROQ_API_KEY'];
  final openaiKey = env['OPENAI_API_KEY'];

  final candidates = <VoicepipeLlm>[];
  final clineKey = env['CLINE_API_KEY'];
  if (clineKey != null && clineKey.isNotEmpty) {
    candidates.add(_openAiCompatible(
      env,
      'https://api.cline.bot/api/v1',
      clineKey,
      env['CLINE_MODEL'] ?? 'poolside/laguna-s-2.1:free',
    ));
  }
  final opencodeGoKey = env['OPENCODE_GO_API_KEY'];
  // Zen (free) before Go (paid): free tier is the default workhorse, paid
  // billing only kicks in when the free one is down.
  if (opencodeKey != null && opencodeKey.isNotEmpty) {
    candidates.add(_openAiCompatible(
      env,
      env['OPENCODE_BASE_URL'] ?? 'https://opencode.ai/zen/v1',
      opencodeKey,
      // laguna-s-2.1-free: no chain-of-thought (thinking) -> fastest TTFT
      // (~1.5s vs ~3.6s for deepseek-v4-flash-free), tool calling works.
      env['OPENCODE_MODEL'] ?? 'laguna-s-2.1-free',
    ));
  }
  if (opencodeGoKey != null && opencodeGoKey.isNotEmpty) {
    candidates.add(_openAiCompatible(
      env,
      'https://opencode.ai/zen/go/v1',
      opencodeGoKey,
      env['OPENCODE_GO_MODEL'] ?? 'kimi-k3',
      // kimi-k3 on the Go endpoint only accepts temperature == 1.
      temperature: 1.0,
    ));
  }
  final geminiKey = env['GEMINI_API_KEY'];
  if (geminiKey != null && geminiKey.isNotEmpty) {
    candidates.add(_openAiCompatible(
      env,
      'https://generativelanguage.googleapis.com/v1beta/openai/',
      geminiKey,
      env['GEMINI_MODEL'] ?? 'gemini-3.7-flash',
    ));
  }
  if (openrouterKey != null && openrouterKey.isNotEmpty) {
    candidates.add(_openAiCompatible(
      env,
      'https://openrouter.ai/api/v1',
      openrouterKey,
      env['OPENROUTER_MODEL'] ?? 'openai/gpt-oss-20b:free',
    ));
  }
  if (groqKey != null && groqKey.isNotEmpty) {
    candidates.add(_openAiCompatible(
      env,
      'https://api.groq.com/openai/v1',
      groqKey,
      env['GROQ_MODEL'] ?? 'llama-3.3-70b-versatile',
    ));
  }
  if (openaiKey != null && openaiKey.isNotEmpty) {
    candidates.add(_openAiCompatible(
      env,
      'https://api.openai.com/v1',
      openaiKey,
      env['OPENAI_MODEL'] ?? 'gpt-4o-mini',
    ));
  }
  if (candidates.isEmpty) return EchoLlm();
  var llm = candidates.first;
  for (final fallback in candidates.skip(1)) {
    llm = FallbackLlm(primary: llm, fallback: fallback);
  }
  return llm;
}
