/// One WebSocket connection == one WebRTC peer (one patient call).
///
/// Owns the RTCPeerConnection (webrtc_dart): offer/answer + ICE over the
/// WebSocket, the audio loop (Opus decode -> [AudioCore.onDecodedPcm],
/// [AudioCore.outgoingPcm] -> Opus encode -> RTP), and the data channel
/// (agent.events contract).
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:opus_codec_dart/opus_codec_dart.dart';
import 'package:web_socket_channel/web_socket_channel.dart';
import 'package:webrtc_dart/nonstandard.dart' as nonstandard;
import 'package:webrtc_dart/webrtc_dart.dart';

import 'audio_core.dart';

class PeerSession {
  final WebSocketChannel _ws;
  final int _id;
  final AudioCore core;

  late final RTCPeerConnection _pc;

  // Audio state (negotiated from the offer's Opus m-line).
  int _sampleRate = 48000;
  int _channels = 2;
  int _samplesPerFrame = 0; // 20 ms frame
  SimpleOpusDecoder? _decoder;
  SimpleOpusEncoder? _encoder;
  nonstandard.MediaStreamTrack? _outTrack;
  final List<Int16List> _pendingFrames = []; // TTS frames before track ready
  final List<int> _pcmBuffer = [];
  StreamSubscription<Int16List>? _outSub;

  // Stats.
  int _packetsReceived = 0;
  int _packetsDecoded = 0;
  int _packetsSent = 0;
  int _framesEncoded = 0;
  final Stopwatch _codecTime = Stopwatch();
  bool _connected = false;
  bool _closed = false;
  int _seq = 1000;
  int _ts = 0;
  int _sendSsrc = 0x50111AAA;
  bool _ssrcKnown = false;
  final bool _debugRtp = Platform.environment['VOICE_FORGE_DEBUG_RTP'] == '1';
  int _sentLogged = 0;

  /// Extract the audio SSRC from our local answer SDP (the value Chrome's
  /// demuxer expects; sending a different SSRC silently drops the stream).
  void _captureAnswerSsrc(String answerSdp) {
    final lines = answerSdp.split('\n');
    var inAudio = false;
    for (final line in lines) {
      if (line.startsWith('m=audio')) {
        inAudio = true;
        continue;
      }
      if (inAudio && line.startsWith('m=')) break; // next m-line (application)
      if (inAudio && line.startsWith('a=ssrc:')) {
        final match = RegExp(r'a=ssrc:(\d+)').firstMatch(line);
        if (match != null) {
          _sendSsrc = int.parse(match.group(1)!);
          _ssrcKnown = true;
          print('[peer$_id] outgoing audio ssrc: $_sendSsrc (from answer)');
        }
        return;
      }
    }
  }

  PeerSession(this._ws, this._id, this.core) {
    core.events.listen(_publishEvent);
    _outSub = core.outgoingPcm.listen(_onOutgoingFrame);
  }

  RTCDataChannel? _eventChannel;
  final List<String> _pendingEvents = [];

  void _publishEvent(Map<String, dynamic> payload) {
    if (_closed) return;
    try {
      final channel = _eventChannel;
      if (channel == null) {
        // Channel not open yet (e.g. greeting before negotiation): queue.
        _pendingEvents.add(jsonEncode(payload));
        return;
      }
      channel.sendString(jsonEncode(payload));
    } catch (_) {}
  }

  Future<void> start() async {
    _pc = RTCPeerConnection(RtcConfiguration(
      iceServers: [
        IceServer(urls: ['stun:stun.l.google.com:19302']),
      ],
    ));

    _pc.onIceCandidate.listen((c) {
      _send({
        'type': 'candidate',
        'candidate': {
          'candidate': c.candidate,
          // Empty strings (not null): flutter_webrtc's native layer crashes
          // on NSNull for sdpMid/usernameFragment.
          'sdpMid': c.sdpMid ?? '',
          'sdpMLineIndex': c.sdpMLineIndex,
          'usernameFragment': c.usernameFragment ?? '',
        },
      });
    });

    _pc.onConnectionStateChange.listen((state) {
      _connected = state == PeerConnectionState.connected;
      print('[peer$_id] connection state: $state');
      if (_connected) {
        _send({'type': 'connected', ...?core.connectionInfo});
        Timer.periodic(const Duration(seconds: 5), _logStats);
      }
      if (state == PeerConnectionState.failed ||
          state == PeerConnectionState.closed) {
        close();
      }
    });

    _pc.onTrack.listen(_onTrack);
    _pc.onDataChannel.listen(_onDataChannel);
  }

