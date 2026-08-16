/// voicepipe Phase 1 POC — headless client self-test.
///
/// Connects to the POC server as a real WebRTC peer (no Flutter needed):
///  1. signals offer/answer + ICE over WebSocket
///  2. publishes synthetic 440 Hz sine audio (Opus-encoded via libopus)
///  3. receives the server's loopback audio, decodes it and verifies the
///     440 Hz tone survived (zero-crossing rate + RMS)
///  4. measures data-channel RTT
///
/// Run (server first):
///   dart run bin/server.dart &
///   dart run bin/self_test.dart
library;

import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:opus_codec_dart/opus_codec_dart.dart';
import 'package:web_socket_channel/web_socket_channel.dart';
import 'package:webrtc_dart/nonstandard.dart' as nonstandard;
import 'package:webrtc_dart/webrtc_dart.dart';

const _serverUrl = 'ws://127.0.0.1:8765/signal';
const _sampleRate = 48000;
const _channels = 2;
const _frameSamples = (_sampleRate * _channels) ~/ 50; // 20 ms = 1920
const _toneHz = 440.0;

void initOpusLibrary() {
  final candidates = <String>[
    '/opt/homebrew/opt/opus/lib/libopus.dylib',
    '/opt/homebrew/lib/libopus.dylib',
    '/usr/local/lib/libopus.dylib',
    'libopus.dylib',
    'libopus.so.0',
    'opus.dll',
  ];
  for (final path in candidates) {
    try {
      initOpus(DynamicLibrary.open(path));
      return;
    } catch (_) {}
  }
  throw StateError('libopus not found');
}

