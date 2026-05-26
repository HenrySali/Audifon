import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import 'data/bridges/audio_bridge_impl.dart';
import 'data/hive_initializer.dart';
import 'domain/entities/audiogram.dart';
import 'domain/gain_prescriber.dart';
import 'presentation/bloc/amplification_bloc.dart';
import 'presentation/screens/main_screen.dart';
import 'presentation/services/permission_service.dart';
import 'presentation/utils/device_checker.dart';

/// Punto de entrada de la aplicación PSK Mobile Hearing Aid.
///
/// Inicializa:
/// 1. Flutter bindings
/// 2. Hive (persistencia local) y abre todos los repositorios
/// 3. Guarda el audiograma por defecto en primer lanzamiento
/// 4. Crea las dependencias del sistema (AudioBridge, GainPrescriber, etc.)
/// 5. Envuelve la app en MultiBlocProvider con AmplificationBloc
/// 6. Restaura la última configuración (perfil, volumen) al iniciar
///
/// Requisitos: 8.4, 4.4
void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Inicializar Hive y abrir todos los repositorios
  final repositories = await HiveInitializer.openRepositories();

  // En primer lanzamiento (no hay audiograma almacenado), guardar el default
  final hasAudiogram = await repositories.audiogramRepository.hasAudiogram();
  if (!hasAudiogram) {
    await repositories.audiogramRepository.saveAudiogram(
      Audiogram.defaultAudiogram(),
    );
  }

  // Crear instancias de servicios
  final audioBridge = AudioBridgeImpl();
  final gainPrescriber = GainPrescriber();
  final deviceChecker = DeviceCheckerImpl();
  final permissionService = PermissionService(deviceChecker: deviceChecker);

  runApp(
    HearingAidApp(
      repositories: repositories,
      audioBridge: audioBridge,
      gainPrescriber: gainPrescriber,
      permissionService: permissionService,
    ),
  );
}

/// Aplicación principal PSK Mobile Hearing Aid.
///
/// Configura el árbol de widgets con:
/// - MultiBlocProvider para inyección de dependencias del BLoC
/// - Tema oscuro con acentos cyan/teal (consistente con la UI existente)
/// - MainScreen como pantalla principal
class HearingAidApp extends StatelessWidget {
  final HiveRepositories repositories;
  final AudioBridgeImpl audioBridge;
  final GainPrescriber gainPrescriber;
  final PermissionService permissionService;

  const HearingAidApp({
    super.key,
    required this.repositories,
    required this.audioBridge,
    required this.gainPrescriber,
    required this.permissionService,
  });

  @override
  Widget build(BuildContext context) {
    return MultiBlocProvider(
      providers: [
        BlocProvider<AmplificationBloc>(
          create: (_) => AmplificationBloc(
            audioBridge: audioBridge,
            audiogramRepository: repositories.audiogramRepository,
            profileRepository: repositories.profileRepository,
            settingsRepository: repositories.settingsRepository,
            gainPrescriber: gainPrescriber,
          ),
        ),
      ],
      child: MaterialApp(
        title: 'PSK Hearing Aid',
        debugShowCheckedModeBanner: false,
        theme: ThemeData.dark().copyWith(
          colorScheme: ColorScheme.dark(
            primary: Colors.cyan,
            secondary: Colors.tealAccent,
            surface: const Color(0xFF16213e),
          ),
          scaffoldBackgroundColor: const Color(0xFF1a1a2e),
          appBarTheme: const AppBarTheme(
            backgroundColor: Color(0xFF0f3460),
            elevation: 0,
          ),
        ),
        home: const MainScreen(),
      ),
    );
  }
}
