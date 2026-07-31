import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// Pantalla "Servicio suspendido" — kill switch del backend remoto.
///
/// Spec: oir-pro-rebrand-harden-and-remote-config — Fase 5b / R6.3.
///
/// Cuando el backend devuelve `blocked == true`, `RemoteConfigGate` reemplaza
/// todo el stack con esta pantalla. Es **no destructiva**: no toca el
/// audiograma, ni los presets, ni la calibración del paciente. Solo
/// muestra el motivo recibido del server y un botón para cerrar la app.
///
/// Decisiones:
///
/// - **Sin botón "Volver"**. El bloqueo es duro — el usuario solo puede
///   cerrar la app. `WillPopScope` ignora el back button del sistema.
/// - **Sin botón "Reintentar"**. Si el técnico levantó el bloqueo en el
///   admin, el próximo arranque de la app va a hacer un fetch nuevo y
///   esta pantalla no aparecerá. No queremos que un usuario quede
///   reintentando contra el server desde acá.
/// - **Tema oscuro #0F1B2D** consistente con `BiometricGate._SplashScreen`.
class BlockedScreen extends StatelessWidget {
  /// Texto que recibimos del backend en `blockedReason`. Si null, usamos
  /// un mensaje genérico.
  final String? blockedReason;

  const BlockedScreen({super.key, this.blockedReason});

  static const Color _kBg = Color(0xFF0F1B2D);
  static const Color _kAmber = Color(0xFFFFB300);
  static const Color _kRed = Color(0xFFE53935);
  static const Color _kCyan = Color(0xFF00E5FF);

  @override
  Widget build(BuildContext context) {
    final reason = (blockedReason == null || blockedReason!.trim().isEmpty)
        ? 'El servicio está temporalmente suspendido.'
        : blockedReason!;

    return WillPopScope(
      // Ignorar back button del sistema (R6.3 — bloqueo duro).
      onWillPop: () async => false,
      child: Scaffold(
        backgroundColor: _kBg,
        body: SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                // Icono grande de warning ámbar / rojo.
                Container(
                  width: 120,
                  height: 120,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: _kAmber.withOpacity(0.10),
                    shape: BoxShape.circle,
                    border: Border.all(
                      color: _kAmber.withOpacity(0.6),
                      width: 2,
                    ),
                  ),
                  child: const Icon(
                    Icons.warning_amber_rounded,
                    color: _kAmber,
                    size: 72,
                  ),
                ).withCenter(),
                const SizedBox(height: 32),

                // Título.
                const Text(
                  'Servicio suspendido',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: _kRed,
                    fontSize: 24,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 0.5,
                  ),
                ),
                const SizedBox(height: 16),

                // Descripción dinámica con el motivo del backend.
                Container(
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    color: const Color(0xFF16213e),
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: _kAmber.withOpacity(0.3)),
                  ),
                  child: Text(
                    reason,
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                      color: Colors.white70,
                      fontSize: 14,
                      height: 1.4,
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                const Text(
                  'Sus datos del paciente, audiograma y presets están a salvo. '
                  'Cuando el servicio se restablezca, la app volverá a '
                  'funcionar sin pérdida de información.',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: Colors.white54,
                    fontSize: 12,
                    height: 1.4,
                  ),
                ),
                const SizedBox(height: 40),

                // Botón "Cerrar app".
                ElevatedButton.icon(
                  onPressed: _exitApp,
                  icon: const Icon(Icons.power_settings_new),
                  label: const Text('Cerrar app'),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: _kCyan.withOpacity(0.15),
                    foregroundColor: _kCyan,
                    side: BorderSide(color: _kCyan.withOpacity(0.4)),
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    textStyle: const TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// Cerrar la app: `SystemNavigator.pop()` para Android (vuelve al
  /// launcher) y un `exit(0)` con delay 500 ms como martillo en algunas
  /// ROM custom que no respetan el call. Mismo patrón que `BiometricGate`
  /// para mantener consistencia.
  static Future<void> _exitApp() async {
    await SystemNavigator.pop();
    await Future<void>.delayed(const Duration(milliseconds: 500));
    exit(0);
  }
}

extension on Widget {
  /// Pequeño helper para centrar el icono sin agregar otro `Center` que
  /// rompa el flow vertical del Column. Lo usamos solo arriba.
  Widget withCenter() => Align(alignment: Alignment.center, child: this);
}
