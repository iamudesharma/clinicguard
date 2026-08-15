/// One voice call to a voicepipe agent server.
///
/// Wraps flutter_webrtc + WebSocket signaling:
///  - microphone -> RTCPeerConnection (Opus)
///  - agent audio plays automatically on the remote track
///  - data channel `agent.events` carries the voicepipe event contract
///    (`user_transcript`, `assistant_text`, `agent_state`, ...) plus
///    ping/pong RTT probes
///  - `sendBargeIn()` sends {"event":"barge_in"} for instant interrupts
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

enum VoiceCallPhase { idle, connecting, connected, error }

class VoiceCallController {
  final String signalingUrl;
  final Map<String, dynamic>? iceServers;
  final String dataChannelLabel;

  final StreamController<VoiceCallPhase> _phase =
      StreamController<VoiceCallPhase>.broadcast();
  final StreamController<Map<String, dynamic>> _events =
      StreamController<Map<String, dynamic>>.broadcast();
  final StreamController<int> _rtt = StreamController<int>.broadcast();

  WebSocketChannel? _ws;
  RTCPeerConnection? _pc;
  RTCDataChannel? _dc;
  MediaStream? _localStream;
  RTCVideoRenderer? _remoteRenderer;
  Timer? _pingTimer;
  int _pingSeq = 0;
  final Map<String, int> _pendingPings = {};
  Future<void> _signalChain = Future<void>.value();
  bool _answerReceived = false;

  VoiceCallController({
    required this.signalingUrl,
    this.iceServers,
    this.dataChannelLabel = 'agent.events',
  });

  /// Call lifecycle (idle -> connecting -> connected / error).
  Stream<VoiceCallPhase> get phase => _phase.stream;

  /// Parsed data-channel messages (the voicepipe event contract).
  Stream<Map<String, dynamic>> get events => _events.stream;

  /// Measured data-channel round-trip times (ms), one per ping.
  Stream<int> get rttMs => _rtt.stream;

  bool _micEnabled = false;
  bool get micEnabled => _micEnabled;

  bool _started = false;
  bool get isStarted => _started;

  Future<void> start() async {
    if (_started) return;
    _started = true;
    _phase.add(VoiceCallPhase.connecting);

    try {
      // 1. microphone
      final stream = await navigator.mediaDevices.getUserMedia({
        'audio': true,
        'video': false,
      });
      _localStream = stream;
      _micEnabled = true;

      // 2. peer connection
      final pc = await createPeerConnection({
        'iceServers': iceServers ??
            [
              {'urls': ['stun:stun.l.google.com:19302']},
            ],
      });
      _pc = pc;

      pc.onIceCandidate = (c) {
        _ws?.sink.add(jsonEncode({
          'type': 'candidate',
          'candidate': {
            'candidate': c.candidate,
            'sdpMid': c.sdpMid,
            'sdpMLineIndex': c.sdpMLineIndex,
          },
        }));
      };
      pc.onConnectionState = (state) {
        if (state == RTCPeerConnectionState.RTCPeerConnectionStateConnected) {
          _phase.add(VoiceCallPhase.connected);
        }
      };
      pc.onTrack = (event) {
        // Web: playback requires attaching the remote stream to an
        // RTCVideoRenderer, which creates the autoplaying <audio> element.
        // (On native platforms audio plays without a renderer.)
        final stream =
            event.streams.isNotEmpty ? event.streams.first : null;
        if (stream != null && stream.getAudioTracks().isNotEmpty) {
          _remoteRenderer ??= RTCVideoRenderer();
          _remoteRenderer!.srcObject = stream;
          debugPrint('[voicepipe] remote audio attached to renderer');
        }
      };

      // 3. mic + data channel
      pc.addTrack(stream.getAudioTracks().first, stream);
      final dc = await pc.createDataChannel(
          dataChannelLabel, RTCDataChannelInit());
      _dc = dc;
      dc.onMessage = _onDataMessage;
      dc.stateChangeStream.listen((state) {
        if (state == RTCDataChannelState.RTCDataChannelOpen) {
          _startPingTimer();
        }
      });

      // 4. signaling
      final ws = WebSocketChannel.connect(Uri.parse(signalingUrl));
      _ws = ws;
      ws.stream.listen(_onSignal, onError: (e) {
        debugPrint('[voicepipe] signaling error: $e');
        _phase.add(VoiceCallPhase.error);
      }, onDone: () {
        if (_started) _phase.add(VoiceCallPhase.error);
      });

      // 5. offer
      final offer = await pc.createOffer();
      await pc.setLocalDescription(offer);
      ws.sink.add(jsonEncode({'type': 'offer', 'sdp': offer.sdp}));
    } catch (e) {
      _phase.add(VoiceCallPhase.error);
      rethrow;
    }
  }

