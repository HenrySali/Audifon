/// Smart Scene Engine — Fase 4.
///
/// Persiste cada análisis aplicado al pipeline en un box Hive separado
/// (`smart_scene_log`) y permite recolectar feedback 👍/👎 del usuario.
/// El log se mantiene corto (FIFO) para que la app no acumule basura.
///
/// Validates: Requirements 5.4, 8.2, 8.3

import 'package:hive/hive.dart';

import 'scene_engine.dart' show SceneAnalysisResult;
import 'scene_snapshot.dart' show SceneClass;
import 'smart_preset.dart';

/// Una entrada del log: timestamp, escena, preset y feedback opcional.
class SceneRecord {
  final int id; // microsecondsSinceEpoch
  final DateTime timestamp;
  final SceneClass sceneClass;
  final double confidence;
  final String presetName;
  final bool wasPersonalized;
  final List<double> gains;
  final bool? feedback; // null = sin respuesta, true = 👍, false = 👎

  const SceneRecord({
    required this.id,
    required this.timestamp,
    required this.sceneClass,
    required this.confidence,
    required this.presetName,
    required this.wasPersonalized,
    required this.gains,
    this.feedback,
  });

  SceneRecord copyWith({bool? feedback}) {
    return SceneRecord(
      id: id,
      timestamp: timestamp,
      sceneClass: sceneClass,
      confidence: confidence,
      presetName: presetName,
      wasPersonalized: wasPersonalized,
      gains: gains,
      feedback: feedback ?? this.feedback,
    );
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
        'id': id,
        'ts': timestamp.toIso8601String(),
        'cls': sceneClass.index,
        'conf': confidence,
        'preset': presetName,
        'perso': wasPersonalized,
        'gains': gains,
        'fb': feedback,
      };

  static SceneRecord fromJson(Map<dynamic, dynamic> json) {
    final clsIdx = (json['cls'] as num).toInt();
    final cls = (clsIdx >= 0 && clsIdx < SceneClass.values.length)
        ? SceneClass.values[clsIdx]
        : SceneClass.unknown;
    return SceneRecord(
      id: (json['id'] as num).toInt(),
      timestamp: DateTime.parse(json['ts'] as String),
      sceneClass: cls,
      confidence: (json['conf'] as num).toDouble(),
      presetName: json['preset'] as String,
      wasPersonalized: json['perso'] as bool,
      gains: (json['gains'] as List)
          .cast<num>()
          .map((e) => e.toDouble())
          .toList(growable: false),
      feedback: json['fb'] as bool?,
    );
  }
}

/// Recorder con Hive box `smart_scene_log`. Mantiene los últimos
/// `maxRecords` (FIFO) para evitar crecimiento ilimitado.
class SceneRecorder {
  static const String boxName = 'smart_scene_log';

  /// Tope de entradas en el log. Más allá se descartan las más viejas.
  final int maxRecords;

  SceneRecorder({this.maxRecords = 100});

  Future<Box<dynamic>> _openBox() async {
    if (Hive.isBoxOpen(boxName)) {
      return Hive.box(boxName);
    }
    return Hive.openBox(boxName);
  }

  /// Registra un nuevo análisis aplicado. Devuelve el `SceneRecord`
  /// guardado (con `id` único basado en microsegundos).
  Future<SceneRecord> record(
    SceneAnalysisResult result, {
    required SmartPreset preset,
  }) async {
    final id = DateTime.now().microsecondsSinceEpoch;
    final rec = SceneRecord(
      id: id,
      timestamp: DateTime.now(),
      sceneClass: result.sceneClass,
      confidence: result.confidence,
      presetName: preset.name,
      wasPersonalized: result.wasPersonalized,
      gains: List<double>.unmodifiable(preset.gains),
    );
    try {
      final box = await _openBox();
      await box.put(id.toString(), rec.toJson());
      await _trim(box);
    } catch (_) {
      // Persistencia tolerante: si Hive falla, devolvemos el record igual.
    }
    return rec;
  }

  /// Actualiza el feedback de una entrada existente.
  Future<void> updateFeedback(int id, bool positive) async {
    try {
      final box = await _openBox();
      final raw = box.get(id.toString());
      if (raw == null) return;
      final existing = SceneRecord.fromJson(_asMap(raw));
      final updated = existing.copyWith(feedback: positive);
      await box.put(id.toString(), updated.toJson());
    } catch (_) {
      // Silencioso.
    }
  }

  /// Devuelve el historial ordenado de más reciente a más antiguo.
  Future<List<SceneRecord>> getHistory({int limit = 10}) async {
    try {
      final box = await _openBox();
      final list = box.values
          .map((v) => SceneRecord.fromJson(_asMap(v)))
          .toList();
      list.sort((a, b) => b.id.compareTo(a.id));
      if (list.length > limit) {
        return list.sublist(0, limit);
      }
      return list;
    } catch (_) {
      return const <SceneRecord>[];
    }
  }

  /// Borra todo el historial.
  Future<void> clearAll() async {
    try {
      final box = await _openBox();
      await box.clear();
    } catch (_) {
      // Silencioso.
    }
  }

  Future<void> _trim(Box<dynamic> box) async {
    if (box.length <= maxRecords) return;
    // Calcular ids ordenados ascendentemente y borrar los más viejos.
    final keys = box.keys.toList();
    keys.sort();
    final excess = box.length - maxRecords;
    for (var i = 0; i < excess; i++) {
      await box.delete(keys[i]);
    }
  }

  static Map<dynamic, dynamic> _asMap(Object? raw) {
    if (raw is Map) return raw;
    throw ArgumentError(
        'SceneRecorder: entrada inesperada en Hive (${raw.runtimeType})');
  }
}
