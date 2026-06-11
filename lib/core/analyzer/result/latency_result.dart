// Feature: in-app-diagnostic-analyzer
// Module: result/latency_result
//
// Output of the LatencyAnalyzer. Lag in samples, latency in ms, normalized
// peak correlation, and a low-confidence flag.

class LatencyResult {
  /// Lag in samples corresponding to the maximum |xcorr|. `-1` when no
  /// SEÑAL segment exists (Req. 10.7).
  final int lagSamples;

  /// `lagSamples × 1000.0 / 48000.0`. NaN when no SEÑAL segment exists.
  final double latencyMs;

  /// `xcorr_max / sqrt(sum(seg_pre²) · sum(seg_post²))`. NaN when no
  /// SEÑAL segment exists.
  final double normalizedPeak;

  /// True when |normalizedPeak| < 0.1 (Req. 10.6) or when no segment was
  /// available (Req. 10.7).
  final bool lowConfidence;

  const LatencyResult({
    required this.lagSamples,
    required this.latencyMs,
    required this.normalizedPeak,
    required this.lowConfidence,
  });
}
