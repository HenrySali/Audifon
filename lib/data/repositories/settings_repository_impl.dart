import 'package:hive/hive.dart';

import '../../domain/entities/calibration_data.dart';
import '../../domain/repositories/settings_repository.dart';

/// Nombre del Hive box para configuración de la app.
const String settingsBoxName = 'settings_box';

/// Claves de configuración en el box.
class _SettingsKeys {
  static const String lastProfile = 'lastProfile';
  static const String lastVolume = 'lastVolume';
  static const String prescriptionMethod = 'prescriptionMethod';
  static const String calibrationData = 'calibrationData';
  static const String lastEqPreset = 'lastEqPreset';
  static const String lastNrLevel = 'lastNrLevel';
}

/// Implementación del repositorio de configuración usando Hive.
///
/// Almacena preferencias del usuario y datos de calibración.
/// Soporta restauración de la última configuración al iniciar la app.
///
/// Requisitos: 4.1, 8.4
class SettingsRepositoryImpl implements SettingsRepository {
  final Box<dynamic> _box;

  SettingsRepositoryImpl(this._box);

  /// Abre el box de Hive para configuración.
  static Future<Box<dynamic>> openBox() async {
    return Hive.openBox(settingsBoxName);
  }

  @override
  Future<String?> getLastProfile() async {
    return _box.get(_SettingsKeys.lastProfile) as String?;
  }

  @override
  Future<void> setLastProfile(String profileName) async {
    await _box.put(_SettingsKeys.lastProfile, profileName);
  }

  @override
  Future<double?> getLastVolume() async {
    final value = _box.get(_SettingsKeys.lastVolume);
    if (value == null) return null;
    return (value as num).toDouble();
  }

  @override
  Future<void> setLastVolume(double volumeDb) async {
    await _box.put(_SettingsKeys.lastVolume, volumeDb);
  }

  @override
  Future<PrescriptionMethod> getPrescriptionMethod() async {
    final value = _box.get(_SettingsKeys.prescriptionMethod) as String?;
    if (value == null) return PrescriptionMethod.nalNl2;
    return PrescriptionMethod.values.firstWhere(
      (m) => m.name == value,
      orElse: () => PrescriptionMethod.nalNl2,
    );
  }

  @override
  Future<void> setPrescriptionMethod(PrescriptionMethod method) async {
    await _box.put(_SettingsKeys.prescriptionMethod, method.name);
  }

  @override
  Future<CalibrationData?> getCalibrationData() async {
    final data = _box.get(_SettingsKeys.calibrationData);
    if (data == null) return null;
    return _deserializeCalibrationData(data);
  }

  @override
  Future<void> setCalibrationData(CalibrationData data) async {
    final serialized = _serializeCalibrationData(data);
    await _box.put(_SettingsKeys.calibrationData, serialized);
  }

  @override
  Future<({String? lastProfile, double? lastVolume})> restoreLastConfig() async {
    final profile = await getLastProfile();
    final volume = await getLastVolume();
    return (lastProfile: profile, lastVolume: volume);
  }

  @override
  Future<Map<String, dynamic>?> getLastEqPreset() async {
    final data = _box.get(_SettingsKeys.lastEqPreset);
    if (data == null) return null;
    return Map<String, dynamic>.from(data as Map);
  }

  @override
  Future<void> setLastEqPreset(Map<String, dynamic> presetJson) async {
    await _box.put(_SettingsKeys.lastEqPreset, presetJson);
  }

  @override
  Future<int?> getLastNrLevel() async {
    return _box.get(_SettingsKeys.lastNrLevel) as int?;
  }

  @override
  Future<void> setLastNrLevel(int level) async {
    await _box.put(_SettingsKeys.lastNrLevel, level);
  }

  // --- Serialización de CalibrationData ---

  Map<String, dynamic> _serializeCalibrationData(CalibrationData data) {
    return {
      'micCalibration': data.micCalibration != null
          ? _serializeMicCalibration(data.micCalibration!)
          : null,
      'headphoneCalibrations': _serializeHeadphoneCalibrations(
        data.headphoneCalibrations,
      ),
    };
  }

