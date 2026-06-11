// Feature: in-app-diagnostic-analyzer
// Module: result/thd_result
//
// Output of the ThdAnalyzer. Fundamental frequency, THD percent, and the
// ANSI/ASA S3.22-2024 compliance flag.

class ThdResult {
  /// Dominant fundamental frequency (Hz). NaN when the fundamental
  /// magnitude is below `kThdLowMagnitudeThreshold`.
  final double fundamentalHz;

  /// `sqrt((P2+P3+P4+P5+P6) / P1) × 100`. NaN when fundamental is NaN.
  final double thdPercent;

  /// True when `thdPercent < kThdLimitPercent (5%)`. False when NaN.
  final bool compliantWithS322;

  const ThdResult({
    required this.fundamentalHz,
    required this.thdPercent,
    required this.compliantWithS322,
  });
}
