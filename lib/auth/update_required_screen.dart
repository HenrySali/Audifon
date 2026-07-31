import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

/// Pantalla de actualizacion obligatoria (variante Servicio Tecnico).
///
/// Se muestra cuando el endpoint check-status devuelve un requiredVersion
/// superior a la version actual de la app. No se puede cerrar ni saltar.
/// Muestra la version requerida y un boton para descargar el APK.
class UpdateRequiredScreen extends StatelessWidget {
  /// Version minima requerida por el servidor (e.g. "2.0.0").
  final String requiredVersion;

  /// URL de descarga del APK. Si no se proporciona, se usa una URL por defecto.
  final String? downloadUrl;

  const UpdateRequiredScreen({
    super.key,
    required this.requiredVersion,
    this.downloadUrl,
  });

  static const Color _kBg = Color(0xFF0F1B2D);
  static const Color _kCyan = Color(0xFF00E5FF);
  static const Color _kAmber = Color(0xFFFFB300);

  /// URL de descarga por defecto del APK.
  static const String _defaultDownloadUrl =
      'https://appsmarttemp.xn--diseosyefectos-tnb.com/oirpro/api/apk/latest';

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
                // Icono de actualizacion
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
                    Icons.system_update_rounded,
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
                  'Actualizacion obligatoria',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: _kAmber,
                    fontSize: 24,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 0.5,
                  ),
                ),
                const SizedBox(height: 16),

                // Descripcion con version requerida
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
                        'Se requiere una nueva version de la aplicacion '
                        'para continuar.',
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          color: Colors.white70,
                          fontSize: 14,
                          height: 1.4,
                        ),
                      ),
                      const SizedBox(height: 12),
                      Text(
                        'Version requerida: $requiredVersion',
                        textAlign: TextAlign.center,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 16,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 40),

                // Boton Descargar actualizacion
                ElevatedButton.icon(
                  onPressed: _openDownload,
                  icon: const Icon(Icons.download_rounded),
                  label: const Text('Descargar actualizacion'),
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

  Future<void> _openDownload() async {
    final url = downloadUrl ?? _defaultDownloadUrl;
    final uri = Uri.parse(url);
    if (await canLaunchUrl(uri)) {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    }
  }

  static Future<void> _exitApp() async {
    await SystemNavigator.pop();
    await Future<void>.delayed(const Duration(milliseconds: 500));
    exit(0);
  }
}
