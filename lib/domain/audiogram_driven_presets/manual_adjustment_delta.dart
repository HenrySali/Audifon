import 'dart:developer' as developer;

import 'package:equatable/equatable.dart';

import 'audiogram_driven_bundle.dart';

/// Delta aditivo de ajustes manuales que se suma sobre un
/// [AudiogramDrivenBundle] base, sin reemplazarlo.
///
/// Modela los ajustes finos que el audiólogo o el usuario aplican
/// encima de la prescripción derivada del audiograma: ecualizador
/// manual por banda, volumen master, override de NR, ratio y knee
/// de compresión. La suma se computa en el bloc al despachar
/// `ApplyAudiogramDrivenBundle`, de modo que el audiograma siempre
/// queda como línea de referencia auditable y el delta queda
/// auditado por separado.
///
/// El delta se persiste por modo de operación en `settings_box`
/// bajo las claves `manual_delta_diagnostic` y `manual_delta_amplifier`
/// (ver design.md, sección "Persistencia (Hive settings_box)").
///
/// Requisitos: 14.2, 14.10
class ManualAdjustmentDelta extends Equatable {
  /// Cantidad de bandas del ecualizador (mismas 12 frecuencias estándar
  /// que [AudiogramDrivenBundle.bandCount]).
  static const int bandCount = AudiogramDrivenBundle.bandCount;

  // --- Rangos válidos por Requirement 14.2 ----------------------------------

  /// Rango válido del delta de EQ por banda en dB.
  static const double eqDeltaMinDb = -10.0;
  static const double eqDeltaMaxDb = 10.0;

  /// Rango válido del delta de volumen master en dB.
  static const double volumeDeltaMinDb = -10.0;
  static const double volumeDeltaMaxDb = 10.0;

  /// Rango válido del delta de nivel de NR (entero).
  static const int nrLevelDeltaMin = -3;
  static const int nrLevelDeltaMax = 3;

  /// Rango válido del delta de ratio de compresión.
  static const double compressionRatioDeltaMin = -1.0;
  static const double compressionRatioDeltaMax = 1.0;

  /// Rango válido del delta de knee de compresión en dB SPL.
  static const double compressionKneeDeltaMinDbSpl = -10.0;
  static const double compressionKneeDeltaMaxDbSpl = 10.0;

  /// Época de referencia para el `editedAt` del delta neutro
  /// ([ManualAdjustmentDelta.zero]). En UTC a 1970-01-01T00:00:00Z.
  static final DateTime _epochUtc = DateTime.utc(1970, 1, 1);

  // --- Campos del delta -----------------------------------------------------

  /// Delta de ganancia EQ por banda en dB. Longitud exacta = [bandCount] (12).
  /// Cada valor en [eqDeltaMinDb], [eqDeltaMaxDb] = [-10, +10] dB.
  final List<double> eqDeltaDb;

  /// Delta de volumen master en dB.
  /// Valor en [volumeDeltaMinDb], [volumeDeltaMaxDb] = [-10, +10] dB.
  final double volumeDeltaDb;

  /// Delta de nivel de NR (entero).
  /// Valor en [nrLevelDeltaMin], [nrLevelDeltaMax] = [-3, +3].
  final int nrLevelDelta;

  /// Delta de ratio de compresión.
  /// Valor en [compressionRatioDeltaMin], [compressionRatioDeltaMax] = [-1.0, +1.0].
  final double compressionRatioDelta;

  /// Delta de knee de compresión en dB SPL.
  /// Valor en [compressionKneeDeltaMinDbSpl], [compressionKneeDeltaMaxDbSpl] = [-10, +10] dB SPL.
  final double compressionKneeDeltaDbSpl;

  /// Timestamp UTC de la última edición del delta, con resolución de
  /// milisegundos. Se serializa como ISO 8601 UTC en [toJson].
  final DateTime editedAt;

  /// Construye un delta inmutable. Todos los campos son requeridos.
  ///
  /// El constructor NO clampea los valores: el clampeo se aplica solo
  /// al deserializar desde Hive vía [ManualAdjustmentDelta.fromJson]
  /// (Req 14.10). Para construir el delta neutro usar
  /// [ManualAdjustmentDelta.zero].
  const ManualAdjustmentDelta({
    required this.eqDeltaDb,
    required this.volumeDeltaDb,
    required this.nrLevelDelta,
    required this.compressionRatioDelta,
    required this.compressionKneeDeltaDbSpl,
    required this.editedAt,
  });

