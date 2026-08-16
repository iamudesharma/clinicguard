import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:voice_forge/src/llm/llm.dart';
import 'package:voice_forge/src/session/agent_session.dart';
import 'package:voice_forge/src/speech/interfaces.dart';

/// Scripted VAD: emits one segment per [pendingSegments] window(s).
class _FakeVad implements VoicepipeVAD {
  final int pendingSegments;
  final int
  perCall; // emit one segment every `perCall` windows (0 = every window)
  _FakeVad({this.pendingSegments = 1, this.perCall = 0});
  int _fired = 0;

  @override
  int get windowSize => 512;

  @override
  Float32List? accept(Float32List frame) {
    _fired++;
    if (perCall != 0) {
      if (_fired % perCall != 0) return null;
      if (_fired ~/ perCall > pendingSegments) return null;
    } else if (_fired > pendingSegments) {
      return null;
    }
    return Float32List.fromList(
      List.generate(16000, (i) => 0.1 * ((i % 50) / 50)),
    );
  }

  @override
  Float32List? flush() => null;
}

class _FakeStt implements VoicepipeSTT {
  @override
  Future<String> transcribe(Float32List segment16k) async => 'my name is priya';
}

class _FakeTts implements VoicepipeTTS {
  final List<String> spoken = [];
  @override
  Future<TtsAudio> synthesize(String text) async {
    spoken.add(text);
    // 0.2s of audio at 16k (would become a few 20ms frames after upsampling)
    return TtsAudio(samples: Float32List(3200), sampleRate: 16000);
  }
}

class _FakeLlm implements VoicepipeLlm {
  final List<ChatMessage> seen = [];
  final String replyText;
  final List<LlmToolCall> toolCalls;
  final bool rejectTools;
  final Completer<void>? gate; // await before replying, when set
  bool _toolCallsFired = false;
  _FakeLlm([
    this.replyText = 'tell me more about your symptoms',
    this.toolCalls = const [],
    this.rejectTools = false,
    this.gate,
  ]);

  @override
  Future<String> reply(List<ChatMessage> history, {int? maxTokens}) async {
    seen.addAll(history);
    if (gate != null) await gate!.future;
    return replyText;
  }

  @override
  Future<LlmReply> replyWithTools(
    List<ChatMessage> history, {
    List<ToolDef>? tools,
    int? maxTokens,
  }) async {
    seen.addAll(history);
    if (gate != null) await gate!.future;
    if (rejectTools) throw LlmException('400: tools not supported');
    if (!_toolCallsFired && toolCalls.isNotEmpty) {
      _toolCallsFired = true; // only fire once, then reply normally
      return LlmReply(toolCalls: toolCalls);
    }
    return LlmReply(content: replyText);
  }

  @override
  Future<LlmReply> streamReplyWithTools(
    List<ChatMessage> history, {
    List<ToolDef>? tools,
    void Function(String partial)? onPartial,
    int? maxTokens,
  }) async {
    seen.addAll(history);
    if (gate != null) await gate!.future;
    if (rejectTools) throw LlmException('400: tools not supported');
    if (!_toolCallsFired && toolCalls.isNotEmpty) {
      _toolCallsFired = true; // only fire once, then reply normally
      return LlmReply(toolCalls: toolCalls);
    }
    final reply = LlmReply(content: replyText);
    if (reply.content != null && onPartial != null) {
      onPartial(reply.content!);
    }
    return reply;
  }
}

