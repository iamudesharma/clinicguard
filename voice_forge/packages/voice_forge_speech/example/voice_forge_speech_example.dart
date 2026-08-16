import 'package:voice_forge_speech/voice_forge_speech.dart';

/// Minimal voice_forge_speech usage: initialize the native bindings and
/// create a Silero VAD. The native `libsherpa-onnx-c-api` library must be
/// loadable by the process (see the README; the voice_forge framework
/// downloads it automatically on first run).
Future<void> main() async {
  // One-time binding init (must run in every isolate that uses sherpa).
  initBindings();

  final vad = VoiceActivityDetector(
    config: VadModelConfig(
      sileroVad: SileroVadModelConfig(model: 'silero_vad.onnx'),
    ),
    bufferSizeInSeconds: 30,
  );

  print('VAD ready');
  vad.free();
}
