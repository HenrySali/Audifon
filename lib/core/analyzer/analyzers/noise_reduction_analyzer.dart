// Feature: in-app-diagnostic-analyzer
// Module: analyzers/noise_reduction_analyzer
//
// Concatenates the noise-only and signal-only segments using
// SnrResult.classifications, runs Welch_PSD on each concatenation, and
// averages the per-bin Spectral_Gain_Curve over each of the 6 spectral
// NR bands. NaN + flag when fewer than 2 segments per class (Req. 8.5,
// 8.6).

import 'dart:math' as math;
import 'dart:typed_data';

import '../constants.dart';
import '../dsp/welch_psd.dart';
import '../result/noise_reduction_result.dart';
import '../result/snr_result.dart';

class NoiseReductionAnalyzer {
  /// Segment length in samples (default 1 s @ 48 kHz).
  final int segmentLength;

  NoiseReductionAnalyzer({int? segmentLength})
      : segmentLength = segmentLength ?? kSampleRate * kSegmentDurationSec;

  NoiseReductionResult analyze({
    required Float64List pre,
    required Float64List post,
    required SnrResult snr,
    required int sampleRate,
  }) {
    final n = math.min(pre.length, post.length);
    final classifications = snr.classifications;
    final segCount = classifications.length;

    final noiseIdx = <int>[];
    final signalIdx = <int>[];
    for (int s = 0; s < segCount; s++) {
      if (classifications[s] == SegmentClassification.noise) {
        noiseIdx.add(s);
      } else if (classifications[s] == SegmentClassification.signal) {
        signalIdx.add(s);
      }
    }

    final noiseInsufficient = noiseIdx.length < 2;
    final signalInsufficient = signalIdx.length < 2;

    final bandCount = kSpectralNrBandsLowHz.length;
    final noiseDb = Float64List(bandCount);
    final signalDb = Float64List(bandCount);
    for (int b = 0; b < bandCount; b++) {
      noiseDb[b] = double.nan;
      signalDb[b] = double.nan;
    }

    if (!noiseInsufficient) {
      _fillBandGains(
        pre: pre,
        post: post,
        n: n,
        segIndices: noiseIdx,
        sampleRate: sampleRate,
        out: noiseDb,
      );
    }
    if (!signalInsufficient) {
      _fillBandGains(
        pre: pre,
        post: post,
        n: n,
        segIndices: signalIdx,
        sampleRate: sampleRate,
        out: signalDb,
      );
    }

    final noiseEvals = <String>[];
    final signalEvals = <String>[];
    for (int b = 0; b < bandCount; b++) {
      noiseEvals.add(_evaluateNoise(noiseDb[b]));
      signalEvals.add(_evaluateSignal(signalDb[b]));
    }

    return NoiseReductionResult(
      bandNames: List<String>.unmodifiable(kSpectralNrBandNames),
      bandLowHz: List<int>.unmodifiable(kSpectralNrBandsLowHz),
      bandHighHz: List<int>.unmodifiable(kSpectralNrBandsHighHz),
      noiseReductionDb: noiseDb,
      signalGainDb: signalDb,
      noiseEvaluations: List<String>.unmodifiable(noiseEvals),
      signalEvaluations: List<String>.unmodifiable(signalEvals),
      noiseInsufficient: noiseInsufficient,
      signalInsufficient: signalInsufficient,
    );
  }

  void _fillBandGains({
    required Float64List pre,
    required Float64List post,
    required int n,
    required List<int> segIndices,
    required int sampleRate,
    required Float64List out,
  }) {
    final concatPre = Float64List(segIndices.length * segmentLength);
    final concatPost = Float64List(segIndices.length * segmentLength);
    int dst = 0;
    for (final s in segIndices) {
      final start = s * segmentLength;
      final end = math.min(start + segmentLength, n);
      for (int i = start; i < end; i++) {
        concatPre[dst] = pre[i];
        concatPost[dst] = post[i];
        dst++;
      }
      // Zero-pad if the last segment is short (degenerate edge).
      while (dst % segmentLength != 0) {
        concatPre[dst] = 0.0;
        concatPost[dst] = 0.0;
        dst++;
      }
    }
    final psd = WelchPsd();
    final psdPre = psd.compute(concatPre, sampleRate);
    final psdPost = psd.compute(concatPost, sampleRate);
    final freqs = psdPre.frequencies;
    final binCount = psdPre.power.length;
    final gain = Float64List(binCount);
    for (int k = 0; k < binCount; k++) {
      final p10 = 10.0 *
          (math.log(psdPre.power[k] + kPsdEpsilon) / math.ln10);
      final q10 = 10.0 *
          (math.log(psdPost.power[k] + kPsdEpsilon) / math.ln10);
      gain[k] = q10 - p10;
    }
    for (int b = 0; b < kSpectralNrBandsLowHz.length; b++) {
      final lo = kSpectralNrBandsLowHz[b].toDouble();
      final hi = kSpectralNrBandsHighHz[b].toDouble();
      double sum = 0.0;
      int count = 0;
      for (int k = 0; k < binCount; k++) {
        final f = freqs[k];
        if (f >= lo && f <= hi) {
          sum += gain[k];
          count++;
        }
      }
      out[b] = count == 0 ? double.nan : sum / count;
    }
  }

  /// Evaluation table from the Octave reference (Spanish).
  static String _evaluateNoise(double v) {
    if (v.isNaN) return 'Sin datos';
    if (v < -6.0) return 'EXCELENTE reduccion';
    if (v < -3.0) return 'BUENA reduccion';
    if (v < -1.0) return 'Leve reduccion';
    if (v < 0.0) return 'Neutro';
    if (v <= 3.0) return 'Neutro';
    return 'AMPLIFICA (problema!)';
  }

  static String _evaluateSignal(double v) {
    if (v.isNaN) return 'Sin datos';
    if (v < -3.0) return 'ATENUA señal (problema?)';
    if (v < 0.0) return 'Neutro/leve atenuacion';
    if (v <= 3.0) return 'Leve amplificacion';
    if (v <= 5.0) return 'Leve amplificacion';
    return 'AMPLIFICA bien';
  }
}
