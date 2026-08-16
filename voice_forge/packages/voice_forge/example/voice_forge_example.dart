import 'package:voice_forge/voice_forge.dart';

/// Minimal voice_forge usage: build the speech kit (auto-downloads the
/// native library and standard models on first run), plug in an LLM, and
/// create a session for one call.
Future<void> main() async {
  // 1. Speech stack — no manual setup: the first call downloads the
  //    prebuilt libsherpa-onnx-c-api (cache: ~/.cache/voice_forge/native/)
  //    and any missing models into 'models/'.
  final kit = await SherpaKit.load(
    models: SherpaModels.fromModelsDir('models'),
  );

  // 2. LLM — any OpenAI-compatible endpoint (or the offline EchoLlm).
  final llm = EchoLlm();

  // 3. Agent — one session per call, fresh VAD per session.
  final agent = VoiceAgent(
    vadFactory: kit.createVad,
    stt: kit.speech.stt,
    tts: kit.speech.tts,
    llm: llm,
    systemPrompt: 'You are a helpful voice assistant.',
  );
  final session = agent.createSession();

  session.events.listen((e) {
    print('[${e.payload['state']}] ${e.payload['text']}');
  });

  // 4. Feed decoded WebRTC audio (48 kHz stereo Int16 PCM).
  //    session.onAudio(pcm);

  print('agent ready; waiting for audio...');
  await Future<void>.delayed(const Duration(seconds: 1));
}
