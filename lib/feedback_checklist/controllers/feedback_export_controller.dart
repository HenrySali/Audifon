/// @file feedback_export_controller.dart
/// @brief Exporta todos los feedbacks acumulados a un archivo JSON y los
/// borra de la app tras la exportación exitosa.
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import '../models/preset_feedback.dart';
import '../store/preset_feedback_store.dart';

class FeedbackExportController {
  /// Exporta todos los feedbacks a un archivo JSON y borra los registros.
  ///
  /// Devuelve la ruta absoluta del archivo generado, o `null` si no había
  /// feedbacks o si hubo un error de escritura (en cuyo caso NO se borra
  /// nada).
  Future<String?> exportAndClear() async {
    try {
      final List<PresetFeedback> all = await PresetFeedbackStore.getAll();
      if (all.isEmpty) return null;

      final Map<String, dynamic> payload = <String, dynamic>{
        'schema_version': '1.0.0',
        'exported_at': DateTime.now().toIso8601String(),
        'device_info': <String, String>{
          'os': Platform.operatingSystem,
          'os_version': Platform.operatingSystemVersion,
        },
        'count': all.length,
        'feedbacks': all.map((f) => f.toJson()).toList(),
      };
      final String jsonStr =
          const JsonEncoder.withIndent('  ').convert(payload);

      // Directorio: en Android external app-specific (Android/data/.../files/),
      // en otras plataformas el documents dir.
      Directory? dir;
      try {
        dir = await getExternalStorageDirectory();
      } catch (_) {
        dir = null;
      }
      dir ??= await getApplicationDocumentsDirectory();

      final String filename =
          'preset_feedback_${_timestampSlug(DateTime.now())}.json';
      final File file = File('${dir.path}/$filename');
      await file.writeAsString(jsonStr, flush: true);

      // Solo borrar después de escribir con éxito.
      await PresetFeedbackStore.clearAll();

      return file.path;
    } catch (e, st) {
      debugPrint('FeedbackExportController.exportAndClear failed: $e\n$st');
      return null;
    }
  }

  String _timestampSlug(DateTime dt) {
    String two(int n) => n.toString().padLeft(2, '0');
    return '${dt.year}${two(dt.month)}${two(dt.day)}_'
        '${two(dt.hour)}${two(dt.minute)}${two(dt.second)}';
  }
}
