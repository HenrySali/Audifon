import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:local_auth/local_auth.dart';

import 'pin_fallback_screen.dart';
import 'pin_setup_screen.dart';
import 'security_settings_repository.dart';

/// Widget que envuelve la app y exige autenticación biométrica (o PIN
/// fallback) antes de mostrar el `child`.
///
/// Spec: oir-pro-rebrand-harden-and-remote-config — Fase 3 (R3.1 a R3.5).
///
/// Flujo:
///
/// 1. `init()` lee `isBiometricRequired()`. Si está OFF, render directo del
///    child (R3.4 — toggle en Servicio Técnico).
/// 2. Si está ON, consulta `LocalAuthentication.canCheckBiometrics` y
///    `getAvailableBiometrics()`:
///      - Hay biometría enrolada → `authenticate(...)` con sticky/biometricOnly=false.
///      - No hay biometría + no hay PIN → push a `PinSetupScreen` (primer arranque).
///      - No hay biometría + sí hay PIN → push a `PinFallbackScreen`.
/// 3. Éxito → `setState(_unlocked = true)` y se renderiza el child.
/// 4. 5 fallas consecutivas → `exit(0)` (R3.3).
///
/// Mientras tanto se muestra un splash en azul marino (#0F1B2D) con el
/// nombre "Oír Pro" y un `CircularProgressIndicator` chico.
///
/// Detalle de implementación: como `BiometricGate` se monta en `runApp`,
/// no hay un `Navigator` por encima. El gate trae su propio `MaterialApp`
/// (con `_navigatorKey`) durante el splash para poder pushear las
/// pantallas de PIN. Cuando desbloquea, devuelve el `child` directo (que a
/// su vez incluye su propio `MaterialApp` con la app real).
class BiometricGate extends StatefulWidget {
  /// Permite inyectar un `LocalAuthentication` mock en tests.
  final LocalAuthentication? localAuth;

  /// Permite inyectar un repo mock en tests.
  final SecuritySettingsRepository? repository;

  /// La app real que se renderiza cuando el gate desbloquea.
  final Widget child;

  const BiometricGate({
    super.key,
    required this.child,
    this.localAuth,
    this.repository,
  });

  @override
  State<BiometricGate> createState() => _BiometricGateState();
}

class _BiometricGateState extends State<BiometricGate> {
  static const Color _kBg = Color(0xFF0F1B2D);

  late final LocalAuthentication _auth;
  late final SecuritySettingsRepository _repo;
  final GlobalKey<NavigatorState> _navigatorKey = GlobalKey<NavigatorState>();

  bool _unlocked = false;

  @override
  void initState() {
    super.initState();
    _auth = widget.localAuth ?? LocalAuthentication();
    _repo = widget.repository ?? SecuritySettingsRepository.instance;
    // Disparar el chequeo después del primer frame para que el splash se
    // pinte antes de bloquear con la llamada nativa.
    WidgetsBinding.instance.addPostFrameCallback((_) => _runGate());
  }

  Future<void> _runGate() async {
    try {
      final required = await _repo.isBiometricRequired();
      if (!required) {
        // Toggle OFF (R3.4): passthrough directo.
        if (!mounted) return;
        setState(() {
          _unlocked = true;
        });
        return;
      }

      final canCheck = await _safeCanCheckBiometrics();
      final available =
          canCheck ? await _safeAvailableBiometrics() : <BiometricType>[];
      final hasBiometric = available.isNotEmpty;
      final hasPin = await _repo.hasPin();

      if (hasBiometric) {
        await _runBiometricFlow();
        return;
      }

      // Sin biometría enrolada: caer al PIN.
      if (!hasPin) {
        await _runPinSetupFlow();
      } else {
        await _runPinFallbackFlow();
      }
    } catch (e) {
      // Cualquier error inesperado en la cadena (Hive corrupto, plugin
      // crash, etc.) deja la app bloqueada con el splash. El usuario puede
      // matar la app y reintentar. No queremos abrir sin auth.
      debugPrint('[BiometricGate] error: $e');
    }
  }

  Future<bool> _safeCanCheckBiometrics() async {
    try {
      return await _auth.canCheckBiometrics;
    } catch (_) {
      return false;
    }
  }

  Future<List<BiometricType>> _safeAvailableBiometrics() async {
    try {
      return await _auth.getAvailableBiometrics();
    } catch (_) {
      return <BiometricType>[];
    }
  }