  void _onSignal(dynamic raw) {
    // Serialize signaling: trickled candidates must not race the answer.
    _signalChain = _signalChain
        .then((_) => _handleSignal(raw))
        .catchError((Object e) {
      debugPrint('[voicepipe] signaling error: $e');
    });
  }

  Future<void> _handleSignal(dynamic raw) async {
    final msg = jsonDecode(raw as String) as Map<String, dynamic>;
    final pc = _pc;
    if (pc == null) return;
    switch (msg['type']) {
      case 'answer':
        await pc.setRemoteDescription(RTCSessionDescription(
          msg['sdp'] as String,
          'answer',
        ));
        _answerReceived = true;
      case 'candidate':
        if (!_answerReceived) return; // already in the answer SDP
        final c = msg['candidate'] as Map<String, dynamic>;
        try {
          await pc.addCandidate(RTCIceCandidate(
            c['candidate'] as String?,
            (c['sdpMid'] as String?) ?? '',
            c['sdpMLineIndex'] as int?,
          ));
        } catch (e) {
          debugPrint('[voicepipe] addCandidate skipped: $e');
        }
      default:
        _events.add(msg); // connected / hello / other server pushes
    }
  }

  void _onDataMessage(RTCDataChannelMessage? msg) {
    if (msg == null) return;
    final text = msg.isBinary ? utf8.decode(msg.binary) : msg.text;
    try {
      final parsed = jsonDecode(text) as Map<String, dynamic>;
      if (parsed['type'] == 'pong') {
        final echo = parsed['echo'] as String;
        final sent = _pendingPings.remove(echo);
        if (sent != null) {
          _rtt.add(DateTime.now().millisecondsSinceEpoch - sent);
        }
        return;
      }
      _events.add(parsed);
    } catch (_) {
      _events.add({'type': 'raw', 'text': text});
    }
  }

  void _startPingTimer() {
    _pingTimer ??= Timer.periodic(const Duration(seconds: 1), (_) {
      final id = 'p${_pingSeq++}';
      _pendingPings[id] = DateTime.now().millisecondsSinceEpoch;
      _dc?.send(RTCDataChannelMessage('ping:$id'));
    });
  }

  /// Instant interrupt: {"event":"barge_in"} on the data channel.
  void sendBargeIn() {
    _dc?.send(RTCDataChannelMessage(
        jsonEncode({'event': 'barge_in'})));
  }

  /// Send a raw message on the data channel.
  Future<void> send(Map<String, dynamic> message) async {
    await _dc?.send(RTCDataChannelMessage(jsonEncode(message)));
  }

  Future<void> setMicEnabled(bool enabled) async {
    _micEnabled = enabled;
    _localStream?.getAudioTracks().firstOrNull?.enabled = enabled;
  }

  Future<void> end() async {
    _started = false;
    _pingTimer?.cancel();
    _pingTimer = null;
    final renderer = _remoteRenderer;
    _remoteRenderer = null;
    if (renderer != null) {
      renderer.srcObject = null;
      await renderer.dispose();
    }
    for (final track in _localStream?.getTracks() ?? <MediaStreamTrack>[]) {
      await track.stop();
    }
    await _localStream?.dispose();
    _localStream = null;
    await _dc?.close();
    _dc = null;
    await _pc?.close();
    _pc = null;
    await _ws?.sink.close();
    _ws = null;
    _phase.add(VoiceCallPhase.idle);
  }

  Future<void> dispose() async {
    await end();
    await _phase.close();
    await _events.close();
    await _rtt.close();
  }
}
