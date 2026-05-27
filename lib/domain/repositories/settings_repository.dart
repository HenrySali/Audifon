import '../entities/calibration_data.dart';

/// Método de prescripción de ganancia.
enum PrescriptionMethod {
  nalNl2,
  halfGain,
}

/// Interfaz del repositorio de configuración de la app.
///
/// Almacena preferencias del usuario: último perfil, volumen,
/// método de prescripción y datos de calibración.
///
/// Requisitos: 4.1, 8.4
abstract class SettingsRepository {
  /// Obtiene el nombre del último perfil utilizado.
  Future<String?> getLastProfile();

  /// Guarda el nombre del último perfil utilizado.
  Future<void> setLastProfile(String profileName);

  /// Obtiene el último volumen utilizado (dB).
  Future<double?> getLastVolume();

  /// Guarda el último volumen utilizado (dB).
  Future<void> setLastVolume(double volumeDb);

  /// Obtiene el método de prescripción configurado.
  Future<PrescriptionMethod> getPrescriptionMethod();

  /// Guarda el método de prescripción.
  Future<void> setPrescriptionMethod(PrescriptionMethod method);

  /// Obtiene los datos de calibración almacenados.
  Future<CalibrationData?> getCalibrationData();

  /// Guarda los datos de calibración.
  Future<void> setCalibrationData(CalibrationData data);

  /// Restaura la última configuración utilizada.
  /// Retorna un record con lastProfile y lastVolume.
  Future<({String? lastProfile, double? lastVolume})> restoreLastConfig();

  /// Obtiene el último preset de EQ guardado.
  Future<Map<String, dynamic>?> getLastEqPreset();

  /// Guarda el preset de EQ activo.
  Future<void> setLastEqPreset(Map<String, dynamic> presetJson);

  /// Obtiene el último nivel de NR guardado.
  Future<int?> getLastNrLevel();

  /// Guarda el nivel de NR activo.
  Future<void> setLastNrLevel(int level);
}
