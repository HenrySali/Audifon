/// @file mic_calibration_result.dart
/// @brief Resultado de una calibración del micrófono (lado de entrada del
///        pipeline DSP del audífono digital V2).
///
/// Este modelo es el "payload" que persiste en `mic_calibration_box` (Hive)
/// y que se exporta como JSON para audit trail conforme a:
///
///   * ANMAT — Disposición 2318/2002, art. 9 (trazabilidad)
///   * Colombia — Decreto 4725/2005, art. 36 (vigilancia post-mercado)
///   * ISO 13485 (QMS) e ISO 14971 (gestión de riesgos)
///
/// Schema version actual: `2.0`. Cualquier cambio incompatible debe bumpear
/// el `schemaVersion` y ofrecer una ruta de migración en el store.
///
/// Validates: Requirements R1, R3, R4 (de
/// `mic-calibration/requirements.md`).

import 'dart:convert';

import 'package:crypto/crypto.dart' as crypto;

/// Métodos válidos de calibración del micrófono. Se usan tanto como
/// discriminador en runtime (controller) como para validar el JSON entrante.
class MicCalibrationMethod {
  /// El operador ajustó manualmente el offset con un slider (campo, sin
  /// sonómetro certificado).
  static const String manual = 'manual';

  /// Captura automática de un tono de referencia conocido (1 kHz típico).
  static const String automaticTone = 'automatic_tone';

  /// Calibración de producción / fábrica con acoplador 2cc IEC 60318-5 y
  /// sonómetro Tipo 2 trazable a INTI / ONAC.
  static const String production2cc = 'production_2cc';

  static const Set<String> all = {manual, automaticTone, production2cc};
}

/// Resultado de una sesión de calibración del micrófono. Inmutable.
///
/// Convenciones:
///
///   * `splOffset` está en dB y SIEMPRE en `[60.0, 130.0]`. Si el constructor
///     recibe un valor fuera de rango lanza [ArgumentError] (no `assert`,
///     porque el assert se elimina en release y dejaría persistir basura).
///   * `calibrationDate` se almacena en UTC. El `toJson()` lo serializa como
///     ISO-8601 con sufijo `Z`.
///   * `sha256` es opcional: por defecto el modelo no se hashea a sí mismo;
///     el caller debe llamar a [withSha256] antes de persistirlo cuando se
///     requiera trazabilidad fuerte (audit trail).
///
/// El campo `qualityFlags` documenta condiciones detectadas durante la
/// captura (por ejemplo `'noisy_environment'`, `'frequency_off_target'`,
/// `'persistence_failed'`).
class MicCalibrationResult {
  /// Versión del esquema JSON. Forward-compatible: cualquier producer que
  /// emita schema 2.0 SHALL ser legible por consumers 2.0+.
  static const String schemaVersion = '2.0';

  /// Mínimo absoluto del offset SPL aceptado por el sistema.
  static const double splOffsetMinDb = 60.0;

  /// Máximo absoluto del offset SPL aceptado por el sistema.
  static const double splOffsetMaxDb = 130.0;

  // --- Campos requeridos -----------------------------------------------------

  /// Identificador único del dispositivo Android (hash del Android ID).
  final String deviceId;

  /// Modelo del teléfono (`Build.MODEL`, ej: "SM-G998B").
  final String deviceModel;

  /// Offset SPL aplicado al pipeline DSP. Cumple `splOffsetMinDb ≤ offset ≤
  /// splOffsetMaxDb`.
  final double splOffset;

  /// Fecha de la calibración en UTC.
  final DateTime calibrationDate;

  /// Método de calibración. Debe ser uno de [MicCalibrationMethod.all].
  final String method;

  /// Versión de la app en el momento de la calibración (ej: "2.5.0").
  final String appVersion;

  /// Versión del firmware del audífono físico (ej: "1.3.0"). Si no hay
  /// firmware (modo simulador), se persiste `"none"` o `"unknown"`.
  final String firmwareVersion;

  // --- Campos opcionales -----------------------------------------------------

  /// SPL del tono de referencia (modo automático o producción).
  final double? referenceSpl;

  /// Frecuencia detectada en Hz (modo automático con Quinn 2nd-order).
  final double? detectedFrequencyHz;

  /// RMS capturado en dBFS (modo automático).
  final double? capturedRmsDbfs;

  /// Flags de calidad observados durante la captura (vacía por defecto).
  final List<String> qualityFlags;

  /// Identificador del operador (si hay login). En modo single-user es
  /// `null` y se mapea a "default" en la clave de persistencia.
  final String? operatorId;

  /// Hash SHA-256 hex de la representación canónica JSON del resultado
  /// (excluyendo el propio campo `sha256`). Se computa con [computeSha256].
  final String? sha256;

