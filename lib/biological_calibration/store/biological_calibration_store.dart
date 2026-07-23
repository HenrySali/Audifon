/// @file biological_calibration_store.dart
/// @brief Persistencia (Hive) de la calibración biológica.
///
/// Guarda la última `BiologicalCalibrationResult` en una caja Hive separada de
/// la calibración electroacústica. Se serializa como JSON (Map<String, dynamic>)
/// usando `toJson()/fromJson()` del modelo, igual que `DeviceCalibrationStore`.
///
/// Box: `biological_calibration_box`
/// Key: `current`
///
/// Métodos provistos:
///  - `init()`: abre la box si todavía no está abierta.
///  - `save(r)`: persiste la calibración (sobrescribe la anterior).
///  - `load()`: devuelve la calibración válida o null (también null si fue
///    marcada como invalidada por `invalidate()`).
///  - `isValidForCurrentDevice(mac)`: compara la MAC BT actual con la guardada.
///  - `isExpired({days})`: true si pasaron más de `days` (default 90) desde
///    el `createdAt` de la calibración guardada.
///  - `invalidate()`: marca la calibración como inválida sin borrarla. La
///    siguiente llamada a `load()` devolverá null hasta que se haga `save()`
///    de una nueva calibración o se llame `clear()`.
///  - `clear()`: borra todo el contenido de la calibración.
///
/// Referencias:
///  - design.md §"Persistencia (Hive)"
///  - lib/calibration_spectrum/device_calibration.dart (patrón equivalente)

import 'dart:convert';

import 'package:hive/hive.dart';

import '../models/biological_calibration_result.dart';

/// Storage helper sobre Hive para la calibración biológica.
class BiologicalCalibrationStore {
  /// Nombre de la box Hive (separada de la electroacústica).
  static const String _boxName = 'biological_calibration_box';

  /// Clave bajo la cual se guarda el JSON serializado.
  static const String _key = 'current';

  /// Flag interno que se inyecta dentro del JSON guardado para marcar la
  /// calibración como invalidada sin borrarla físicamente.
  static const String _invalidatedFlag = '_store_invalidated';

  /// Abre la box si todavía no está abierta. Es seguro llamarlo varias veces.
  static Future<void> init() async {
    await _openBox();
  }

  /// Guarda la calibración (sobrescribe la anterior) y limpia la marca de
  /// invalidación si existía.
  static Future<void> save(BiologicalCalibrationResult r) async {
    final box = await _openBox();
    final Map<String, dynamic> json = Map<String, dynamic>.from(r.toJson());
    // Asegurar que un save explícito limpia cualquier marca previa.
    json[_invalidatedFlag] = false;
    await box.put(_key, jsonEncode(json));
  }

  /// Carga la calibración guardada. Devuelve null si:
  ///  - No hay nada guardado.
  ///  - El JSON está corrupto.
  ///  - Fue marcada como invalidada.
  static Future<BiologicalCalibrationResult?> load() async {
    final box = await _openBox();
    final raw = box.get(_key) as String?;
    if (raw == null || raw.isEmpty) return null;
    try {
      final j = jsonDecode(raw) as Map<String, dynamic>;
      if (j[_invalidatedFlag] == true) return null;
      return BiologicalCalibrationResult.fromJson(j);
    } catch (_) {
      return null;
    }
  }

  /// Compara la MAC BT actual con la guardada en la calibración.
  ///
  /// Devuelve false si:
  ///  - No hay calibración guardada.
  ///  - La calibración fue invalidada.
  ///  - La MAC del dispositivo conectado actualmente no coincide con la MAC
  ///    sobre la cual se hizo la calibración (la calibración es específica
  ///    al par parlante/auricular usado).
  static Future<bool> isValidForCurrentDevice(
    String currentBtMacAddress,
  ) async {
    final r = await load();
    if (r == null) return false;
    return r.device.bluetoothMac == currentBtMacAddress;
  }

  /// True si pasaron más de [days] días desde el `createdAt` de la
  /// calibración guardada. Si no hay nada guardado o el dato está corrupto
  /// también devuelve true (no podemos confiar en una calibración inexistente
  /// o ilegible).
  ///
  /// Nota: opera sobre el JSON crudo para no depender del estado de
  /// invalidación — una calibración invalidada también puede haber expirado.
  static Future<bool> isExpired({int days = 90}) async {
    final box = await _openBox();
    final raw = box.get(_key) as String?;
    if (raw == null || raw.isEmpty) return true;
    try {
      final j = jsonDecode(raw) as Map<String, dynamic>;
      final createdAtRaw = j['created_at'] ?? j['createdAt'];
      if (createdAtRaw is! String || createdAtRaw.isEmpty) return true;
      final createdAt = DateTime.parse(createdAtRaw);
      final age = DateTime.now().difference(createdAt);
      return age.inDays > days;
    } catch (_) {
      return true;
    }
  }

  /// Marca la calibración como inválida agregando un flag dentro del JSON,
  /// pero conservando los datos. Útil para invalidar tras un cambio de
  /// dispositivo sin perder el historial. Después de esto, `load()` devuelve
  /// null hasta que se haga un nuevo `save()` o `clear()`.
  static Future<void> invalidate() async {
    final box = await _openBox();
    final raw = box.get(_key) as String?;
    if (raw == null || raw.isEmpty) return;
    try {
      final j = jsonDecode(raw) as Map<String, dynamic>;
      j[_invalidatedFlag] = true;
      await box.put(_key, jsonEncode(j));
    } catch (_) {
      // JSON corrupto: no hay forma de marcarlo, lo ignoramos en silencio.
    }
  }

  /// Borra todo el contenido de la calibración guardada.
  static Future<void> clear() async {
    final box = await _openBox();
    await box.delete(_key);
  }

  /// Abre la box (idempotente).
  static Future<Box<dynamic>> _openBox() async {
    if (Hive.isBoxOpen(_boxName)) return Hive.box(_boxName);
    return Hive.openBox(_boxName);
  }
}
