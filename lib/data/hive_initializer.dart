import 'package:hive_flutter/hive_flutter.dart';

import 'repositories/audiogram_repository_impl.dart';
import 'repositories/profile_repository_impl.dart';
import 'repositories/settings_repository_impl.dart';

/// Inicializador de Hive para la aplicación.
///
/// Configura Hive con Flutter, abre todos los boxes necesarios,
/// y proporciona acceso a las instancias de repositorios.
///
/// Nota: No se usan adaptadores generados por código (TypeAdapters).
/// En su lugar, los repositorios serializan/deserializan manualmente
/// usando Maps dinámicos, lo que evita la dependencia de build_runner
/// para la persistencia.
///
/// Boxes registrados:
/// - audiogram_box: Almacena el audiograma del usuario
/// - profiles_box: Almacena perfiles personalizados
/// - settings_box: Almacena configuración (lastProfile, lastVolume, calibración)
class HiveInitializer {
  HiveInitializer._();

  static bool _initialized = false;

  /// Inicializa Hive y abre todos los boxes de la aplicación.
  ///
  /// Debe llamarse una sola vez al inicio de la app, antes de
  /// crear los repositorios.
  static Future<void> initialize() async {
    if (_initialized) return;

    await Hive.initFlutter();
    _initialized = true;
  }

  /// Abre todos los boxes necesarios y retorna las instancias de repositorios.
  ///
  /// Llama a [initialize] primero si no se ha hecho.
  static Future<HiveRepositories> openRepositories() async {
    if (!_initialized) {
      await initialize();
    }

    final audiogramBox = await AudiogramRepositoryImpl.openBox();
    final profilesBox = await ProfileRepositoryImpl.openBox();
    final settingsBox = await SettingsRepositoryImpl.openBox();

    return HiveRepositories(
      audiogramRepository: AudiogramRepositoryImpl(audiogramBox),
      profileRepository: ProfileRepositoryImpl(profilesBox),
      settingsRepository: SettingsRepositoryImpl(settingsBox),
    );
  }

  /// Cierra todos los boxes de Hive.
  static Future<void> close() async {
    await Hive.close();
    _initialized = false;
  }
}

/// Contenedor de todos los repositorios Hive de la aplicación.
class HiveRepositories {
  final AudiogramRepositoryImpl audiogramRepository;
  final ProfileRepositoryImpl profileRepository;
  final SettingsRepositoryImpl settingsRepository;

  const HiveRepositories({
    required this.audiogramRepository,
    required this.profileRepository,
    required this.settingsRepository,
  });
}