/// Poll until [session] reaches [state] (turn starts after the merge window).
Future<void> waitForState(AgentSession session, AgentState state) async {
  for (var i = 0; i < 100; i++) {
    if (session.state == state) return;
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
}

void main() {
  test('greeting is spoken and seeds history', () async {
    final tts = _FakeTts();
    final session = AgentSession(
      vad: _FakeVad(pendingSegments: 0),
      stt: _FakeStt(),
      tts: tts,
      llm: _FakeLlm(),
    );
    await session.greet('namaste and welcome');
    expect(tts.spoken, ['namaste and welcome']);
    session.dispose();
  });

  test('one utterance flows VAD -> STT -> LLM -> TTS with events', () async {
    final llm = _FakeLlm();
    final tts = _FakeTts();
    final session = AgentSession(
      vad: _FakeVad(),
      stt: _FakeStt(),
      tts: tts,
      llm: llm,
    );

    final events = <Map<String, dynamic>>[];
    session.events.listen((e) => events.add(e.payload));

    session.onAudio(Int16List(1920 * 3)); // 60ms -> one VAD window
    await Future<void>.delayed(const Duration(milliseconds: 800));

    expect(tts.spoken.length, 1);
    expect(events.any((e) => e['type'] == 'user_transcript'), isTrue);
    expect(events.any((e) => e['type'] == 'assistant_text'), isTrue);
    expect(
      events.any((e) => e['type'] == 'agent_state' && e['state'] == 'speaking'),
      isTrue,
    );
    expect(
      events.any(
        (e) => e['type'] == 'agent_state' && e['state'] == 'listening',
      ),
      isTrue,
    );
    session.dispose();
  });

  test('barge-in during speaking cuts the reply short', () async {
    final tts = _FakeTts();
    final session = AgentSession(
      vad: _FakeVad(),
      stt: _FakeStt(),
      tts: tts,
      llm: _FakeLlm('a somewhat long reply to interrupt'),
    );
    final events = <Map<String, dynamic>>[];
    session.events.listen((e) => events.add(e.payload));

    session.onAudio(Int16List(1920 * 3));
    // Let it reach the speaking phase (turn starts after the merge window).
    await waitForState(session, AgentState.speaking);
    expect(session.state, AgentState.speaking);

    session.interrupt();
    await Future<void>.delayed(const Duration(milliseconds: 300));
    expect(session.state, AgentState.listening);
    session.dispose();
  });

  test(
    'onset barge-in stops the agent as soon as the user starts talking',
    () async {
      final tts = _FakeTts();
      final session = AgentSession(
        vad: _FakeVad(),
        stt: _FakeStt(),
        tts: tts,
        llm: _FakeLlm('a somewhat long reply to interrupt'),
        bargeInRmsThreshold: 0.05,
        bargeInOnsetFrames: 2,
      );
      final events = <Map<String, dynamic>>[];
      session.events.listen((e) => events.add(e.payload));

      session.onAudio(Int16List(1920 * 3)); // silence starts a turn
      await waitForState(session, AgentState.speaking);
      expect(session.state, AgentState.speaking);

      // User starts talking: loud frames (~0.18 RMS) over the agent.
      final loud = Int16List(1920 * 3);
      for (var i = 0; i < loud.length; i++) {
        loud[i] = i.isEven ? 6000 : -6000;
      }
      session.onAudio(loud);
      await Future<void>.delayed(const Duration(milliseconds: 300));
      expect(session.state, AgentState.listening);
      expect(
        events.any(
          (e) => e['type'] == 'agent_state' && e['state'] == 'listening',
        ),
        isTrue,
      );
      session.dispose();
    },
  );

  test('addSystemContext injects a system message the LLM sees', () async {
    final llm = _FakeLlm();
    final session = AgentSession(
      vad: _FakeVad(),
      stt: _FakeStt(),
      tts: _FakeTts(),
      llm: llm,
    );
    await session.greet('namaste and welcome');
    session.addSystemContext(
      'PATIENT CONTEXT: name Asha, allergies penicillin',
    );

    session.onAudio(Int16List(1920 * 3));
    await Future<void>.delayed(const Duration(milliseconds: 800));

    expect(
      llm.seen.any(
        (m) => m.role == 'system' && m.content.contains('penicillin'),
      ),
      isTrue,
    );
    session.dispose();
  });

  test('generateSummary parses JSON from a wrapped LLM reply', () async {
    final llm = _FakeLlm(
      'Here you go: {"patient_name": "Priya", "chief_complaint": "fever", '
      '"symptoms": ["fever"], "urgency_level": "medium", "reason": "2 days", '
      '"recommendation": "see a doctor", "language": "English"}',
    );
    final session = AgentSession(
      vad: _FakeVad(),
      stt: _FakeStt(),
      tts: _FakeTts(),
      llm: llm,
    );
    final summary = await session.generateSummary();
    expect(summary, isNotNull);
    expect(summary!['patient_name'], 'Priya');
    expect(summary['chief_complaint'], 'fever');
    session.dispose();
  });

  test('tool calls are executed and the final content is spoken', () async {
    final llm = _FakeLlm('The clinic has a slot tomorrow at 11:00.', [
      LlmToolCall(
        id: 'call_1',
        name: 'get_available_slots',
        arguments: const {},
      ),
    ]);
    final executed = <String>[];
    final session = AgentSession(
      vad: _FakeVad(),
      stt: _FakeStt(),
      tts: _FakeTts(),
      llm: llm,
    );
    session.configure(
      tools: [
        ToolDef(
          name: 'get_available_slots',
          description: 'list slots',
          parameters: const {'type': 'object', 'properties': {}},
        ),
      ],
      toolExecutor: (call) async {
        executed.add(call.name);
        return jsonEncode({
          'slots': [
            {'label': 'Tomorrow 11:00'},
          ],
        });
      },
    );

    session.onAudio(Int16List(1920 * 3));
    await Future<void>.delayed(const Duration(milliseconds: 800));

    expect(executed, ['get_available_slots']);
    expect(
      llm.seen.any(
        (m) => m.role == 'assistant' && m.toolCalls?.isNotEmpty == true,
      ),
      isTrue,
    );
    expect(
      llm.seen.any((m) => m.role == 'tool' && m.toolCallId == 'call_1'),
      isTrue,
    );
    expect(
      llm.seen.any(
        (m) => m.role == 'tool' && m.content.contains('Tomorrow 11:00'),
      ),
      isTrue,
    );
    session.dispose();
  });

  test('knowledge provider output is injected per turn', () async {
    final llm = _FakeLlm();
    final session = AgentSession(
      vad: _FakeVad(),
      stt: _FakeStt(),
      tts: _FakeTts(),
      llm: llm,
    );
    session.configure(
      knowledgeProvider: (userText) async => 'KNOWLEDGE: fever care tips',
    );

    session.onAudio(Int16List(1920 * 3));
    await Future<void>.delayed(const Duration(milliseconds: 800));

    expect(
      llm.seen.any(
        (m) =>
            m.role == 'system' &&
            m.content.contains('KNOWLEDGE: fever care tips'),
      ),
      isTrue,
    );
    session.dispose();
  });

  test('falls back to plain reply when the provider rejects tools', () async {
    final tts = _FakeTts();
    final llm = _FakeLlm('no tools for you', const [], true);
    final session = AgentSession(
      vad: _FakeVad(),
      stt: _FakeStt(),
      tts: tts,
      llm: llm,
    );
    session.configure(
      tools: [
        ToolDef(
          name: 'get_available_slots',
          description: 'list slots',
          parameters: const {'type': 'object', 'properties': {}},
        ),
      ],
      toolExecutor: (call) async => '{}',
    );

    session.onAudio(Int16List(1920 * 3));
    await Future<void>.delayed(const Duration(milliseconds: 800));

    expect(tts.spoken, ['no tools for you']);
    session.dispose();
  });

  test('segments close in time merge into a single turn', () async {
    final llm = _FakeLlm();
    final tts = _FakeTts();
    final session = AgentSession(
      vad: _FakeVad(pendingSegments: 2),
      stt: _FakeStt(),
      tts: tts,
      llm: llm,
    );

    session.onAudio(Int16List(1920 * 3)); // two VAD segments in one burst
    await Future<void>.delayed(const Duration(milliseconds: 900));

    final userMsgs = llm.seen.where((m) => m.role == 'user').toList();
    expect(userMsgs.length, 1); // merged: one utterance, one LLM turn
    expect(tts.spoken.length, 1);
    session.dispose();
  });

  test(
    'barge-in drops stale queued segments before the LLM hears them',
    () async {
      final gate = Completer<void>();
      final llm = _FakeLlm('reply text', const [], false, gate);
      final tts = _FakeTts();
      final events = <Map<String, dynamic>>[];
      final session = AgentSession(
        vad: _FakeVad(
          pendingSegments: 3,
          perCall: 1,
        ), // one segment per onAudio
        stt: _FakeStt(),
        tts: tts,
        llm: llm,
      );
      session.events.listen((e) => events.add(e.payload));

      // 3072 int16 samples -> exactly one 512-sample VAD window (no leftover),
      // so each onAudio call yields exactly one segment.
      session.onAudio(Int16List(3072)); // segment 1 -> turn in flight
      await waitForState(session, AgentState.thinking);

      session.onAudio(Int16List(3072)); // segment 2 -> queued (stale)
      await Future<void>.delayed(const Duration(milliseconds: 50));

      session.interrupt(); // new utterance: queue dropped, epoch bumped
      gate.complete();
      await Future<void>.delayed(const Duration(milliseconds: 300));
      // Segment 1's reply was stale by the time the LLM finished: never spoken.
      expect(tts.spoken, isEmpty);

      session.onAudio(Int16List(3072)); // segment 3 -> the new utterance
      await Future<void>.delayed(const Duration(milliseconds: 900));

      // One transcript per real user turn: segments 1 + 3 (2), stale 2 dropped.
      final transcripts = events
          .where((e) => e['type'] == 'user_transcript')
          .length;
      expect(transcripts, 2);
      expect(tts.spoken.length, 1); // only segment 3's reply is spoken
      session.dispose();
    },
  );

  test('in-flight turn aborts when the user starts a new utterance', () async {
    final gate = Completer<void>();
    final llm = _FakeLlm('stale reply', const [], false, gate);
    final tts = _FakeTts();
    final session = AgentSession(
      vad: _FakeVad(),
      stt: _FakeStt(),
      tts: tts,
      llm: llm,
    );

    session.onAudio(Int16List(1920 * 3)); // turn starts, LLM gated
    await waitForState(session, AgentState.thinking);

    session.interrupt(); // user starts talking before the reply lands
    gate.complete();
    await Future<void>.delayed(const Duration(milliseconds: 300));

    // The stale reply was dropped: no transcript, no history, no speech.
    expect(tts.spoken, isEmpty);
    expect(
      llm.seen.where((m) => m.role == 'user').length,
      1, // user message recorded, but the assistant reply never was
    );
    session.dispose();
  });
}
