import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:voice_forge/src/llm/llm.dart';

void main() {
  test('EchoLlm returns its fixed reply', () async {
    final llm = EchoLlm('hello there');
    expect(await llm.reply([const ChatMessage('user', 'hi')]), 'hello there');
  });

  test('OpenAiCompatibleLlm retries as a plain request when the stream '
      'yields only reasoning', () async {
    var streamCalls = 0;
    final client = MockClient((req) async {
      if (req.body.contains('"stream":true')) {
        streamCalls++;
        return http.Response.bytes(
          utf8.encode(
            'data: ${jsonEncode({
              'choices': [
                {'delta': {'reasoning_content': 'thinking...'}},
              ],
            })}\n\ndata: [DONE]\n\n',
          ),
          200,
          headers: {'content-type': 'text/event-stream'},
        );
      }
      return http.Response(
        jsonEncode({
          'choices': [
            {
              'message': {
                'role': 'assistant',
                'content': 'hello there',
              },
            },
          ],
        }),
        200,
      );
    });
    final llm = OpenAiCompatibleLlm(
      baseUrl: 'https://example.test/v1',
      apiKey: 'k',
      model: 'm',
      client: client,
    );
    var partial = '';
    final reply = await llm.streamReplyWithTools(
      [const ChatMessage('user', 'hi')],
      onPartial: (p) => partial += p,
    );
    expect(streamCalls, 1);
    expect(partial, '');
    expect(reply.content, 'hello there');
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
              'message': {'content': '  the reply  '},
            },
          ],
        }),
        200,
        headers: {'content-type': 'application/json'},
      );
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
    expect(
      () => llm.reply([const ChatMessage('user', 'x')]),
      throwsA(isA<LlmException>()),
    );
  });

  test('OpenAiCompatibleLlm unwraps a Cline-style "data" response', () async {
    final client = MockClient(
      (_) async => http.Response(
        jsonEncode({
          'data': {
            'choices': [
              {
                'message': {'content': 'wrapped reply'},
              },
            ],
          },
        }),
        200,
        headers: {'content-type': 'application/json'},
      ),
    );
    final llm = OpenAiCompatibleLlm(
      baseUrl: 'https://api.cline.bot/api/v1',
      apiKey: 'k',
      model: 'm',
      client: client,
    );
    expect(await llm.reply([const ChatMessage('user', 'hi')]), 'wrapped reply');
  });

  test('replyWithTools sends tools and parses tool_calls', () async {
    final client = MockClient((request) async {
      final body = jsonDecode(request.body) as Map<String, dynamic>;
      final tools = body['tools'] as List;
      expect(tools.length, 1);
      expect((tools.first as Map)['function']['name'], 'book_appointment');
      final messages = body['messages'] as List;
      expect(
        messages.any(
          (m) => m['role'] == 'assistant' && m['tool_calls'] is List,
        ),
        isTrue,
      );
      expect(
        messages.any(
          (m) => m['role'] == 'tool' && m['tool_call_id'] == 'call_0',
        ),
        isTrue,
      );
      return http.Response(
        jsonEncode({
          'choices': [
            {
              'message': {
                'content': null,
                'tool_calls': [
                  {
                    'id': 'call_1',
                    'type': 'function',
                    'function': {
                      'name': 'book_appointment',
                      'arguments': '{"slot": "Tomorrow 11:00"}',
                    },
                  },
                ],
              },
            },
          ],
        }),
        200,
        headers: {'content-type': 'application/json'},
      );
    });

    final llm = OpenAiCompatibleLlm(
      baseUrl: 'https://api.test/v1',
      apiKey: 'k',
      model: 'm',
      client: client,
    );
    final reply = await llm.replyWithTools(
      const [
        ChatMessage('user', 'book me'),
        ChatMessage(
          'assistant',
          '',
          toolCalls: [
            LlmToolCall(
              id: 'call_0',
              name: 'get_available_slots',
              arguments: {},
            ),
          ],
        ),
        ChatMessage('tool', '{"slots":[]}', toolCallId: 'call_0'),
      ],
      tools: [
        ToolDef(
          name: 'book_appointment',
          description: 'book it',
          parameters: const {'type': 'object'},
        ),
      ],
    );
    expect(reply.content, isNull);
    expect(reply.toolCalls.length, 1);
    expect(reply.toolCalls.first.name, 'book_appointment');
    expect(reply.toolCalls.first.id, 'call_1');
    expect(reply.toolCalls.first.arguments['slot'], 'Tomorrow 11:00');
  });

  test(
    'assistant tool-call message with empty content omits the content key',
    () async {
      final client = MockClient((request) async {
        final body = jsonDecode(request.body) as Map<String, dynamic>;
        final messages = body['messages'] as List;
        final assistant = messages.singleWhere(
          (m) => m['role'] == 'assistant' && m['tool_calls'] is List,
        );
        expect((assistant as Map).containsKey('content'), isFalse);
        return http.Response(
          jsonEncode({
            'choices': [
              {
                'message': {'content': 'done'},
              },
            ],
          }),
          200,
          headers: {'content-type': 'application/json'},
        );
      });

      final llm = OpenAiCompatibleLlm(
        baseUrl: 'https://api.test/v1',
        apiKey: 'k',
        model: 'm',
        client: client,
      );
      final reply = await llm.replyWithTools(const [
        ChatMessage('user', 'book me'),
        ChatMessage(
          'assistant',
          '',
          toolCalls: [
            LlmToolCall(
              id: 'call_0',
              name: 'get_available_slots',
              arguments: {},
            ),
          ],
        ),
        ChatMessage('tool', '{"slots":[]}', toolCallId: 'call_0'),
      ]);
      expect(reply.content, 'done');
    },
  );

  test(
    'reply returns empty completion error when content is missing',
    () async {
      final client = MockClient(
        (_) async => http.Response(
          jsonEncode({
            'choices': [
              {
                'message': {'content': null},
              },
            ],
          }),
          200,
          headers: {'content-type': 'application/json'},
        ),
      );
      final llm = OpenAiCompatibleLlm(
        baseUrl: 'https://api.test/v1',
        apiKey: 'k',
        model: 'm',
        client: client,
      );
      expect(
        () => llm.reply([const ChatMessage('user', 'x')]),
        throwsA(isA<LlmException>()),
      );
    },
  );

  test('OpenAiCompatibleLlm merges static and per-request headers', () async {
    String? firstSession;
    var calls = 0;
    final client = MockClient((request) async {
      calls++;
      expect(request.headers['x-opencode-client'], 'cli');
      expect(request.headers['User-Agent'], 'opencode/latest/cli');
      expect(request.headers['x-opencode-session'], isNotEmpty);
      expect(request.headers['x-opencode-project'], isNotEmpty);
      expect(request.headers['x-opencode-request'], isNotEmpty);
      if (firstSession == null) {
        firstSession = request.headers['x-opencode-session'];
      } else {
        expect(request.headers['x-opencode-session'], firstSession);
        expect(
          request.headers['x-opencode-request'],
          isNot(firstSession),
        );
      }
      return http.Response(
        jsonEncode({
          'choices': [
            {
              'message': {'content': 'hi'},
            },
          ],
        }),
        200,
        headers: {'content-type': 'application/json'},
      );
    });
    final llm = OpenAiCompatibleLlm(
      baseUrl: 'https://opencode.ai/zen/go/v1',
      apiKey: 'k',
      model: 'm',
      extraHeaders: const {
        'x-opencode-client': 'cli',
        'User-Agent': 'opencode/latest/cli',
        'x-opencode-session': 'sess',
        'x-opencode-project': 'proj',
      },
      requestHeaders: () => {'x-opencode-request': 'req-$calls'},
      client: client,
    );
    await llm.replyWithTools(const [ChatMessage('user', 'hi')]);
    await llm.replyWithTools(const [ChatMessage('user', 'hi')]);
    expect(calls, 2);
  });

  test('OpenAiCompatibleLlm does not add provider headers by default', () async {
    final client = MockClient((request) async {
      expect(request.headers['x-opencode-client'], isNull);
      expect(request.headers['User-Agent'], isNot('opencode/latest/cli'));
      return http.Response(
        jsonEncode({
          'choices': [
            {
              'message': {'content': 'hi'},
            },
          ],
        }),
        200,
        headers: {'content-type': 'application/json'},
      );
    });
    final llm = OpenAiCompatibleLlm(
      baseUrl: 'https://api.groq.com/openai/v1',
      apiKey: 'k',
      model: 'm',
      client: client,
    );
    await llm.replyWithTools(const [ChatMessage('user', 'hi')]);
  });

  test('llmFromEnv falls back to EchoLlm without explicit trio', () {
    expect(llmFromEnv(const {}), isA<EchoLlm>());
    expect(
      llmFromEnv(const {'VOICE_FORGE_LLM_API_KEY': 'k'}),
      isA<EchoLlm>(),
    );
  });

  test('llmFromEnv uses explicit VOICE_FORGE_LLM_* trio', () {
    final llm = llmFromEnv(const {
      'VOICE_FORGE_LLM_BASE_URL': 'https://api.example.com/v1',
      'VOICE_FORGE_LLM_API_KEY': 'k',
      'VOICE_FORGE_LLM_MODEL': 'custom-model',
    });
    expect(llm, isA<OpenAiCompatibleLlm>());
    final openAi = llm as OpenAiCompatibleLlm;
    expect(openAi.baseUrl, 'https://api.example.com/v1');
    expect(openAi.model, 'custom-model');
  });

  test('chainLlms wires FallbackLlm in order', () {
    final a = EchoLlm('a');
    final b = EchoLlm('b');
    final c = EchoLlm('c');
    final llm = chainLlms([a, b, c]);
    expect(llm, isA<FallbackLlm>());
    final outer = llm as FallbackLlm;
    expect(outer.fallback, same(c));
    final inner = outer.primary as FallbackLlm;
    expect(inner.primary, same(a));
    expect(inner.fallback, same(b));
  });

  test(
    'FallbackLlm falls through to the fallback on a single failure',
    () async {
      var primaryCalls = 0;
      final primary = _ThrowingLlm(() {
        primaryCalls++;
        throw LlmException('400: boom');
      });
      final fallback = EchoLlm('fallback reply');
      final llm = FallbackLlm(primary: primary, fallback: fallback);

      expect(
        await llm.reply([const ChatMessage('user', 'hi')]),
        'fallback reply',
      );
      expect(primaryCalls, 1);
    },
  );

  test('FallbackLlm switches providers after the failure threshold', () async {
    final primary = _ThrowingLlm(() => throw LlmException('400: boom'));
    final fallback = EchoLlm('fallback reply');
    final llm = FallbackLlm(
      primary: primary,
      fallback: fallback,
      failureThreshold: 2,
    );

    await llm.reply([const ChatMessage('user', 'hi')]);
    await llm.reply([const ChatMessage('user', 'hi')]);
    final third = await llm.reply([const ChatMessage('user', 'hi')]);
    expect(third, 'fallback reply');
    expect(primary.calls, 2); // third call went straight to the fallback
  });

  test('FallbackLlm recovers when the primary works again', () async {
    var failing = true;
    final primary = _ThrowingLlm(() {
      if (failing) throw LlmException('400: boom');
      return 'primary ok';
    });
    final llm = FallbackLlm(
      primary: primary,
      fallback: EchoLlm('fallback reply'),
    );

    expect(
      await llm.reply([const ChatMessage('user', 'hi')]),
      'fallback reply',
    );
    failing = false;
    expect(await llm.reply([const ChatMessage('user', 'hi')]), 'primary ok');
    expect(primary.calls, 2);
  });

  test('FallbackLlm marks a rate-limited primary down immediately', () async {
    final primary = _ThrowingLlm(() => throw LlmException('429: rate limit'));
    final fallback = EchoLlm('fallback reply');
    final llm = FallbackLlm(
      primary: primary,
      fallback: fallback,
      failureThreshold: 5,
    );

    // A single 429 marks it down (after one transient retry): the second
    // call skips the primary entirely.
    expect(
      await llm.reply([const ChatMessage('user', 'hi')]),
      'fallback reply',
    );
    expect(
      await llm.reply([const ChatMessage('user', 'hi')]),
      'fallback reply',
    );
    expect(primary.calls, 2);
  });

  test('FallbackLlm marks a 5xx server-error primary down immediately',
      () async {
    final primary = _ThrowingLlm(() => throw LlmException('503: boom'));
    final fallback = EchoLlm('fallback reply');
    final llm = FallbackLlm(
      primary: primary,
      fallback: fallback,
      failureThreshold: 5,
    );

    // A single 503 (endpoint unavailable) marks it down with no transient
    // retry: the second call skips the primary entirely.
    expect(
      await llm.reply([const ChatMessage('user', 'hi')]),
      'fallback reply',
    );
    expect(
      await llm.reply([const ChatMessage('user', 'hi')]),
      'fallback reply',
    );
    expect(primary.calls, 1);
  });

  test('FallbackLlm only marks down after the threshold for non-429', () async {
    final primary = _ThrowingLlm(() => throw LlmException('400: boom'));
    final fallback = EchoLlm('fallback reply');
    final llm = FallbackLlm(
      primary: primary,
      fallback: fallback,
      failureThreshold: 3,
    );

    await llm.reply([const ChatMessage('user', 'hi')]); // 1: still retries
    await llm.reply([const ChatMessage('user', 'hi')]); // 2: still retries
    expect(primary.calls, 2);
    await llm.reply([const ChatMessage('user', 'hi')]); // 3: marked down
    await llm.reply([const ChatMessage('user', 'hi')]); // skips primary
    expect(primary.calls, 3);
  });

  test(
    'FallbackLlm streams via the primary and falls back on failure',
    () async {
      var primaryCalls = 0;
      final primary = _ThrowingLlm(() {
        primaryCalls++;
        throw LlmException('400: boom');
      });
      final llm = FallbackLlm(primary: primary, fallback: EchoLlm('fb reply'));
      final partials = <String>[];
      final reply = await llm.streamReplyWithTools(const [
        ChatMessage('user', 'hi'),
      ], onPartial: partials.add);
      expect(reply.content, 'fb reply');
      expect(partials, ['fb reply']);
      expect(primaryCalls, 1);
    },
  );

  test('streamReplyWithTools parses SSE deltas and assembles tool calls', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final port = server.port;
    final sentBodies = <String>[];
    server.listen((req) async {
      sentBodies.add(await utf8.decoder.bind(req).join());
      final res = req.response
        ..statusCode = 200
        ..headers.contentType = ContentType('text', 'event-stream');
      // Written incrementally like a real provider: content deltas,
      // a reasoning delta (must never reach onPartial), then tool-call
      // fragments split across events.
      res.write(
        r'data: {"choices":[{"delta":{"role":"assistant","content":"Hello "}}]}'
        '\n\n',
      );
      await res.flush();
      res.write(
        r'data: {"choices":[{"delta":{"reasoning_content":"(thinking)"}}]}'
        '\n\n',
      );
      res.write(
        r'data: {"choices":[{"delta":{"content":"world"}}]}'
        '\n\n',
      );
      await res.flush();
      res.write(
        r'data: {"choices":[{"delta":{"tool_calls":[{"index":0,"id":"call_1",'
        r'"function":{"name":"get_available_slots","arguments":"{\"day\":\""}}]}}]}'
        '\n\n',
      );
      res.write(
        r'data: {"choices":[{"delta":{"tool_calls":[{"index":0,'
        r'"function":{"arguments":"tomorrow\"}"}}]}}]}'
        '\n\n',
      );
      res.write('data: [DONE]\n\n');
      await res.close();
    });

    final llm = OpenAiCompatibleLlm(
      baseUrl: 'http://127.0.0.1:$port/v1',
      apiKey: 'k',
      model: 'm',
    );
    final partials = <String>[];
    final reply = await llm.streamReplyWithTools(const [
      ChatMessage('user', 'hi'),
    ], onPartial: partials.add);
    await server.close(force: true);

    // Reasoning deltas skipped, content deltas delivered in order.
    expect(partials, ['Hello ', 'world']);
    expect(reply.content, 'Hello world');
    // Tool-call arguments assembled across the two fragments.
    expect(reply.toolCalls.length, 1);
    expect(reply.toolCalls.first.id, 'call_1');
    expect(reply.toolCalls.first.name, 'get_available_slots');
    expect(reply.toolCalls.first.arguments, {'day': 'tomorrow'});
    // The request asked for streaming, with the default max_tokens.
    final sent = jsonDecode(sentBodies.single) as Map<String, dynamic>;
    expect(sent['stream'], true);
    expect(sent['max_tokens'], 80);
    expect(sent.containsKey('stream_options'), isFalse);
  });

  test(
    'streamReplyWithTools falls back to plain JSON when SSE yields no deltas',
    () async {
      final client = MockClient(
        (_) async => http.Response(
          'data: {"choices":[{"message":{"content":"plain json reply"}}]}\n\n'
          'data: [DONE]\n\n',
          200,
          headers: {'content-type': 'text/event-stream'},
        ),
      );
      final llm = OpenAiCompatibleLlm(
        baseUrl: 'https://api.test/v1',
        apiKey: 'k',
        model: 'm',
        client: client,
      );
      final reply = await llm.streamReplyWithTools(const [
        ChatMessage('user', 'hi'),
      ]);
      expect(reply.content, 'plain json reply');
    },
  );

  test('streamReplyWithTools parses a plain JSON response when the provider '
      'ignores stream: true', () async {
    final client = MockClient((request) async {
      expect(jsonDecode(request.body)['stream'], true);
      return http.Response(
        jsonEncode({
          'choices': [
            {
              'message': {'content': 'plain reply'},
            },
          ],
        }),
        200,
        headers: {'content-type': 'application/json'},
      );
    });
    final llm = OpenAiCompatibleLlm(
      baseUrl: 'https://api.test/v1',
      apiKey: 'k',
      model: 'm',
      client: client,
    );
    final reply = await llm.streamReplyWithTools(const [
      ChatMessage('user', 'hi'),
    ]);
    expect(reply.content, 'plain reply');
  });

  test('streamReplyWithTools throws on a non-200 SSE error', () async {
    final client = MockClient(
      (_) async => http.Response(
        'data: {"error":{"message":"model exploded"}}\n\n',
        500,
        headers: {'content-type': 'text/event-stream'},
      ),
    );
    final llm = OpenAiCompatibleLlm(
      baseUrl: 'https://api.test/v1',
      apiKey: 'k',
      model: 'm',
      client: client,
    );
    expect(
      () => llm.streamReplyWithTools(const [ChatMessage('user', 'x')]),
      throwsA(isA<LlmException>()),
    );
  });

  test('streamReplyWithTools retries without tools on a tools 400', () async {
    var calls = 0;
    final client = MockClient((request) async {
      calls++;
      final body = jsonDecode(request.body) as Map<String, dynamic>;
      if (calls == 1) {
        expect(body['tools'], isNotNull);
        return http.Response(
          jsonEncode({
            'error': {'message': 'tools are not supported'},
          }),
          400,
          headers: {'content-type': 'application/json'},
        );
      }
      // Retry streams without the tools key.
      expect(body.containsKey('tools'), isFalse);
      return http.Response(
        'data: {"choices":[{"delta":{"content":"retried"}}]}\n\n'
        'data: [DONE]\n\n',
        200,
        headers: {'content-type': 'text/event-stream'},
      );
    });
    final llm = OpenAiCompatibleLlm(
      baseUrl: 'https://api.test/v1',
      apiKey: 'k',
      model: 'm',
      client: client,
    );
    final reply = await llm.streamReplyWithTools(
      const [ChatMessage('user', 'hi')],
      tools: [
        ToolDef(
          name: 'book_appointment',
          description: 'book it',
          parameters: const {'type': 'object'},
        ),
      ],
    );
    expect(calls, 2);
    expect(reply.content, 'retried');
  });

  test('maxTokens: 0 omits max_tokens from the request body', () async {
    final client = MockClient((request) async {
      final body = jsonDecode(request.body) as Map<String, dynamic>;
      expect(body.containsKey('max_tokens'), isFalse);
      return http.Response(
        jsonEncode({
          'choices': [
            {
              'message': {'content': 'ok'},
            },
          ],
        }),
        200,
        headers: {'content-type': 'application/json'},
      );
    });
    final llm = OpenAiCompatibleLlm(
      baseUrl: 'https://api.test/v1',
      apiKey: 'k',
      model: 'm',
      maxTokens: 0,
      client: client,
    );
    expect(
      (await llm.streamReplyWithTools(const [ChatMessage('user', 'x')]))
          .content,
      'ok',
    );
  });
}

class _ThrowingLlm implements VoicepipeLlm {
  final String Function() _call;
  int calls = 0;
  _ThrowingLlm(this._call);

  @override
  String get label => 'ThrowingLlm';

  @override
  Future<String> reply(List<ChatMessage> history, {int? maxTokens}) async {
    calls++;
    return _call();
  }

  @override
  Future<LlmReply> replyWithTools(
    List<ChatMessage> history, {
    List<ToolDef>? tools,
    int? maxTokens,
  }) async {
    calls++;
    return LlmReply(content: _call());
  }

  @override
  Future<LlmReply> streamReplyWithTools(
    List<ChatMessage> history, {
    List<ToolDef>? tools,
    void Function(String partial)? onPartial,
    int? maxTokens,
  }) async {
    calls++;
    return LlmReply(content: _call());
  }
}
