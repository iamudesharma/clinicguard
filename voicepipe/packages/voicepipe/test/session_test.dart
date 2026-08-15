import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:voicepipe/src/llm/llm.dart';
import 'package:voicepipe/src/session/agent_session.dart';
import 'package:voicepipe/src/speech/interfaces.dart';

/// Scripted VAD: emits one segment on the first window after reset.
class _FakeVad implements VoicepipeVAD {
  final int pendingSegments;
  _FakeVad({this.pendingSegments = 1});
  int _fired = 0;

  @override
  int get windowSize => 512;

  @override
  Float32List? accept(Float32List frame) {
    if (_fired >= pendingSegments) return null;
    _fired++;
    return Float32List.fromList(
        List.generate(16000, (i) => 0.1 * ((i % 50) / 50)));
  }

  @override
  Float32List? flush() => null;
}

class _FakeStt implements VoicepipeSTT {
  @override
  String transcribe(Float32List segment16k) => 'my name is priya';
}

class _FakeTts implements VoicepipeTTS {
  final List<String> spoken = [];
  @override
  TtsAudio synthesize(String text) {
    spoken.add(text);
    // 0.2s of audio at 16k (would become a few 20ms frames after upsampling)
    return TtsAudio(samples: Float32List(3200), sampleRate: 16000);
  }
}

class _FakeLlm implements VoicepipeLlm {
  final List<ChatMessage> seen = [];
  final String replyText;
  _FakeLlm([this.replyText = 'tell me more about your symptoms']);

  @override
  Future<String> reply(List<ChatMessage> history) async {
    seen.addAll(history);
    return replyText;
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
    await Future<void>.delayed(const Duration(milliseconds: 300));

    expect(tts.spoken.length, 1);
    expect(events.any((e) => e['type'] == 'user_transcript'), isTrue);
    expect(events.any((e) => e['type'] == 'assistant_text'), isTrue);
    expect(events.any((e) =>
        e['type'] == 'agent_state' && e['state'] == 'speaking'), isTrue);
    expect(events.any((e) =>
        e['type'] == 'agent_state' && e['state'] == 'listening'), isTrue);
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
    // Let it reach the speaking phase.
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(session.state, AgentState.speaking);

    session.interrupt();
    await Future<void>.delayed(const Duration(milliseconds: 300));
    expect(session.state, AgentState.listening);
    session.dispose();
  });

  test('generateSummary parses JSON from a wrapped LLM reply', () async {
    final llm = _FakeLlm(
        'Here you go: {"patient_name": "Priya", "chief_complaint": "fever", '
        '"symptoms": ["fever"], "urgency_level": "medium", "reason": "2 days", '
        '"recommendation": "see a doctor", "language": "English"}');
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
}
