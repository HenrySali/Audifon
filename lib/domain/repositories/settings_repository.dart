import '../entities/calibration_data.dart';
import '../entities/prescription_mode.dart';

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

  /// Obtiene el modo de prescriptor persistido (Smart-NL2 / Smart-NL3).
  /// Retorna [PrescriberMode.smartNl2] si no hay valor guardado (default
  /// para instalaciones nuevas — Req 5.8).
  Future<PrescriberMode> getPrescriberMode();

  /// Guarda el modo de prescriptor seleccionado por el usuario.
  Future<void> setPrescriberMode(PrescriberMode mode);

  /// Obtiene la experiencia previa del usuario con audífonos en meses.
  ///
  /// Retorna `null` cuando todavía no hay un valor guardado, lo que
  /// representa un usuario nuevo (sin onboarding completo). El prescriptor
  /// NL3 utiliza este dato para aplicar la corrección de aclimatización
  /// (-3 dB en todas las bandas) cuando `experienceMonths < 6`.
  Future<int?> getExperienceMonths();

  /// Guarda la experiencia previa del usuario con audífonos en meses.
  ///
  /// Acepta valores ≥ 0; los valores negativos se tratan como cero.
  Future<void> setExperienceMonths(int months);
}
