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
      items.add(Recommendation(
        severity: RecommendationSeverity.warn,
        stage: 'Limpiador de ruido',
        message: 'DNN agresiva — el SNR empeoró ${snr.snrImprovementDb.toStringAsFixed(1)} dB',
        suggestion: 'Bajar intensidad del limpiador de ruido (slider) al 60% o menos',
      ));
    }

    // 14.2 — THD > 5%.
    if (!thd.thdPercent.isNaN && thd.thdPercent > kThdLimitPercent) {
      items.add(Recommendation(
        severity: RecommendationSeverity.error,
        stage: 'MPO / Distorsión',
        message: 'Distorsión alta (THD ${thd.thdPercent.toStringAsFixed(1)}%)',
        suggestion: 'Reducir ganancias EQ en agudos o subir threshold MPO',
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
      final bandsStr = affectedBands.map((f) => '${f >= 1000 ? "${f ~/ 1000}k" : "$f"} Hz').join(', ');
      items.add(Recommendation(
        severity: RecommendationSeverity.warn,
        stage: 'EQ (prescripción)',
        message: 'Ganancia medida difiere de la prescrita en: $bandsStr',
        suggestion: 'Ajustar EQ en esas bandas o recalibrar el audiograma',
      ));
    }

    // 14.4 — Observed WDRC ratio exceeds configured by > 1.0.
    final obs = wdrc.observedCompressionRatio;
    final cfg = wdrc.configuredCompressionRatio;
    if (!obs.isNaN &&
        obs.isFinite &&
        !cfg.isNaN &&
        obs - cfg > kCompressionRatioWarnDelta) {
      items.add(Recommendation(
        severity: RecommendationSeverity.warn,
        stage: 'WDRC',
        message: 'WDRC sobre-comprime (ratio observado ${obs.toStringAsFixed(1)} vs configurado ${cfg.toStringAsFixed(1)})',
        suggestion: 'Reducir compression ratio o subir compression knee',
      ));
    }

    // 14.5 — Clipping post ≥ 0.01%.
    if (!quality.clippingPostPercent.isNaN &&
        quality.clippingPostPercent >= kClippingPostErrorPercent) {
      items.add(Recommendation(
        severity: RecommendationSeverity.error,
        stage: 'MPO / Distorsión',
        message: 'Clipping detectado (${quality.clippingPostPercent.toStringAsFixed(2)}% de muestras)',
        suggestion: 'Bajar volumen o reducir ganancias EQ en agudos',
      ));
    }

    // 14.6 — Latency > 20 ms.
    if (!latency.latencyMs.isNaN && latency.latencyMs > kLatencyWarnMs) {
      items.add(Recommendation(
        severity: RecommendationSeverity.warn,
        stage: 'Latencia',
        message: 'Latencia alta (${latency.latencyMs.toStringAsFixed(0)} ms)',
        suggestion: 'Reducir tamaño de bloque DNN o desactivar módulos pesados',
      ));
    }

    // 14.7 — LTASS deviation in 250–4000 Hz.
    if (_ltassDeviates(psdPre)) {
      items.add(const Recommendation(
        severity: RecommendationSeverity.info,
        stage: 'Ambiente',
        message: 'La grabación no tiene perfil speech-like (LTASS)',
        suggestion: 'Repetir el test con voz humana activa para métricas representativas',
      ));
    }

    // 14.8 — wdrcLevelSource == "local".
    if (metadata.wdrcLevelSource == 'local') {
      items.add(const Recommendation(
        severity: RecommendationSeverity.info,
        stage: 'WDRC',
        message: 'Nivel del WDRC medido localmente (modo legacy)',
        suggestion: 'El ratio efectivo puede no reflejar la cadena pre-DNN',
      ));
    }

    return RecommendationsResult(
      items: List<Recommendation>.unmodifiable(items),
      summary: _buildSummary(items),
      stageVerdicts: _buildVerdicts(snr, thd, bandGain, wdrc, quality, latency),
    );
  }

  /// Genera un resumen en texto del estado general.
  String _buildSummary(List<Recommendation> items) {
    final errors = items.where((r) => r.severity == RecommendationSeverity.error).length;
    final warns = items.where((r) => r.severity == RecommendationSeverity.warn).length;
    if (errors > 0) {
      return 'Se detectaron $errors problemas críticos y $warns advertencias. '
          'El sistema necesita ajustes para funcionar correctamente.';
    } else if (warns > 0) {
      return 'El sistema funciona pero tiene $warns advertencias que pueden '
          'mejorar la calidad de audio. Revisar las sugerencias.';
    } else {
      return 'El sistema funciona correctamente. No se detectaron problemas '
          'significativos en ninguna etapa del pipeline.';
    }
  }

  /// Genera veredictos por etapa del pipeline.
  Map<String, String> _buildVerdicts(
    SnrResult snr,
    ThdResult thd,
    BandGainResult bandGain,
    WdrcIoResult wdrc,
    QualityResult quality,
    LatencyResult latency,
  ) {
    final v = <String, String>{};

    // Limpiador de ruido (DNN/NR)
    if (snr.snrImprovementDb.isNaN || snr.insufficientVad) {
      v['Limpiador de ruido'] = 'SIN DATOS';
    } else if (snr.snrImprovementDb < 0) {
      v['Limpiador de ruido'] = 'ERROR';
    } else if (snr.snrImprovementDb < kSnrImprovementWarnDb) {
      v['Limpiador de ruido'] = 'WARN';
    } else {
      v['Limpiador de ruido'] = 'OK';
    }

    // EQ (prescripción)
    final maxDev = bandGain.absoluteDeviationsDb
        .where((d) => !d.isNaN)
        .fold(0.0, (a, b) => a > b ? a : b);
    if (maxDev > kBandDeviationWarnDb) {
      v['EQ (prescripción)'] = 'WARN';
    } else if (maxDev > kBandDeviationWarnDb * 2) {
      v['EQ (prescripción)'] = 'ERROR';
    } else {
      v['EQ (prescripción)'] = 'OK';
    }

    // WDRC
    final obsRatio = wdrc.observedCompressionRatio;
    final cfgRatio = wdrc.configuredCompressionRatio;
    if (obsRatio.isNaN || !obsRatio.isFinite) {
      v['WDRC'] = 'SIN DATOS';
    } else if ((obsRatio - cfgRatio).abs() > kCompressionRatioWarnDelta) {
      v['WDRC'] = 'WARN';
    } else {
      v['WDRC'] = 'OK';
    }

    // MPO / Distorsión
    if (!thd.thdPercent.isNaN && thd.thdPercent > kThdLimitPercent) {
      v['MPO / Distorsión'] = 'ERROR';
    } else if (!quality.clippingPostPercent.isNaN && quality.clippingPostPercent > 0) {
      v['MPO / Distorsión'] = 'WARN';
    } else {
      v['MPO / Distorsión'] = 'OK';
    }

    // Latencia
    if (latency.latencyMs.isNaN || latency.lowConfidence) {
      v['Latencia'] = 'SIN DATOS';
    } else if (latency.latencyMs > kLatencyWarnMs) {
      v['Latencia'] = 'WARN';
    } else {
      v['Latencia'] = 'OK';
    }

    // Calidad general
    if (!quality.clippingPostPercent.isNaN && quality.clippingPostPercent >= kClippingPostErrorPercent) {
      v['Calidad general'] = 'ERROR';
    } else {
      v['Calidad general'] = 'OK';
    }

    return v;
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
