// Feature: in-app-diagnostic-analyzer
// Module: result/quality_result
//
// Output of the QualityAnalyzer. Full-recording RMS, peak, and clipping
// metrics for both channels plus the global gain.

class QualityResult {
  /// `20·log10(rms_post + ε) − 20·log10(rms_pre + ε)`.
  final double globalGainDb;

  /// Pre channel RMS in dBFS.
  final double rmsPreDbfs;

  /// Post channel RMS in dBFS.
  final double rmsPostDbfs;

  /// Pre channel peak in dBFS.
  final double peakPreDbfs;

  /// Post channel peak in dBFS.
  final double peakPostDbfs;

  /// Percent of pre-channel samples whose absolute value exceeds 0.99.
  final double clippingPrePercent;

  /// Percent of post-channel samples whose absolute value exceeds 0.99.
  final double clippingPostPercent;

  const QualityResult({
    required this.globalGainDb,
    required this.rmsPreDbfs,
    required this.rmsPostDbfs,
    required this.peakPreDbfs,
    required this.peakPostDbfs,
    required this.clippingPrePercent,
    required this.clippingPostPercent,
  });
}
