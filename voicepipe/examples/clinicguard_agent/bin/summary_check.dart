/// Standalone check of generateSummary (no transport): seeds history, calls
/// the LLM, prints the raw reply + parsed summary.
///   dart run bin/summary_check.dart
library;

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:voicepipe/voicepipe.dart';

const _systemPrompt = '''
You are "ClinicGuard", a multilingual clinical triage dispatcher for a
primary-care clinic. Ask ONE short question at a time. Finish with a clear
recommendation. Never diagnose. Urgency: low/medium/high/emergency.
''';

Future<void> main() async {
  final llm = llmFromEnv(Platform.environment);
  print('LLM: ${llm is EchoLlm ? "EchoLlm" : "OpenAI-compatible"}');

  final session = AgentSession(
    vad: _StubVad(),
    stt: _StubStt(),
    tts: _StubTts(),
    llm: llm,
    systemPrompt: _systemPrompt,
  );

  // Seed history like a real call: greeting, then one user turn through the
  // VAD/STT/LLM path (real LLM reply), then generate the summary.
  await session.greet('Namaste and welcome to the clinic. Please tell me '
      'your name, age, and what is bothering you.');

  // Trigger a segment: 60ms of audio fills one 512-sample VAD window and the
  // stub VAD returns a segment on its first accept.
  session.events.listen((e) => print('  event: ${e.payload['type']}: '
      '${e.payload['text'] ?? e.payload['state'] ?? ''}'));
  session.onAudio(Int16List(1920 * 3));
  print('state after onAudio: ${session.state}');
  await Future<void>.delayed(const Duration(seconds: 12));
  print('state after wait: ${session.state}');

  final summary = await session.generateSummary();
  print('parsed summary: $summary');
  session.dispose();
  exit(summary != null &&
          summary['chief_complaint'] is String &&
          (summary['chief_complaint'] as String).isNotEmpty
      ? 0
      : 1);
}

class _StubVad implements VoicepipeVAD {
  @override
  int get windowSize => 512;
  bool _fired = false;

  @override
  Float32List? accept(Float32List frame) {
    print('  [stub-vad] accept called, fired=$_fired');
    if (_fired) return null;
    _fired = true;
    // audible (non-silent) segment so the energy guard passes
    return Float32List.fromList(
        List.generate(16000, (i) => 0.1 * (i % 100) / 100));
  }

  @override
  Float32List? flush() => null;
}

class _StubStt implements VoicepipeSTT {
  @override
  String transcribe(Float32List segment16k) =>
      'My name is Priya, I am 30 years old, and I have had a fever and '
      'headache for two days.';
}

class _StubTts implements VoicepipeTTS {
  @override
  TtsAudio synthesize(String text) =>
      TtsAudio(samples: Float32List(1600), sampleRate: 16000);
}
