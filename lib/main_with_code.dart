import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:hive/hive.dart';

import 'auth/auth_screen.dart';
import 'auth/auth_service.dart';
import 'auth/blocked_by_code_screen.dart';
import 'auth/license_expired_screen.dart';
import 'auth/update_required_screen.dart';
import 'data/bridges/audio_bridge_impl.dart';
import 'data/hive_initializer.dart';
import 'data/services/adaptive_learning_service.dart';
import 'data/services/remote_config_service.dart';
import 'domain/entities/audiogram.dart';
import 'domain/gain_prescriber.dart';
import 'presentation/bloc/amplification_bloc.dart';
import 'presentation/screens/main_screen.dart';
import 'presentation/screens/permissions_screen.dart';
import 'presentation/services/permission_service.dart';
import 'presentation/utils/device_checker.dart';
import 'presentation/widgets/remote_config_gate.dart';
import 'security/biometric_gate.dart';
import 'security/security_settings_repository.dart';

/// Punto de entrada alternativo CON codigo de activacion.
///
/// Para compilar esta variante:
///   flutter run -t lib/main_with_code.dart
///
/// Flujo:
/// 1. Misma inicializacion que main.dart (Hive, audiograma, servicios, etc.)
/// 2. Usa AuthApp como root widget
/// 3. Si hay modo guardado (technical) -> CodeStatusGate -> BiometricGate -> app
/// 4. Si no hay modo -> muestra AuthScreen para ingresar codigo
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

  // Gate de biometria / PIN antes de mostrar la UI principal.
  await SecuritySettingsRepository.instance.init();

  // Cliente del backend remoto (kill switch + notificacion de update).
  await RemoteConfigService.instance.init();

  // Aprendizaje Adaptativo: init (carga historial desde Hive).
  await _initAdaptiveLearning();

  runApp(
    AuthApp(
      repositories: repositories,
      audioBridge: audioBridge,
      gainPrescriber: gainPrescriber,
      permissionService: permissionService,
    ),
  );
}

/// Aplicacion con autenticacion por codigo (variante tecnico).
///
/// Flujo:
/// 1. Al iniciar, verifica si hay un modo guardado (SharedPreferences)
/// 2. Si NO hay modo guardado -> muestra AuthScreen para ingresar codigo
/// 3. Si SI hay modo guardado (technical) -> CodeStatusGate -> BiometricGate -> app
class AuthApp extends StatelessWidget {
  final HiveRepositories repositories;
  final AudioBridgeImpl audioBridge;
  final GainPrescriber gainPrescriber;
  final PermissionService permissionService;

  const AuthApp({
    super.key,
    required this.repositories,
    required this.audioBridge,
    required this.gainPrescriber,
    required this.permissionService,
  });

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Oir Pro - Servicio Tecnico',
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
      home: FutureBuilder<TechMode?>(
        future: AuthService().getSavedMode().timeout(
              const Duration(seconds: 5),
              onTimeout: () => null,
            ),
        builder: (context, snapshot) {
          if (snapshot.connectionState == ConnectionState.waiting) {
            // Loading
            return const Scaffold(
              backgroundColor: Color(0xFF1a1a2e),
              body: Center(
                child: CircularProgressIndicator(color: Colors.cyan),
              ),
            );
          }

          final savedMode = snapshot.data;
          if (savedMode == null || savedMode == TechMode.locked) {
            // Sin modo guardado -> pedir codigo
            return AuthScreen(
              repositories: repositories,
              audioBridge: audioBridge,
              gainPrescriber: gainPrescriber,
              permissionService: permissionService,
            );
          }

          // Modo guardado valido -> verificar estado del codigo antes de abrir
          return CodeStatusGate(
            repositories: repositories,
            audioBridge: audioBridge,
            gainPrescriber: gainPrescriber,
            permissionService: permissionService,
          );
        },
      ),
    );
  }
}

/// Version actual de la app. Se usa para comparar con requiredVersion
/// del servidor en el flujo de check-status.
const String kAppVersion = '1.0.0';

/// Gate intermedio que verifica el estado del codigo de activacion antes
/// de permitir el acceso a BiometricGate -> RemoteConfigGate -> HearingAidApp.
///
/// Flujo:
/// - Si hay internet: llama a checkStatus(code, deviceId)
///   - blocked -> BlockedByCodeScreen
///   - expirado -> LicenseExpiredScreen
///   - requiredVersion > version actual -> UpdateRequiredScreen
///   - ok -> continua a BiometricGate
/// - Si no hay internet: verifica expiresAt local
///   - Si fecha actual > expiresAt -> LicenseExpiredScreen (offline)
///   - Si no vencio -> continua normal
class CodeStatusGate extends StatefulWidget {
  final HiveRepositories repositories;
  final AudioBridgeImpl audioBridge;
  final GainPrescriber gainPrescriber;
  final PermissionService permissionService;

  const CodeStatusGate({
    super.key,
    required this.repositories,
    required this.audioBridge,
    required this.gainPrescriber,
    required this.permissionService,
  });

  @override
  State<CodeStatusGate> createState() => _CodeStatusGateState();
}

class _CodeStatusGateState extends State<CodeStatusGate> {
  final AuthService _authService = AuthService();
  bool _loading = true;
  Widget? _blockedWidget;

  @override
  void initState() {
    super.initState();
    _checkCodeStatus();
  }

