import '../audiogram_driven_presets/audiogram_driven_bundle.dart';
import '../audiogram_driven_presets/custom_preset_record.dart';
import '../audiogram_driven_presets/manual_adjustment_delta.dart';
import '../audiogram_driven_presets/profile_repository_warning.dart';
import '../entities/audiogram.dart';
import '../entities/environment_profile.dart';
import '../entities/prescription_mode.dart';
import '../entities/patient_profile.dart';

/// Interfaz del repositorio de perfiles de entorno y presets
/// personalizados.
///
/// Gestiona perfiles predefinidos (Silencioso, Conversación, Ruidoso) y
/// presets personalizados creados por el usuario, persistiendo el
/// contexto clínico completo de cada preset (audiograma, bundle,
/// estilo, override de NR, delta manual) — Req 8.1, 8.2, 8.3, 8.4.
///
/// Las advertencias observables (preset migrado, blob corrupto, fallo
/// parcial al marcar presets como obsoletos) se publican vía el
/// stream [warnings] para que la UI pueda mostrarlas como badges o
/// snackbars sin acoplar la persistencia con el bundle activo del
/// bloc — Req 8.4, 8.5, 9.3.
///
/// Requisitos: 8.1, 8.2, 8.3, 8.4, 8.5, 8.6, 9.2, 9.3, 9.5
abstract class ProfileRepository {
  /// Stream de advertencias observables emitidas por el repositorio.
  ///
  /// Las advertencias se emiten:
  /// - al cargar un preset migrado (Req 8.4),
  /// - al excluir un preset corrupto del listado (Req 8.5),
  /// - al fallar parcialmente la actualización del flag stale (Req 9.3).
  Stream<ProfileRepositoryWarning> get warnings;

  /// Obtiene todos los perfiles disponibles (predefinidos + custom).
  ///
  /// Los presets corruptos (audiograma o bundle fuera de rango) se
  /// excluyen del listado y se reportan como advertencias en
  /// [warnings] (Req 8.5).
  Future<List<EnvironmentProfile>> getAllProfiles();

  /// Obtiene los perfiles predefinidos del sistema.
  List<EnvironmentProfile> getPredefinedProfiles();

  /// Obtiene un perfil por nombre.
  Future<EnvironmentProfile?> getProfileByName(String name);

  /// Lista los presets personalizados con su contexto clínico
  /// completo (audiograma + bundle + flags `stale`/`migrated`).
  ///
  /// La carga aplica:
  /// - migración de schema legacy → recomputa el bundle desde el
  ///   audiograma + estilo + override y persiste el blob actualizado
  ///   con `migrated = true` (Req 8.4);
  /// - validación estructural y de rango → presets corruptos se
  ///   excluyen del listado y se reportan vía [warnings] (Req 8.5).
  Future<List<CustomPresetRecord>> getCustomPresets();

  /// Obtiene un preset personalizado por nombre con su contexto
  /// clínico completo. `null` si no existe o el preset persistido
  /// está corrupto.
  ///
  /// Aplica el mismo pipeline de migración + validación que
  /// [getCustomPresets].
  Future<CustomPresetRecord?> getCustomPresetByName(String name);

  /// Guarda un preset personalizado capturando el contexto clínico
  /// completo (audiograma + bundle + estilo + override + delta).
  ///
  /// El blob serializado tiene un tope estructural de 64 KB; si lo
  /// supera el método lanza [StateError] sin pisar el preset
  /// previamente guardado con el mismo nombre (Req 8.3).
  ///
  /// Si el preset ya existe se reemplaza (Hive `put`); todos los demás
  /// presets quedan inalterados (Req 8.6).
  ///
  /// Cuando [createdAt] se omite el repositorio resuelve
  /// `DateTime.now().toUtc()` al momento de la escritura.
  Future<void> saveCustomProfile({
    required String name,
    required Audiogram audiogram,
    required AudiogramDrivenBundle bundle,
    String appliedStyleName = '',
    int nrOverride = 0,
    ManualAdjustmentDelta? manualDelta,
    DateTime? createdAt,
  });

  /// API legacy: persiste un [EnvironmentProfile] sin contexto
  /// clínico. Mantenida temporalmente para soportar callers que
  /// todavía no migraron al path bundle-driven; los presets
  /// guardados por esta vía no aparecen en [getCustomPresets] hasta
  /// que se vuelva a guardar con la API nueva.
  ///
  /// Requisitos: 8.2 (read-back compatibility)
  @Deprecated(
    'Usar saveCustomProfile(name:, audiogram:, bundle:, ...) con el '
    'contexto clínico completo. La API legacy se mantiene sólo para '
    'callers en transición y no preserva el bundle ni el audiograma.',
  )
  Future<void> saveLegacyCustomProfile(EnvironmentProfile profile);

  /// Elimina un preset personalizado por nombre.
  /// No permite eliminar perfiles predefinidos (Req 8.6).
  Future<void> deleteCustomProfile(String name);

  /// Marca como obsoletos los presets personalizados cuyo audiograma
  /// difiera del [newAudiogram] en más de [thresholdDb] dB de MAD por
  /// banda (Req 9.2).
  ///
  /// Retorna la lista de nombres de presets que NO pudieron
  /// actualizarse (errores de IO o blob corrupto). Estos casos se
  /// publican además en [warnings] como
  /// [ProfileRepositoryWarningType.staleUpdateFailed] (Req 9.3).
  Future<List<String>> markCustomPresetsAsStale(
    Audiogram newAudiogram, {
    double thresholdDb = 5.0,
  });

  /// Regenera el bundle persistido del preset con [name] usando el
  /// [audiogram] actual del paciente, el [appliedStyleName] y el
  /// `nrOverride` originales del preset. Limpia el flag `stale`
  /// (Req 9.5).
  ///
  /// Si la regeneración falla (BundleBuilder lanza, persistencia
  /// falla, estilo desconocido) el método hace rollback al blob
  /// previo y propaga la excepción al caller (Req 9.6).
  Future<void> regenerateCustomPreset(
    String name, {
    required Audiogram audiogram,
    required PrescriptionMode mode,
    PatientProfile? profile,
  });

  /// Verifica si un perfil es predefinido (no eliminable).
  bool isPredefined(String name);

  /// Cierra los recursos (stream controllers) del repositorio.
  ///
  /// Llamar al apagar la app o desmontar el contenedor de DI para
  /// evitar leaks de listeners en [warnings].
  Future<void> dispose();
}
