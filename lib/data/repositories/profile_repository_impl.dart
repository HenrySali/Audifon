import 'package:hive/hive.dart';

import '../../domain/entities/environment_profile.dart';
import '../../domain/repositories/profile_repository.dart';

/// Nombre del Hive box para perfiles de entorno.
const String profilesBoxName = 'profiles_box';

/// Implementación del repositorio de perfiles usando Hive.
///
/// Gestiona perfiles predefinidos (en memoria) y personalizados
/// (persistidos en Hive). Los perfiles se serializan como Maps
/// sin code generation.
///
/// Requisitos: 8.1, 8.4
class ProfileRepositoryImpl implements ProfileRepository {
  final Box<dynamic> _box;

  /// Nombres de los perfiles predefinidos (no eliminables).
  static const Set<String> _predefinedNames = {
    'Silencioso',
    'Conversación',
    'Ruidoso',
  };

  ProfileRepositoryImpl(this._box);

  /// Abre el box de Hive para perfiles.
  static Future<Box<dynamic>> openBox() async {
    return Hive.openBox(profilesBoxName);
  }

  @override
  List<EnvironmentProfile> getPredefinedProfiles() {
    return EnvironmentProfile.predefinedProfiles;
  }

  @override
  Future<List<EnvironmentProfile>> getAllProfiles() async {
    final predefined = getPredefinedProfiles();
    final customProfiles = <EnvironmentProfile>[];

    for (final key in _box.keys) {
      final data = _box.get(key);
      if (data != null) {
        final profile = _deserialize(data);
        // No duplicar predefinidos
        if (!_predefinedNames.contains(profile.name)) {
          customProfiles.add(profile);
        }
      }
    }

    return [...predefined, ...customProfiles];
  }

  @override
  Future<EnvironmentProfile?> getProfileByName(String name) async {
    // Buscar primero en predefinidos
    for (final profile in EnvironmentProfile.predefinedProfiles) {
      if (profile.name == name) return profile;
    }

    // Buscar en personalizados
    final data = _box.get(name);
    if (data == null) return null;
    return _deserialize(data);
  }

  @override
  Future<void> saveCustomProfile(EnvironmentProfile profile) async {
    final data = _serialize(profile);
    await _box.put(profile.name, data);
  }

  @override
  Future<void> deleteCustomProfile(String name) async {
    if (isPredefined(name)) return; // No eliminar predefinidos
    await _box.delete(name);
  }

  @override
  bool isPredefined(String name) {
    return _predefinedNames.contains(name);
  }

  /// Serializa un EnvironmentProfile a un Map almacenable en Hive.
  Map<String, dynamic> _serialize(EnvironmentProfile profile) {
    return {
      'name': profile.name,
      'nrLevel': profile.nrLevel,
      'compressionRatio': profile.compressionRatio,
      'expansionKnee': profile.expansionKnee,
      'compressionKnee': profile.compressionKnee,
    };
  }

  /// Deserializa un Map de Hive a un EnvironmentProfile.
  EnvironmentProfile _deserialize(dynamic data) {
    final map = Map<String, dynamic>.from(data as Map);
    return EnvironmentProfile(
      name: map['name'] as String,
      nrLevel: map['nrLevel'] as int,
      compressionRatio: (map['compressionRatio'] as num).toDouble(),
      expansionKnee: (map['expansionKnee'] as num).toDouble(),
      compressionKnee: (map['compressionKnee'] as num).toDouble(),
    );
  }
}