  void _logStats(Timer _) {
    print('[peer$_id] stats: rx=$_packetsReceived decoded=$_packetsDecoded '
        'sent=$_packetsSent frames=$_framesEncoded');
  }

  // ---------------------------------------------------------------------------
  // Media
  // ---------------------------------------------------------------------------

  void _onTrack(RTCRtpTransceiver transceiver) {
    final codec = transceiver.receiver.codec;
    print('[peer$_id] track: ${codec.mimeType} '
        'pt=${codec.payloadType} rate=${codec.clockRate} ch=${codec.channels}');
    if (!codec.mimeType.toLowerCase().contains('opus')) {
      print('[peer$_id] ignoring non-Opus track');
      return;
    }

    _sampleRate = codec.clockRate;
    _channels = codec.channels ?? 2;
    _samplesPerFrame = (_sampleRate * _channels) ~/ 50; // 20 ms
    // Persistent codec instances (libopus via Dart FFI) are correct for real
    // packet streams. Note: we observed a Dart-FFI state bug when the SAME
    // packet bytes are decoded/encoded repeatedly at 48 kHz (garbage output);
    // real continuous streams (phase-progressive frames) are unaffected.
    _decoder = SimpleOpusDecoder(sampleRate: _sampleRate, channels: _channels);
    _encoder = SimpleOpusEncoder(
      sampleRate: _sampleRate,
      channels: _channels,
      application: Application.voip,
    );

    // Outgoing pre-encoded RTP track: whatever we write() is sent to the peer
    // (SSRC + payload type are rewritten to the negotiated values).
    final outTrack =
        nonstandard.MediaStreamTrack(kind: nonstandard.MediaKind.audio);
    _outTrack = outTrack;
    transceiver.sender.registerNonstandardTrack(outTrack);

    transceiver.receiver.track.onReceiveRtp.listen(_onRtp);
    print('[peer$_id] audio pipeline ready');
  }

  void _flushPendingFrames() {
    if (_pendingFrames.isNotEmpty) {
      print('[peer$_id] flushing ${_pendingFrames.length} pending frames');
      for (final f in _pendingFrames) {
        _sendFrame(f);
      }
      _pendingFrames.clear();
    }
  }

  void _onRtp(RtpPacket packet) {
    if (_closed) return;
    _packetsReceived++;
    final payload = packet.payload;
    if (payload.isEmpty) return; // DTX / silence packets

    _codecTime.start();
    final pcm = _decoder!.decode(input: payload);
    _codecTime.stop();
    _packetsDecoded++;

    // Feed the pipeline: VAD/STT (agent) or loopback encode.
    if (pcm.length == _samplesPerFrame) {
      core.onDecodedPcm(pcm);
    } else if (pcm.length > 0) {
      // Non-20ms frames: buffer until a full frame accumulates.
      _pcmBuffer.addAll(pcm);
      while (_pcmBuffer.length >= _samplesPerFrame) {
        final frame = Int16List.fromList(
          _pcmBuffer.sublist(0, _samplesPerFrame),
        );
        _pcmBuffer.removeRange(0, _samplesPerFrame);
        core.onDecodedPcm(frame);
      }
    }
  }

  /// TTS frames from the core -> Opus -> RTP. Buffered until BOTH the outgoing
  /// track exists and the negotiated SSRC is known (sending before that with a
  /// wrong SSRC makes Chrome drop the whole stream).
  void _onOutgoingFrame(Int16List frame) {
    if (_closed) return;
    if (_outTrack == null || !_ssrcKnown) {
      _pendingFrames.add(frame);
      return;
    }
    _sendFrame(frame);
  }

