import '../entities/environment_profile.dart';

/// Interfaz del repositorio de perfiles de entorno.
///
/// Gestiona perfiles predefinidos y personalizados del usuario.
///
/// Requisitos: 8.1, 8.4
abstract class ProfileRepository {
  /// Obtiene todos los perfiles disponibles (predefinidos + personalizados).
  Future<List<EnvironmentProfile>> getAllProfiles();

  /// Obtiene los perfiles predefinidos del sistema.
  List<EnvironmentProfile> getPredefinedProfiles();

  /// Obtiene un perfil por nombre.
  Future<EnvironmentProfile?> getProfileByName(String name);

  /// Guarda un perfil personalizado.
  Future<void> saveCustomProfile(EnvironmentProfile profile);

  /// Elimina un perfil personalizado por nombre.
  /// No permite eliminar perfiles predefinidos.
  Future<void> deleteCustomProfile(String name);

  /// Verifica si un perfil es predefinido (no eliminable).
  bool isPredefined(String name);
}
