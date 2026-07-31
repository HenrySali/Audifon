// Feature: in-app-diagnostic-analyzer
// Module: result/audiogram_comparison_result
//
// Output of the AudiogramInverter. Inferred audiogram in dB HL plus the
// reference audiogram from DSP_Metadata, both index-aligned to the 12
// audiometric bands.

import 'dart:typed_data';

class AudiogramComparisonResult {
  /// 12 audiometric center frequencies (Hz).
  final List<int> frequenciesHz;

  /// Inferred dB HL thresholds (length 12). NaN propagates from NaN gains.
  final Float64List inferredThresholdsDbHl;

  /// Reference dB HL thresholds from DSP_Metadata (length 12). Bands not
  /// present in the metadata map are reported as NaN.
  final Float64List referenceThresholdsDbHl;

  const AudiogramComparisonResult({
    required this.frequenciesHz,
    required this.inferredThresholdsDbHl,
    required this.referenceThresholdsDbHl,
  });
}
