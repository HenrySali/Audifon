// Repositorio del audit trail de calibración nativa.
//
// Persiste registros de calibración de micrófono y de auricular en el
// Hive box `calibration_box`, junto con SHA-256 verificable para
// trazabilidad ANMAT/INVIMA/FDA. Spec: `native-calibration-handlers`,
// Requirement 4.

import 'dart:convert';
import 'dart:developer' as developer;

import 'package:crypto/crypto.dart';
import 'package:hive/hive.dart';

import '../../domain/entities/calibration_audit_record.dart';

/// Nombre del Hive box que centraliza la persistencia de calibración
/// nativa (offsets vivos + audit trail).
const String calibrationBoxName = 'calibration_box';

/// Prefijos de claves dentro del box.
const String _kAuditMicPrefix = 'audit_mic_';
const String _kAuditHpPrefix = 'audit_hp_';

/// Repositorio de audit trail de calibración con verificación SHA-256.
///
/// **Persistencia.** Cada record vive bajo la clave
/// `audit_<type>_<isoTimestampUtc>` dentro del box
/// [`calibrationBoxName`](`calibration_box`). El payload se serializa
/// como JSON-string con [jsonEncode].
///
/// **Hash.** Cada record incluye un campo `sha256` calculado sobre la
/// representación canónica (claves ordenadas alfabéticamente
/// recursivamente) del payload SIN el campo `sha256`. Esto evita
/// self-reference y permite a [verifyIntegrity] recomputar el hash
/// para detectar tampering.
///
/// **Idioma del log.** Todos los logs internos usan
/// `developer.log(name: 'NativeCalibration')` con nivel INFO/SEVERE
/// (1000 = SEVERE, 800 = INFO).
class CalibrationAuditRepository {
  final Box<dynamic> _box;

  CalibrationAuditRepository(this._box);

  /// Abre el box `calibration_box`. El caller es responsable de
  /// inicializar Hive antes (típicamente en `main()` con
  /// `Hive.initFlutter`).
  static Future<Box<dynamic>> openBox() async {
    if (Hive.isBoxOpen(calibrationBoxName)) {
      return Hive.box<dynamic>(calibrationBoxName);
    }
    return Hive.openBox<dynamic>(calibrationBoxName);
  }

  // ─── Append + getters ──────────────────────────────────────────────────

  /// Persiste un audit record de calibración de micrófono.
  /// Lanza [StateError] si el `record.sha256` no coincide con el hash
  /// recalculado, para evitar persistir registros con hash inválido.
  Future<void> appendMicCalibration(MicCalibrationAudit record) async {
    _assertHashIsValid(record);
    final key = record.storageKey;
    if (_box.containsKey(key)) {
      throw StateError(
        'calibration_box ya contiene un audit con clave $key. '
        'Usá un timestamp distinto para evitar colisión.',
      );
    }
    final encoded = jsonEncode(record.toJson());
    await _box.put(key, encoded);
    // También actualizamos las claves "vivas" para que el resto de la
    // app pueda leer el último offset sin parsear todos los audits.
    await _box.put('mic_offset_db', record.micOffsetDb);
    await _box.put(
      'last_calibrated_at_mic',
      record.timestampUtc.toUtc().toIso8601String(),
    );
    developer.log(
      'appendMicCalibration: offset=${record.micOffsetDb} dB, '
      'sha256=${record.sha256.substring(0, 12)}…',
      name: 'NativeCalibration',
      level: 800,
    );
  }

  /// Persiste un audit record de calibración de auricular.
  Future<void> appendHpCalibration(HpCalibrationAudit record) async {
    _assertHashIsValid(record);
    final key = record.storageKey;
    if (_box.containsKey(key)) {
      throw StateError(
        'calibration_box ya contiene un audit con clave $key.',
      );
    }
    final encoded = jsonEncode(record.toJson());
    await _box.put(key, encoded);
    // Actualizar claves vivas por headphoneId.
    final tableKey = 'hp_offset_table.${record.headphoneId}';
    final timestampKey = 'last_calibrated_at_hp.${record.headphoneId}';
    final tableMap = <String, double>{};
    for (var i = 0; i < record.frequenciesHz.length; i++) {
      tableMap[record.frequenciesHz[i].toString()] = record.hpOffsetDb[i];
    }
    await _box.put(tableKey, tableMap);
    await _box.put(
      timestampKey,
      record.timestampUtc.toUtc().toIso8601String(),
    );
    developer.log(
      'appendHpCalibration: id=${record.headphoneId}, '
      'sha256=${record.sha256.substring(0, 12)}…',
      name: 'NativeCalibration',
      level: 800,
    );
  }

