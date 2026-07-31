// Feature: in-app-diagnostic-analyzer
// Module: result/band_gain_result
//
// Output of the BandGainAnalyzer. Carries the per-band measured gain, the
// prescribed gain from DSP_Metadata, the absolute deviation, the global
// RMS deviation, and the auxiliary spectral curves.

import 'dart:typed_data';

import 'psd_result.dart';

class BandGainResult {
  /// 12 audiometric center frequencies (Hz).
  final List<int> bandFrequencies;

  /// Measured gain per band (dB). NaN where no PSD bin falls within
  /// ±100 Hz of the band center.
  final Float64List measuredGainsDb;

  /// Prescribed gain per band (dB), copied from `eqGainsDb` in the JSON
  /// metadata.
  final Float64List prescribedGainsDb;

  /// |measured − prescribed| per band (dB). NaN propagates from
  /// `measuredGainsDb`.
  final Float64List absoluteDeviationsDb;

  /// Global RMS deviation across the 12 bands (dB). NaN-safe: bands with
  /// NaN deviation are skipped.
  final double globalRmsDeviationDb;

  /// Welch_PSD of the pre channel (V²/Hz, linear).
  final PsdResult psdPre;

  /// Welch_PSD of the post channel (V²/Hz, linear).
  final PsdResult psdPost;

  /// Per-bin Spectral_Gain_Curve in dB. Length = `psdPre.power.length`.
  final Float64List spectralGainCurveDb;

  const BandGainResult({
    required this.bandFrequencies,
    required this.measuredGainsDb,
    required this.prescribedGainsDb,
    required this.absoluteDeviationsDb,
    required this.globalRmsDeviationDb,
    required this.psdPre,
    required this.psdPost,
    required this.spectralGainCurveDb,
  });
}
