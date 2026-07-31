// Feature: in-app-diagnostic-analyzer
// Module: analyzers/quality_analyzer
//
// Full-recording RMS pre/post, Global_Gain, peak in dBFS, clipping
// percent at |s| > 0.99 (Req. 12).

import 'dart:math' as math;
import 'dart:typed_data';

import '../constants.dart';
import '../result/quality_result.dart';

class QualityAnalyzer {
  QualityResult analyze({
    required Float64List pre,
    required Float64List post,
  }) {
    final preStats = _channelStats(pre);
    final postStats = _channelStats(post);
    final rmsPreDbfs = _todB(preStats.rms);
    final rmsPostDbfs = _todB(postStats.rms);
    return QualityResult(
      globalGainDb: rmsPostDbfs - rmsPreDbfs,
      rmsPreDbfs: rmsPreDbfs,
      rmsPostDbfs: rmsPostDbfs,
      peakPreDbfs: _todB(preStats.peak),
      peakPostDbfs: _todB(postStats.peak),
      clippingPrePercent: preStats.clippingPercent,
      clippingPostPercent: postStats.clippingPercent,
    );
  }

  static double _todB(double x) {
    return 20.0 * (math.log(x + kPsdEpsilon) / math.ln10);
  }

  static _ChannelStats _channelStats(Float64List signal) {
    if (signal.isEmpty) {
      return const _ChannelStats(rms: 0.0, peak: 0.0, clippingPercent: 0.0);
    }
    double sumSq = 0.0;
    double peak = 0.0;
    int clippedCount = 0;
    for (int i = 0; i < signal.length; i++) {
      final v = signal[i];
      sumSq += v * v;
      final a = v.abs();
      if (a > peak) peak = a;
      if (a > kClippingThreshold) clippedCount++;
    }
    final rms = math.sqrt(sumSq / signal.length);
    return _ChannelStats(
      rms: rms,
      peak: peak,
      clippingPercent: 100.0 * clippedCount / signal.length,
    );
  }
}

class _ChannelStats {
  final double rms;
  final double peak;
  final double clippingPercent;
  const _ChannelStats({
    required this.rms,
    required this.peak,
    required this.clippingPercent,
  });
}
