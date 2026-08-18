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
///
/// Transcriptions are async: implementations may run the (potentially slow)
/// recognition off the caller's isolate, e.g. in a worker isolate, so the
/// voice loop stays responsive.
abstract interface class VoicepipeSTT {
  /// Transcribe a 16 kHz mono float segment; returns the trimmed text.
  Future<String> transcribe(Float32List segment16k);
}

/// Streaming speech-to-text: accepts partial transcripts while the user
/// is still speaking, and finalizes when the utterance ends.
///
/// Unlike [VoicepipeSTT] which requires a complete audio segment,
/// streaming STT processes audio frame-by-frame and returns partial
/// results that improve as more audio arrives.
abstract interface class VoicepipeStreamingSTT {
  /// Feed a 16 kHz mono float frame (typically 512 samples = 32ms).
  /// Returns a partial transcript that may improve with subsequent frames.
  String acceptFrame(Float32List frame);

  /// Finalize the current utterance and return the final transcript.
  /// Called when VAD emits a completed segment. Resets internal state
  /// for the next utterance.
  String finalize();

  /// Reset state for a new utterance (e.g. on barge-in).
  void reset();

  /// Set language hint for multilingual models (e.g. Nemotron 3.5).
  /// [lang] — e.g. 'en-US', 'hi-IN', or 'auto' for auto-detection.
  /// No-op for models that don't support language hints.
  void setLanguage(String lang) {}
}

/// Text-to-speech output.
class TtsAudio {
  final Float32List samples;
  final int sampleRate;
  const TtsAudio({required this.samples, required this.sampleRate});
}

/// Text-to-speech for agent replies.
///
/// Synthesis is async like [VoicepipeSTT] (see its doc comment).
abstract interface class VoicepipeTTS {
  Future<TtsAudio> synthesize(String text);
}
