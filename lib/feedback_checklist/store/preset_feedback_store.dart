/// @file preset_feedback_store.dart
/// @brief Persistencia (Hive) de los feedbacks acumulados del paciente.
library;

import 'dart:convert';

import 'package:hive/hive.dart';

import '../models/preset_feedback.dart';

class PresetFeedbackStore {
  static const String _boxName = 'preset_feedback_box';

  static Future<Box<dynamic>> _openBox() async {
    if (Hive.isBoxOpen(_boxName)) return Hive.box(_boxName);
    return Hive.openBox(_boxName);
  }

  static Future<void> init() async {
    await _openBox();
  }

  /// Agrega un nuevo feedback al box. Sobrescribe si la `id` ya existe
  /// (improbable porque usa microsecondsSinceEpoch).
  static Future<void> add(PresetFeedback fb) async {
    final box = await _openBox();
    await box.put(fb.id.toString(), jsonEncode(fb.toJson()));
  }

  /// Devuelve todos los feedbacks ordenados por timestamp descendente.
  /// Las entradas corruptas se omiten en silencio.
  static Future<List<PresetFeedback>> getAll() async {
    final box = await _openBox();
    final List<PresetFeedback> result = <PresetFeedback>[];
    for (final key in box.keys) {
      final dynamic raw = box.get(key);
      if (raw is! String || raw.isEmpty) continue;
      try {
        final j = jsonDecode(raw) as Map<String, dynamic>;
        result.add(PresetFeedback.fromJson(j));
      } catch (_) {
        // Skip corrupt
      }
    }
    result.sort((a, b) => b.timestamp.compareTo(a.timestamp));
    return result;
  }

  /// Cantidad de feedbacks acumulados.
  static Future<int> getCount() async {
    final box = await _openBox();
    return box.length;
  }

  /// Borra todos los feedbacks. Usado tras una exportación masiva exitosa.
  static Future<void> clearAll() async {
    final box = await _openBox();
    await box.clear();
  }
}
