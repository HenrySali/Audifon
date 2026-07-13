/// @file calibration_report_json.dart
/// @brief Serializa un CalibrationSequenceReport a JSON.
///
/// REQ-12 del spec:
///  - schema_version: 1 (REQ-12.4)
///  - disclaimer presente (REQ-16.2)
///  - metadata + lista de tonos + globalVerdict
///
/// Se mantiene en un archivo separado de `validator_orchestrator.dart`
/// para que el orquestador no tenga dependencias innecesarias y para
/// facilitar testing puro (Property 8).

import 'tone_test_result.dart';
import 'validator_orchestrator.dart';

const String calibrationReportDisclaimer =
    'Daily / biological calibration check. NO reemplaza la calibración '
    'exhaustiva anual trazable a NIST.';

/// Serializa el reporte. Garantiza la presencia de `schema_version` y
/// `disclaimer` (Property 8 del design).
Map<String, dynamic> calibrationReportToJson(CalibrationSequenceReport r) {
  return {
    'schema_version': 1,
    'disclaimer': calibrationReportDisclaimer,
    'timestamp': r.timestamp.toIso8601String(),
    'global_verdict': r.globalVerdict.name,
    'preset': r.preset.name,
    'target_level_dbspl': r.targetLevelDbSpl,
    'sample_rate_hz': r.sampleRateHz,
    'fft_size': r.fftSize,
    'window_type': r.windowType.name,
    'noise_floor': {
      'dbfs': r.noiseFloor.noiseFloorDbFs.isFinite
          ? r.noiseFloor.noiseFloorDbFs
          : null,
      'is_acceptable': r.noiseFloor.isAcceptable,
      'rejection_reason': r.noiseFloor.rejectionReason,
    },
    'tones': r.tones.map((t) => t.toJson()).toList(),
    'tones_count': r.tones.length,
    'tones_passed': r.tones.where((t) => t.isPass).length,
    'tones_failed': r.tones.where((t) => t.isFail).length,
  };
}

/// Sugiere un nombre de archivo para el reporte exportado.
String suggestedReportFilename({
  String deviceLabel = 'device',
  DateTime? at,
}) {
  final t = at ?? DateTime.now();
  final stamp = '${t.year.toString().padLeft(4, '0')}'
      '${t.month.toString().padLeft(2, '0')}'
      '${t.day.toString().padLeft(2, '0')}_'
      '${t.hour.toString().padLeft(2, '0')}'
      '${t.minute.toString().padLeft(2, '0')}'
      '${t.second.toString().padLeft(2, '0')}';
  return 'calib_report_${deviceLabel}_$stamp.json';
}
