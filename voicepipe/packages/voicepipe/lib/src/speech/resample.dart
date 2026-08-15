/// Minimal linear resamplers for the voice pipeline.
///
/// The WebRTC path carries 48 kHz stereo; VAD/STT run at 16 kHz mono and
/// TTS (piper) outputs 22.05 kHz mono. Quality is "good enough for a demo
/// voice loop": a short moving-average low-pass before decimation and
/// linear interpolation for upsampling.
library;

import 'dart:math';
import 'dart:typed_data';

/// Downmix stereo interleaved to mono, then decimate [srcRate] -> [dstRate]
/// with a 5-tap moving-average low-pass. [srcRate] must be a multiple of
/// [dstRate] for exact ratios.
Float32List downmixAndResample(Int16List pcm, int srcRate, int srcChannels, int dstRate) {
  final mono = Float32List(pcm.length ~/ srcChannels);
  for (var i = 0; i < mono.length; i++) {
    var sum = 0;
    for (var c = 0; c < srcChannels; c++) {
      sum += pcm[i * srcChannels + c];
    }
    mono[i] = (sum / srcChannels) / 32768.0;
  }
  if (srcRate == dstRate) return mono;

  final ratio = srcRate ~/ dstRate;
  final out = Float32List(mono.length ~/ ratio);
  for (var i = 0; i < out.length; i++) {
    // moving average over `ratio` input samples (cheap low-pass)
    var acc = 0.0;
    final start = i * ratio;
    for (var j = 0; j < ratio; j++) {
      acc += mono[start + j];
    }
    out[i] = acc / ratio;
  }
  return out;
}

/// Upsample mono [srcRate] -> [dstRate] with linear interpolation.
Float32List resampleUp(Float32List samples, int srcRate, int dstRate) {
  if (srcRate == dstRate) return samples;
  final out = Float32List((samples.length * dstRate / srcRate).round());
  final step = srcRate / dstRate;
  for (var i = 0; i < out.length; i++) {
    final pos = i * step;
    final lo = pos.floor();
    final hi = min(lo + 1, samples.length - 1);
    final frac = pos - lo;
    out[i] = samples[lo] + (samples[hi] - samples[lo]) * frac;
  }
  return out;
}

/// Float32 [-1,1] mono -> Int16 interleaved with [channels] copies.
Int16List toPcm16Stereo(Float32List samples, int channels) {
  final out = Int16List(samples.length * channels);
  for (var i = 0; i < samples.length; i++) {
    final v = (samples[i].clamp(-1.0, 1.0) * 32767).round();
    for (var c = 0; c < channels; c++) {
      out[i * channels + c] = v;
    }
  }
  return out;
}
