import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:clinic_guard/vad/barge_in_detector.dart';

Uint8List _pcmFrames(int count, double amplitude) {
  final bytes = Uint8List(count * 2);
  const freq = 440.0;
  const rate = 16000.0;
  for (var i = 0; i < count; i++) {
    final v = (sin(2 * pi * freq * i / rate) * amplitude * 32767).round();
    bytes[i * 2] = v & 0xff;
    bytes[i * 2 + 1] = (v >> 8) & 0xff;
  }
  return bytes;
}


void main() {
  test('detects speech start on loud audio and end on silence', () {
    var starts = 0, ends = 0;
    final vad = BargeInDetector(
      rmsThreshold: 0.05,
      voicedFramesToStart: 2,
      silentFramesToEnd: 6,
      onSpeechStart: () => starts++,
      onSpeechEnd: () => ends++,
    );

    // 0.4s loud (amplitude 0.5 -> rms ~0.35) in 20ms frames
    for (var i = 0; i < 20; i++) {
      vad.process(_pcmFrames(320, 0.5));
    }
    expect(starts, 1, reason: 'speech start must fire exactly once');
    expect(vad.isSpeaking, isTrue);

    // 0.6s silence (rms 0)
    for (var i = 0; i < 30; i++) {
      vad.process(_pcmFrames(320, 0.0));
    }
    expect(ends, 1, reason: 'speech end must fire after hangover');
    expect(vad.isSpeaking, isFalse);
  });

  test('ignores brief noise spikes (needs consecutive voiced windows)', () {
    var starts = 0;
    final vad = BargeInDetector(
      rmsThreshold: 0.05,
      voicedFramesToStart: 3,
      silentFramesToEnd: 6,
      onSpeechStart: () => starts++,
      onSpeechEnd: () {},
    );
    // two loud frames then silence - below the 3-frame threshold
    vad.process(_pcmFrames(320, 0.5));
    vad.process(_pcmFrames(320, 0.5));
    for (var i = 0; i < 10; i++) {
      vad.process(_pcmFrames(320, 0.0));
    }
    expect(starts, 0, reason: 'short noise must not trigger barge-in');
  });

  test('threshold gates quiet audio', () {
    var starts = 0;
    final vad = BargeInDetector(
      rmsThreshold: 0.1,
      voicedFramesToStart: 2,
      silentFramesToEnd: 4,
      onSpeechStart: () => starts++,
      onSpeechEnd: () {},
    );
    // amplitude 0.03 -> rms ~0.02, below threshold
    for (var i = 0; i < 10; i++) {
      vad.process(_pcmFrames(320, 0.03));
    }
    expect(starts, 0);
  });
}
