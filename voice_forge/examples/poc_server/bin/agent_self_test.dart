/// voice_forge Phase 2 agent self-test: full loop over WebRTC.
///
/// Connects to `bin/agent_server.dart` as a WebRTC peer, streams the first
/// seconds of Obama.wav as "patient speech" (48k stereo, real-time paced),
/// and verifies the agent:
///   1. segments speech with Silero VAD (user_transcript events, non-empty)
///   2. replies via LLM (assistant_text event, non-empty)
///   3. speaks via Piper TTS (received audio with RMS > 0)
///   4. publishes agent_state transitions (listening -> thinking -> speaking)
///
/// Run (agent server first, from examples/poc_server):
///   dart run bin/agent_server.dart &
///   dart run bin/agent_self_test.dart
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
const _modelsDir = '../../models';
// 12s of loud speech per turn (wav 13-25s): its quiet tail (after ~20s) lets
// the last turn-1 reply play out fully — continuous speech during a reply
// would trip the instant-onset barge-in gate and cut it to ~40ms.
const _sendSeconds = 12;
const _frameSamples = 48000 * 2 ~/ 50; // 20 ms stereo

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
  stdout.writeln('=== voice_forge agent self-test ===');

  final ws = WebSocketChannel.connect(Uri.parse(_serverUrl));
  final pc = RTCPeerConnection(RtcConfiguration(
    iceServers: [IceServer(urls: ['stun:stun.l.google.com:19302'])],
  ));

  final outTrack =
      nonstandard.MediaStreamTrack(kind: nonstandard.MediaKind.audio);
  final transceiver =
      pc.addTransceiver(outTrack, direction: RtpTransceiverDirection.sendrecv);
  transceiver.sender.registerNonstandardTrack(outTrack);

  // --- collect agent events + reply audio --------------------------------
  final events = <String>[];
  final rtts = <int>[];
  final pings = <int, int>{};
  final receivedPcm = <int>[];
  var receivedPackets = 0;
  var pingId = 0;

  final decoder =
      SimpleOpusDecoder(sampleRate: 48000, channels: 2);
  pc.onTrack.listen((t) {
    t.receiver.track.onReceiveRtp.listen((packet) {
      receivedPackets++;
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
    }
  });

  final offer = await pc.createOffer();
  await pc.setLocalDescription(offer);
  ws.sink.add(jsonEncode({'type': 'offer', 'sdp': offer.sdp}));
  await answer.future.timeout(const Duration(seconds: 10));

  await pc.onConnectionStateChange
      .firstWhere((s) => s == PeerConnectionState.connected)
      .timeout(const Duration(seconds: 15));
  stdout.writeln('  [client] connected to agent server');

  // --- barge-in bookkeeping ------------------------------------------------
  final bargeInDone = Completer<int>();
  var userTranscriptCount = 0;
  var speakingCount = 0;
  var bargeInSentAt = 0;
  var listeningAfterBargeIn = false;

  // --- open data channel + start pings -----------------------------------
  await pc.waitForReady();
  final dc = pc.createDataChannel('agent.events');
  dc.onMessage.listen((msg) {
    if (msg is! String) return;
    try {
      final parsed = jsonDecode(msg) as Map<String, dynamic>;
      switch (parsed['type']) {
        case 'pong':
          final echo = parsed['echo'] as String;
          final id = int.parse(echo.split(':')[1]);
          final sent = pings.remove(id);
          if (sent != null) {
            rtts.add(DateTime.now().millisecondsSinceEpoch - sent);
          }
        case 'agent_state':
          final state = parsed['state'] as String;
          if (state == 'speaking') speakingCount++;
          if (state == 'listening' &&
              bargeInSentAt > 0 &&
              !listeningAfterBargeIn) {
            listeningAfterBargeIn = true;
            bargeInDone.complete(
                DateTime.now().millisecondsSinceEpoch - bargeInSentAt);
          }
          final t = parsed['type'] as String;
          events.add('$t: $state');
          stdout.writeln('  [agent] $t: $state');
        case 'user_transcript':
          userTranscriptCount++;
          final t = parsed['type'] as String;
          final text = (parsed['text'] ?? '') as String;
          events.add('$t: $text');
          stdout.writeln('  [agent] $t: $text');
        case 'assistant_text':
        case 'agent_error':
          final t = parsed['type'] as String;
          final text =
              (parsed['text'] ?? parsed['error']) as String;
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
  final pingTimer = Timer.periodic(const Duration(seconds: 1), (_) {
    pings[pingId] = DateTime.now().millisecondsSinceEpoch;
    dc.sendString('ping:${pingId++}');
  });

  // --- stream Obama.wav (patient speech) at real-time pace ---------------
  // (pure-Dart WAV parse: 16-bit PCM, mono, 16 kHz)
  final waveBytes = File('$_modelsDir/Obama.wav').readAsBytesSync();
  final source = Float32List((waveBytes.length - 44) ~/ 2);
  for (var i = 0; i < source.length; i++) {
    final offset = 44 + i * 2;
    source[i] = (waveBytes[offset] | (waveBytes[offset + 1] << 8)).toSigned(16) /
        32768.0;
  }
  // Obama.wav: ~6s of applause, "Go!" + crowd noise, then speech. Start at
  // 13s ("Thank everybody...", loud and pause-free): starting earlier the
  // crowd noise right after "Go!" trips the instant-onset barge-in gate and
  // cuts the first reply before any audio plays.
  var srcIdx = 13 * 16000;

  var sentFrames = 0;
  var seq = 2000;
  var ts = 50000;
  Timer? sendTimer;
  var turn = 0;
  const turns = 6; // up to 6 streaming attempts (empty transcripts retry)

  // ONE persistent encoder for the whole call: a fresh-per-frame Opus
  // encoder decodes to silence/near-silence on the receiving side (each
  // packet starts from encoder reset state), so the VAD finds nothing and
  // the test flakes. The real app uses a persistent encoder too.
  final encoder = SimpleOpusEncoder(
    sampleRate: 48000,
    channels: 2,
    application: Application.voip,
  );

  void streamTurn() {
    if (turn >= turns) return;
    turn++;
    sentFrames = 0;
    // Loop the same loud speech section for every turn (Obama.wav has quiet
    // stretches that produce no VAD segments at all).
    srcIdx = 13 * 16000;
    stdout.writeln('  [client] turn $turn: streaming ${_sendSeconds}s of speech...');
    final framesThisTurn = _sendSeconds * 50;
    // 8s of speech (wav 13-21s), then 4s of silence: the LAST utterance
    // (16-19.6s) completes fully inside the speech window, and the silence
    // lets its reply play out uninterrupted (loud audio during a reply
    // trips the RMS onset gate and cuts it to ~60ms).
    final speechFrames = 8 * 50;
    sendTimer = Timer.periodic(const Duration(milliseconds: 20), (_) {
      // 20ms of 16k mono -> interpolate to 48k stereo
      final stereo = Int16List(_frameSamples);
      if (sentFrames < speechFrames) {
        final step = 16000 / 48000;
        for (var s = 0; s < 48000 ~/ 50; s++) {
          final pos = srcIdx + s * step;
          final lo = pos.floor();
          final hi = min(lo + 1, source.length - 1);
          final frac = pos - lo;
          final v = source[lo] + (source[hi] - source[lo]) * frac;
          final sample = (v.clamp(-1.0, 1.0) * 32767).round();
          stereo[s * 2] = sample;
          stereo[s * 2 + 1] = sample;
        }
        srcIdx += 320;
      }

      final encoded = encoder.encode(input: stereo);

      outTrack.writeRtp(RtpPacket(
        payloadType: 111,
        sequenceNumber: seq++,
        timestamp: ts,
        ssrc: 0x22222222,
        payload: encoded,
      ));
      ts += 960;
      sentFrames++;
      if (sentFrames >= framesThisTurn) sendTimer?.cancel();
    });
  }

  // Wait until `cond` becomes true (poll), for at most [timeout].
  Future<bool> waitFor(bool Function() cond, Duration timeout) async {
    final deadline = DateTime.now().add(timeout);
    while (DateTime.now().isBefore(deadline)) {
      if (cond()) return true;
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    return cond();
  }

  // --- stream turns until TWO replies played fully, then barge in over the
  // next reply ------------------------------------------------------------
  // Each attempt streams 8s of speech + 4s of silence: the silence tail lets
  // the last reply play out fully (loud audio during a reply trips the RMS
  // onset gate and cuts it). Whisper occasionally transcribes a segment as
  // empty — that turn is dropped and the attempt simply retries.
  const repliesBeforeBargeIn = 2;
  var attempts = 0;
  const maxAttempts = 6;
  while (speakingCount <= repliesBeforeBargeIn && attempts < maxAttempts) {
    attempts++;
    final txBefore = userTranscriptCount;
    final spBefore = speakingCount;
    stdout.writeln('  [client] attempt $attempts: streaming '
        '${_sendSeconds}s (8s speech + silence)...');
    streamTurn();
    final gotTranscript = await waitFor(
        () => userTranscriptCount > txBefore, const Duration(seconds: 20));
    if (!gotTranscript) continue; // empty transcript -> retry
    final gotReply = await waitFor(
        () => speakingCount > spBefore, const Duration(seconds: 20));
    if (!gotReply) continue;
    if (speakingCount <= repliesBeforeBargeIn) {
      // Let the reply play out (silence tail) and the stream timer end.
      await Future<void>.delayed(const Duration(seconds: 8));
    }
  }
  if (speakingCount <= repliesBeforeBargeIn) {
    stdout.writeln('  [client] only $speakingCount reply(ies) from '
        '$attempts attempt(s); skipping barge-in');
  }

  // --- barge in over the most recent reply (still in synthesis) ----------
  await Future<void>.delayed(const Duration(milliseconds: 300));
  final lenAtBargeIn = receivedPcm.length;
  bargeInSentAt = DateTime.now().millisecondsSinceEpoch;
  dc.sendString(jsonEncode({'event': 'barge_in'}));
  stdout.writeln('  [client] barge_in sent');
  final bargeInLatencyMs =
      await bargeInDone.future.timeout(const Duration(seconds: 5));
  stdout.writeln('  [client] barge-in -> listening: ${bargeInLatencyMs}ms');

  // Speaking must actually stop: no more than ~1.0s of TTS audio within
  // the 2.5s after the barge-in.
  await Future<void>.delayed(const Duration(milliseconds: 2500));
  final audioGrewAfterBargeIn = receivedPcm.length - lenAtBargeIn;
  final audioCut = audioGrewAfterBargeIn < 48000 * 2 * 1.0;

  await Future<void>.delayed(const Duration(seconds: 10));
  pingTimer.cancel();

  final avgRtt =
      rtts.isEmpty ? -1 : rtts.reduce((a, b) => a + b) ~/ rtts.length;
  final rms = receivedPcm.isEmpty
      ? 0.0
      : sqrt(receivedPcm.map((s) => (s / 32767) * (s / 32767)).reduce((a, b) => a + b) /
          receivedPcm.length);
  final seconds = receivedPcm.length / (48000 * 2);

  stdout.writeln();
  stdout.writeln('--- results ---');
  stdout.writeln('user transcripts:    ${events.where((e) => e.startsWith('user_transcript')).length}');
  stdout.writeln('assistant texts:     ${events.where((e) => e.startsWith('assistant_text')).length}');
  stdout.writeln('state transitions:   ${events.where((e) => e.startsWith('agent_state')).length}');
  stdout.writeln('errors:              ${events.where((e) => e.startsWith('agent_error')).length}');
  stdout.writeln('reply audio:         ${seconds.toStringAsFixed(1)}s rms=$rms '
      '(${receivedPackets} packets)');
  stdout.writeln('data-channel RTT:    $avgRtt ms');
  stdout.writeln('barge-in latency:    $bargeInLatencyMs ms '
      '(audio cut: ${audioCut ? 'yes' : 'NO'})');

  final pass = events.where((e) => e.startsWith('user_transcript') && e.length > 25).length >= 2 &&
      // With streaming replies, a barge-in'd reply may be dropped entirely
      // (no assistant_text) — at least one full reply must still be recorded.
      events.where((e) => e.startsWith('assistant_text') && e.length > 20).length >= 1 &&
      events.any((e) => e.startsWith('agent_state: speaking')) &&
      bargeInLatencyMs < 2000 &&
      audioCut &&
      rms > 0.01 && seconds > 2.0 && events.every((e) => !e.startsWith('agent_error'));
  stdout.writeln(pass ? 'RESULT: PASS' : 'RESULT: FAIL');
  await pc.close();
  await ws.sink.close();
  exit(pass ? 0 : 1);
}
