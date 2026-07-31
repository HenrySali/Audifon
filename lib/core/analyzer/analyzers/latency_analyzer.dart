// Feature: in-app-diagnostic-analyzer
// Module: analyzers/latency_analyzer
//
// Selects the SEÑAL segment with the highest pre-RMS, computes a
// time-domain cross-correlation in lag range [-2400, +2400] samples
// (±50 ms at 48 kHz), normalizes the peak, and converts lag to ms via
// `lagSamples × 1000.0 / 48000.0`. Sets `lowConfidence` when
// |normalizedPeak| < 0.1 (Req. 10.6) or when no SEÑAL segment exists
// (Req. 10.7).

import 'dart:math' as math;
import 'dart:typed_data';

import '../constants.dart';
import '../result/latency_result.dart';
import '../result/snr_result.dart';

class LatencyAnalyzer {
  /// 1-s segment length (default 48 000 samples).
  final int segmentLength;

  LatencyAnalyzer({int? segmentLength})
      : segmentLength = segmentLength ?? kSampleRate * kSegmentDurationSec;

  /// Returns the index in `snr.classifications` of the SEÑAL segment with
  /// the highest pre-RMS, or `null` if none exists. Public so the
  /// ThdAnalyzer can reuse the same selection (Req. 11.1).
  int? bestSignalSegment(SnrResult snr) {
    int? bestIdx;
    double bestRms = -double.infinity;
    for (int s = 0; s < snr.classifications.length; s++) {
      if (snr.classifications[s] == SegmentClassification.signal) {
        final v = snr.rmsPreDbfs[s];
        if (v > bestRms) {
          bestRms = v;
          bestIdx = s;
        }
      }
    }
    return bestIdx;
  }

  LatencyResult analyze({
    required Float64List pre,
    required Float64List post,
    required SnrResult snr,
  }) {
    final segIdx = bestSignalSegment(snr);
    if (segIdx == null) {
      return const LatencyResult(
        lagSamples: -1,
        latencyMs: double.nan,
        normalizedPeak: double.nan,
        lowConfidence: true,
      );
    }
    final segStart = segIdx * segmentLength;
    final segEnd = math.min(segStart + segmentLength, math.min(pre.length, post.length));
    final segLen = segEnd - segStart;
    if (segLen <= 0) {
      return const LatencyResult(
        lagSamples: -1,
        latencyMs: double.nan,
        normalizedPeak: double.nan,
        lowConfidence: true,
      );
    }

    // Pre/Post slices.
    final segPre = Float64List(segLen);
    final segPost = Float64List(segLen);
    for (int i = 0; i < segLen; i++) {
      segPre[i] = pre[segStart + i];
      segPost[i] = post[segStart + i];
    }

    // Cross-correlation in lag range [-maxLag, +maxLag], capped by
    // segment length to avoid out-of-range access.
    final maxLag = math.min(kMaxLagSamples, segLen - 1);
    double bestAbs = -double.infinity;
    double bestVal = 0.0;
    int bestLag = 0;
    for (int lag = -maxLag; lag <= maxLag; lag++) {
      double sum = 0.0;
      if (lag >= 0) {
        // post[k+lag] · pre[k]  for k in [0, segLen − lag)
        final upper = segLen - lag;
        for (int k = 0; k < upper; k++) {
          sum += segPost[k + lag] * segPre[k];
        }
      } else {
        // post[k] · pre[k − lag]  for k in [0, segLen + lag)
        final upper = segLen + lag;
        final shift = -lag;
        for (int k = 0; k < upper; k++) {
          sum += segPost[k] * segPre[k + shift];
        }
      }
      final a = sum.abs();
      if (a > bestAbs) {
        bestAbs = a;
        bestVal = sum;
        bestLag = lag;
      }
    }

    // Normalization.
    double sumPreSq = 0.0;
    double sumPostSq = 0.0;
    for (int i = 0; i < segLen; i++) {
      sumPreSq += segPre[i] * segPre[i];
      sumPostSq += segPost[i] * segPost[i];
    }
    final denom = math.sqrt(sumPreSq * sumPostSq);
    final normPeak = denom > 0 ? bestVal / denom : double.nan;
    final lowConf = normPeak.isNaN ||
        normPeak.abs() < kLatencyLowConfidenceThreshold;

    final latencyMs = bestLag * 1000.0 / kSampleRate.toDouble();
    return LatencyResult(
      lagSamples: bestLag,
      latencyMs: latencyMs,
      normalizedPeak: normPeak,
      lowConfidence: lowConf,
    );
  }
}
