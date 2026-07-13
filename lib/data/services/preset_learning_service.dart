import 'package:hive_flutter/hive_flutter.dart';

/// Servicio de aprendizaje local de presets — Etapa 1.
///
/// Registra cada vez que el usuario aplica un preset (manual o sugerido por
/// "Auto") junto con la clase de ambiente detectada y el feedback subjetivo
/// posterior (👍 / 👎 / sin respuesta).
///
/// Con suficientes registros por combinación `(envClass, presetName)`,
/// calcula un score de "satisfacción" por preset en cada ambiente. Cuando
/// el `PresetAdvisor` necesita sugerir un preset, primero consulta este
/// servicio para ver si hay un preset distinto al default que el usuario
/// haya preferido para ese ambiente.
///
/// Todo es local (Hive). No se envía nada a servidor.
class PresetLearningService {
  static const String _boxName = 'preset_learning_log';
  static const String _entriesKey = 'entries';

  /// Mínimo de registros con feedback para que la app considere "aprendido"
  /// un preset alternativo en cierto ambiente.
  static const int minSampleSize = 5;

  /// Diferencia mínima de score (positivos − negativos) para considerar
  /// un preset alternativo "claramente mejor" que el default.
  static const int minScoreDelta = 3;

  /// Lista en memoria, sincronizada con Hive.
  final List<LearningEntry> _entries = [];
  bool _loaded = false;

  /// Carga todas las entradas desde Hive.
  Future<void> load() async {
    if (_loaded) return;
    final box = await Hive.openBox<dynamic>(_boxName);
    final raw = box.get(_entriesKey);
    if (raw is List) {
      _entries.clear();
      for (final item in raw) {
        if (item is Map) {
          try {
            _entries.add(LearningEntry.fromMap(Map<String, dynamic>.from(item)));
          } catch (_) {
            // Ignorar entradas corruptas.
          }
        }
      }
    }
    _loaded = true;
  }

  /// Persiste la lista a Hive.
  Future<void> _save() async {
    final box = await Hive.openBox<dynamic>(_boxName);
    await box.put(_entriesKey, _entries.map((e) => e.toMap()).toList());
  }

  /// Registra una nueva aplicación de preset. Devuelve el ID asignado para
  /// poder agregar feedback luego.
  Future<int> recordApplication({
    required int envClass,
    required String presetName,
    String? source, // "auto", "manual", "test"
    Map<String, dynamic>? metrics,
  }) async {
    await load();
    final id = DateTime.now().microsecondsSinceEpoch;
    _entries.add(LearningEntry(
      id: id,
      timestamp: DateTime.now(),
      envClass: envClass,
      presetName: presetName,
      source: source ?? 'manual',
      feedback: null,
      metrics: metrics,
    ));
    await _save();
    return id;
  }

  /// Marca el feedback (positivo / negativo) de una aplicación previa.
  Future<void> recordFeedback({
    required int entryId,
    required bool positive,
  }) async {
    await load();
    final idx = _entries.indexWhere((e) => e.id == entryId);
    if (idx < 0) return;
    _entries[idx] = _entries[idx].copyWith(feedback: positive);
    await _save();
  }

  /// Calcula el score (positivos − negativos) por preset para un ambiente.
  /// Solo cuenta entradas con feedback explícito.
  Map<String, int> scoresForEnv(int envClass) {
    final scores = <String, int>{};
    for (final e in _entries) {
      if (e.envClass != envClass || e.feedback == null) continue;
      scores[e.presetName] = (scores[e.presetName] ?? 0) +
          (e.feedback! ? 1 : -1);
    }
    return scores;
  }

  /// Cuenta total de entradas con feedback para un ambiente.
  int sampleSizeForEnv(int envClass) {
    int n = 0;
    for (final e in _entries) {
      if (e.envClass == envClass && e.feedback != null) n++;
    }
    return n;
  }

