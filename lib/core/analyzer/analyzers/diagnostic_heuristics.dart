// Feature: in-app-diagnostic-analyzer
// Module: analyzers/diagnostic_heuristics
//
// Total rule engine. Emits ordered Spanish-language `Recommendation`
// items per Req. 14.1–14.8. Never throws on NaN — NaN comparisons are
// false, so a NaN metric simply emits no recommendation for that rule.

import 'dart:math' as math;

import '../../diagnostic_metadata.dart';
import '../constants.dart';
import '../result/band_gain_result.dart';
import '../result/latency_result.dart';
import '../result/psd_result.dart';
import '../result/quality_result.dart';
import '../result/recommendations_result.dart';
import '../result/snr_result.dart';
import '../result/thd_result.dart';
import '../result/wdrc_io_result.dart';

class DiagnosticHeuristics {
  RecommendationsResult evaluate({
    required SnrResult snr,
    required ThdResult thd,
    required BandGainResult bandGain,
    required WdrcIoResult wdrc,
    required QualityResult quality,
    required LatencyResult latency,
    required PsdResult psdPre,
    required DiagnosticMetadata metadata,
  }) {
    final items = <Recommendation>[];

    // 14.1 — DNN agresiva.
    if (!snr.snrImprovementDb.isNaN &&
        snr.snrImprovementDb < kSnrImprovementWarnDb) {
      items.add(const Recommendation(
        severity: RecommendationSeverity.warn,
        message: 'DNN agresiva, considerar bajar intensidad del denoiser',
      ));
    }

    // 14.2 — THD > 5%.
    if (!thd.thdPercent.isNaN && thd.thdPercent > kThdLimitPercent) {
      items.add(const Recommendation(
        severity: RecommendationSeverity.error,
        message:
            'Distorsión alta (THD > 5%), posible saturación del MPO o WDRC',
      ));
    }

    // 14.3 — Per-band deviation > 6 dB.
    final affectedBands = <int>[];
    for (int b = 0; b < bandGain.bandFrequencies.length; b++) {
      final d = bandGain.absoluteDeviationsDb[b];
      if (!d.isNaN && d > kBandDeviationWarnDb) {
        affectedBands.add(bandGain.bandFrequencies[b]);
      }
    }
    if (affectedBands.isNotEmpty) {
      items.add(Recommendation(
        severity: RecommendationSeverity.warn,
        message:
            'Ganancia medida muy distinta a la prescrita en banda(s) ${affectedBands.join(', ')}',
      ));
    }

    // 14.4 — Observed WDRC ratio exceeds configured by > 1.0.
    final obs = wdrc.observedCompressionRatio;
    final cfg = wdrc.configuredCompressionRatio;
    if (!obs.isNaN &&
        obs.isFinite &&
        !cfg.isNaN &&
        obs - cfg > kCompressionRatioWarnDelta) {
      items.add(const Recommendation(
        severity: RecommendationSeverity.warn,
        message: 'WDRC sobre-comprime, ratio observado mayor al configurado',
      ));
    }

    // 14.5 — Clipping post ≥ 0.01%.
    if (!quality.clippingPostPercent.isNaN &&
        quality.clippingPostPercent >= kClippingPostErrorPercent) {
      items.add(const Recommendation(
        severity: RecommendationSeverity.error,
        message: 'Clipping en señal post-DSP, revisar MPO',
      ));
    }

    // 14.6 — Latency > 20 ms.
    if (!latency.latencyMs.isNaN && latency.latencyMs > kLatencyWarnMs) {
      items.add(const Recommendation(
        severity: RecommendationSeverity.warn,
        message: 'Latencia alta (> 20 ms), riesgo de eco perceptible',
      ));
    }

    // 14.7 — LTASS deviation in 250–4000 Hz.
    if (_ltassDeviates(psdPre)) {
      items.add(const Recommendation(
        severity: RecommendationSeverity.info,
        message:
            'Grabación no es speech-like (LTASS), las métricas SNR/THD pueden no ser representativas',
      ));
    }

    // 14.8 — wdrcLevelSource == "local".
    if (metadata.wdrcLevelSource == 'local') {
      items.add(const Recommendation(
        severity: RecommendationSeverity.info,
        message:
            'Nivel del WDRC medido localmente (modo legacy), el ratio efectivo puede no reflejar la cadena pre-DNN',
      ));
    }

    return RecommendationsResult(items: List<Recommendation>.unmodifiable(items));
  }

  /// Returns true when the pre-channel PSD differs from the LTASS
  /// reference by more than ±6 dB at any frequency in 250..4000 Hz.
  ///
  /// The PSD is integrated within ±100 Hz around each audiometric
  /// frequency and converted to dB SPL by adding 94 dB (since the WAV
  /// values are dimensionless [-1, 1] equivalent of full-scale 1 Pa, the
  /// constant cancels out in the deviation computation — only the
  /// shape relative to the LTASS curve matters; we re-center on the
  /// recording's own spectrum).
  bool _ltassDeviates(PsdResult psd) {
    if (psd.power.isEmpty) return false;
    final freqs = psd.frequencies;
    final pwr = psd.power;
    // Compute the per-band integrated power (V²) within ±100 Hz.
    final bandDb = <int, double>{};
    for (final f in kAudiometricBandsHz) {
      if (f < kLtassCheckLowHz || f > kLtassCheckHighHz) continue;
      double sum = 0.0;
      int count = 0;
      for (int k = 0; k < pwr.length; k++) {
        if ((freqs[k] - f).abs() <= kBandHalfBandwidthHz) {
          sum += pwr[k];
          count++;
        }
      }
      if (count == 0) continue;
      final mean = sum / count;
      final db = 10.0 * (math.log(mean + kPsdEpsilon) / math.ln10);
      bandDb[f] = db;
    }
    if (bandDb.isEmpty) return false;
    // Re-center: align the recording's mean and the LTASS mean at the
    // checked frequencies, then compare deviations.
    double recMean = 0.0;
    double refMean = 0.0;
    int n = 0;
    for (final entry in bandDb.entries) {
      final ref = kLtassDbSpl[entry.key];
      if (ref == null) continue;
      recMean += entry.value;
      refMean += ref;
      n++;
    }
    if (n == 0) return false;
    recMean /= n;
    refMean /= n;
    for (final entry in bandDb.entries) {
      final ref = kLtassDbSpl[entry.key];
      if (ref == null) continue;
      final dev = (entry.value - recMean) - (ref - refMean);
      if (dev.abs() > kLtassDeviationDbLimit) return true;
    }
    return false;
  }
}
