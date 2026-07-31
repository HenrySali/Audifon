import 'package:equatable/equatable.dart';

/// Tipo de advertencia emitida por el repositorio de perfiles
/// personalizados.
///
/// Las advertencias son señales no-bloqueantes que la UI puede mostrar
/// como badges o snackbars sin interrumpir el flujo clínico activo.
///
/// - [migrated]: el preset fue cargado desde un blob legacy (sin
///   `schemaVersion` o con versión anterior) y el repositorio
///   recomputó el bundle al esquema actual. La UI debe mostrar el
///   chip "Migrado" sobre el preset (Req 8.7).
/// - [corrupt]: el preset persistido tiene un audiograma o bundle
///   fuera de rango y fue excluido del listado retornado por
///   `getAllProfiles` / `getCustomPresets`. La UI puede listar el
///   nombre del preset corrupto sin afectar el bundle activo
///   (Req 8.5).
/// - [staleUpdateFailed]: una entrada del listado falló al recibir
///   el flag `stale = true` durante `markCustomPresetsAsStale`. El
///   resto de los presets se actualizaron exitosamente (Req 9.3).
enum ProfileRepositoryWarningType {
  migrated,
  corrupt,
  staleUpdateFailed,
}

/// Advertencia observable emitida por el repositorio de perfiles.
///
/// Se publica vía el stream `ProfileRepository.warnings` para que la
/// capa de presentación (BLoC + UI) pueda mostrarla sin acoplar la
/// persistencia con la lógica clínica activa (Req 8.4, 8.5, 9.3).
class ProfileRepositoryWarning extends Equatable {
  /// Tipo de advertencia.
  final ProfileRepositoryWarningType type;

  /// Identificador del preset afectado (su `name`).
  final String presetName;

  /// Mensaje descriptivo orientado a developers/QA. La UI puede
  /// mostrar un texto user-friendly basado en [type] sin depender
  /// directamente de este string.
  final String message;

  /// Lista de violaciones detectadas (sólo poblada cuando
  /// [type] == [ProfileRepositoryWarningType.corrupt]).
  final List<String> violations;

  const ProfileRepositoryWarning({
    required this.type,
    required this.presetName,
    required this.message,
    this.violations = const [],
  });

  @override
  List<Object?> get props => [type, presetName, message, violations];
}
