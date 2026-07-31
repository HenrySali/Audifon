/// @file preset_feedback.dart
/// @brief Registro completo del feedback del paciente sobre una
/// configuración aplicada al audífono.
library;

import 'feedback_checklist_item.dart';

/// Registro completo de feedback de una configuración aplicada.
class PresetFeedback {
  static const String schemaVersion = '1.0.0';

  /// `microsecondsSinceEpoch` del momento en que se completó el feedback.
  /// Se usa como key en Hive.
  final int id;

  final DateTime timestamp;

  /// Nombre de la escena detectada (ej: 'speech_quiet', 'music', etc.) o null.
  final String? sceneClass;

  /// Nombre del preset aplicado.
  final String presetName;

  /// Ganancias EQ aplicadas (12 valores).
  final List<double> gains;

  /// Items con su rating.
  final List<FeedbackChecklistItem> items;

  /// Comentario libre del usuario (opcional).
  final String? comment;

  /// Resultado del 👍/👎 del banner. null si solo se abrió el dialog.
  final bool? thumbsUp;

  const PresetFeedback({
    required this.id,
    required this.timestamp,
    required this.sceneClass,
    required this.presetName,
    required this.gains,
    required this.items,
    required this.comment,
    required this.thumbsUp,
  });

  Map<String, dynamic> toJson() => {
        'schema_version': schemaVersion,
        'id': id,
        'timestamp': timestamp.toIso8601String(),
        'scene_class': sceneClass,
        'preset_name': presetName,
        'gains': gains,
        'items': items.map((e) => e.toJson()).toList(),
        'comment': comment,
        'thumbs_up': thumbsUp,
      };

  factory PresetFeedback.fromJson(Map<String, dynamic> j) {
    final List<dynamic> rawItems = (j['items'] as List?) ?? <dynamic>[];
    final List<dynamic> rawGains = (j['gains'] as List?) ?? <dynamic>[];
    return PresetFeedback(
      id: (j['id'] as num).toInt(),
      timestamp: DateTime.parse(j['timestamp'] as String),
      sceneClass: j['scene_class'] as String?,
      presetName: j['preset_name'] as String? ?? '',
      gains: rawGains.map((e) => (e as num).toDouble()).toList(),
      items: rawItems
          .map((e) =>
              FeedbackChecklistItem.fromJson((e as Map).cast<String, dynamic>()))
          .toList(),
      comment: j['comment'] as String?,
      thumbsUp: j['thumbs_up'] as bool?,
    );
  }
}
