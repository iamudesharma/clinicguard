import 'dart:math';
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:voice_forge/src/speech/resample.dart';

void main() {
  test('downmix stereo to mono averages channels', () {
    final stereo = Int16List.fromList([1000, 2000, 3000, 4000]);
    final mono = downmixAndResample(stereo, 48000, 2, 48000);
    expect(mono.length, 2);
    expect(mono[0], closeTo(1500 / 32768, 0.001));
    expect(mono[1], closeTo(3500 / 32768, 0.001));
  });

  test('decimation 48k -> 16k preserves a tone (length ratio)', () {
    const rate = 48000;
    final n = rate * 2; // 1s stereo
    final pcm = Int16List(n);
    for (var i = 0; i < n ~/ 2; i++) {
      final v = (0.5 * sin(2 * pi * 440 * i / rate) * 32767).round();
      pcm[i * 2] = v;
      pcm[i * 2 + 1] = v;
    }
    final mono16k = downmixAndResample(pcm, rate, 2, 16000);
    expect(mono16k.length, rate ~/ 3); // exactly 1/3 of the mono length
    final rms = sqrt(
      mono16k.map((s) => s * s).reduce((a, b) => a + b) / mono16k.length,
    );
    // 0.5 amplitude tone -> rms ~0.354
    expect(rms, closeTo(0.354, 0.05));
  });

  test('upsample 22050 -> 48000 keeps length ratio and continuity', () {
    final src = Float32List(22050); // 1s
    for (var i = 0; i < src.length; i++) {
      src[i] = sin(2 * pi * 440 * i / 22050);
    }
    final up = resampleUp(src, 22050, 48000);
    expect(up.length, closeTo(48000, 1));
    // No zero gaps (interpolation continuity).
    var zeros = 0;
    for (final s in up) {
      if (s == 0) zeros++;
    }
    expect(zeros, lessThan(50));
  });

  test('toPcm16Stereo duplicates channels', () {
    final mono = Float32List.fromList([0.5, -0.5]);
    final stereo = toPcm16Stereo(mono, 2);
    expect(stereo.length, 4);
    expect(stereo[0], stereo[1]);
    expect(stereo[0], (0.5 * 32767).round());
    expect(stereo[3], (-0.5 * 32767).round());
  });
}
