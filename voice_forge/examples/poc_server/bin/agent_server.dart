/// voice_forge Phase 2 agent server: real voice agent over WebRTC.
///
///   Flutter/web client --WebRTC--> webrtc_dart --Opus decode--> AgentSession
///                                     ^                         |
///                                     |                 VAD -> Whisper STT
///                                     |                         |
///                                     |            LLM (Groq/OpenAI/
///                                     |            OpenRouter/Echo)
///                                     |                         |
///                                     +---Opus encode---- Piper TTS
///
/// Events are published on the data channel topic "agent.events" using the
/// ClinicGuard contract: user_transcript / assistant_text / agent_state.
///
/// Run (models + native lib must be present; see scripts/):
///   dart run bin/agent_server.dart
///
/// Env: GROQ_API_KEY / OPENAI_API_KEY (or VOICE_FORGE_LLM_*), and
///      VOICE_FORGE_WHISPER_MODEL=tiny|base (default tiny).
library;

import 'dart:async';
import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:opus_codec_dart/opus_codec_dart.dart';
import 'package:voice_forge/voice_forge.dart';

// Models live in the voice_forge repo root (run from examples/poc_server).
const _modelsDir = '../../models';

void initOpusLibrary() {
  for (final path in [
    '/opt/homebrew/opt/opus/lib/libopus.dylib',
    '/opt/homebrew/lib/libopus.dylib',
    '/usr/local/lib/libopus.dylib',
    'libopus.dylib',
    'libopus.so.0',
  ]) {
    try {
      initOpus(DynamicLibrary.open(path));
      return;
    } catch (_) {}
  }
  throw StateError('libopus not found (brew install opus)');
}

class AgentCore implements AudioCore {
  final AgentSession session;
  final _events = StreamController<Map<String, dynamic>>.broadcast();

  AgentCore(this.session) {
    session.events.listen((e) => _events.add(e.payload));
  }

  @override
  void onDecodedPcm(Int16List pcm48kStereo) {
    session.onAudio(pcm48kStereo);
  }

  @override
  Stream<Int16List> get outgoingPcm => session.ttsAudio;

  @override
  void onDataMessage(Map<String, dynamic> message) {
    if (message['event'] == 'barge_in') {
      stdout.writeln('[agent] barge-in from client');
      session.interrupt();
    }
  }

  @override
  Stream<Map<String, dynamic>> get events => _events.stream;

  @override
  void onPeerClosed() {}

  @override
  void onDataChannelOpen() {}

  @override
  Map<String, dynamic>? get connectionInfo => null;

  void dispose() {
    session.dispose();
    _events.close();
  }
}

Future<void> main() async {
  initOpusLibrary();

  final whisperModel =
      Platform.environment['VOICE_FORGE_WHISPER_MODEL'] ?? 'tiny';
  stdout.writeln('loading sherpa-onnx + models from $_modelsDir '
      '(whisper=$whisperModel) ...');
  final sw = Stopwatch()..start();
  final kit = await SherpaKit.load(
    models: SherpaModels.fromModelsDir(_modelsDir,
        whisperPrefix: whisperModel),
  );
  stdout.writeln('sherpa-onnx ready in ${sw.elapsed.inSeconds}s');

  final llm = llmFromEnv(Platform.environment);
  stdout.writeln('LLM: '
      '${llm is EchoLlm ? "EchoLlm (offline demo; set GROQ_API_KEY/OPENAI_API_KEY for real replies)" : "OpenAI-compatible"}');

  // STT/TTS run in a worker isolate so speech never blocks the LLM turn;
  // VAD stays on the main isolate (cheap, one stateful instance per call).
  final speech = await kit.createWorkerSpeech();

  final agent = VoiceAgent(
    vadFactory: kit.createVad,
    stt: speech.stt,
    tts: speech.tts,
    llm: llm,
  );

  await runVoiceCallServer(
    coreFactory: () => AgentCore(agent.createSession()),
  );
}
