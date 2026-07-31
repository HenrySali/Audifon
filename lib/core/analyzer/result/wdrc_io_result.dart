// Feature: in-app-diagnostic-analyzer
// Module: result/wdrc_io_result
//
// Output of the WdrcIoAnalyzer. Three zone results (Baja / Media / Alta),
// the IEEE-754 observed compression ratio, the configured ratio, and the
// per-segment scatter points.

import 'dart:typed_data';

/// Represents a single (input_db, output_db) point on the WDRC I/O curve.
class WdrcIoPoint {
  final double inDb;
  final double outDb;

  const WdrcIoPoint(this.inDb, this.outDb);
}

class WdrcZoneResult {
  /// Display name of the zone in Spanish (e.g. "Baja (exp)").
  final String name;

  /// Mean input level over the zone (dBFS). NaN when empty.
  final double meanInputDbfs;

  /// Mean output level over the zone (dBFS). NaN when empty.
  final double meanOutputDbfs;

  /// Mean output−input gain over the zone (dB). NaN when < 2 segments.
  final double meanGainDb;

  /// OLS slope of `output_db = slope·input_db + intercept`. NaN when
  /// < 2 segments.
  final double slope;

  /// OLS intercept. NaN when < 2 segments.
  final double intercept;

  /// Raw (input, output) points belonging to the zone.
  final List<WdrcIoPoint> points;

  /// True when the zone has fewer than 2 segments.
  final bool insufficientData;

  const WdrcZoneResult({
    required this.name,
    required this.meanInputDbfs,
    required this.meanOutputDbfs,
    required this.meanGainDb,
    required this.slope,
    required this.intercept,
    required this.points,
    required this.insufficientData,
  });
}

class WdrcIoResult {
  final WdrcZoneResult low;
  final WdrcZoneResult mid;
  final WdrcZoneResult high;

  /// `1.0 / high.slope` evaluated as raw IEEE-754. Propagates ±∞ and NaN
  /// without sentinel substitution (Req. 9.5).
  final double observedCompressionRatio;

  /// Configured `compressionRatio` from DSP_Metadata.
  final double configuredCompressionRatio;

  /// All per-segment points, in input-RMS sorted order.
  final List<WdrcIoPoint> allPoints;

  /// Per-segment input RMS in dBFS (sorted ascending).
  final Float64List sortedInputDbfs;

  /// Per-segment output RMS in dBFS (sorted by `sortedInputDbfs`).
  final Float64List sortedOutputDbfs;

  const WdrcIoResult({
    required this.low,
    required this.mid,
    required this.high,
    required this.observedCompressionRatio,
    required this.configuredCompressionRatio,
    required this.allPoints,
    required this.sortedInputDbfs,
    required this.sortedOutputDbfs,
  });
}
