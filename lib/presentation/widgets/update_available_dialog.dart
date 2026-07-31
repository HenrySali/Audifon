import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../data/services/remote_config_service.dart';

/// Diálogo "Actualización disponible" — Fase 5b / R6.3.
///
/// Muestra al usuario que hay una versión nueva del APK del backend Oír
/// Pro. El comportamiento depende de la severidad:
///
/// - Si `isVersionNewer(config.minVersion, currentVersion) == true` →
///   diálogo **modal bloqueante**. Sin botón "Más tarde",
///   `barrierDismissible: false`, `WillPopScope.false`. La única forma
///   de cerrar es tocar "Actualizar" (que abre el navegador) y después
///   apagar la app manualmente. Esto materializa R6.3 — el min_version
///   sirve para forzar updates por seguridad o por cambios de schema
///   incompatibles del backend.
///
/// - Si solo `isVersionNewer(config.latestVersion, currentVersion) == true` →
///   diálogo opcional con dos botones: "Más tarde" (cierra sin hacer
///   nada) y "Actualizar" (abre el navegador).
///
/// - Si `apkUrl` viene null o vacío del backend, el botón "Actualizar"
///   no se muestra y solo queda "Cerrar".
///
/// Estilo dark consistente con el resto de la app: fondo `#16213e`,
/// títulos cyan `#00E5FF`, bordes cyan tenues.
Future<void> showUpdateDialog(
  BuildContext context,
  RemoteConfig config,
  String currentVersion,
) async {
  final isMandatory = isVersionNewer(config.minVersion, currentVersion);
  final hasApkUrl = config.apkUrl != null && config.apkUrl!.isNotEmpty;

  await showDialog<void>(
    context: context,
    barrierDismissible: !isMandatory,
    builder: (ctx) {
      return WillPopScope(
        // Si es mandatorio, ignoramos el back button del sistema.
        onWillPop: () async => !isMandatory,
        child: _UpdateDialogContent(
          config: config,
          currentVersion: currentVersion,
          isMandatory: isMandatory,
          hasApkUrl: hasApkUrl,
        ),
      );
    },
  );
}

class _UpdateDialogContent extends StatelessWidget {
  final RemoteConfig config;
  final String currentVersion;
  final bool isMandatory;
  final bool hasApkUrl;

  const _UpdateDialogContent({
    required this.config,
    required this.currentVersion,
    required this.isMandatory,
    required this.hasApkUrl,
  });

  static const Color _kBg = Color(0xFF16213e);
  static const Color _kCyan = Color(0xFF00E5FF);
  static const Color _kAmber = Color(0xFFFFB300);

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: _kBg,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(color: _kCyan.withOpacity(0.3)),
      ),
      titlePadding: const EdgeInsets.fromLTRB(20, 18, 20, 0),
      contentPadding: const EdgeInsets.fromLTRB(20, 12, 20, 8),
      actionsPadding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
      title: Row(
        children: [
          Icon(
            isMandatory
                ? Icons.priority_high_rounded
                : Icons.system_update_alt,
            color: isMandatory ? _kAmber : _kCyan,
            size: 26,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              isMandatory
                  ? 'Actualización requerida'
                  : 'Actualización disponible',
              style: TextStyle(
                color: isMandatory ? _kAmber : _kCyan,
                fontSize: 16,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ],
      ),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            isMandatory
                ? 'Esta versión ya no es compatible con el servicio. Para '
                    'seguir usando Oír Pro tenés que actualizar.'
                : 'Hay una nueva versión de Oír Pro disponible.',
            style: const TextStyle(
              color: Colors.white,
              fontSize: 13,
              height: 1.4,
            ),
          ),
          const SizedBox(height: 12),
          _VersionRow(label: 'Versión actual', value: currentVersion),
          const SizedBox(height: 4),
          _VersionRow(
            label: 'Última versión',
            value: config.latestVersion,
            highlight: true,
          ),
          if (isMandatory) ...[
            const SizedBox(height: 4),
            _VersionRow(
              label: 'Mínima requerida',
              value: config.minVersion,
              highlight: true,
            ),
          ],
          if (!hasApkUrl) ...[
            const SizedBox(height: 12),
            const Text(
              'Todavía no hay un APK publicado. Contactá al soporte técnico.',
              style: TextStyle(
                color: Colors.white54,
                fontSize: 11,
                fontStyle: FontStyle.italic,
              ),
            ),
          ],
        ],
      ),
      actions: _buildActions(context),
    );
  }

  List<Widget> _buildActions(BuildContext context) {
    if (!hasApkUrl) {
      // Sin URL → solo botón "Cerrar". Si es mandatorio el usuario va a
      // tener que apagar la app manualmente (queda en este diálogo).
      return [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          style: TextButton.styleFrom(foregroundColor: _kCyan),
          child: const Text('Cerrar'),
        ),
      ];
    }

    final actions = <Widget>[];

    // Solo mostramos "Más tarde" si el update NO es mandatorio.
    if (!isMandatory) {
      actions.add(
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          style: TextButton.styleFrom(foregroundColor: Colors.white60),
          child: const Text('Más tarde'),
        ),
      );
    }

    actions.add(
      ElevatedButton.icon(
        onPressed: () => _launchApk(context, config.apkUrl!),
        icon: const Icon(Icons.download_rounded, size: 18),
        label: const Text('Actualizar'),
        style: ElevatedButton.styleFrom(
          backgroundColor: _kCyan.withOpacity(0.15),
          foregroundColor: _kCyan,
          side: BorderSide(color: _kCyan.withOpacity(0.5)),
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        ),
      ),
    );

    return actions;
  }

  Future<void> _launchApk(BuildContext context, String url) async {
    final uri = Uri.tryParse(url);
    if (uri == null) {
      debugPrint('[UpdateDialog] apkUrl inválido: $url');
      return;
    }
    try {
      final ok = await launchUrl(uri, mode: LaunchMode.externalApplication);
      if (!ok) {
        debugPrint('[UpdateDialog] launchUrl devolvió false para $uri');
      }
    } catch (e) {
      debugPrint('[UpdateDialog] error abriendo apkUrl: $e');
    }
    // Si NO es mandatorio cerramos el diálogo después de disparar el
    // navegador. Si es mandatorio, lo dejamos abierto: el usuario va a
    // instalar la APK desde el navegador y al volver a Oír Pro la app
    // ya tendrá la versión nueva (o si vuelve sin instalar, sigue el
    // diálogo modal acá).
    if (!isMandatory && context.mounted) {
      Navigator.of(context).pop();
    }
  }
}

class _VersionRow extends StatelessWidget {
  final String label;
  final String value;
  final bool highlight;

  const _VersionRow({
    required this.label,
    required this.value,
    this.highlight = false,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        SizedBox(
          width: 110,
          child: Text(
            label,
            style: const TextStyle(color: Colors.white54, fontSize: 12),
          ),
        ),
        Expanded(
          child: Text(
            value,
            style: TextStyle(
              color: highlight
                  ? const Color(0xFF00E5FF)
                  : Colors.white,
              fontSize: 12,
              fontWeight: highlight ? FontWeight.w600 : FontWeight.w400,
            ),
          ),
        ),
      ],
    );
  }
}