void main() async {
  initOpusLibrary();
  stdout.writeln('=== voicepipe headless self-test ===');

  final ws = WebSocketChannel.connect(Uri.parse(_serverUrl));
  final pc = RTCPeerConnection(RtcConfiguration(
    iceServers: [
      IceServer(urls: ['stun:stun.l.google.com:19302']),
    ],
  ));

  // --- outgoing synthetic audio track --------------------------------
  final outTrack = nonstandard.MediaStreamTrack(kind: nonstandard.MediaKind.audio);
  final transceiver = pc.addTransceiver(outTrack, direction: RtpTransceiverDirection.sendrecv);
  transceiver.sender.registerNonstandardTrack(outTrack);

  // Persistent client-side encoder (matches the server's persistent encoder;
  // correct for non-repeating frames).
  final encoder = SimpleOpusEncoder(
    sampleRate: _sampleRate,
    channels: _channels,
    application: Application.voip,
  );

  // --- data channel for RTT probe ------------------------------------
  await pc.waitForReady();
  final dc = pc.createDataChannel('agent.events');

  // --- receive loopback audio, verify the tone -----------------------
  final receivedPcm = <int>[];
  final rtts = <int>[];
  final pings = <int, int>{}; // id -> sent ms
  var receivedPackets = 0;
  var iccSent = 0;

  // Persistent client-side decoder (matches the server's persistent decoder;
  // correct for non-repeating packet streams).
  final decoder = SimpleOpusDecoder(sampleRate: _sampleRate, channels: _channels);
  pc.onTrack.listen((t) {
    final codec = t.receiver.codec;
    stdout.writeln('  [client] loopback track: ${codec.mimeType} '
        'pt=${codec.payloadType} rate=${codec.clockRate} ch=${codec.channels}');
    t.receiver.track.onReceiveRtp.listen((packet) {
      receivedPackets++;
      final pcm = decoder.decode(input: packet.payload);
      final peak = pcm.map((s) => s.abs()).reduce(max) / 32767;
      if (receivedPackets <= 5 ||
          receivedPackets % 25 == 0 ||
          receivedPackets > 145) {
        stdout.writeln('  [client] pkt#$receivedPackets seq=${packet.sequenceNumber} '
            'ts=${packet.timestamp} payload=${packet.payload.length}B peak=$peak');
      }
      receivedPcm.addAll(pcm);
    });
  });

  dc.onMessage.listen((msg) {
    if (msg is! String) return;
    final parsed = jsonDecode(msg) as Map<String, dynamic>;
    if (parsed['type'] == 'pong') {
      final echo = parsed['echo'] as String;
      final id = int.parse(echo.split(':')[1]);
      final sent = pings.remove(id);
      if (sent != null) rtts.add(DateTime.now().millisecondsSinceEpoch - sent);
    }
  });

  // --- ICE + offer/answer signaling -----------------------------------
  pc.onIceCandidate.listen((c) {
    iccSent++;
    ws.sink.add(jsonEncode({
      'type': 'candidate',
      'candidate': {
        'candidate': c.candidate,
        'sdpMid': c.sdpMid,
        'sdpMLineIndex': c.sdpMLineIndex,
        'usernameFragment': c.usernameFragment,
      },
    }));
  });

  final answer = Completer<void>();
  ws.stream.listen((raw) async {
    final msg = jsonDecode(raw as String) as Map<String, dynamic>;
    switch (msg['type']) {
      case 'answer':
        await pc.setRemoteDescription(
          RTCSessionDescription(type: 'answer', sdp: msg['sdp'] as String),
        );
        answer.complete();
      case 'candidate':
        final c = msg['candidate'] as Map<String, dynamic>;
        await pc.addIceCandidate(
          RTCIceCandidate.fromSdp(c['candidate'] as String),
        );
      case 'connected':
        stdout.writeln('  [client] server says connected');
    }
  });

  final offer = await pc.createOffer();
  await pc.setLocalDescription(offer);
  ws.sink.add(jsonEncode({'type': 'offer', 'sdp': offer.sdp}));

  await answer.future.timeout(const Duration(seconds: 10));
  stdout.writeln('  [client] answer received, waiting for ICE/DTLS/SRTP...');

  final connected = await pc.onConnectionStateChange
      .firstWhere((s) => s == PeerConnectionState.connected)
      .timeout(const Duration(seconds: 15));
  stdout.writeln('  [client] connected ($connected), sending 3s of 440Hz tone');

  // --- send a PHASE-CONTINUOUS tone in real time ----------------------
  // (a real mic stream is continuous across 20ms frames; repeating one
  // identical frame would phase-jump at each boundary and defeat
  // overlap-add reconstruction)
  var seq = Random().nextInt(1 << 10);
  var ts = Random().nextInt(1 << 28);
  final perChannel = _frameSamples ~/ _channels;
  var tonePhase = 0.0;
  const phaseStep = 2 * pi * _toneHz / _sampleRate;

  Int16List nextToneFrame() {
    final frame = Int16List(_frameSamples);
    for (var i = 0; i < perChannel; i++) {
      final v = (0.3 * sin(tonePhase + phaseStep * i) * 32767).round();
      for (var c = 0; c < _channels; c++) {
        frame[i * _channels + c] = v;
      }
    }
    tonePhase += phaseStep * perChannel;
    return frame;
  }

  // data-channel ping every 500 ms while sending audio
  var pingId = 0;
  final pingTimer = Timer.periodic(const Duration(milliseconds: 500), (_) {
    pings[pingId] = DateTime.now().millisecondsSinceEpoch;
    dc.sendString('ping:${pingId++}');
  });

  final audioTimer = Timer.periodic(const Duration(milliseconds: 20), (_) {
    final encoded = encoder.encode(input: nextToneFrame());
    final pkt = RtpPacket(
      payloadType: 111,
      sequenceNumber: seq++,
      timestamp: ts,
      ssrc: 0x11111111,
      payload: encoded,
    );
    ts += _frameSamples ~/ _channels;
    outTrack.writeRtp(pkt);
  });

  await Future<void>.delayed(const Duration(seconds: 3));
  audioTimer.cancel();
  pingTimer.cancel();

  // --- analyze the loopback -------------------------------------------
  final avgRtt = rtts.isEmpty ? -1 : rtts.reduce((a, b) => a + b) ~/ rtts.length;
  final rms = receivedPcm.isEmpty
      ? 0.0
      : sqrt(receivedPcm.map((s) => (s / 32767) * (s / 32767)).reduce((a, b) => a + b) /
          receivedPcm.length);
  var zeroCrossings = 0;
  var prev = 0;
  for (var i = _channels; i < receivedPcm.length; i += _channels) {
    if (prev < 0 && receivedPcm[i] >= 0) zeroCrossings++;
    prev = receivedPcm[i];
  }
  final seconds = receivedPcm.length / (_sampleRate * _channels);
  final freq = seconds == 0 ? 0.0 : zeroCrossings / seconds;

  stdout.writeln();
  stdout.writeln('--- results ---');
  stdout.writeln('ice candidates sent:    $iccSent');
  stdout.writeln('loopback packets rx:    $receivedPackets');
  stdout.writeln('loopback samples rx:    ${receivedPcm.length} '
      '(${seconds.toStringAsFixed(2)}s)');
  stdout.writeln('loopback RMS:           ${rms.toStringAsFixed(4)} '
      '(tone ~0.21, silence ~0)');
  stdout.writeln('loopback freq:          ${freq.toStringAsFixed(1)} Hz '
      '(expected ~440 Hz)');

  if (Platform.environment.containsKey('DUMP_PCM')) {
    final f = File('/tmp/voicepipe_loop.pcm');
    f.writeAsBytesSync(Int16List.fromList(receivedPcm).buffer.asUint8List());
    stdout.writeln('dumped ${receivedPcm.length} samples to ${f.path}');
    stdout.writeln('first 64 samples: '
        '${receivedPcm.take(64).join(',')}');
  }
  stdout.writeln('data-channel RTT:       $avgRtt ms (${rtts.length} probes)');

  final pass = receivedPackets > 100 &&
      rms > 0.1 &&
      (freq - _toneHz).abs() < 40 &&
      avgRtt >= 0 && avgRtt < 500;
  stdout.writeln(pass ? 'RESULT: PASS' : 'RESULT: FAIL');
  await pc.close();
  await ws.sink.close();
  exit(pass ? 0 : 1);
}