  Future<void> _runBiometricFlow() async {
    try {
      final ok = await _auth.authenticate(
        localizedReason: 'Identificate para abrir Oír Pro',
        options: const AuthenticationOptions(
          biometricOnly: false,
          stickyAuth: true,
          useErrorDialogs: true,
        ),
      );
      if (ok) {
        await _repo.resetFailedAttempts();
        if (!mounted) return;
        setState(() {
          _unlocked = true;
        });
        return;
      }
    } catch (e) {
      debugPrint('[BiometricGate] authenticate() falló: $e');
    }

    // Falla — incrementar y, si llega al tope, salir.
    await _repo.incrementFailedAttempts();
    final used = await _repo.getFailedAttempts();
    if (used >= SecuritySettingsRepository.maxFailedAttempts) {
      _exitApp();
      return;
    }

    // Si tiene PIN seteado, ofrecer el fallback. Sino, reintentar bio.
    final hasPin = await _repo.hasPin();
    if (hasPin) {
      await _runPinFallbackFlow();
    } else {
      // Reintento limpio del flujo biométrico.
      if (!mounted) return;
      await _runBiometricFlow();
    }
  }

  Future<void> _runPinSetupFlow() async {
    final navigator = _navigatorKey.currentState;
    if (navigator == null) return;
    final ok = await navigator.push<bool>(
      MaterialPageRoute(
        builder: (_) => const PinSetupScreen(),
        fullscreenDialog: true,
      ),
    );
    if (ok == true) {
      if (!mounted) return;
      setState(() {
        _unlocked = true;
      });
    } else {
      // Usuario canceló el setup. Sin PIN no se puede entrar.
      _exitApp();
    }
  }

  Future<void> _runPinFallbackFlow() async {
    final navigator = _navigatorKey.currentState;
    if (navigator == null) return;
    final ok = await navigator.push<bool>(
      MaterialPageRoute(
        builder: (_) => const PinFallbackScreen(),
        fullscreenDialog: true,
      ),
    );
    if (ok == true) {
      if (!mounted) return;
      setState(() {
        _unlocked = true;
      });
    } else {
      // El PinFallbackScreen ya cierra la app vía exit(0) cuando se
      // agotan los intentos. Si llegamos acá con `false` es un escape
      // anómalo (back button) — cerramos también.
      _exitApp();
    }
  }

  void _exitApp() {
    // SystemNavigator.pop() es la salida "elegante" en Android (cierra la
    // task y vuelve al launcher). Si por algún motivo no funciona (algunas
    // ROM custom no respetan el call), exit(0) es el martillo final.
    SystemNavigator.pop();
    Future<void>.delayed(const Duration(milliseconds: 500), () {
      exit(0);
    });
  }

  @override
  Widget build(BuildContext context) {
    if (_unlocked) return widget.child;
    // Mientras el gate no desbloquea, montamos un MaterialApp propio para
    // tener Navigator y poder pushear las pantallas de PIN. Cuando
    // `_unlocked = true`, se desmonta y se renderiza el `child` real.
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      navigatorKey: _navigatorKey,
      theme: ThemeData.dark().copyWith(scaffoldBackgroundColor: _kBg),
      home: const _SplashScreen(),
    );
  }
}

/// Splash en azul marino con el logo y un loader chico abajo (R3.5 —
/// splash sin frame de UI detrás).
class _SplashScreen extends StatelessWidget {
  const _SplashScreen();

  static const Color _kBg = Color(0xFF0F1B2D);
  static const Color _kCyan = Color(0xFF00E5FF);

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: _kBg,
      body: SafeArea(
        child: Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Container(
                width: 88,
                height: 88,
                decoration: BoxDecoration(
                  color: _kCyan.withOpacity(0.08),
                  border: Border.all(color: _kCyan.withOpacity(0.4), width: 2),
                  borderRadius: BorderRadius.circular(20),
                ),
                child: const Icon(Icons.hearing, color: _kCyan, size: 48),
              ),
              const SizedBox(height: 20),
              const Text(
                'Oír Pro',
                style: TextStyle(
                  color: _kCyan,
                  fontSize: 28,
                  fontWeight: FontWeight.w600,
                  letterSpacing: 1.2,
                ),
              ),
              const SizedBox(height: 8),
              const Text(
                'Servicio Técnico',
                style: TextStyle(color: Colors.white60, fontSize: 13),
              ),
              const SizedBox(height: 48),
              const SizedBox(
                width: 22,
                height: 22,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  color: _kCyan,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
