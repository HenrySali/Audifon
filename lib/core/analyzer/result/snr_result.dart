// Feature: in-app-diagnostic-analyzer
// Module: result/snr_result
//
// Output of the SnrAnalyzer. Carries per-segment classifications used by
// downstream analyzers (NoiseReduction, WdrcIo, Latency, Thd).

import 'dart:typed_data';

/// VAD_Classification of a 1-second segment based on the pre-channel RMS
/// percentile.
enum SegmentClassification { noise, signal, transition }

class SnrResult {
  /// `mean(rms_pre_db_signal) − mean(rms_pre_db_noise)`. NaN when either
  /// class has no segments.
  final double snrPreDb;

  /// `mean(rms_post_db_signal) − mean(rms_post_db_noise)`. NaN when either
  /// class has no segments.
  final double snrPostDb;

  /// `snrPostDb − snrPreDb`. NaN when either is NaN.
  final double snrImprovementDb;

  /// Number of RUIDO segments.
  final int noiseSegmentCount;

  /// Number of SEÑAL segments.
  final int signalSegmentCount;

  /// Number of TRANSICIÓN segments.
  final int transitionSegmentCount;

  /// True when noise=0 or signal=0; mirrors NaN values above.
  final bool insufficientVad;

  /// Per-segment VAD classification (length = number of 1-s segments).
  final List<SegmentClassification> classifications;

  /// Per-segment pre RMS in dBFS.
  final Float64List rmsPreDbfs;

  /// Per-segment post RMS in dBFS.
  final Float64List rmsPostDbfs;

  const SnrResult({
    required this.snrPreDb,
    required this.snrPostDb,
    required this.snrImprovementDb,
    required this.noiseSegmentCount,
    required this.signalSegmentCount,
    required this.transitionSegmentCount,
    required this.insufficientVad,
    required this.classifications,
    required this.rmsPreDbfs,
    required this.rmsPostDbfs,
  });
}
