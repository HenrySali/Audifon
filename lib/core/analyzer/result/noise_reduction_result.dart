// Feature: in-app-diagnostic-analyzer
// Module: result/noise_reduction_result
//
// Output of the NoiseReductionAnalyzer. Per-band NR / signal-gain values
// over the 6 spectral NR bands plus their Spanish-language evaluations.

import 'dart:typed_data';

class NoiseReductionResult {
  /// Spanish names of the 6 spectral NR bands.
  final List<String> bandNames;

  /// Low edge of each band (Hz).
  final List<int> bandLowHz;

  /// High edge of each band (Hz).
  final List<int> bandHighHz;

  /// Mean Spectral_Gain_Curve over each band on the noise-only
  /// concatenation (dB). NaN when fewer than 2 RUIDO segments.
  final Float64List noiseReductionDb;

  /// Mean Spectral_Gain_Curve over each band on the signal-only
  /// concatenation (dB). NaN when fewer than 2 SEÑAL segments.
  final Float64List signalGainDb;

  /// Per-band Spanish evaluation of `noiseReductionDb`.
  final List<String> noiseEvaluations;

  /// Per-band Spanish evaluation of `signalGainDb`.
  final List<String> signalEvaluations;

  /// True when fewer than 2 RUIDO segments are available.
  final bool noiseInsufficient;

  /// True when fewer than 2 SEÑAL segments are available.
  final bool signalInsufficient;

  const NoiseReductionResult({
    required this.bandNames,
    required this.bandLowHz,
    required this.bandHighHz,
    required this.noiseReductionDb,
    required this.signalGainDb,
    required this.noiseEvaluations,
    required this.signalEvaluations,
    required this.noiseInsufficient,
    required this.signalInsufficient,
  });
}
