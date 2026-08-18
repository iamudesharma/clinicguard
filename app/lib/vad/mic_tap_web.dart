import 'dart:js_interop';

import 'package:flutter/foundation.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:web/web.dart' as web;

import 'barge_in_detector.dart';
import 'mic_tap.dart';

/// Web implementation: routes the mic MediaStream through an AudioContext
/// ScriptProcessorNode and feeds the PCM into [BargeInDetector]. The graph
/// ends in a zero-gain node so nothing is ever played back (no feedback).
///
/// Caveat: this tap reads the post-AEC track — the mic's WebRTC track is
/// captured with echoCancellation/noiseSuppression/autoGainControl on
/// (see voice_call_controller). Residual echo can still slip through on
/// loud speakers: use headphones or raise the detector's rmsThreshold
/// (BARGE_IN_RMS_THRESHOLD) when testing on speakers.
class _WebMicTap implements MicTap {
  web.AudioContext? _ctx;
  web.MediaStreamAudioSourceNode? _source;
  web.ScriptProcessorNode? _processor;
  web.GainNode? _mute;
  BargeInDetector? _detector;

  final Uint8List _pcm = Uint8List(8192); // 4096 samples * 2 bytes

  @override
  void start(MediaStream stream, BargeInDetector detector) {
    try {
      _detector = detector;
      final ctx = web.AudioContext();
      _ctx = ctx;
      // getUserMedia grants transient user activation; resume makes the
      // graph run (Chrome starts AudioContext suspended).
      ctx.resume();
      // On web the stream is dart_webrtc's MediaStreamWeb; expose its JS
      // stream to the AudioContext graph.
      final jsStream = (stream as dynamic).jsStream as web.MediaStream;
      final source = ctx.createMediaStreamSource(jsStream);
      _source = source;
      final processor = ctx.createScriptProcessor(4096, 1, 1);
      _processor = processor;
      processor.onaudioprocess = ((web.AudioProcessingEvent event) {
        final input = event.inputBuffer;
        final samples = input.getChannelData(0).toDart;
        _feed(samples, input.sampleRate);
      }).toJS;
      final mute = ctx.createGain();
      mute.gain.value = 0;
      _mute = mute;
      source.connect(processor);
      processor.connect(mute);
      mute.connect(ctx.destination);
      debugPrint('[barge-in] web mic tap started');
    } catch (e) {
      debugPrint('[barge-in] web mic tap failed, falling back to server: $e');
      stop();
    }
  }

  void _feed(Float32List samples, double sampleRate) {
    final detector = _detector;
    if (detector == null || samples.isEmpty) return;
    // Decimate to ~16 kHz (48k -> every 3rd sample; 44.1k -> every 2nd).
    final step = sampleRate > 20000 ? 3 : 2;
    final count = samples.length ~/ step;
    final bytes = _pcm;
    for (var i = 0; i < count; i++) {
      final v = (samples[i * step] * 32767).round().clamp(-32768, 32767);
      bytes[2 * i] = v & 0xff;
      bytes[2 * i + 1] = (v >> 8) & 0xff;
    }
    detector.process(Uint8List.sublistView(bytes, 0, 2 * count));
  }

  @override
  void stop() {
    final processor = _processor;
    if (processor != null) processor.onaudioprocess = null;
    _source?.disconnect();
    _processor?.disconnect();
    _mute?.disconnect();
    _source = null;
    _processor = null;
    _mute = null;
    _ctx?.close();
    _ctx = null;
    _detector = null;
  }
}

MicTap createMicTapImpl() => _WebMicTap();