  /// Retorna todos los audit records persistidos, ordenados
  /// cronológicamente. Filtro opcional por `type ∈ {'mic', 'hp'}`.
  Future<List<CalibrationAuditRecord>> getAll({String? type}) async {
    final keys = _box.keys
        .where((k) => k is String && k.startsWith('audit_'))
        .map((k) => k as String)
        .toList()
      ..sort();
    final records = <CalibrationAuditRecord>[];
    for (final key in keys) {
      if (type == 'mic' && !key.startsWith(_kAuditMicPrefix)) continue;
      if (type == 'hp' && !key.startsWith(_kAuditHpPrefix)) continue;
      final raw = _box.get(key);
      if (raw is! String) continue;
      try {
        final decoded = jsonDecode(raw) as Map<String, dynamic>;
        if (key.startsWith(_kAuditMicPrefix)) {
          records.add(MicCalibrationAudit.fromJson(decoded));
        } else if (key.startsWith(_kAuditHpPrefix)) {
          records.add(HpCalibrationAudit.fromJson(decoded));
        }
      } catch (e, st) {
        // Saltar records corruptos en lugar de explotar la lista entera.
        developer.log(
          'getAll: record corrupto en clave $key — saltado',
          name: 'NativeCalibration',
          level: 1000,
          error: e,
          stackTrace: st,
        );
      }
    }
    return records;
  }

  /// Retorna el último audit de mic, o `null` si no hay calibraciones.
  Future<MicCalibrationAudit?> getLatestMic() async {
    final all = await getAll(type: 'mic');
    if (all.isEmpty) return null;
    return all.last as MicCalibrationAudit;
  }

  /// Retorna el último audit de auricular para `headphoneId` específico.
  /// Si `headphoneId` es `null`, retorna el último audit hp de cualquier
  /// auricular.
  Future<HpCalibrationAudit?> getLatestHp(String? headphoneId) async {
    final all = (await getAll(type: 'hp'))
        .whereType<HpCalibrationAudit>()
        .where(
          (r) => headphoneId == null || r.headphoneId == headphoneId,
        )
        .toList();
    if (all.isEmpty) return null;
    return all.last;
  }

  /// Recomputa el SHA-256 del record y lo compara con el persistido.
  /// Retorna `true` si coinciden (record íntegro), `false` si fueron
  /// manipulados.
  Future<bool> verifyIntegrity(CalibrationAuditRecord record) async {
    final recomputed = computeSha256(record.toJsonWithoutSha());
    final ok = recomputed == record.sha256;
    if (!ok) {
      developer.log(
        'verifyIntegrity: hash mismatch para ${record.storageKey}. '
        'Esperado=$recomputed, persistido=${record.sha256}',
        name: 'NativeCalibration',
        level: 1000,
      );
    }
    return ok;
  }

  /// Borra todos los audit records. Solo permitido bajo el flag
  /// `forTests = true` para evitar borrado accidental en producción.
  Future<void> clear({required bool forTests}) async {
    if (!forTests) {
      throw StateError(
        'CalibrationAuditRepository.clear solo permitido bajo forTests=true. '
        'Borrar audit trail en producción rompe la cadena de evidencia.',
      );
    }
    final keys = _box.keys
        .where((k) =>
            k is String &&
            (k.startsWith('audit_') ||
                k == 'mic_offset_db' ||
                k.startsWith('last_calibrated_at_') ||
                k.startsWith('hp_offset_table.')))
        .toList();
    for (final k in keys) {
      await _box.delete(k);
    }
  }

  // ─── Static helpers ────────────────────────────────────────────────────

  /// Calcula `SHA-256(canonicalJson(payload))` en hex.
  /// El campo `sha256` (si existe) es ignorado para evitar self-reference.
  static String computeSha256(Map<String, dynamic> payload) {
    final filtered = Map<String, dynamic>.from(payload)..remove('sha256');
    final canonical = canonicalJson(filtered);
    final bytes = utf8.encode(canonical);
    return sha256.convert(bytes).toString();
  }

  /// Canonical JSON: claves ordenadas alfabéticamente de forma recursiva,
  /// sin indentación, sin espacios adicionales. Determinista entre runs.
  ///
  /// Reglas:
  ///   - Map → object con claves String ordenadas ascendentemente.
  ///   - List → array con orden preservado (NO se reordenan elementos).
  ///   - Primitivos (int, double, bool, String, null) → identidad.
  ///   - DateTime → ISO-8601 UTC con `Z`.
  ///   - Otros → toString() (último resort para evitar excepciones).
  static String canonicalJson(dynamic value) {
    return jsonEncode(_canonicalize(value));
  }

  static dynamic _canonicalize(dynamic value) {
    if (value is Map) {
      final sortedKeys = value.keys.map((k) => k.toString()).toList()..sort();
      final out = <String, dynamic>{};
      for (final k in sortedKeys) {
        out[k] = _canonicalize(value[k]);
      }
      return out;
    }
    if (value is List) {
      return value.map(_canonicalize).toList();
    }
    if (value is DateTime) {
      return value.toUtc().toIso8601String();
    }
    return value;
  }

  void _assertHashIsValid(CalibrationAuditRecord record) {
    final recomputed = computeSha256(record.toJsonWithoutSha());
    if (recomputed != record.sha256) {
      throw StateError(
        'Audit record con SHA-256 inválido. '
        'Esperado=$recomputed, recibido=${record.sha256}. '
        'Asegurate de calcular el hash con `computeSha256(toJsonWithoutSha())` '
        'antes de instanciar el record.',
      );
    }
  }
}