  void _sendFrame(Int16List frame) {
    _codecTime.start();
    final encoded = _encoder!.encode(input: frame);
    _codecTime.stop();
    _framesEncoded++;
    _packetsSent++;
    final packet = RtpPacket(
      payloadType: 111,
      sequenceNumber: _seq++,
      timestamp: _ts += _samplesPerFrame ~/ _channels,
      ssrc: _sendSsrc,
      payload: encoded,
    );
    _outTrack!.writeRtp(packet);
    if (_debugRtp && _sentLogged++ < 3) {
      print('[peer$_id] SENT rtp pt=${packet.payloadType} '
          'ssrc=${packet.ssrc} seq=${packet.sequenceNumber} '
          'ts=${packet.timestamp} payload=${encoded.length}B');
    }
  }

  // ---------------------------------------------------------------------------
  // Data channel (agent.events contract)
  // ---------------------------------------------------------------------------

  void _onDataChannel(RTCDataChannel dc) {
    print('[peer$_id] data channel open: "${dc.label}"');
    if (dc.label == 'agent.events') {
      _eventChannel = dc;
    }
    // The onStateChange stream does not replay the current state: check it
    // synchronously, and only then listen for the transition.
    void onChannelOpen() {
      dc.sendString(jsonEncode({
        'type': 'hello',
        'text': 'voice_forge agent ready',
      }));
      if (dc.label == 'agent.events') {
        // Flush events queued before the channel opened, then start the core.
        for (final pending in _pendingEvents) {
          try {
            dc.sendString(pending);
          } catch (_) {}
        }
        _pendingEvents.clear();
        try {
          core.onDataChannelOpen();
        } catch (e) {
          print('[peer$_id] onDataChannelOpen failed: $e');
        }
      }
    }

    if (dc.state == DataChannelState.open) {
      onChannelOpen();
    } else {
      dc.onStateChange
          .where((s) => s == DataChannelState.open)
          .listen((_) => onChannelOpen());
    }
    dc.onMessage.listen((message) {
      if (message is! String) return;
      if (message.startsWith('ping')) {
        dc.sendString(jsonEncode({
          'type': 'pong',
          'echo': message,
          'serverTime': DateTime.now().millisecondsSinceEpoch,
        }));
        return;
      }
      try {
        final msg = jsonDecode(message) as Map<String, dynamic>;
        core.onDataMessage(msg);
      } catch (_) {
        print('[peer$_id] non-JSON datachannel: $message');
      }
    });
  }

  // ---------------------------------------------------------------------------
  // Signaling
  // ---------------------------------------------------------------------------

  Future<void> handleMessage(String raw) async {
    final msg = jsonDecode(raw) as Map<String, dynamic>;
    switch (msg['type']) {
      case 'offer':
        final sdp = msg['sdp'] as String;
        await _pc.setRemoteDescription(
          RTCSessionDescription(type: 'offer', sdp: sdp),
        );
        final answer = await _pc.createAnswer();
        await _pc.setLocalDescription(answer);
        _send({'type': 'answer', 'sdp': answer.sdp});
        _captureAnswerSsrc(answer.sdp);
        // Flush greeting frames now that the outgoing SSRC is known (flushing
        // earlier, inside _onTrack, would send them with the wrong SSRC and
        // Chrome would drop the whole stream).
        _flushPendingFrames();
        print('[peer$_id] answered offer (${sdp.length} bytes)');
        if (_debugRtp) {
          File('/tmp/voice_forge_offer_$_id.sdp').writeAsStringSync(sdp);
          File('/tmp/voice_forge_answer_$_id.sdp').writeAsStringSync(answer.sdp);
          print('[peer$_id] SDP dumped to /tmp/voice_forge_{offer,answer}_$_id.sdp');
        }
      case 'candidate':
        final c = msg['candidate'] as Map<String, dynamic>;
        final parsed = RTCIceCandidate.fromSdp(c['candidate'] as String);
        await _pc.addIceCandidate(parsed);
      default:
        print('[peer$_id] unknown message: ${msg['type']}');
    }
  }

  void _send(Map<String, dynamic> payload) {
    if (!_closed) _ws.sink.add(jsonEncode(payload));
  }

  /// Closes the peer session (also invoked when the WS or ICE fails).
  void close() {
    if (_closed) return;
    _closed = true;
    print('[peer$_id] closing peer session');
    _outSub?.cancel();
    try {
      core.onPeerClosed();
    } catch (e) {
      print('[peer$_id] onPeerClosed failed: $e');
    }
    _pc.close();
  }
}