  /// Construye el delta neutro: todos los campos numéricos en cero y
  /// `editedAt` fijado a la época UTC (1970-01-01T00:00:00Z).
  ///
  /// Este es el estado canónico tras un "Resetear ajustes manuales"
  /// (Req 14.9): aplicar este delta sobre un bundle no produce ningún
  /// cambio respecto a la prescripción del audiograma.
  factory ManualAdjustmentDelta.zero() {
    return ManualAdjustmentDelta(
      eqDeltaDb: List<double>.filled(bandCount, 0.0, growable: false),
      volumeDeltaDb: 0.0,
      nrLevelDelta: 0,
      compressionRatioDelta: 0.0,
      compressionKneeDeltaDbSpl: 0.0,
      editedAt: _epochUtc,
    );
  }

  /// Indica si todos los campos numéricos del delta son cero, es decir
  /// si aplicarlo no altera el bundle base. El `editedAt` no influye en
  /// esta comprobación: aunque el usuario haya tocado un slider y
  /// luego lo haya devuelto a cero, el delta sigue siendo "neutro".
  bool get isZero {
    if (volumeDeltaDb != 0.0) return false;
    if (nrLevelDelta != 0) return false;
    if (compressionRatioDelta != 0.0) return false;
    if (compressionKneeDeltaDbSpl != 0.0) return false;
    for (var i = 0; i < eqDeltaDb.length; i++) {
      if (eqDeltaDb[i] != 0.0) return false;
    }
    return true;
  }

  // --- Serialización JSON ---------------------------------------------------

  /// Serializa el delta a un mapa JSON-compatible.
  ///
  /// El `editedAt` se normaliza a UTC con resolución de milisegundos
  /// (sin microsegundos) para garantizar el round-trip exacto vía
  /// [ManualAdjustmentDelta.fromJson].
  Map<String, dynamic> toJson() {
    return {
      'eqDeltaDb': List<double>.from(eqDeltaDb),
      'volumeDeltaDb': volumeDeltaDb,
      'nrLevelDelta': nrLevelDelta,
      'compressionRatioDelta': compressionRatioDelta,
      'compressionKneeDeltaDbSpl': compressionKneeDeltaDbSpl,
      'editedAt': _toIsoUtcMs(editedAt),
    };
  }

  /// Deserializa un delta desde un mapa JSON aplicando clampeo
  /// graceful por campo (Req 14.10).
  ///
  /// Si algún valor está fuera del rango declarado en Requirement 14.2,
  /// se ajusta al bound más cercano y se emite un warning observable
  /// vía `dart:developer`'s `log`. La carga NO aborta: siempre retorna
  /// un delta válido en rango.
  ///
  /// Lanza [FormatException] solo si:
  /// - algún campo obligatorio está ausente o tiene tipo incorrecto.
  /// - `eqDeltaDb` no es una lista de exactamente [bandCount] elementos.
  /// - `editedAt` no parsea como ISO 8601.
  factory ManualAdjustmentDelta.fromJson(Map<String, dynamic> json) {
    final eqRaw = json['eqDeltaDb'];
    if (eqRaw is! List) {
      throw const FormatException(
        'ManualAdjustmentDelta: campo "eqDeltaDb" no es una lista.',
      );
    }
    if (eqRaw.length != bandCount) {
      throw FormatException(
        'ManualAdjustmentDelta: "eqDeltaDb" longitud=${eqRaw.length} '
        '≠ $bandCount bandas requeridas.',
      );
    }

    final eqDeltaDb = List<double>.generate(
      bandCount,
      (i) => _clampDoubleField(
        value: (eqRaw[i] as num).toDouble(),
        fieldName: 'eqDeltaDb[$i]',
        min: eqDeltaMinDb,
        max: eqDeltaMaxDb,
      ),
      growable: false,
    );

    final volumeDeltaDb = _clampDoubleField(
      value: _readDouble(json, 'volumeDeltaDb'),
      fieldName: 'volumeDeltaDb',
      min: volumeDeltaMinDb,
      max: volumeDeltaMaxDb,
    );

    final nrLevelDelta = _clampIntField(
      value: _readInt(json, 'nrLevelDelta'),
      fieldName: 'nrLevelDelta',
      min: nrLevelDeltaMin,
      max: nrLevelDeltaMax,
    );

    final compressionRatioDelta = _clampDoubleField(
      value: _readDouble(json, 'compressionRatioDelta'),
      fieldName: 'compressionRatioDelta',
      min: compressionRatioDeltaMin,
      max: compressionRatioDeltaMax,
    );

    final compressionKneeDeltaDbSpl = _clampDoubleField(
      value: _readDouble(json, 'compressionKneeDeltaDbSpl'),
      fieldName: 'compressionKneeDeltaDbSpl',
      min: compressionKneeDeltaMinDbSpl,
      max: compressionKneeDeltaMaxDbSpl,
    );

    final editedAtStr = json['editedAt'];
    if (editedAtStr is! String) {
      throw const FormatException(
        'ManualAdjustmentDelta: campo "editedAt" ausente o no es String.',
      );
    }
    final editedAt = DateTime.parse(editedAtStr).toUtc();

    return ManualAdjustmentDelta(
      eqDeltaDb: eqDeltaDb,
      volumeDeltaDb: volumeDeltaDb,
      nrLevelDelta: nrLevelDelta,
      compressionRatioDelta: compressionRatioDelta,
      compressionKneeDeltaDbSpl: compressionKneeDeltaDbSpl,
      editedAt: editedAt,
    );
  }

