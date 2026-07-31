// Feature: in-app-diagnostic-analyzer
// Module: analyzers/snr_analyzer
//
// 1-second non-overlapping segmentation, per-segment RMS in dBFS,
// percentile VAD over the pre-channel RMS distribution, SNR pre/post and
// improvement, and exposes the per-segment classification list for the
// downstream NoiseReduction / WdrcIo / Latency / Thd analyzers.

import 'dart:math' as math;
import 'dart:typed_data';

import '../constants.dart';
import '../result/snr_result.dart';

class SnrAnalyzer {
  /// `segmentLength` defaults to 1 second at 48 kHz (48 000 samples).
  final int segmentLength;

  SnrAnalyzer({int? segmentLength})
      : segmentLength = segmentLength ?? kSampleRate * kSegmentDurationSec;

  SnrResult analyze({
    required Float64List pre,
    required Float64List post,
  }) {
    final n = math.min(pre.length, post.length);
    final segCount = n ~/ segmentLength;

    if (segCount == 0) {
      return SnrResult(
        snrPreDb: double.nan,
        snrPostDb: double.nan,
        snrImprovementDb: double.nan,
        noiseSegmentCount: 0,
        signalSegmentCount: 0,
        transitionSegmentCount: 0,
        insufficientVad: true,
        classifications: const <SegmentClassification>[],
        rmsPreDbfs: Float64List(0),
        rmsPostDbfs: Float64List(0),
      );
    }

    final rmsPreDb = Float64List(segCount);
    final rmsPostDb = Float64List(segCount);

    for (int s = 0; s < segCount; s++) {
      final start = s * segmentLength;
      double sumPre = 0.0;
      double sumPost = 0.0;
      for (int i = 0; i < segmentLength; i++) {
        final p = pre[start + i];
        final q = post[start + i];
        sumPre += p * p;
        sumPost += q * q;
      }
      final rmsPre = math.sqrt(sumPre / segmentLength);
      final rmsPost = math.sqrt(sumPost / segmentLength);
      rmsPreDb[s] = 20.0 * (math.log(rmsPre + kPsdEpsilon) / math.ln10);
      rmsPostDb[s] = 20.0 * (math.log(rmsPost + kPsdEpsilon) / math.ln10);
    }

    // Percentile thresholds on the pre-channel RMS distribution.
    final sorted = Float64List.fromList(rmsPreDb)..sort();
    final q1 = _percentile(sorted, 0.25);
    final q3 = _percentile(sorted, 0.75);

    final classifications =
        List<SegmentClassification>.filled(segCount, SegmentClassification.transition);
    int noise = 0;
    int signal = 0;
    int trans = 0;
    for (int s = 0; s < segCount; s++) {
      final v = rmsPreDb[s];
      if (v <= q1) {
        classifications[s] = SegmentClassification.noise;
        noise++;
      } else if (v >= q3) {
        classifications[s] = SegmentClassification.signal;
        signal++;
      } else {
        classifications[s] = SegmentClassification.transition;
        trans++;
      }
    }

    final insufficient = noise == 0 || signal == 0;

    double snrPre = double.nan;
    double snrPost = double.nan;
    double snrImp = double.nan;
    if (!insufficient) {
      double sumPreNoise = 0.0;
      double sumPreSig = 0.0;
      double sumPostNoise = 0.0;
      double sumPostSig = 0.0;
      for (int s = 0; s < segCount; s++) {
        switch (classifications[s]) {
          case SegmentClassification.noise:
            sumPreNoise += rmsPreDb[s];
            sumPostNoise += rmsPostDb[s];
          case SegmentClassification.signal:
            sumPreSig += rmsPreDb[s];
            sumPostSig += rmsPostDb[s];
          case SegmentClassification.transition:
            break;
        }
      }
      snrPre = sumPreSig / signal - sumPreNoise / noise;
      snrPost = sumPostSig / signal - sumPostNoise / noise;
      snrImp = snrPost - snrPre;
    }

    return SnrResult(
      snrPreDb: snrPre,
      snrPostDb: snrPost,
      snrImprovementDb: snrImp,
      noiseSegmentCount: noise,
      signalSegmentCount: signal,
      transitionSegmentCount: trans,
      insufficientVad: insufficient,
      classifications: List.unmodifiable(classifications),
      rmsPreDbfs: rmsPreDb,
      rmsPostDbfs: rmsPostDb,
    );
  }

  /// Linear percentile of a sorted Float64List using the
  /// "round-to-nearest-1-based-index" convention used by Octave's percentile
  /// helper inside the golden reference. `p` is in [0, 1].
  static double _percentile(Float64List sorted, double p) {
    final n = sorted.length;
    if (n == 0) return double.nan;
    if (n == 1) return sorted[0];
    // Octave-style: idx = round(p · n), clamped to [1, n], 1-based.
    int idx = (p * n).round();
    if (idx < 1) idx = 1;
    if (idx > n) idx = n;
    return sorted[idx - 1];
  }
}