  Future<void> _checkCodeStatus() async {
    setState(() {
      _loading = true;
      _blockedWidget = null;
    });

    final code = await _authService.getActivationCode();
    if (code == null) {
      // No hay codigo guardado (validacion anterior al update), continuar
      setState(() => _loading = false);
      return;
    }

    final deviceId = await _authService.getDeviceId();
    final result = await _authService.checkStatus(code, deviceId);

    if (!mounted) return;

    if (result.noNetwork) {
      // Sin internet: verificar expiresAt local
      final expiresAtStr = await _authService.getExpiresAt();
      if (expiresAtStr != null) {
        final expiresAt = DateTime.tryParse(expiresAtStr);
        if (expiresAt != null && DateTime.now().isAfter(expiresAt)) {
          setState(() {
            _loading = false;
            _blockedWidget = LicenseExpiredScreen(
              additionalMessage: 'Conectate a internet para verificar tu licencia.',
              onRetry: _checkCodeStatus,
            );
          });
          return;
        }
      }
      // No vencio o no hay expiresAt guardado -> continuar
      setState(() => _loading = false);
      return;
    }

    if (result.blocked) {
      setState(() {
        _loading = false;
        _blockedWidget = BlockedByCodeScreen(
          blockedReason: result.blockedReason,
          onRetry: _checkCodeStatus,
        );
      });
      return;
    }

    if (!result.ok) {
      // Podria ser licencia vencida u otro error del server
      final errorMsg = result.error ?? '';
      if (errorMsg.toLowerCase().contains('vencio') ||
          errorMsg.toLowerCase().contains('expired')) {
        setState(() {
          _loading = false;
          _blockedWidget = LicenseExpiredScreen(
            onRetry: _checkCodeStatus,
          );
        });
        return;
      }
      // Otro error no bloqueante -> continuar
      setState(() => _loading = false);
      return;
    }

    // ok == true
    // Verificar requiredVersion
    if (result.requiredVersion != null &&
        result.requiredVersion!.isNotEmpty &&
        _isVersionGreater(result.requiredVersion!, kAppVersion)) {
      setState(() {
        _loading = false;
        _blockedWidget = UpdateRequiredScreen(
          requiredVersion: result.requiredVersion!,
        );
      });
      return;
    }

    // Todo ok, actualizar expiresAt local si viene
    if (result.expiresAt != null) {
      await _authService.saveExpiresAt(result.expiresAt!);
    }

    setState(() => _loading = false);
  }

  /// Compara dos versiones semver. Retorna true si [requiredVer] > [currentVer].
  bool _isVersionGreater(String requiredVer, String currentVer) {
    final reqParts = requiredVer.split('.').map((s) => int.tryParse(s) ?? 0).toList();
    final curParts = currentVer.split('.').map((s) => int.tryParse(s) ?? 0).toList();

    // Normalizar longitudes
    while (reqParts.length < 3) {
      reqParts.add(0);
    }
    while (curParts.length < 3) {
      curParts.add(0);
    }

    for (int i = 0; i < 3; i++) {
      if (reqParts[i] > curParts[i]) return true;
      if (reqParts[i] < curParts[i]) return false;
    }
    return false; // iguales
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Scaffold(
        backgroundColor: Color(0xFF1a1a2e),
        body: Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              CircularProgressIndicator(color: Colors.cyan),
              SizedBox(height: 16),
              Text(
                'Verificando estado...',
                style: TextStyle(color: Colors.white54, fontSize: 14),
              ),
            ],
          ),
        ),
      );
    }

    if (_blockedWidget != null) {
      return _blockedWidget!;
    }

    // Estado OK: continuar con el flujo normal
    return BiometricGate(
      child: RemoteConfigGate(
        child: HearingAidApp(
          repositories: widget.repositories,
          audioBridge: widget.audioBridge,
          gainPrescriber: widget.gainPrescriber,
          permissionService: widget.permissionService,
        ),
      ),
    );
  }
}

/// Aplicacion principal PSK Mobile Hearing Aid (variante tecnico con codigo).
///
/// Identica a la de main.dart pero accesible desde main_with_code.dart.
/// No requiere parametro userMode ya que el tecnico siempre tiene acceso
/// completo a todas las pantallas.
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
        home: const PermissionsScreen(child: MainScreen()),
      ),
    );
  }
}

/// Inicializa el servicio de aprendizaje adaptativo.
Future<void> _initAdaptiveLearning() async {
  AdaptiveLearningService.instance.configure(
    const AdaptiveLearningConfig(
      hermesBaseUrl: 'http://149.50.137.2:8080',
      requestTimeout: Duration(seconds: 15),
      maxObservations: 200,
    ),
  );
  await AdaptiveLearningService.instance.init();

  // Set device ID for Hermes tracking
  final deviceId = await _getOrCreateDeviceId();
  AdaptiveLearningService.instance.setDeviceId(deviceId);
  // Sync history from server (non-blocking)
  AdaptiveLearningService.instance.syncFromServer();
}

/// Obtiene o crea un ID de dispositivo unico para tracking de Hermes.
Future<String> _getOrCreateDeviceId() async {
  final box = await Hive.openBox('settings_box');
  final existing = box.get('hermes_device_id') as String?;
  if (existing != null && existing.isNotEmpty) return existing;

  final rng = Random.secure();
  final bytes = List<int>.generate(8, (_) => rng.nextInt(256));
  final id = bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  await box.put('hermes_device_id', id);
  return id;
}
