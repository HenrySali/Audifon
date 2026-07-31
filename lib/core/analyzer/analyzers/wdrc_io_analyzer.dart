// Feature: in-app-diagnostic-analyzer
// Module: analyzers/wdrc_io_analyzer
//
// 1-second segments aligned with SnrAnalyzer, sort by pre-RMS, tercile
// partition (Baja / Media / Alta), per-zone OLS regression, raw IEEE 754
// `1.0 / slope_alta` for the observed compression ratio. NaN+flag for
// zones with < 2 segments (Req. 9.7).

import 'dart:math' as math;
import 'dart:typed_data';

import '../constants.dart';
import '../result/wdrc_io_result.dart';

class WdrcIoAnalyzer {
  /// 1-s segment length (default 48 000 samples).
  final int segmentLength;

  WdrcIoAnalyzer({int? segmentLength})
      : segmentLength = segmentLength ?? kSampleRate * kSegmentDurationSec;

  WdrcIoResult analyze({
    required Float64List pre,
    required Float64List post,
    required double configuredCompressionRatio,
  }) {
    final n = math.min(pre.length, post.length);
    final segCount = n ~/ segmentLength;

    final inDb = Float64List(segCount);
    final outDb = Float64List(segCount);
    for (int s = 0; s < segCount; s++) {
      final start = s * segmentLength;
      double sumIn = 0.0;
      double sumOut = 0.0;
      for (int i = 0; i < segmentLength; i++) {
        final p = pre[start + i];
        final q = post[start + i];
        sumIn += p * p;
        sumOut += q * q;
      }
      final rmsIn = math.sqrt(sumIn / segmentLength);
      final rmsOut = math.sqrt(sumOut / segmentLength);
      inDb[s] = 20.0 * (math.log(rmsIn + kPsdEpsilon) / math.ln10);
      outDb[s] = 20.0 * (math.log(rmsOut + kPsdEpsilon) / math.ln10);
    }

    // Sort indices by inDb ascending.
    final indices = List<int>.generate(segCount, (i) => i);
    indices.sort((a, b) => inDb[a].compareTo(inDb[b]));

    final sortedIn = Float64List(segCount);
    final sortedOut = Float64List(segCount);
    final allPoints = <WdrcIoPoint>[];
    for (int i = 0; i < segCount; i++) {
      sortedIn[i] = inDb[indices[i]];
      sortedOut[i] = outDb[indices[i]];
      allPoints.add(WdrcIoPoint(sortedIn[i], sortedOut[i]));
    }

    // Tercile boundaries — Octave-style 1-based round-to-nearest.
    final t1 = segCount == 0 ? 0 : math.max(1, (segCount * 0.33).round());
    final t2 = segCount == 0 ? 0 : math.max(t1, (segCount * 0.66).round());

    final low = _zone(
      name: 'Baja (exp)',
      sortedIn: sortedIn,
      sortedOut: sortedOut,
      from: 0,
      to: t1,
    );
    final mid = _zone(
      name: 'Media (lin)',
      sortedIn: sortedIn,
      sortedOut: sortedOut,
      from: t1,
      to: t2,
    );
    final high = _zone(
      name: 'Alta (comp)',
      sortedIn: sortedIn,
      sortedOut: sortedOut,
      from: t2,
      to: segCount,
    );

    // Raw IEEE 754 1.0 / slope_alta. NaN propagates; ±0 ⇒ ±∞.
    final observedRatio = 1.0 / high.slope;

    return WdrcIoResult(
      low: low,
      mid: mid,
      high: high,
      observedCompressionRatio: observedRatio,
      configuredCompressionRatio: configuredCompressionRatio,
      allPoints: List<WdrcIoPoint>.unmodifiable(allPoints),
      sortedInputDbfs: sortedIn,
      sortedOutputDbfs: sortedOut,
    );
  }

  WdrcZoneResult _zone({
    required String name,
    required Float64List sortedIn,
    required Float64List sortedOut,
    required int from,
    required int to,
  }) {
    final count = to - from;
    final points = <WdrcIoPoint>[];
    for (int i = from; i < to; i++) {
      points.add(WdrcIoPoint(sortedIn[i], sortedOut[i]));
    }
    if (count == 0) {
      return WdrcZoneResult(
        name: name,
        meanInputDbfs: double.nan,
        meanOutputDbfs: double.nan,
        meanGainDb: double.nan,
        slope: double.nan,
        intercept: double.nan,
        points: List<WdrcIoPoint>.unmodifiable(points),
        insufficientData: true,
      );
    }
    double sumIn = 0.0;
    double sumOut = 0.0;
    for (int i = from; i < to; i++) {
      sumIn += sortedIn[i];
      sumOut += sortedOut[i];
    }
    final meanIn = sumIn / count;
    final meanOut = sumOut / count;

    double slope = double.nan;
    double intercept = double.nan;
    double meanGain = double.nan;
    bool insufficient = count < 2;
    if (count >= 2) {
      double sxx = 0.0;
      double sxy = 0.0;
      for (int i = from; i < to; i++) {
        final dx = sortedIn[i] - meanIn;
        final dy = sortedOut[i] - meanOut;
        sxx += dx * dx;
        sxy += dx * dy;
      }
      if (sxx == 0.0) {
        slope = double.nan;
        intercept = double.nan;
      } else {
        slope = sxy / sxx;
        intercept = meanOut - slope * meanIn;
      }
      meanGain = meanOut - meanIn;
    }

    return WdrcZoneResult(
      name: name,
      meanInputDbfs: meanIn,
      meanOutputDbfs: meanOut,
      meanGainDb: meanGain,
      slope: slope,
      intercept: intercept,
      points: List<WdrcIoPoint>.unmodifiable(points),
      insufficientData: insufficient,
    );
  }
}
