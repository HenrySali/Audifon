// Feature: in-app-diagnostic-analyzer
// Module: analyzers/audiogram_inverter
//
// Inverts the simplified NAL-NL2 base curve documented in
// `web-simulator/src/audiogram/prescription-engine.js`:
//
//   G65 = 0.31 · T_SPL − 5.0
//   ⇒  T_SPL = (G65 + 5.0) / 0.31
//   T_HL = T_SPL − RETSPL(f)
//   T_HL = clamp(T_HL, 0, 120)
//
// Propagates NaN gain → NaN threshold (Req. 13.6).

import 'dart:typed_data';

import '../constants.dart';
import '../result/audiogram_comparison_result.dart';

class AudiogramInverter {
  /// Inverts measured per-band gains to inferred dB HL thresholds and
  /// pairs them with the reference thresholds from DSP_Metadata.
  AudiogramComparisonResult invert({
    required Float64List measuredGainsDb,
    required Map<int, double> referenceThresholds,
  }) {
    if (measuredGainsDb.length != kAudiometricBandsHz.length) {
      throw ArgumentError(
        'measuredGainsDb must have ${kAudiometricBandsHz.length} elements '
        '(got ${measuredGainsDb.length})',
      );
    }
    final inferred = Float64List(kAudiometricBandsHz.length);
    final reference = Float64List(kAudiometricBandsHz.length);
    for (int i = 0; i < kAudiometricBandsHz.length; i++) {
      final f = kAudiometricBandsHz[i];
      final g = measuredGainsDb[i];
      if (g.isNaN) {
        inferred[i] = double.nan;
      } else {
        final tSpl = (g + 5.0) / 0.31;
        final retspl = kRetsplDb[f]!;
        final tHl = tSpl - retspl;
        inferred[i] = tHl.clamp(0.0, 120.0);
      }
      reference[i] = referenceThresholds[f] ?? double.nan;
    }
    return AudiogramComparisonResult(
      frequenciesHz: List<int>.unmodifiable(kAudiometricBandsHz),
      inferredThresholdsDbHl: inferred,
      referenceThresholdsDbHl: reference,
    );
  }
}