  CalibrationData _deserializeCalibrationData(dynamic raw) {
    final map = Map<String, dynamic>.from(raw as Map);

    MicCalibrationResult? micCalibration;
    if (map['micCalibration'] != null) {
      micCalibration = _deserializeMicCalibration(map['micCalibration']);
    }

    final headphoneCalibrations = <String, HeadphoneCalibrationResult>{};
    if (map['headphoneCalibrations'] != null) {
      final hpMap = Map<String, dynamic>.from(
        map['headphoneCalibrations'] as Map,
      );
      for (final entry in hpMap.entries) {
        headphoneCalibrations[entry.key] =
            _deserializeHeadphoneCalibration(entry.value);
      }
    }

    return CalibrationData(
      micCalibration: micCalibration,
      headphoneCalibrations: headphoneCalibrations,
    );
  }

  Map<String, dynamic> _serializeMicCalibration(MicCalibrationResult mic) {
    return {
      'splOffset': mic.splOffset,
      'confidenceLevel': mic.confidenceLevel,
      'method': mic.method,
      'calibratedAt': mic.calibratedAt.toIso8601String(),
      'deviceModel': mic.deviceModel,
    };
  }

  MicCalibrationResult _deserializeMicCalibration(dynamic raw) {
    final map = Map<String, dynamic>.from(raw as Map);
    return MicCalibrationResult(
      splOffset: (map['splOffset'] as num).toDouble(),
      confidenceLevel: (map['confidenceLevel'] as num).toDouble(),
      method: map['method'] as String,
      calibratedAt: DateTime.parse(map['calibratedAt'] as String),
      deviceModel: map['deviceModel'] as String,
    );
  }

  Map<String, dynamic> _serializeHeadphoneCalibrations(
    Map<String, HeadphoneCalibrationResult> calibrations,
  ) {
    final result = <String, dynamic>{};
    for (final entry in calibrations.entries) {
      result[entry.key] = _serializeHeadphoneCalibration(entry.value);
    }
    return result;
  }

  Map<String, dynamic> _serializeHeadphoneCalibration(
    HeadphoneCalibrationResult hp,
  ) {
    // Convert Map<int, double> to Map<String, double> for Hive
    final freqResponse = <String, double>{};
    for (final entry in hp.frequencyResponse.entries) {
      freqResponse[entry.key.toString()] = entry.value;
    }
    final compensation = <String, double>{};
    for (final entry in hp.compensation.entries) {
      compensation[entry.key.toString()] = entry.value;
    }

    return {
      'frequencyResponse': freqResponse,
      'compensation': compensation,
      'headphoneId': hp.headphoneId,
      'headphoneName': hp.headphoneName,
      'calibratedAt': hp.calibratedAt.toIso8601String(),
      'isBluetooth': hp.isBluetooth,
    };
  }

  HeadphoneCalibrationResult _deserializeHeadphoneCalibration(dynamic raw) {
    final map = Map<String, dynamic>.from(raw as Map);

    final freqResponseRaw = Map<String, dynamic>.from(
      map['frequencyResponse'] as Map,
    );
    final frequencyResponse = <int, double>{};
    for (final entry in freqResponseRaw.entries) {
      frequencyResponse[int.parse(entry.key)] =
          (entry.value as num).toDouble();
    }

    final compensationRaw = Map<String, dynamic>.from(
      map['compensation'] as Map,
    );
    final compensation = <int, double>{};
    for (final entry in compensationRaw.entries) {
      compensation[int.parse(entry.key)] = (entry.value as num).toDouble();
    }

    return HeadphoneCalibrationResult(
      frequencyResponse: frequencyResponse,
      compensation: compensation,
      headphoneId: map['headphoneId'] as String,
      headphoneName: map['headphoneName'] as String,
      calibratedAt: DateTime.parse(map['calibratedAt'] as String),
      isBluetooth: map['isBluetooth'] as bool,
    );
  }
}