  /// Constructor principal. Aplica:
  ///
  ///   * `assert` de rango (modo debug, defensa contra programmer error).
  ///   * Validación dura con [ArgumentError] (modo release, defensa contra
  ///     datos corruptos cargados desde JSON externo).
  ///
  /// Validates: R1 (persistencia con offset válido), R2 (rango del slider).
  MicCalibrationResult({
    required this.deviceId,
    required this.deviceModel,
    required this.splOffset,
    required this.calibrationDate,
    required this.method,
    required this.appVersion,
    required this.firmwareVersion,
    this.referenceSpl,
    this.detectedFrequencyHz,
    this.capturedRmsDbfs,
    List<String>? qualityFlags,
    this.operatorId,
    this.sha256,
  })  : assert(
          splOffset >= splOffsetMinDb && splOffset <= splOffsetMaxDb,
          'splOffset $splOffset fuera de rango [$splOffsetMinDb, $splOffsetMaxDb]',
        ),
        qualityFlags = List<String>.unmodifiable(qualityFlags ?? const []) {
    // Validación hard, aplica también en release. R1.4 / R2.1 exigen que
    // jamás se persista un offset fuera de rango.
    if (splOffset < splOffsetMinDb || splOffset > splOffsetMaxDb) {
      throw ArgumentError.value(
        splOffset,
        'splOffset',
        'debe estar en [$splOffsetMinDb, $splOffsetMaxDb] dB',
      );
    }
    if (!MicCalibrationMethod.all.contains(method)) {
      throw ArgumentError.value(
        method,
        'method',
        'debe ser uno de ${MicCalibrationMethod.all.toList()}',
      );
    }
  }

  /// Serializa el resultado a JSON con `schemaVersion = "2.0"` y todos los
  /// campos en `camelCase`. Las fechas se serializan en ISO-8601 UTC
  /// (sufijo "Z") para garantizar reproducibilidad bit-a-bit del hash.
  ///
  /// Validates: R1.2, R9.1.
  Map<String, dynamic> toJson() {
    final dateUtc = calibrationDate.toUtc();
    return <String, dynamic>{
      'schemaVersion': schemaVersion,
      'deviceId': deviceId,
      'deviceModel': deviceModel,
      'splOffset': splOffset,
      'calibrationDate': dateUtc.toIso8601String(),
      'method': method,
      'referenceSpl': referenceSpl,
      'detectedFrequencyHz': detectedFrequencyHz,
      'capturedRmsDbfs': capturedRmsDbfs,
      'qualityFlags': List<String>.from(qualityFlags),
      'operatorId': operatorId,
      'appVersion': appVersion,
      'firmwareVersion': firmwareVersion,
      'sha256': sha256,
    };
  }

  /// Reconstruye un [MicCalibrationResult] desde JSON. Lanza
  /// [FormatException] si el `schemaVersion` no es exactamente `"2.0"` (la
  /// migración de schemas previos es responsabilidad del store, no del
  /// modelo).
  ///
  /// Validates: R9.2 (validación de schemaVersion al importar).
  factory MicCalibrationResult.fromJson(Map<String, dynamic> j) {
    final version = j['schemaVersion'];
    if (version != schemaVersion) {
      throw FormatException(
        'schemaVersion incompatible: esperado "$schemaVersion", recibido '
        '"${version ?? '<ausente>'}"',
      );
    }

    final rawFlags = j['qualityFlags'];
    final flags = rawFlags is List
        ? rawFlags.map((e) => e.toString()).toList(growable: false)
        : const <String>[];

    return MicCalibrationResult(
      deviceId: j['deviceId'] as String,
      deviceModel: j['deviceModel'] as String,
      splOffset: (j['splOffset'] as num).toDouble(),
      calibrationDate: DateTime.parse(j['calibrationDate'] as String).toUtc(),
      method: j['method'] as String,
      referenceSpl: (j['referenceSpl'] as num?)?.toDouble(),
      detectedFrequencyHz: (j['detectedFrequencyHz'] as num?)?.toDouble(),
      capturedRmsDbfs: (j['capturedRmsDbfs'] as num?)?.toDouble(),
      qualityFlags: flags,
      operatorId: j['operatorId'] as String?,
      appVersion: j['appVersion'] as String,
      firmwareVersion: j['firmwareVersion'] as String,
      sha256: j['sha256'] as String?,
    );
  }

