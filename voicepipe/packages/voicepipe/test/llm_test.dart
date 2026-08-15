import 'dart:convert';

import 'package:test/test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:voicepipe/src/llm/llm.dart';

void main() {
  test('EchoLlm returns its fixed reply', () async {
    final llm = EchoLlm('hello there');
    expect(await llm.reply([const ChatMessage('user', 'hi')]), 'hello there');
  });

  test('OpenAiCompatibleLlm posts messages and parses content', () async {
    final client = MockClient((request) async {
      expect(request.url.toString(), 'https://api.test/v1/chat/completions');
      expect(request.headers['Authorization'], 'Bearer key123');
      final body = jsonDecode(request.body) as Map<String, dynamic>;
      expect(body['model'], 'model-x');
      expect((body['messages'] as List).length, 2);
      return http.Response(
          jsonEncode({
            'choices': [
              {
                'message': {'content': '  the reply  '}
              }
            ]
          }),
          200,
          headers: {'content-type': 'application/json'});
    });

    final llm = OpenAiCompatibleLlm(
      baseUrl: 'https://api.test/v1',
      apiKey: 'key123',
      model: 'model-x',
      client: client,
    );
    final reply = await llm.reply([
      const ChatMessage('user', 'hello'),
      const ChatMessage('assistant', 'hi'),
    ]);
    expect(reply, 'the reply');
  });

  test('OpenAiCompatibleLlm throws on non-200', () async {
    final client = MockClient((_) async => http.Response('boom', 429));
    final llm = OpenAiCompatibleLlm(
      baseUrl: 'https://api.test/v1',
      apiKey: 'k',
      model: 'm',
      client: client,
    );
    expect(() => llm.reply([const ChatMessage('user', 'x')]),
        throwsA(isA<LlmException>()));
  });

  test('llmFromEnv falls back to EchoLlm without keys', () {
    expect(llmFromEnv(const {}), isA<EchoLlm>());
    expect(llmFromEnv(const {'GROQ_API_KEY': 'k'}), isA<OpenAiCompatibleLlm>());
  });
}
