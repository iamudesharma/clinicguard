import 'package:flutter_webrtc/flutter_webrtc.dart';

import 'barge_in_detector.dart';
import 'mic_tap.dart';

/// Native platforms: no raw mic PCM is exposed by flutter_webrtc, so the
/// client does not tap the mic. The agent's server-side Silero VAD plus its
/// instant onset gate already handle barge-in.
class _NoopMicTap implements MicTap {
  @override
  void start(MediaStream stream, BargeInDetector detector) {}

  @override
  void stop() {}
}

MicTap createMicTapImpl() => _NoopMicTap();
