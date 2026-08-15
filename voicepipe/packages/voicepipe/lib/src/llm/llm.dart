/// LLM interface + OpenAI-compatible HTTP implementation (and a mock for tests).
library;

import 'dart:convert';

import 'package:http/http.dart' as http;

/// A chat message in the agent's conversation history.
class ChatMessage {
  final String role; // system | user | assistant
  final String content;
  const ChatMessage(this.role, this.content);
}

/// Minimal LLM contract: prompt -> text reply.
abstract interface class VoicepipeLlm {
  Future<String> reply(List<ChatMessage> history);
}

/// OpenAI-compatible chat completions (Groq, OpenRouter, OpenCode Zen, ...).
class OpenAiCompatibleLlm implements VoicepipeLlm {
  final String baseUrl;
  final String apiKey;
  final String model;
  final double temperature;
  final Duration timeout;
  final http.Client _client;

  OpenAiCompatibleLlm({
    required this.baseUrl,
    required this.apiKey,
    required this.model,
    this.temperature = 0.3,
    this.timeout = const Duration(seconds: 15),
    http.Client? client,
  }) : _client = client ?? http.Client();

  @override
  Future<String> reply(List<ChatMessage> history) async {
    final uri = Uri.parse('$baseUrl/chat/completions');
    final res = await _client
        .post(
          uri,
          headers: {
            'Authorization': 'Bearer $apiKey',
            'Content-Type': 'application/json',
          },
          body: jsonEncode({
            'model': model,
            'temperature': temperature,
            'messages': [
              for (final m in history)
                {'role': m.role, 'content': m.content},
            ],
          }),
        )
        .timeout(timeout);

    if (res.statusCode != 200) {
      throw LlmException('${res.statusCode}: '
          '${res.body.length > 200 ? res.body.substring(0, 200) : res.body}');
    }
    final data = jsonDecode(res.body) as Map<String, dynamic>;
    final choices = data['choices'] as List<dynamic>;
    final content = (choices.first['message'] as Map<String, dynamic>)['content'];
    if (content is! String || content.isEmpty) {
      throw LlmException('empty completion');
    }
    return content.trim();
  }
}

/// Fixed-reply LLM for offline tests and demos without an API key.
class EchoLlm implements VoicepipeLlm {
  final String replyText;
  EchoLlm([this.replyText = 'I am your triage assistant. Please tell me your symptoms.']);

  @override
  Future<String> reply(List<ChatMessage> history) async => replyText;
}

class LlmException implements Exception {
  final String message;
  LlmException(this.message);
  @override
  String toString() => 'LlmException: $message';
}

/// Build an OpenAI-compatible LLM from environment variables:
///   VOICEPIPE_LLM_BASE_URL, VOICEPIPE_LLM_API_KEY, VOICEPIPE_LLM_MODEL
/// Falls back to [EchoLlm] when no key is configured.
VoicepipeLlm llmFromEnv(Map<String, String> env) {
  final groq = env['GROQ_API_KEY'] != null;
  final openai = env['OPENAI_API_KEY'] != null;
  final base = env['VOICEPIPE_LLM_BASE_URL'] ??
      (groq
          ? 'https://api.groq.com/openai/v1'
          : openai
              ? 'https://api.openai.com/v1'
              : '');
  final key = env['VOICEPIPE_LLM_API_KEY'] ??
      env['GROQ_API_KEY'] ??
      env['OPENAI_API_KEY'] ??
      '';
  final model = env['VOICEPIPE_LLM_MODEL'] ??
      (groq ? 'llama-3.3-70b-versatile' : 'gpt-4o-mini');
  if (base.isEmpty || key.isEmpty) {
    return EchoLlm();
  }
  return OpenAiCompatibleLlm(baseUrl: base, apiKey: key, model: model);
}
