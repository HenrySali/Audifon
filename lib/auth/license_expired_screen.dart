import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// Pantalla de licencia vencida (variante Servicio Tecnico).
///
/// Se muestra cuando el endpoint check-status indica que la licencia expiro,
/// o cuando estando offline la fecha local supera expiresAt guardado.
/// Tiene un boton "Reintentar" y un boton "Cerrar app".
class LicenseExpiredScreen extends StatelessWidget {
  /// Mensaje adicional para mostrar (e.g. "Conectate a internet" en offline).
  final String? additionalMessage;

  /// Callback para reintentar la verificacion.
  final VoidCallback onRetry;

  const LicenseExpiredScreen({
    super.key,
    this.additionalMessage,
    required this.onRetry,
  });

  static const Color _kBg = Color(0xFF0F1B2D);
  static const Color _kRed = Color(0xFFE53935);
  static const Color _kCyan = Color(0xFF00E5FF);
  static const Color _kAmber = Color(0xFFFFB300);

  @override
  Widget build(BuildContext context) {
    return WillPopScope(
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
                // Icono de reloj / expirado
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
                    Icons.timer_off_rounded,
                    color: _kAmber,
                    size: 72,
                  ),
                ),
                const SizedBox(height: 32),

                // Branding
                const Text(
                  'Servicio Tecnico',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: Colors.white38,
                    fontSize: 12,
                    fontWeight: FontWeight.w500,
                    letterSpacing: 1.0,
                  ),
                ),
                const SizedBox(height: 8),

                // Titulo
                const Text(
                  'Licencia vencida',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: _kRed,
                    fontSize: 24,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 0.5,
                  ),
                ),
                const SizedBox(height: 16),

                // Descripcion
                Container(
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    color: const Color(0xFF16213e),
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: _kAmber.withOpacity(0.3)),
                  ),
                  child: Column(
                    children: [
                      const Text(
                        'Tu licencia vencio. Contacta al administrador.',
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          color: Colors.white70,
                          fontSize: 14,
                          height: 1.4,
                        ),
                      ),
                      if (additionalMessage != null) ...[
                        const SizedBox(height: 8),
                        Text(
                          additionalMessage!,
                          textAlign: TextAlign.center,
                          style: const TextStyle(
                            color: Colors.white54,
                            fontSize: 13,
                            height: 1.4,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
                const SizedBox(height: 40),

                // Boton Reintentar
                ElevatedButton.icon(
                  onPressed: onRetry,
                  icon: const Icon(Icons.refresh),
                  label: const Text('Reintentar'),
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
                const SizedBox(height: 12),

                // Boton Cerrar app
                OutlinedButton.icon(
                  onPressed: _exitApp,
                  icon: const Icon(Icons.power_settings_new),
                  label: const Text('Cerrar app'),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: Colors.white54,
                    side: const BorderSide(color: Colors.white24),
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

  static Future<void> _exitApp() async {
    await SystemNavigator.pop();
    await Future<void>.delayed(const Duration(milliseconds: 500));
    exit(0);
  }
}