  // --- Helpers de clampeo ---------------------------------------------------

  /// Clampea un double al rango [[min], [max]]. Si el valor está fuera de
  /// rango (incluyendo NaN/Infinity), lo ajusta al bound más cercano y
  /// emite un warning observable. NaN se mapea al [min] por convención.
  static double _clampDoubleField({
    required double value,
    required String fieldName,
    required double min,
    required double max,
  }) {
    if (value.isNaN) {
      developer.log(
        'ManualAdjustmentDelta.fromJson: $fieldName=NaN, '
        'clampeado a $min (fallback).',
        name: 'ManualAdjustmentDelta',
        level: 900, // warning
      );
      return min;
    }
    if (value < min || value > max) {
      final clamped = value.clamp(min, max).toDouble();
      developer.log(
        'ManualAdjustmentDelta.fromJson: $fieldName=$value '
        'fuera de rango [$min, $max], clampeado a $clamped.',
        name: 'ManualAdjustmentDelta',
        level: 900, // warning
      );
      return clamped;
    }
    return value;
  }

  /// Clampea un int al rango [[min], [max]]. Si está fuera de rango lo
  /// ajusta al bound más cercano y emite un warning observable.
  static int _clampIntField({
    required int value,
    required String fieldName,
    required int min,
    required int max,
  }) {
    if (value < min || value > max) {
      final clamped = value.clamp(min, max);
      developer.log(
        'ManualAdjustmentDelta.fromJson: $fieldName=$value '
        'fuera de rango [$min, $max], clampeado a $clamped.',
        name: 'ManualAdjustmentDelta',
        level: 900, // warning
      );
      return clamped;
    }
    return value;
  }

  // --- Helpers de lectura JSON ----------------------------------------------

  static double _readDouble(Map<String, dynamic> json, String key) {
    final raw = json[key];
    if (raw is! num) {
      throw FormatException(
        'ManualAdjustmentDelta: campo "$key" no es numérico.',
      );
    }
    return raw.toDouble();
  }

  static int _readInt(Map<String, dynamic> json, String key) {
    final raw = json[key];
    if (raw is! num) {
      throw FormatException(
        'ManualAdjustmentDelta: campo "$key" no es numérico.',
      );
    }
    return raw.toInt();
  }

  /// Convierte un [DateTime] a ISO 8601 UTC truncando microsegundos
  /// para conservar resolución de milisegundos a través del round-trip.
  static String _toIsoUtcMs(DateTime dt) {
    final utc = dt.toUtc();
    final truncated = DateTime.fromMillisecondsSinceEpoch(
      utc.millisecondsSinceEpoch,
      isUtc: true,
    );
    return truncated.toIso8601String();
  }

  // --- Equatable ------------------------------------------------------------

  @override
  List<Object?> get props => [
        eqDeltaDb,
        volumeDeltaDb,
        nrLevelDelta,
        compressionRatioDelta,
        compressionKneeDeltaDbSpl,
        editedAt,
      ];
}
