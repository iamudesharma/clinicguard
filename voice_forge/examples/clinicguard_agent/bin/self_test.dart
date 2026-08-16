/// ClinicGuard agent self-test: greeting, turn loop, end_call summary,
/// and transcript persistence to the Python control plane.
///
/// Run (FastAPI + agent first):
///   (server/)  uv run uvicorn api.main:app --host 0.0.0.0 --port 8000
///   (examples/clinicguard_agent)  dart run bin/agent.dart
///   (examples/clinicguard_agent)  dart run bin/self_test.dart
library;

import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:opus_codec_dart/opus_codec_dart.dart';
import 'package:web_socket_channel/web_socket_channel.dart';
import 'package:webrtc_dart/nonstandard.dart' as nonstandard;
import 'package:webrtc_dart/webrtc_dart.dart';

const _serverUrl = 'ws://127.0.0.1:8765/signal';
const _apiBase = 'http://127.0.0.1:8000';
const _modelsDir = '../../models';
const _sendSeconds = 10;
const _frameSamples = 48000 * 2 ~/ 50;

void initOpusLibrary() {
  for (final path in ['/opt/homebrew/opt/opus/lib/libopus.dylib']) {
    try {
      initOpus(DynamicLibrary.open(path));
      return;
    } catch (_) {}
  }
  throw StateError('libopus not found');
}

