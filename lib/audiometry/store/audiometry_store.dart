/// @file audiometry_store.dart
/// @brief Persistencia (Hive) de los resultados de audiometría del paciente.
///
/// Guarda la última `AudiometryResult` bajo la clave `last` y mantiene un
/// historial circular de hasta 20 entradas (JSON serializadas) bajo la clave
/// `history`. Sigue el mismo patrón que `BiologicalCalibrationStore` para
/// mantener la consistencia entre módulos de persistencia.
///
/// Box: `patient_audiometry_box`
/// Keys:
///   - `last`: JSON string con la última audiometría completada.
///   - `history`: `List<String>` con hasta 20 JSONs, ordenable por `testedAt`.
///
/// Métodos provistos:
///  - `init()`: abre la box si todavía no está abierta.
///  - `saveLast(r)`: persiste la audiometría como `last` y la agrega al
///    historial (manteniendo solo las últimas 20 entradas).
///  - `loadLast()`: devuelve la última audiometría guardada o null.
///  - `loadHistory()`: devuelve la lista de audiometrías del historial,
///    ordenada por `testedAt` descendente (más reciente primero).
///
/// Referencias:
///  - design.md §"Persistencia"
///  - lib/biological_calibration/store/biological_calibration_store.dart

import 'dart:convert';

import 'package:hive/hive.dart';

import '../models/audiometry_result.dart';

/// Storage helper sobre Hive para los resultados de audiometría del paciente.
class AudiometryStore {
  /// Nombre de la box Hive (separada de cualquier otra).
  static const String _boxName = 'patient_audiometry_box';

  /// Clave bajo la cual se guarda la última audiometría.
  static const String _keyLast = 'last';

  /// Clave bajo la cual se guarda el historial (List<String> con JSONs).
  static const String _keyHistory = 'history';

  /// Tamaño máximo del historial. Audiometrías más viejas se descartan.
  static const int _maxHistory = 20;

  /// Abre la box si todavía no está abierta. Es seguro llamarlo varias veces.
  static Future<void> init() async {
    await _openBox();
  }

  /// Guarda la audiometría como `last` y la agrega al historial.
  ///
  /// El historial se recorta a las últimas [_maxHistory] entradas, descartando
  /// las más antiguas (por orden de inserción). La entrada nueva se agrega
  /// al final.
  static Future<void> saveLast(AudiometryResult r) async {
    final box = await _openBox();
    final encoded = jsonEncode(r.toJson());

    // Guardar como 'last'
    await box.put(_keyLast, encoded);

    // Actualizar history (List<String>)
    final List<String> history = _readHistory(box);
    history.add(encoded);

    // Mantener solo las últimas _maxHistory entradas
    if (history.length > _maxHistory) {
      history.removeRange(0, history.length - _maxHistory);
    }

    await box.put(_keyHistory, history);
  }

  /// Carga la última audiometría guardada. Devuelve null si:
  ///  - No hay nada guardado bajo la clave `last`.
  ///  - El JSON está corrupto.
  static Future<AudiometryResult?> loadLast() async {
    final box = await _openBox();
    final raw = box.get(_keyLast) as String?;
    if (raw == null || raw.isEmpty) return null;
    try {
      final j = jsonDecode(raw) as Map<String, dynamic>;
      return AudiometryResult.fromJson(j);
    } catch (_) {
      return null;
    }
  }

  /// Carga el historial de audiometrías ordenado por `testedAt` descendente
  /// (más reciente primero). Las entradas con JSON corrupto se omiten en
  /// silencio para no romper la lectura del resto.
  static Future<List<AudiometryResult>> loadHistory() async {
    final box = await _openBox();
    final List<String> rawList = _readHistory(box);

    final List<AudiometryResult> results = [];
    for (final raw in rawList) {
      if (raw.isEmpty) continue;
      try {
        final j = jsonDecode(raw) as Map<String, dynamic>;
        results.add(AudiometryResult.fromJson(j));
      } catch (_) {
        // JSON corrupto: omitir esta entrada y continuar.
      }
    }

    // Ordenar por testedAt descendente (más reciente primero)
    results.sort((a, b) => b.testedAt.compareTo(a.testedAt));
    return results;
  }

  /// Lee el historial crudo desde la box como `List<String>`. Maneja el caso
  /// de que la entrada todavía no exista o sea de un tipo inesperado.
  static List<String> _readHistory(Box<dynamic> box) {
    final dynamic raw = box.get(_keyHistory);
    if (raw == null) return <String>[];
    if (raw is List) {
      // Hive puede devolver List<dynamic>; lo convertimos a List<String>.
      return raw.whereType<String>().toList();
    }
    return <String>[];
  }

  /// Abre la box (idempotente).
  static Future<Box<dynamic>> _openBox() async {
    if (Hive.isBoxOpen(_boxName)) return Hive.box(_boxName);
    return Hive.openBox(_boxName);
  }
}
