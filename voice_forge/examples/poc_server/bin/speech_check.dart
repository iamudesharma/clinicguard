/// Offline speech-stack check (no WebRTC): Silero VAD + Whisper STT +
/// Piper TTS against the bundled Obama.wav.
///
/// Run (from examples/poc_server):
///   dart run bin/speech_check.dart
library;

import 'dart:ffi';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:opus_codec_dart/opus_codec_dart.dart';
import 'package:voice_forge/voice_forge.dart';

void initOpusLibrary() {
  for (final path in ['/opt/homebrew/opt/opus/lib/libopus.dylib']) {
    try {
      initOpus(DynamicLibrary.open(path));
      return;
    } catch (_) {}
  }
}

Future<void> main() async {
  initOpusLibrary();

  const modelsDir = '../../models';
  final whisperModel = Platform.environment['VOICE_FORGE_WHISPER_MODEL'] ?? 'tiny';

  final sw = Stopwatch()..start();
  final kit = await SherpaKit.load(
    models: SherpaModels.fromModelsDir(modelsDir, whisperPrefix: whisperModel),
  );
  final vad = kit.createVad();
  final stt = kit.speech.stt;
  final tts = kit.speech.tts;
  print('sherpa-onnx ready (whisper=$whisperModel) in ${sw.elapsed.inSeconds}s');

  // --- STT + VAD ----------------------------------------------------------
  final wave = File('$modelsDir/Obama.wav').readAsBytesSync();
  final samples = Float32List((wave.length - 44) ~/ 2);
  for (var i = 0; i < samples.length; i++) {
    final offset = 44 + i * 2;
    samples[i] =
        (wave[offset] | (wave[offset + 1] << 8)).toSigned(16) / 32768.0;
  }
  print('Obama.wav: 16000 Hz, ${samples.length} samples');
  final ssw = Stopwatch()..start();
  final segments = <String>[];
  var offset = 0;
  while (offset < samples.length) {
    final take = min(vad.windowSize, samples.length - offset);
    final frame = Float32List.sublistView(samples, offset, offset + take);
    offset += take;
    final seg = vad.accept(frame);
    if (seg != null) {
      final text = stt.transcribe(seg);
      segments.add(text);
      print('  segment: "$text"');
    }
  }
  final tail = vad.flush();
  if (tail != null) {
    final text = stt.transcribe(tail);
    segments.add(text);
    print('  segment: "$text"');
  }
  print('STT: ${segments.length} segments in ${ssw.elapsed.inSeconds}s');

  // --- TTS ----------------------------------------------------------------
  final audio = tts.synthesize('Hello, I am your voice_forge agent.');
  final rms = audio.samples.isEmpty
      ? 0.0
      : sqrt(audio.samples.map((s) => s * s).reduce((a, b) => a + b) /
          audio.samples.length);
  print('TTS: ${audio.sampleRate} Hz, ${audio.samples.length} samples '
      '(${(audio.samples.length / audio.sampleRate).toStringAsFixed(1)}s), '
      'rms=${rms.toStringAsFixed(3)}');

  kit.dispose();
  final pass =
      segments.isNotEmpty && segments.join(' ').length > 20 && rms > 0.01;
  print(pass ? 'RESULT: PASS' : 'RESULT: FAIL');
  exit(pass ? 0 : 1);
}
