/// @file tone_test_result.dart
/// @brief Resultado de la evaluación de un tono.

import 'tone_snapshot.dart' show ToneVerdict;

export 'tone_snapshot.dart' show ToneVerdict;

/// Causas de fallo, ordenadas por severidad descendente.
enum FailureReason {
  frequencyOutOfTolerance,
  levelOutOfTolerance,
  thdAboveLimit,
  snrInsufficient,
  signalNotDetected,
}

/// Texto humano para mostrar en UI/JSON.
extension FailureReasonLabel on FailureReason {
  String get label => switch (this) {
        FailureReason.frequencyOutOfTolerance => 'frecuencia fuera de tolerancia',
        FailureReason.levelOutOfTolerance => 'nivel fuera de tolerancia',
        FailureReason.thdAboveLimit => 'THD sobre el límite',
        FailureReason.snrInsufficient => 'SNR insuficiente',
        FailureReason.signalNotDetected => 'señal no detectada',
      };

  String get id => switch (this) {
        FailureReason.frequencyOutOfTolerance => 'frequency_out_of_tolerance',
        FailureReason.levelOutOfTolerance => 'level_out_of_tolerance',
        FailureReason.thdAboveLimit => 'thd_above_limit',
        FailureReason.snrInsufficient => 'snr_insufficient',
        FailureReason.signalNotDetected => 'signal_not_detected',
      };
}

/// Resultado completo de un tono evaluado.
class ToneTestResult {
  final double expectedFreqHz;
  final double peakFreqHz;
  final double levelDbSpl;
  final double levelDbFs;
  final double thdPercent;
  final double snrDb;
  final List<double> harmonicsDbFs;
  final ToneVerdict verdict;
  final List<FailureReason> failureReasons;
  final double noiseFloorDbFs;
  final DateTime timestamp;

  const ToneTestResult({
    required this.expectedFreqHz,
    required this.peakFreqHz,
    required this.levelDbSpl,
    required this.levelDbFs,
    required this.thdPercent,
    required this.snrDb,
    required this.harmonicsDbFs,
    required this.verdict,
    required this.failureReasons,
    required this.noiseFloorDbFs,
    required this.timestamp,
  });

  bool get isPass => verdict == ToneVerdict.pass;
  bool get isFail => verdict == ToneVerdict.fail;

  Map<String, dynamic> toJson() => {
        'expected_freq_hz': expectedFreqHz,
        'peak_freq_hz': peakFreqHz.isFinite ? peakFreqHz : null,
        'level_dbspl': levelDbSpl.isFinite ? levelDbSpl : null,
        'level_dbfs': levelDbFs.isFinite ? levelDbFs : null,
        'thd_percent': thdPercent.isFinite ? thdPercent : null,
        'snr_db': snrDb.isFinite ? snrDb : null,
        'harmonics_dbfs': harmonicsDbFs.map((v) => v.isFinite ? v : null).toList(),
        'verdict': verdict.name,
        'failure_reasons': failureReasons.map((r) => r.id).toList(),
        'noise_floor_dbfs': noiseFloorDbFs.isFinite ? noiseFloorDbFs : null,
        'timestamp': timestamp.toIso8601String(),
      };
}
