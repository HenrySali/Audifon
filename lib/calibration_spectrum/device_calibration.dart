/// @file device_calibration.dart
/// @brief Calibración de referencia del dispositivo (parlante + mic).
///
/// Modelo de "calibración biológica" estilo audiómetro:
///  - El usuario calibra una vez con un sonómetro externo.
///  - Por cada frecuencia se guarda: dBFS medido por la app + dB SPL leído del sonómetro.
///  - En validaciones diarias se comparan dBFS de hoy vs dBFS de referencia.
///  - Si la diferencia excede toleranceDbDrift -> FAIL (algo cambió en el dispositivo).
///  - Cumple conceptualmente ANSI S3.6 §5: "biological / daily calibration check".
///
/// Persistencia: Hive box `calibration_spectrum_box`, key `device_calibration`.

import 'dart:convert';

import 'package:hive/hive.dart';

/// Una entrada por frecuencia.
class CalibrationEntry {
  final double freqHz;
  final double referenceDbFs;   // dBFS medido por la app durante calibración.
  final double referenceDbSpl;  // dB SPL leído por el usuario en el sonómetro.

  const CalibrationEntry({
    required this.freqHz,
    required this.referenceDbFs,
    required this.referenceDbSpl,
  });

  Map<String, dynamic> toJson() => {
        'freq_hz': freqHz,
        'reference_dbfs': referenceDbFs,
        'reference_dbspl': referenceDbSpl,
      };

  factory CalibrationEntry.fromJson(Map<String, dynamic> j) {
    return CalibrationEntry(
      freqHz: (j['freq_hz'] as num).toDouble(),
      referenceDbFs: (j['reference_dbfs'] as num).toDouble(),
      referenceDbSpl: (j['reference_dbspl'] as num).toDouble(),
    );
  }
}

/// Calibración completa de un dispositivo.
class DeviceCalibration {
  final DateTime timestamp;
  final Map<double, CalibrationEntry> entries;
  final double toleranceDbDrift;  // típico 3 dB; FAIL si abs(today-ref) > este valor.

  const DeviceCalibration({
    required this.timestamp,
    required this.entries,
    this.toleranceDbDrift = 3.0,
  });

  bool hasFreq(double freqHz) => entries.containsKey(freqHz);

  CalibrationEntry? entryFor(double freqHz) => entries[freqHz];

  /// Convierte un dBFS medido hoy a dB SPL usando la referencia.
  /// Si no hay referencia para esa freq, retorna null.
  double? dbFsToDbSpl(double freqHz, double dbFsToday) {
    final e = entryFor(freqHz);
    if (e == null) return null;
    // SPL hoy = dBFS hoy + (refSPL - refdBFS)
    return dbFsToday + (e.referenceDbSpl - e.referenceDbFs);
  }

  /// Drift dBFS hoy vs referencia. Null si no hay referencia.
  double? driftDb(double freqHz, double dbFsToday) {
    final e = entryFor(freqHz);
    if (e == null) return null;
    return dbFsToday - e.referenceDbFs;
  }

  Map<String, dynamic> toJson() => {
        'timestamp': timestamp.toIso8601String(),
        'tolerance_db_drift': toleranceDbDrift,
        'entries': entries.values.map((e) => e.toJson()).toList(),
      };

  factory DeviceCalibration.fromJson(Map<String, dynamic> j) {
    final list = (j['entries'] as List).cast<Map<String, dynamic>>();
    final map = <double, CalibrationEntry>{};
    for (final e in list) {
      final entry = CalibrationEntry.fromJson(e);
      map[entry.freqHz] = entry;
    }
    return DeviceCalibration(
      timestamp: DateTime.parse(j['timestamp'] as String),
      entries: map,
      toleranceDbDrift:
          (j['tolerance_db_drift'] as num?)?.toDouble() ?? 3.0,
    );
  }
}

/// Storage helper sobre Hive.
class DeviceCalibrationStore {
  static const _boxName = 'calibration_spectrum_box';
  static const _key = 'device_calibration';

  /// Carga la calibración guardada o null si no hay.
  static Future<DeviceCalibration?> load() async {
    final box = await _openBox();
    final raw = box.get(_key) as String?;
    if (raw == null || raw.isEmpty) return null;
    try {
      final j = jsonDecode(raw) as Map<String, dynamic>;
      return DeviceCalibration.fromJson(j);
    } catch (_) {
      return null;
    }
  }

  /// Guarda la calibración (sobrescribe la anterior).
  static Future<void> save(DeviceCalibration cal) async {
    final box = await _openBox();
    await box.put(_key, jsonEncode(cal.toJson()));
  }

  /// Borra la calibración guardada.
  static Future<void> clear() async {
    final box = await _openBox();
    await box.delete(_key);
  }

  static Future<Box<dynamic>> _openBox() async {
    if (Hive.isBoxOpen(_boxName)) return Hive.box(_boxName);
    return Hive.openBox(_boxName);
  }
}
