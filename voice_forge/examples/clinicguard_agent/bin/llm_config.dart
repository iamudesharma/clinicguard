/// ClinicGuard LLM provider chain (application wiring, not the framework).
///
/// Order: Cline → OpenCode Zen Go → Gemini → OpenRouter → offline echo.
library;

import 'dart:math';

import 'package:voice_forge/voice_forge.dart';

String _uuidV4() {
  final rng = Random.secure();
  final bytes = List<int>.generate(16, (_) => rng.nextInt(256));
  bytes[6] = (bytes[6] & 0x0f) | 0x40;
  bytes[8] = (bytes[8] & 0x3f) | 0x80;
  final hex = bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  return '${hex.substring(0, 8)}-${hex.substring(8, 12)}-'
      '${hex.substring(12, 16)}-${hex.substring(16, 20)}-${hex.substring(20)}';
}

/// Per-call OpenCode client headers (matches `opencode` CLI / Zen Go API).
class _OpenCodeHeaders {
  _OpenCodeHeaders()
      : sessionId = _uuidV4(),
        projectId = _uuidV4();

  final String sessionId;
  final String projectId;

  Map<String, String> staticHeaders() => {
        'x-opencode-client': 'cli',
        'User-Agent': 'opencode/latest/cli',
        'x-opencode-session': sessionId,
        'x-opencode-project': projectId,
      };

  Map<String, String> perRequest() => {
        'x-opencode-request': _uuidV4(),
      };
}

VoicepipeLlm _openAi(
  Map<String, String> env,
  String base,
  String key,
  String model, {
  double temperature = 0.3,
  Map<String, String>? extraHeaders,
  Map<String, String> Function()? requestHeaders,
  String? name,
}) {
  final timeoutSeconds =
      int.tryParse(env['VOICE_FORGE_LLM_TIMEOUT_SECONDS'] ?? '') ?? 45;
  return OpenAiCompatibleLlm(
    baseUrl: base,
    apiKey: key,
    model: model,
    name: name,
    temperature: temperature,
    extraHeaders: extraHeaders,
    requestHeaders: requestHeaders,
    timeout: Duration(seconds: timeoutSeconds),
  );
}

/// Explicit `VOICE_FORGE_LLM_*` trio overrides the whole chain.
VoicepipeLlm clinicGuardLlmFromEnv(Map<String, String> env) {
  final explicitBase = env['VOICE_FORGE_LLM_BASE_URL'] ?? '';
  final explicitKey = env['VOICE_FORGE_LLM_API_KEY'] ?? '';
  if (explicitBase.isNotEmpty && explicitKey.isNotEmpty) {
    return _openAi(
      env,
      explicitBase,
      explicitKey,
      env['VOICE_FORGE_LLM_MODEL'] ?? '',
    );
  }

  final candidates = <VoicepipeLlm>[];

  final clineKey = env['CLINE_API_KEY'];
  if (clineKey != null && clineKey.isNotEmpty) {
    candidates.add(
      _openAi(
        env,
        env['CLINE_BASE_URL'] ?? 'https://api.cline.bot/api/v1',
        clineKey,
        env['CLINE_MODEL'] ?? 'poolside/laguna-s-2.1:free',
        name: 'cline',
      ),
    );
  }

  final opencodeKey =
      env['OPENCODE_API_KEY'] ?? env['OPENCODE_GO_API_KEY'] ?? '';
  if (opencodeKey.isNotEmpty) {
    final headers = _OpenCodeHeaders();
    candidates.add(
      _openAi(
        env,
        env['OPENCODE_BASE_URL'] ?? 'https://opencode.ai/zen/go/v1',
        opencodeKey,
        env['OPENCODE_MODEL'] ?? 'deepseek-v4-flash-free',
        name: 'opencode',
        extraHeaders: headers.staticHeaders(),
        requestHeaders: headers.perRequest,
      ),
    );
  }

  final geminiKey = env['GEMINI_API_KEY'];
  if (geminiKey != null && geminiKey.isNotEmpty) {
    candidates.add(
      _openAi(
        env,
        env['GEMINI_BASE_URL'] ??
            'https://generativelanguage.googleapis.com/v1beta/openai/',
        geminiKey,
        env['GEMINI_MODEL'] ?? 'gemini-3.7-flash',
        name: 'gemini',
      ),
    );
  }

  final openrouterKey = env['OPENROUTER_API_KEY'];
  if (openrouterKey != null && openrouterKey.isNotEmpty) {
    candidates.add(
      _openAi(
        env,
        'https://openrouter.ai/api/v1',
        openrouterKey,
        env['OPENROUTER_MODEL'] ?? 'openai/gpt-oss-20b:free',
        name: 'openrouter',
      ),
    );
  }

  return chainLlms(candidates);
}
