/// Abstraction between the WebRTC transport and the audio pipeline.
library;

import 'dart:typed_data';

/// Implemented by the loopback demo or the [AgentSession] bridge.
abstract interface class AudioCore {
  /// Decoded caller audio: 48 kHz stereo interleaved int16, ~20 ms per call.
  void onDecodedPcm(Int16List pcm48kStereo);

  /// Frames the transport should Opus-encode and send to the caller
  /// (48 kHz stereo interleaved, 20 ms).
  Stream<Int16List> get outgoingPcm;

  /// Client-originated data-channel messages (e.g. {"event":"barge_in"}).
  void onDataMessage(Map<String, dynamic> message);

  /// Server-originated events published on the data channel (agent.events).
  Stream<Map<String, dynamic>> get events;

  /// The peer connection closed (call ended) — finalize/summarize here.
  void onPeerClosed() {}

  /// The `agent.events` data channel opened — safe to start speaking now.
  void onDataChannelOpen() {}

  /// Extra fields merged into the `connected` signaling message
  /// (e.g. {"room": "clinic-abc123"}).
  Map<String, dynamic>? get connectionInfo => null;
}
