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

  // --- Tecnico↔Paciente feature parity (Task 1.1) -------------------------
  // Las cinco keys siguientes se introducen para alinear el técnico con el
  // paciente. Los getters son SINCRÓNICOS para que el helper
  // `_effectiveCompressionRatio(bundle)` del AmplificationBloc pueda leerlos
  // sin `await` (Req 4.4, 4.5, 4.7). Los setters quedan asíncronos porque
  // Hive escribe a disco.

  /// Estado del toggle "MHL Prescripción" (gains EQ flat 8 dB + ratio 1.0).
  /// Default `false` cuando la key está ausente.
  ///
  /// Requisitos: 1.10
  bool get mhlPrescriptionEnabled;

  /// Persiste el estado del toggle "MHL Prescripción".
  ///
  /// Requisitos: 1.10
  Future<void> setMhlPrescriptionEnabled(bool value);

  /// Estado del toggle "Modo Música" (NR=0 + DNN=0).
  /// Default `false` cuando la key está ausente.
  ///
  /// Requisitos: 1.11
  bool get musicModeEnabled;

  /// Persiste el estado del toggle "Modo Música".
  ///
  /// Requisitos: 1.11
  Future<void> setMusicModeEnabled(bool value);

  /// Slider de Comodidad `[0.0, 1.0]` que ajusta el `compressionRatio` del
  /// WDRC vía `base + (1 - base) * comfort`. Default `0.5` cuando la key
  /// está ausente o contiene un valor no numérico (NaN, null, etc.).
  /// El valor retornado siempre está clampeado a `[0.0, 1.0]`.
  ///
  /// Requisitos: 4.6, 4.7
  double get comfort;

  /// Persiste el slider de Comodidad. El valor se clampa a `[0.0, 1.0]`
  /// antes de escribir; valores no finitos (NaN/±Infinity) se reemplazan
  /// por el default `0.5`.
  ///
  /// Requisitos: 4.6, 4.7
  Future<void> setComfort(double value);

  /// Intensidad del DNN `[0.0, 1.0]`. Default `0.6` cuando la key está
  /// ausente o contiene un valor no numérico. El valor retornado siempre
  /// está clampeado a `[0.0, 1.0]`.
  ///
  /// Requisitos: 6.7
  double get dnnIntensity;

  /// Persiste la intensidad del DNN. El valor se clampa a `[0.0, 1.0]`;
  /// valores no finitos se reemplazan por el default `0.6`.
  ///
  /// Requisitos: 6.7
  Future<void> setDnnIntensity(double value);

  /// Nivel de NR `[0, 3]`. Default `0` cuando ninguna key está presente.
  ///
  /// Lee primero la key nueva `nrLevel`; si no existe, hace fallback a la
  /// key legacy `lastNrLevel` (vía [getLastNrLevel]) para mantener
  /// retro-compatibilidad con instalaciones previas. La primera invocación
  /// de [setNrLevel] sincroniza ambas keys.
  ///
  /// Requisitos: 6.8
  int get nrLevel;

  /// Persiste el nivel de NR clampeado a `[0, 3]` y sincroniza la key
  /// legacy `lastNrLevel` para que [getLastNrLevel] devuelva el mismo
  /// valor.
  ///
  /// Requisitos: 6.8
  Future<void> setNrLevel(int value);

  /// Estado del toggle "Modo Conversación" (SCO + 16 kHz a baja latencia).
  /// Default `false` cuando la key está ausente.
  bool get conversationModeEnabled;

  /// Persiste el estado del toggle "Modo Conversación".
  Future<void> setConversationModeEnabled(bool value);

  // --- Gain Ceiling (calibración de ganancia máxima del hardware) ----------
  // El técnico usa un slider para encontrar el punto de distorsión del
  // auricular conectado. Ese valor se persiste como techo absoluto de
  // ganancia por banda. Default 50.0 (sin restricción — usuario no calibró).

  /// Techo de ganancia máxima del hardware en dB **escalar** (legacy).
  ///
  /// Valor en `[0.0, 50.0]`. Default `50.0` cuando la key está ausente
  /// (equivalente a "sin límite": el hardware soporta todo el rango del EQ).
  /// Lectura sincrónica para uso en clamps hot-path.
  ///
  /// **Reemplazado por [hardwareGainCeilingPerBandDb]** a partir de la
  /// calibración de 12 pasos. Esta propiedad se conserva por
  /// retro-compatibilidad: implementaciones nuevas la derivan como
  /// `min(hardwareGainCeilingPerBandDb)` para que cualquier consumidor
  /// legacy reciba el techo más restrictivo de las 12 bandas.
  double get hardwareGainCeilingDb;

  /// Persiste el techo escalar legacy.
  ///
  /// El valor se clampa a `[0.0, 50.0]`; valores no finitos se reemplazan
  /// por el default `50.0`. Setter conservado por backward compat: la
  /// implementación replica el valor en las 12 bandas para mantener
  /// coherencia con [hardwareGainCeilingPerBandDb].
  Future<void> setHardwareGainCeilingDb(double value);

  /// Techo de ganancia máxima del hardware en dB, **por banda** (12).
  ///
  /// Lista de longitud exacta 12, alineada con
  /// `Audiogram.standardFrequencies` (250, 500, 750, 1000, 1500, 2000,
  /// 2500, 3000, 3500, 4000, 6000, 8000 Hz). Cada valor en `[0.0, 50.0]`;
  /// default `[50.0, 50.0, ..., 50.0]` cuando la key está ausente
  /// (equivalente a "sin restricción" en todas las bandas).
  ///
  /// Lectura sincrónica para uso en hot-path del DSP. La implementación
  /// migra automáticamente la key escalar legacy [hardwareGainCeilingDb]
  /// a las 12 bandas (replicando el valor) cuando la key per-banda no
  /// está presente.
  List<double> get hardwareGainCeilingPerBandDb;

  /// Persiste el techo por banda. Recibe lista de longitud 12; cada
  /// valor se clampa a `[0.0, 50.0]` y los valores no finitos se
  /// reemplazan por `50.0`. Si la lista no tiene 12 elementos la
  /// implementación rellena con `50.0` los faltantes o trunca los
  /// excedentes.
  Future<void> setHardwareGainCeilingPerBandDb(List<double> values);
}
