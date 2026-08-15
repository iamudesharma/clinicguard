import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:livekit_client/livekit_client.dart';
// ignore: implementation_imports - createAudioFrameCapture isn't publicly exported
import 'package:livekit_client/src/audio/audio_frame_capture.dart'
    as audio_capture;

import 'barge_in_detector.dart';

/// Wires local mic capture -> energy VAD -> instant ducking + agent signal.
///
/// On speech start:
///   1. locally disables the agent's remote audio track (instant silence),
///   2. publishes {"event":"barge_in"} over the `agent.events` data channel so
///      the Python agent calls `session.interrupt()` and stops generating.
/// On speech end the agent track is re-enabled after a short hold-off.
class BargeInController {
  static const String _topic = 'agent.events';

  late final Room _room;
  late final BargeInDetector _detector;

  audio_capture.AudioFrameCapture? _capture;
  StreamSubscription<audio_capture.AudioFrame>? _frames;
  RemoteAudioTrack? _agentTrack;
  Timer? _rearmTimer;
  bool _ducked = false;

  // ignore: prefer_initializing_formals - keep the public parameter name
  BargeInController({required Room room}) {
    _room = room;
    _detector = BargeInDetector(
      onSpeechStart: _noop,
      onSpeechEnd: _noop,
    );
  }
  static void _noop() {}

  /// Start detecting barge-in on the local mic track.
  Future<void> start(LocalAudioTrack micTrack) async {
    _detector
      ..reset()
      ..onSpeechStart = _handleSpeechStart
      ..onSpeechEnd = _handleSpeechEnd;

    final capture = audio_capture.createAudioFrameCapture();
    _capture = capture;
    final started = await capture.start(
      track: micTrack.mediaStreamTrack,
      rendererId: 'barge-in-vad',
      sampleRate: 16000,
      channels: 1,
      format: audio_capture.AudioFormat.Int16,
    );
    if (!started) {
      debugPrint('[barge-in] audio frame capture failed to start');
      return;
    }
    _frames = capture.frameStream.listen(
      _detector.process,
      onError: (Object e) => debugPrint('[barge-in] frame stream error: $e'),
    );
    debugPrint('[barge-in] detector armed');
  }

  /// Provide the agent's audio track (discovered when the agent joins).
  void setAgentTrack(RemoteAudioTrack? track) {
    _agentTrack = track;
  }

  Future<void> stop() async {
    _rearmTimer?.cancel();
    await _frames?.cancel();
    await _capture?.stop();
    _frames = null;
    _capture = null;
    _ducked = false;
    await _agentTrack?.enable();
  }

  bool get isDucked => _ducked;

  void _handleSpeechStart() {
    debugPrint('[barge-in] speech detected');
    if (_ducked) return;
    _ducked = true;
    _agentTrack?.disable(); // instant local silence
    _publish({'event': 'barge_in'});
  }

  void _handleSpeechEnd() {
    // give the agent a beat to acknowledge the interrupt before re-arming audio
    _rearmTimer?.cancel();
    _rearmTimer = Timer(const Duration(milliseconds: 250), () async {
      _ducked = false;
      await _agentTrack?.enable();
    });
  }

  void _publish(Map<String, dynamic> payload) {
    try {
      final bytes = utf8.encode(jsonEncode(payload));
      _room.localParticipant?.publishData(
        bytes,
        reliable: true,
        topic: _topic,
      );
    } catch (e) {
      debugPrint('[barge-in] publish failed: $e');
    }
  }
}
