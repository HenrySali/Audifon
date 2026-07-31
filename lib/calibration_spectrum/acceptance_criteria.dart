/// @file acceptance_criteria.dart
/// @brief Criterios de aceptación PASS/FAIL por tono.
///
/// Implementa REQ-10 del spec: tolerancia de frecuencia, THD, SNR, nivel.
/// Función pure `evaluate()` para garantizar determinismo (Property 6).

import 'tone_snapshot.dart';
import 'tone_test_result.dart';

/// Preset de criterios.
enum AcceptancePreset { clinical, premium }

/// Criterios cuantitativos de aceptación.
class AcceptanceCriteria {
  final double freqTolerancePercent;     // ±5%
  final double thdMaxPercent;             // 3.0 (clinical) | 1.0 (premium)
  final double snrMinDb;                  // > 30 dB
  final double levelToleranceLowDb;       // ±3 dB para freq ≤ 4 kHz
  final double levelToleranceHighDb;      // ±6 dB para freq > 4 kHz
  final int harmonicsCount;               // 4 (H2-H5) | 7 (H2-H8)
  final double noiseFloorMaxDbFs;         // -20 dB FS

  const AcceptanceCriteria({
    required this.freqTolerancePercent,
    required this.thdMaxPercent,
    required this.snrMinDb,
    required this.levelToleranceLowDb,
    required this.levelToleranceHighDb,
    required this.harmonicsCount,
    required this.noiseFloorMaxDbFs,
  });

  /// Preset clínico (default): THD < 3%, H2-H5.
  factory AcceptanceCriteria.clinical() => const AcceptanceCriteria(
    freqTolerancePercent: 5.0,
    thdMaxPercent: 3.0,
    snrMinDb: 30.0,
    levelToleranceLowDb: 3.0,
    levelToleranceHighDb: 6.0,
    harmonicsCount: 4,
    noiseFloorMaxDbFs: -20.0,
  );

  /// Preset premium: THD < 1%, H2-H8.
  factory AcceptanceCriteria.premium() => const AcceptanceCriteria(
    freqTolerancePercent: 5.0,
    thdMaxPercent: 1.0,
    snrMinDb: 30.0,
    levelToleranceLowDb: 3.0,
    levelToleranceHighDb: 6.0,
    harmonicsCount: 7,
    noiseFloorMaxDbFs: -20.0,
  );

  /// Selecciona el preset por enum.
  factory AcceptanceCriteria.fromPreset(AcceptancePreset preset) {
    return switch (preset) {
      AcceptancePreset.clinical => AcceptanceCriteria.clinical(),
      AcceptancePreset.premium => AcceptanceCriteria.premium(),
    };
  }

  /// Tolerancia de nivel aplicable según frecuencia esperada.
  double levelToleranceForFreq(double expectedFreqHz) {
    return expectedFreqHz <= 4000.0 ? levelToleranceLowDb : levelToleranceHighDb;
  }
}

/// Función pure: evalúa un snapshot contra los criterios y retorna el resultado.
///
/// @param snapshot El último snapshot capturado del ToneAnalyzer.
/// @param criteria Los criterios del preset activo.
/// @param targetLevelDbSpl Nivel objetivo de la secuencia (50 dB SPL default).
/// @return ToneTestResult con verdict, failureReasons y métricas.
ToneTestResult evaluate({
  required ToneSnapshot snapshot,
  required AcceptanceCriteria criteria,
  required double targetLevelDbSpl,
}) {
  final reasons = <FailureReason>[];

  // Si el snapshot vino con flags de NaN/no-señal, propagamos el FAIL directamente.
  if (snapshot.hasFlag(ToneFailureFlag.nanInf) ||
      !snapshot.peakFreqHz.isFinite ||
      !snapshot.thdPercent.isFinite) {
    reasons.add(FailureReason.signalNotDetected);
  }
  if (snapshot.hasFlag(ToneFailureFlag.noSignal)) {
    reasons.add(FailureReason.signalNotDetected);
  }

  // Frecuencia.
  if (snapshot.peakFreqHz.isFinite && snapshot.expectedFreqHz > 0) {
    final tolHz = snapshot.expectedFreqHz * (criteria.freqTolerancePercent / 100.0);
    final errHz = (snapshot.peakFreqHz - snapshot.expectedFreqHz).abs();
    if (errHz > tolHz) {
      reasons.add(FailureReason.frequencyOutOfTolerance);
    }
  }

  // THD.
  if (snapshot.thdPercent.isFinite) {
    if (snapshot.thdPercent > criteria.thdMaxPercent) {
      reasons.add(FailureReason.thdAboveLimit);
    }
  }

  // SNR.
  if (snapshot.snrDb.isFinite) {
    if (snapshot.snrDb < criteria.snrMinDb) {
      reasons.add(FailureReason.snrInsufficient);
    }
  }

  // Nivel.
  final levelTol = criteria.levelToleranceForFreq(snapshot.expectedFreqHz);
  final levelErr = (snapshot.peakMagnitudeDbspl - targetLevelDbSpl).abs();
  if (snapshot.peakMagnitudeDbspl.isFinite && levelErr > levelTol) {
    reasons.add(FailureReason.levelOutOfTolerance);
  }

  // Eliminar duplicados manteniendo orden de severidad: freq → level → thd → snr → noSignal.
  const order = [
    FailureReason.frequencyOutOfTolerance,
    FailureReason.levelOutOfTolerance,
    FailureReason.thdAboveLimit,
    FailureReason.snrInsufficient,
    FailureReason.signalNotDetected,
  ];
  final ordered = <FailureReason>[];
  for (final r in order) {
    if (reasons.contains(r) && !ordered.contains(r)) ordered.add(r);
  }

  final verdict = ordered.isEmpty
      ? ToneVerdict.pass
      : ToneVerdict.fail;

  return ToneTestResult(
    expectedFreqHz: snapshot.expectedFreqHz,
    peakFreqHz: snapshot.peakFreqHz,
    levelDbSpl: snapshot.peakMagnitudeDbspl,
    levelDbFs: snapshot.peakMagnitudeDbfs,
    thdPercent: snapshot.thdPercent,
    snrDb: snapshot.snrDb,
    harmonicsDbFs: List<double>.from(snapshot.harmonicsDbfs),
    verdict: verdict,
    failureReasons: ordered,
    noiseFloorDbFs: snapshot.noiseFloorDbfs,
    timestamp: DateTime.fromMicrosecondsSinceEpoch(
      snapshot.timestampUs > 0 ? snapshot.timestampUs : DateTime.now().microsecondsSinceEpoch,
    ),
  );
}