  /// Sugiere un preset alternativo para [envClass] basado en lo aprendido.
  ///
  /// Devuelve null si no hay datos suficientes o si el [defaultName] sigue
  /// siendo el mejor.
  ///
  /// Lógica:
  ///  1. Necesita al menos `minSampleSize` entradas con feedback en ese ambiente.
  ///  2. Encuentra el preset con score más alto.
  ///  3. Si supera el score del default por al menos `minScoreDelta`, lo sugiere.
  String? suggestAlternative({
    required int envClass,
    required String defaultName,
  }) {
    if (sampleSizeForEnv(envClass) < minSampleSize) return null;
    final scores = scoresForEnv(envClass);
    if (scores.isEmpty) return null;
    final defaultScore = scores[defaultName] ?? 0;
    String? best;
    int bestScore = defaultScore;
    for (final entry in scores.entries) {
      if (entry.value > bestScore) {
        bestScore = entry.value;
        best = entry.key;
      }
    }
    if (best == null || best == defaultName) return null;
    if ((bestScore - defaultScore) < minScoreDelta) return null;
    return best;
  }

  /// Devuelve un resumen leíble del aprendizaje hasta el momento.
  Map<int, Map<String, int>> getAllScores() {
    final out = <int, Map<String, int>>{};
    for (final e in _entries) {
      if (e.feedback == null) continue;
      out.putIfAbsent(e.envClass, () => <String, int>{});
      final m = out[e.envClass]!;
      m[e.presetName] = (m[e.presetName] ?? 0) + (e.feedback! ? 1 : -1);
    }
    return out;
  }

  /// Última entrada registrada (para encadenar feedback rápido).
  LearningEntry? get lastEntry => _entries.isEmpty ? null : _entries.last;

  /// Total de entradas con feedback (positivos + negativos).
  int get totalFeedbackCount =>
      _entries.where((e) => e.feedback != null).length;

  /// Lista completa para mostrar en la pantalla de "historial".
  List<LearningEntry> get allEntries => List.unmodifiable(_entries);

  /// Borra todo el historial de aprendizaje.
  Future<void> clearAll() async {
    await load();
    _entries.clear();
    await _save();
  }
}

/// Entrada del log de aprendizaje.
class LearningEntry {
  final int id;
  final DateTime timestamp;
  final int envClass;
  final String presetName;
  final String source; // "auto", "manual", "test"
  final bool? feedback; // null = sin respuesta, true = 👍, false = 👎
  final Map<String, dynamic>? metrics;

  const LearningEntry({
    required this.id,
    required this.timestamp,
    required this.envClass,
    required this.presetName,
    required this.source,
    required this.feedback,
    this.metrics,
  });

  LearningEntry copyWith({bool? feedback}) => LearningEntry(
        id: id,
        timestamp: timestamp,
        envClass: envClass,
        presetName: presetName,
        source: source,
        feedback: feedback ?? this.feedback,
        metrics: metrics,
      );

  Map<String, dynamic> toMap() => {
        'id': id,
        'timestamp': timestamp.toIso8601String(),
        'envClass': envClass,
        'presetName': presetName,
        'source': source,
        'feedback': feedback,
        if (metrics != null) 'metrics': metrics,
      };

  static LearningEntry fromMap(Map<String, dynamic> m) {
    return LearningEntry(
      id: (m['id'] as num?)?.toInt() ?? DateTime.now().microsecondsSinceEpoch,
      timestamp: DateTime.tryParse(m['timestamp'] as String? ?? '') ??
          DateTime.now(),
      envClass: (m['envClass'] as num?)?.toInt() ?? -1,
      presetName: m['presetName'] as String? ?? 'Unknown',
      source: m['source'] as String? ?? 'manual',
      feedback: m['feedback'] as bool?,
      metrics: m['metrics'] is Map
          ? Map<String, dynamic>.from(m['metrics'] as Map)
          : null,
    );
  }
}
