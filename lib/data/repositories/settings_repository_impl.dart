import 'package:hive/hive.dart';

import '../../domain/entities/calibration_data.dart';
import '../../domain/entities/prescription_mode.dart';
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
  static const String prescriberMode = 'prescriberMode';
  static const String experienceMonths = 'experienceMonths';

  // --- Tecnico↔Paciente feature parity (Task 1.1) -------------------------
  // Keys nuevas alineadas con el paciente
  // (`PACIENTE/oir_pro_patient_app/lib/data/settings_repository.dart`).
  // Defaults: false / false / 0.5 / 0.6 / 0.
  static const String mhlPrescriptionEnabled = 'mhlPrescriptionEnabled';
  static const String musicModeEnabled = 'musicModeEnabled';
  static const String comfort = 'comfort';
  static const String dnnIntensity = 'dnnIntensity';

  /// Storage key del nuevo `nrLevel`. El nombre del campo lleva el sufijo
  /// `V2` para distinguirlo del legacy [lastNrLevel] dentro del mapa de
  /// constantes; el valor en disco (`'nrLevel'`) coincide con el del
  /// paciente.
  static const String nrLevelV2 = 'nrLevel';

  /// Modo Conversación (SCO + 16 kHz). Default false.
  static const String conversationModeEnabled = 'conversationModeEnabled';

  /// Techo de ganancia máxima del hardware (dB). Default 50.0.
  static const String hardwareGainCeilingDb = 'hardwareGainCeilingDb';
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

  @override
  Future<PrescriberMode> getPrescriberMode() async {
    final value = _box.get(_SettingsKeys.prescriberMode) as String?;
    if (value == null) return PrescriberMode.smartNl2;
    return PrescriberMode.values.firstWhere(
      (m) => m.name == value,
      orElse: () => PrescriberMode.smartNl2,
    );
  }

  @override
  Future<void> setPrescriberMode(PrescriberMode mode) async {
    await _box.put(_SettingsKeys.prescriberMode, mode.name);
  }

  @override
  Future<int?> getExperienceMonths() async {
    try {
      final value = _box.get(_SettingsKeys.experienceMonths);
      if (value == null) return null;
      return (value as num).toInt();
    } catch (_) {
      // Persistencia tolerante: ante un valor corrupto retornar null
      // (equivale a usuario nuevo / onboarding pendiente).
      return null;
    }
  }

  @override
  Future<void> setExperienceMonths(int months) async {
    final clamped = months < 0 ? 0 : months;
    try {
      await _box.put(_SettingsKeys.experienceMonths, clamped);
    } catch (_) {
      // Persistencia tolerante: si Hive falla, no propagar el error
      // para no interrumpir el flujo de UI.
    }
  }

  // --- Tecnico↔Paciente feature parity (Task 1.1) -------------------------
  // Implementación de las cinco keys nuevas que alinean el técnico con el
  // paciente. Los getters son sincrónicos (sin `Future`) para que el helper
  // `_effectiveCompressionRatio(bundle)` del AmplificationBloc pueda leer
  // `comfort` sin `await`. La normalización (clamp, NaN→default) ocurre
  // tanto en lectura como en escritura para protegernos de boxes corruptos
  // o legados.

  @override
  bool get mhlPrescriptionEnabled =>
      _box.get(_SettingsKeys.mhlPrescriptionEnabled) == true;

  @override
  Future<void> setMhlPrescriptionEnabled(bool value) async {
    await _box.put(_SettingsKeys.mhlPrescriptionEnabled, value);
  }

  @override
  bool get musicModeEnabled =>
      _box.get(_SettingsKeys.musicModeEnabled) == true;

  @override
  Future<void> setMusicModeEnabled(bool value) async {
    await _box.put(_SettingsKeys.musicModeEnabled, value);
  }

  @override
  double get comfort => _readClamped01(_SettingsKeys.comfort, fallback: 0.5);

  @override
  Future<void> setComfort(double value) async {
    await _box.put(_SettingsKeys.comfort, _normalize01(value, fallback: 0.5));
  }

  @override
  double get dnnIntensity =>
      _readClamped01(_SettingsKeys.dnnIntensity, fallback: 0.6);

  @override
  Future<void> setDnnIntensity(double value) async {
    await _box.put(
      _SettingsKeys.dnnIntensity,
      _normalize01(value, fallback: 0.6),
    );
  }

  @override
  int get nrLevel {
    // 1) Lee la key nueva (`nrLevel`).
    final v = _box.get(_SettingsKeys.nrLevelV2);
    if (v is int) return _clampNrLevel(v);
    // 2) Fallback a la key legacy `lastNrLevel` para retro-compatibilidad
    //    con instalaciones previas (Task 1.1: "Mantener `lastNrLevel` como
    //    fallback de lectura").
    final legacy = _box.get(_SettingsKeys.lastNrLevel);
    if (legacy is int) return _clampNrLevel(legacy);
    if (legacy is num) return _clampNrLevel(legacy.toInt());
    // 3) Sin valor previo → default 0.
    return 0;
  }

  @override
  Future<void> setNrLevel(int value) async {
    final clamped = _clampNrLevel(value);
    // Sincroniza ambas keys: el primer `setNrLevel` deja la legacy alineada
    // con la nueva para que `getLastNrLevel()` siga devolviendo el valor
    // correcto a cualquier consumidor antiguo.
    await _box.put(_SettingsKeys.nrLevelV2, clamped);
    await _box.put(_SettingsKeys.lastNrLevel, clamped);
  }

  @override
  bool get conversationModeEnabled =>
      _box.get(_SettingsKeys.conversationModeEnabled) == true;

  @override
  Future<void> setConversationModeEnabled(bool value) async {
    await _box.put(_SettingsKeys.conversationModeEnabled, value);
  }

  // --- Gain Ceiling (calibración de ganancia máxima del hardware) ----------

  @override
  double get hardwareGainCeilingDb {
    final raw = _box.get(_SettingsKeys.hardwareGainCeilingDb);
    if (raw is! num || raw.isNaN) return 50.0;
    final d = raw.toDouble();
    if (!d.isFinite) return 50.0;
    if (d < 0.0) return 0.0;
    if (d > 50.0) return 50.0;
    return d;
  }

  @override
  Future<void> setHardwareGainCeilingDb(double value) async {
    double v = value;
    if (v.isNaN || !v.isFinite) v = 50.0;
    if (v < 0.0) v = 0.0;
    if (v > 50.0) v = 50.0;
    await _box.put(_SettingsKeys.hardwareGainCeilingDb, v);
  }

  /// Lee una key con un valor numérico esperado en `[0.0, 1.0]`. Trata
  /// valores ausentes, no numéricos, NaN y ±Infinity como [fallback].
  /// Cualquier otro valor se clampa al rango.
  double _readClamped01(String key, {required double fallback}) {
    final raw = _box.get(key);
    if (raw is! num || raw.isNaN) return fallback;
    final d = raw.toDouble();
    if (!d.isFinite) return fallback;
    if (d < 0.0) return 0.0;
    if (d > 1.0) return 1.0;
    return d;
  }

  /// Normaliza un valor antes de persistirlo en una key de rango `[0, 1]`.
  /// Valores no finitos (NaN, ±Infinity) se reemplazan por [fallback];
  /// cualquier otro valor se clampa al rango.
  double _normalize01(double value, {required double fallback}) {
    if (value.isNaN || !value.isFinite) return fallback;
    if (value < 0.0) return 0.0;
    if (value > 1.0) return 1.0;
    return value;
  }

  /// Clampa un entero al rango válido del NR `[0, 3]`.
  int _clampNrLevel(int value) {
    if (value < 0) return 0;
    if (value > 3) return 3;
    return value;
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