  /// Devuelve una copia con los campos indicados sobrescritos. No recalcula
  /// el `sha256`: si la copia debe quedar firmada, llamar [withSha256]
  /// después.
  MicCalibrationResult copyWith({
    String? deviceId,
    String? deviceModel,
    double? splOffset,
    DateTime? calibrationDate,
    String? method,
    double? referenceSpl,
    double? detectedFrequencyHz,
    double? capturedRmsDbfs,
    List<String>? qualityFlags,
    String? operatorId,
    String? appVersion,
    String? firmwareVersion,
    String? sha256,
  }) {
    return MicCalibrationResult(
      deviceId: deviceId ?? this.deviceId,
      deviceModel: deviceModel ?? this.deviceModel,
      splOffset: splOffset ?? this.splOffset,
      calibrationDate: calibrationDate ?? this.calibrationDate,
      method: method ?? this.method,
      referenceSpl: referenceSpl ?? this.referenceSpl,
      detectedFrequencyHz: detectedFrequencyHz ?? this.detectedFrequencyHz,
      capturedRmsDbfs: capturedRmsDbfs ?? this.capturedRmsDbfs,
      qualityFlags: qualityFlags ?? this.qualityFlags,
      operatorId: operatorId ?? this.operatorId,
      appVersion: appVersion ?? this.appVersion,
      firmwareVersion: firmwareVersion ?? this.firmwareVersion,
      sha256: sha256 ?? this.sha256,
    );
  }

  /// Calcula el SHA-256 hex (lowercase, 64 chars) de la representación
  /// canónica JSON del resultado, excluyendo el propio campo `sha256` para
  /// evitar dependencia circular.
  ///
  /// La canonicalización ordena las claves alfabéticamente en cada nivel,
  /// de modo que dos resultados semánticamente iguales producen el mismo
  /// hash sin importar el orden de inserción.
  ///
  /// Validates: R4.1 (SHA-256 de cada payload de calibración para audit
  /// trail).
  String computeSha256() {
    final json = toJson()..remove('sha256');
    final canonical = _canonicalEncode(json);
    final digest = crypto.sha256.convert(utf8.encode(canonical));
    return digest.toString();
  }

  /// Devuelve una copia del resultado con el campo `sha256` recalculado.
  /// Idempotente: `r.withSha256().withSha256()` produce el mismo resultado.
  MicCalibrationResult withSha256() {
    final hex = computeSha256();
    return copyWith(sha256: hex);
  }

  /// Recalcula el SHA-256 actual y lo compara con el campo `sha256`. Si el
  /// objeto no tiene hash (lo que ocurre, por ejemplo, justo después de
  /// `fromJson` de un export legacy), considera la firma trivialmente
  /// correcta y devuelve `true`.
  ///
  /// Validates: R4.1 (verificación de integridad del audit trail) y R9.2
  /// (verificación de SHA-256 al importar).
  bool verifySha256() {
    if (sha256 == null) return true;
    return computeSha256() == sha256;
  }

  // ---------------------------------------------------------------------------
  // Igualdad estructural y hashCode (para tests, sets, mapas).
  // ---------------------------------------------------------------------------

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    if (other is! MicCalibrationResult) return false;
    return other.deviceId == deviceId &&
        other.deviceModel == deviceModel &&
        other.splOffset == splOffset &&
        other.calibrationDate.toUtc() == calibrationDate.toUtc() &&
        other.method == method &&
        other.referenceSpl == referenceSpl &&
        other.detectedFrequencyHz == detectedFrequencyHz &&
        other.capturedRmsDbfs == capturedRmsDbfs &&
        _listEq(other.qualityFlags, qualityFlags) &&
        other.operatorId == operatorId &&
        other.appVersion == appVersion &&
        other.firmwareVersion == firmwareVersion &&
        other.sha256 == sha256;
  }

  @override
  int get hashCode => Object.hash(
        deviceId,
        deviceModel,
        splOffset,
        calibrationDate.toUtc().millisecondsSinceEpoch,
        method,
        referenceSpl,
        detectedFrequencyHz,
        capturedRmsDbfs,
        Object.hashAll(qualityFlags),
        operatorId,
        appVersion,
        firmwareVersion,
        sha256,
      );

  @override
  String toString() {
    return 'MicCalibrationResult('
        'deviceModel: $deviceModel, '
        'splOffset: ${splOffset.toStringAsFixed(2)} dB, '
        'method: $method, '
        'date: ${calibrationDate.toUtc().toIso8601String()}, '
        'sha256: ${sha256 ?? "<unsigned>"})';
  }

  // ---------------------------------------------------------------------------
  // Helpers internos.
  // ---------------------------------------------------------------------------

  /// Codificador JSON canónico: ordena las claves de cada `Map` y usa
  /// [jsonEncode] estándar (que ya maneja tipos primitivos / listas).
  ///
  /// La canonicalización es esencial para que `computeSha256` sea
  /// determinístico independientemente del orden de inserción.
  static String _canonicalEncode(Object? value) {
    return jsonEncode(_canonicalize(value));
  }

  static Object? _canonicalize(Object? value) {
    if (value is Map) {
      final sortedKeys = value.keys.map((e) => e.toString()).toList()..sort();
      final out = <String, Object?>{};
      for (final k in sortedKeys) {
        out[k] = _canonicalize(value[k]);
      }
      return out;
    }
    if (value is Iterable) {
      return value.map(_canonicalize).toList(growable: false);
    }
    return value;
  }

  static bool _listEq(List<String> a, List<String> b) {
    if (identical(a, b)) return true;
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }
}
