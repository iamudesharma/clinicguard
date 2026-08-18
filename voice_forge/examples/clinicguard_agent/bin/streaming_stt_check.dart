/// Real integration test: loads the Zipformer streaming model and
/// transcribes the bundled Obama.wav test audio frame-by-frame.
///
/// Usage:
///   cd voice_forge/examples/clinicguard_agent
///   dart run bin/streaming_stt_check.dart
///
/// Expected output:
///   streaming STT: <model path>
///   partial transcripts: <count>
///   final transcript: <non-empty string>
///   RESULT: PASS

import 'dart:io';
import 'dart:typed_data';

import 'package:voice_forge/voice_forge.dart';

void main() async {
  // Resolve paths relative to the agent directory.
  final agentDir = Directory.current.path;
  final modelsDir = '$agentDir/../../models';

  final streamingDir =
      '$modelsDir/sherpa-onnx-streaming-zipformer-en-2023-06-26';
  if (!Directory(streamingDir).existsSync()) {
    print('ERROR: streaming model not found at $streamingDir');
    print('Run: cd voice_forge && bash scripts/fetch_models.sh');
    exit(1);
  }

  print('streaming STT: $streamingDir');

  // Load sherpa-onnx and create the kit.
  final kit = await SherpaKit.load(
    models: SherpaModels(
      sileroVad: '$modelsDir/silero_vad.onnx',
      whisperDir: '$modelsDir/sherpa-onnx-whisper-tiny',
      piperDir: '$modelsDir/vits-piper-en_US-lessac-medium-int8',
      streamingDir: streamingDir,
    ),
  );

  final streamingStt = kit.streamingStt;
  if (streamingStt == null) {
    print('ERROR: streamingStt is null after load');
    kit.dispose();
    exit(1);
  }

  // Load the test audio (Obama.wav — 16 kHz mono).
  final wavFile = File('$modelsDir/Obama.wav');
  if (!wavFile.existsSync()) {
    print('ERROR: Obama.wav not found');
    kit.dispose();
    exit(1);
  }
  final wavBytes = wavFile.readAsBytesSync();

  // Parse 16-bit PCM from the WAV (skip 44-byte header).
  final dataBytes = wavBytes.sublist(44);
  final sampleCount = dataBytes.length ~/ 2;
  final samples = Int16List(sampleCount);
  for (var i = 0; i < sampleCount; i++) {
    samples[i] = dataBytes[i * 2] | (dataBytes[i * 2 + 1] << 8);
  }

  // Convert to float32 [-1, 1].
  final floatSamples = Float32List(sampleCount);
  for (var i = 0; i < sampleCount; i++) {
    floatSamples[i] = samples[i] / 32768.0;
  }

  // Feed frames (512 samples = 32ms at 16 kHz).
  const frameSize = 512;
  final partials = <String>[];
  var lastPartial = '';

  for (var offset = 0; offset < floatSamples.length; offset += frameSize) {
    final end = (offset + frameSize < floatSamples.length)
        ? offset + frameSize
        : floatSamples.length;
    final frame = floatSamples.sublist(offset, end);

    final partial = streamingStt.acceptFrame(frame);
    if (partial.isNotEmpty && partial != lastPartial) {
      partials.add(partial);
      lastPartial = partial;
    }
  }

  // Finalize the utterance.
  final finalText = streamingStt.finalize();

  print('partial transcripts: ${partials.length}');
  if (partials.isNotEmpty) {
    print('  first: "${partials.first}"');
    print('  last:  "${partials.last}"');
  }
  print('final transcript: "$finalText"');

  // Verify results.
  final ok = finalText.trim().isNotEmpty;
  print('');
  print(ok ? 'RESULT: PASS' : 'RESULT: FAIL');

  kit.dispose();
  exit(ok ? 0 : 1);
}
