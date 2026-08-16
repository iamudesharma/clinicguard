import 'package:flutter_webrtc/flutter_webrtc.dart';

import 'barge_in_detector.dart';
import 'mic_tap_stub.dart' if (dart.library.js_interop) 'mic_tap_web.dart';

/// Taps the local microphone PCM so the app can detect the user starting to
/// speak *while the agent is talking* and send an instant `barge_in` over the
/// data channel (ChatGPT-style interruption, ~100 ms instead of waiting for
/// the server's Silero VAD, which only fires when the utterance ends).
abstract class MicTap {
  /// Start feeding PCM from [stream] into [detector]. Safe to call once per
  /// call; call [stop] on hang-up.
  void start(MediaStream stream, BargeInDetector detector);

  void stop();
}

/// Platform factory: on web this is an AudioContext tap on the mic stream;
/// on native platforms (iOS/Android/macOS) it is a no-op and barge-in is
/// handled server-side by the agent's own VAD + onset gate.
MicTap createMicTap() => createMicTapImpl();
