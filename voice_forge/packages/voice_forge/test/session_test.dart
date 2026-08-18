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

/// TTS whose synthesize never completes — simulates a wedged worker isolate.
class _HangingTts implements VoicepipeTTS {
  @override
  Future<TtsAudio> synthesize(String text) => Completer<TtsAudio>().future;
}

class _FakeLlm implements VoicepipeLlm {
  final List<ChatMessage> seen = [];
  final String replyText;
  final List<LlmToolCall> toolCalls;
  final bool rejectTools;
  final Completer<void>? gate; // await before replying, when set
  bool _toolCallsFired = false;

  @override
  String get label => 'FakeLlm';

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

/// Streaming STT that records every acceptFrame call and returns scripted
/// final texts. Mirrors the real recognizer lifecycle (reset -> frames ->
/// finalize) so we can assert the session feeds it the post-barge-in audio.
class _RecordingStreamingStt implements VoicepipeStreamingSTT {
  final List<int> framesFed = []; // acceptFrame call count, grows over time
  int _finalizeCount = 0;
  final List<String> finalTexts;

  _RecordingStreamingStt([this.finalTexts = const ['my name is priya']]);

  @override
  String acceptFrame(Float32List frame) {
    framesFed.add(1);
    return '';
  }

  @override
  String finalize() {
    final text =
        _finalizeCount < finalTexts.length ? finalTexts[_finalizeCount] : '';
    _finalizeCount++;
    return text;
  }

  @override
  void reset() {}

  @override
  void setLanguage(String lang) {}
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

  test(
    'streaming STT keeps receiving frames after a barge-in (regression: '
    'post-interrupt utterance is not starved)',
    () async {
      final gate = Completer<void>();
      final llm = _FakeLlm('answer to the new utterance', const [], false, gate);
      final tts = _FakeTts();
      // First finalize = the interrupted turn; second = the new utterance.
      final streamStt = _RecordingStreamingStt(
        ['first utterance', 'new utterance text'],
      );
      final session = AgentSession(
        vad: _FakeVad(perCall: 1, pendingSegments: 3), // one segment per burst
        stt: _FakeStt(),
        tts: tts,
        llm: llm,
        streamingStt: streamStt,
      );
      final events = <Map<String, dynamic>>[];
      session.events.listen((e) => events.add(e.payload));

      // Start a turn so the agent is busy (processing), then interrupt.
      session.onAudio(Int16List(1920 * 3));
      await waitForState(session, AgentState.thinking);
      session.interrupt();
      gate.complete();
      await Future<void>.delayed(const Duration(milliseconds: 300));

      final framesBefore = streamStt.framesFed.length;

      // The user keeps talking after the interrupt: feed loud audio (as the
      // VAD would during a real utterance).
      final loud = Int16List(1920 * 3);
      for (var i = 0; i < loud.length; i++) {
        loud[i] = i.isEven ? 6000 : -6000;
      }
      session.onAudio(loud);
      await Future<void>.delayed(const Duration(milliseconds: 200));

      // Frames must keep flowing into the recognizer after the interrupt;
      // the old `!_interrupt` guard starved it and the turn was lost.
      expect(streamStt.framesFed.length, greaterThan(framesBefore));

      // The new utterance's final text reaches the LLM and is spoken.
      await Future<void>.delayed(const Duration(milliseconds: 600));
      expect(
        llm.seen.any((m) => m.role == 'user' && m.content == 'new utterance text'),
        isTrue,
        reason: 'post-barge-in utterance must be transcribed and sent to the LLM',
      );
      expect(tts.spoken, isNotEmpty);
      session.dispose();
    },
  );

  test('TTS synthesis timeout does not hang the turn in speaking', () async {
    final llm = _FakeLlm('a reply that can never be spoken');
    // A TTS whose synthesize never completes: the wedged-worker case.
    final hangingTts = _HangingTts();
    final events = <Map<String, dynamic>>[];
    final session = AgentSession(
      vad: _FakeVad(),
      stt: _FakeStt(),
      tts: hangingTts,
      llm: llm,
      ttsTimeout: const Duration(milliseconds: 50),
    );
    session.events.listen((e) => events.add(e.payload));

    session.onAudio(Int16List(1920 * 3));
    // The turn should error out and return to listening instead of hanging.
    await waitForState(session, AgentState.thinking);
    await Future<void>.delayed(const Duration(milliseconds: 500));
    expect(
      events.any((e) => e['type'] == 'agent_error'),
      isTrue,
      reason: 'a wedged TTS must surface as an agent_error',
    );
    expect(session.state, AgentState.listening);
    session.dispose();
  });

  test('TtsChunker does not cut on "to"/"and" the way the old splitter did', () {
    final chunker = TtsChunker();
    // Token-sized chunks, as a streaming LLM emits them.
    const tokens = [
      "I'm ",
      'sorry ',
      'to ',
      'hear ',
      'that ',
      'you ',
      'have ',
      'been ',
      'feeling ',
      'unwell ',
      'today ',
      'and ',
      'I ',
      'need ',
      'to ',
      'ask ',
      'a ',
      'few ',
      'questions.',
    ];
    final pieces = <TtsPiece>[];
    for (final t in tokens) {
      pieces.addAll(chunker.add(t));
    }
    final rest = chunker.flush();
    if (rest != null) pieces.add(rest);

    expect(
      pieces.map((p) => p.text).toList(),
      ["I'm sorry to hear that you have been feeling unwell today and I need to ask a few questions."],
    );
    expect(pieces.single.reason, 'sentence');
  });

  test('TtsChunker waits for sentence end instead of comma splits', () {
    final chunker = TtsChunker();
    expect(chunker.add('Hello, how are you'), isEmpty);

    final pieces = chunker.add(
      ' doing today. I would like to know more about the pain.',
    );
    expect(pieces.length, 2);
    expect(pieces.first.reason, 'sentence');
    expect(pieces.first.text, 'Hello, how are you doing today.');
    expect(pieces.last.text, 'I would like to know more about the pain.');
  });
}
