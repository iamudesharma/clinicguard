/// Pluggable speech interfaces for the voice agent.
///
/// The conversation loop depends only on these; sherpa-onnx ships one
/// implementation (`SherpaVad`/`SherpaStt`/`SherpaTts`), and any other
/// provider (cloud STT/TTS, different local engines) can plug in.
library;

import 'dart:typed_data';

/// Stream-segmentation VAD: feed 16 kHz mono float frames, receive completed
/// speech segments.
abstract interface class VoicepipeVAD {
  /// Required frame length in samples (Silero v5: 512 @ 16 kHz = 32 ms).
  int get windowSize;

  /// Feed one frame of exactly [windowSize] samples.
  /// Returns the completed speech segment (16 kHz mono) when an utterance
  /// just ended, otherwise null.
  Float32List? accept(Float32List frame);

  /// Flush pending state (call at call end; may emit a final segment).
  Float32List? flush();
}

/// Speech-to-text for completed segments.
abstract interface class VoicepipeSTT {
  /// Transcribe a 16 kHz mono float segment; returns the trimmed text.
  String transcribe(Float32List segment16k);
}

/// Text-to-speech output.
class TtsAudio {
  final Float32List samples;
  final int sampleRate;
  const TtsAudio({required this.samples, required this.sampleRate});
}

/// Text-to-speech for agent replies.
abstract interface class VoicepipeTTS {
  TtsAudio synthesize(String text);
}
