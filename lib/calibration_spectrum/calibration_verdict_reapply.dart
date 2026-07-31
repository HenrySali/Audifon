/// @file calibration_verdict_reapply.dart
/// @brief Re-evaluación del verdict usando calibración guardada del dispositivo.
///
/// Cuando hay una `DeviceCalibration` cargada, el verdict por nivel se
/// reemplaza por un check de drift dBFS:
///   - Mido dBFS hoy.
///   - Comparo con el dBFS guardado para esa frecuencia.
///   - Si abs(diff) <= toleranceDbDrift -> el nivel sigue OK (no hay drift).
///   - Si abs(diff)  > toleranceDbDrift -> drift detectado (FAIL nivel).
///
/// El drift se reporta también en `levelDbSpl` (recalculado desde el
/// SPL referencia + drift), de modo que la UI ve un valor coherente.

import 'device_calibration.dart';
import 'tone_test_result.dart';
import 'validator_orchestrator.dart';

CalibrationSequenceReport applyDeviceCalibration(
  CalibrationSequenceReport report,
  DeviceCalibration cal,
) {
  final newTones = <ToneTestResult>[];
  for (final r in report.tones) {
    final entry = cal.entryFor(r.expectedFreqHz);
    if (entry == null) {
      // Sin calibración para esta freq: dejamos el verdict tal como vino.
      newTones.add(r);
      continue;
    }

    // Drift dBFS hoy vs referencia.
    final driftDb = r.levelDbFs - entry.referenceDbFs;

    // SPL inferido = SPL referencia + drift.
    final inferredSpl = entry.referenceDbSpl + driftDb;

    // Quitamos las razones de level y las re-aplicamos por drift.
    final reasons = r.failureReasons
        .where((x) => x != FailureReason.levelOutOfTolerance)
        .toList();

    if (driftDb.abs() > cal.toleranceDbDrift) {
      reasons.add(FailureReason.levelOutOfTolerance);
    }

    final verdict = reasons.isEmpty ? ToneVerdict.pass : ToneVerdict.fail;

    newTones.add(ToneTestResult(
      expectedFreqHz: r.expectedFreqHz,
      peakFreqHz: r.peakFreqHz,
      levelDbSpl: inferredSpl,
      levelDbFs: r.levelDbFs,
      thdPercent: r.thdPercent,
      snrDb: r.snrDb,
      harmonicsDbFs: r.harmonicsDbFs,
      verdict: verdict,
      failureReasons: reasons,
      noiseFloorDbFs: r.noiseFloorDbFs,
      timestamp: r.timestamp,
    ));
  }

  // Recalcular global verdict.
  final globalIsPass = newTones.isNotEmpty &&
      newTones.every((t) => t.verdict == ToneVerdict.pass);
  final globalVerdict = globalIsPass ? ToneVerdict.pass : ToneVerdict.fail;

  return CalibrationSequenceReport(
    tones: newTones,
    noiseFloor: report.noiseFloor,
    preset: report.preset,
    targetLevelDbSpl: report.targetLevelDbSpl,
    sampleRateHz: report.sampleRateHz,
    fftSize: report.fftSize,
    windowType: report.windowType,
    globalVerdict: globalVerdict,
    timestamp: report.timestamp,
  );
}