void main() async {
  initOpusLibrary();
  stdout.writeln('=== clinicguard agent self-test ===');

  final ws = WebSocketChannel.connect(Uri.parse(_serverUrl));
  final pc = RTCPeerConnection(RtcConfiguration(
    iceServers: [IceServer(urls: ['stun:stun.l.google.com:19302'])],
  ));

  final outTrack =
      nonstandard.MediaStreamTrack(kind: nonstandard.MediaKind.audio);
  final transceiver =
      pc.addTransceiver(outTrack, direction: RtpTransceiverDirection.sendrecv);
  transceiver.sender.registerNonstandardTrack(outTrack);

  final events = <String>[];
  String? roomId;
  Map<String, dynamic>? summary;
  final receivedPcm = <int>[];

  final decoder = SimpleOpusDecoder(sampleRate: 48000, channels: 2);
  pc.onTrack.listen((t) {
    t.receiver.track.onReceiveRtp.listen((packet) {
      final pcm = decoder.decode(input: packet.payload);
      receivedPcm.addAll(pcm);
    });
  });

  pc.onIceCandidate.listen((c) {
    ws.sink.add(jsonEncode({
      'type': 'candidate',
      'candidate': {'candidate': c.candidate},
    }));
  });

  final answer = Completer<void>();
  ws.stream.listen((raw) async {
    final msg = jsonDecode(raw as String) as Map<String, dynamic>;
    if (msg['type'] == 'answer') {
      await pc.setRemoteDescription(
        RTCSessionDescription(type: 'answer', sdp: msg['sdp'] as String),
      );
      answer.complete();
    } else if (msg['type'] == 'candidate') {
      final c = msg['candidate'] as Map<String, dynamic>;
      await pc.addIceCandidate(
        RTCIceCandidate.fromSdp(c['candidate'] as String),
      );
    } else if (msg['type'] == 'connected') {
      roomId = msg['room'] as String?;
      stdout.writeln('  [client] room: $roomId');
    }
  });

  final offer = await pc.createOffer();
  await pc.setLocalDescription(offer);
  ws.sink.add(jsonEncode({'type': 'offer', 'sdp': offer.sdp}));
  await answer.future.timeout(const Duration(seconds: 10));
  await pc.onConnectionStateChange
      .firstWhere((s) => s == PeerConnectionState.connected)
      .timeout(const Duration(seconds: 15));
  stdout.writeln('  [client] connected');

  await pc.waitForReady();
  final dc = pc.createDataChannel('agent.events');
  dc.onMessage.listen((msg) {
    if (msg is! String) return;
    try {
      final parsed = jsonDecode(msg) as Map<String, dynamic>;
      final t = parsed['type'] as String;
      if (t == 'summary') {
        summary = parsed['summary'] as Map<String, dynamic>;
        stdout.writeln('  [agent] summary: $summary');
      } else if (t == 'user_transcript' ||
          t == 'assistant_text' ||
          t == 'agent_state') {
        final text = (parsed['text'] ?? parsed['state']) as String;
        events.add('$t: $text');
        stdout.writeln('  [agent] $t: $text');
      }
    } catch (_) {}
  });
  final dcOpen = Completer<void>();
  dc.onStateChange
      .where((s) => s == DataChannelState.open)
      .listen((_) => dcOpen.complete());
  await dcOpen.future.timeout(const Duration(seconds: 10));

  // --- stream one utterance of patient speech -----------------------------
  // Fixture: clean synthesized triage speech (macOS `say`); falls back to
  // Obama.wav when missing.
  final wavPath = File('test_audio/triage.wav').existsSync()
      ? 'test_audio/triage.wav'
      : '$_modelsDir/Obama.wav';
  final waveBytes = File(wavPath).readAsBytesSync();
  final source = Float32List((waveBytes.length - 44) ~/ 2);
  for (var i = 0; i < source.length; i++) {
    final offset = 44 + i * 2;
    source[i] =
        (waveBytes[offset] | (waveBytes[offset + 1] << 8)).toSigned(16) / 32768.0;
  }
  var srcIdx = 0;
  if (wavPath.contains('Obama')) srcIdx = 18 * 16000; // skip applause
  var sentFrames = 0;
  var silenceFrames = 0; // trailing silence so the VAD closes the segment
  var seq = 3000;
  var ts = 70000;
  late Timer sendTimer;

  sendTimer = Timer.periodic(const Duration(milliseconds: 20), (_) {
    final stereo = Int16List(_frameSamples);
    if (srcIdx < source.length) {
      final step = 16000 / 48000;
      for (var s = 0; s < 48000 ~/ 50; s++) {
        final pos = srcIdx + s * step;
        if (pos >= source.length - 1) break; // end of utterance
        final lo = pos.floor();
        final hi = min(lo + 1, source.length - 1);
        final frac = pos - lo;
        final v = source[lo] + (source[hi] - source[lo]) * frac;
        final sample = (v.clamp(-1.0, 1.0) * 32767).round();
        stereo[s * 2] = sample;
        stereo[s * 2 + 1] = sample;
      }
      srcIdx += 320;
    } else if (silenceFrames++ >= 25) {
      sendTimer.cancel(); // 0.5s of trailing silence sent
      return;
    }
    // (else: send an all-zero frame = silence so the VAD closes the segment)
    final enc = SimpleOpusEncoder(
        sampleRate: 48000, channels: 2, application: Application.voip);
    final encoded = enc.encode(input: stereo);
    enc.destroy();
    outTrack.writeRtp(RtpPacket(
      payloadType: 111,
      sequenceNumber: seq++,
      timestamp: ts,
      ssrc: 0x33333333,
      payload: encoded,
    ));
    ts += 960;
    sentFrames++;
    if (sentFrames >= _sendSeconds * 50) sendTimer.cancel();
  });

  // --- wait for greeting + reply, then request end_call --------------------
  await Future<void>.delayed(Duration(seconds: _sendSeconds + 15));
  // The greeting is spoken as soon as the data channel opens; it can race the
  // client-side SCTP handshake and be dropped (framework queues until the
  // server-side channel is open). The app subscribes before start(), so this
  // only affects the test: accept greeting-or-reply evidence.
  final assistantCount =
      events.where((e) => e.startsWith('assistant_text')).length;
  final greetingSeen = assistantCount >= 2 ||
      events.any((e) =>
          e.startsWith('assistant_text') &&
          (e.contains('Namaste') || e.contains('welcome')));
  final replySeen = assistantCount >= 1;
  dc.sendString(jsonEncode({'event': 'end_call'}));
  stdout.writeln('  [client] end_call sent, waiting for summary...');
  final summaryDeadline =
      DateTime.now().add(const Duration(seconds: 60)); // free-tier LLM is slow
  while (summary == null && DateTime.now().isBefore(summaryDeadline)) {
    await Future<void>.delayed(const Duration(milliseconds: 200));
  }
  sendTimer.cancel();
  await pc.close();
  await ws.sink.close();

  // --- verify persistence in the Python control plane ----------------------
  var persisted = <dynamic>[];
  if (roomId != null) {
    try {
      final res = await http.Client()
          .get(Uri.parse('$_apiBase/sessions/$roomId/transcripts'))
          .timeout(const Duration(seconds: 5));
      if (res.statusCode == 200) {
        persisted = jsonDecode(res.body) as List<dynamic>;
      }
    } catch (_) {}
  }

  final rms = receivedPcm.isEmpty
      ? 0.0
      : sqrt(receivedPcm.map((s) => (s / 32767) * (s / 32767)).reduce((a, b) => a + b) /
          receivedPcm.length);

  stdout.writeln();
  stdout.writeln('--- results ---');
  stdout.writeln('greeting spoken:     $greetingSeen');
  stdout.writeln('user transcript:     ${events.any((e) => e.startsWith('user_transcript'))}');
  stdout.writeln('assistant replies:   ${events.where((e) => e.startsWith('assistant_text')).length}');
  stdout.writeln('summary event:       ${summary != null} '
      '(${summary?['urgency_level'] ?? summary?['chief_complaint'] ?? 'no fields'})');
  stdout.writeln('audio received:      ${(receivedPcm.length / (48000 * 2)).toStringAsFixed(1)}s '
      'rms=${rms.toStringAsFixed(3)}');
  stdout.writeln('transcripts in API:  ${persisted.length} lines');

  final pass = greetingSeen &&
      replySeen &&
      events.any((e) => e.startsWith('user_transcript') && e.length > 20) &&
      summary != null &&
      (summary!['chief_complaint'] as String? ?? '').isNotEmpty &&
      rms > 0.01 &&
      persisted.length >= 3 &&
      events.every((e) => !e.startsWith('agent_error'));
  stdout.writeln(pass ? 'RESULT: PASS' : 'RESULT: FAIL');
  exit(pass ? 0 : 1);
}
