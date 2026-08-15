import 'dart:math';

// ignore: implementation_imports - createAudioFrameCapture isn't publicly exported
import 'package:livekit_client/src/audio/audio_frame_capture.dart'
    show AudioFrame;

/// Energy-based voice activity detection for instant local barge-in.
///
/// Processes raw PCM frames from [AudioFrameCapture] and detects speech using an
/// RMS threshold with hangover counters (voiced/silent frame counts). Runs fully
/// on-device with no native dependencies — the server-side Silero VAD remains the
/// authoritative barge-in detector; this one exists purely for instant local
/// ducking + a fast data-channel signal to the agent.
class BargeInDetector {
  /// RMS (0..1) above which a 20ms window counts as voiced.
  final double rmsThreshold;

  /// Consecutive voiced windows required to declare speech start (~40-60ms).
  final int voicedFramesToStart;

  /// Consecutive silent windows required to declare speech end (~200-300ms).
  final int silentFramesToEnd;

  /// Called once when speech starts (barge-in moment).
  void Function() onSpeechStart;

  /// Called once when speech ends.
  void Function() onSpeechEnd;

  BargeInDetector({
    this.rmsThreshold = 0.025,
    this.voicedFramesToStart = 2,
    this.silentFramesToEnd = 12,
    required this.onSpeechStart,
    required this.onSpeechEnd,
  });

  static const int _windowSizeSamples = 320; // 20ms at 16kHz

  final List<double> _window = List.filled(_windowCapacity, 0);
  static const int _windowCapacity = 1024;
  int _windowCount = 0;
  bool _speaking = false;
  int _voicedRun = 0;
  int _silentRun = 0;

  /// Feed a raw PCM frame (int16) captured from the microphone.
  void process(AudioFrame frame) {
    final data = frame.data;
    final channels = frame.channels;

    for (var i = 0; i + 1 < data.length; i += 2) {
      // int16 little-endian -> sample in [-1, 1]
      final raw = data[i] | (data[i + 1] << 8);
      final sample = (raw >= 32768 ? raw - 65536 : raw) / 32768.0;
      _window[_windowCount++] = sample;
      if (_windowCount >= _windowSizeSamples) {
        _onWindowComplete(channels);
        _windowCount = 0;
      }
    }
  }

  void _onWindowComplete(int channels) {
    var sumSq = 0.0;
    for (final s in _window) {
      sumSq += s * s;
    }
    final rms = sqrt(sumSq / _windowSizeSamples);
    final voiced = rms >= rmsThreshold;

    if (!_speaking) {
      _voicedRun = voiced ? _voicedRun + 1 : 0;
      if (_voicedRun >= voicedFramesToStart) {
        _speaking = true;
        _voicedRun = 0;
        _silentRun = 0;
        onSpeechStart();
      }
    } else {
      _silentRun = voiced ? 0 : _silentRun + 1;
      if (_silentRun >= silentFramesToEnd) {
        _speaking = false;
        _silentRun = 0;
        onSpeechEnd();
      }
    }
  }

  bool get isSpeaking => _speaking;

  void reset() {
    _speaking = false;
    _voicedRun = 0;
    _silentRun = 0;
    _windowCount = 0;
  }
}
