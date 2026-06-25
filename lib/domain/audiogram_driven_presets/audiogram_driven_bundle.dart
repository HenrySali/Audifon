import 'package:equatable/equatable.dart';

import '../entities/loss_type.dart';
import '../entities/prescription_mode.dart';
import 'operating_mode.dart';

/// Bundle inmutable derivado del audiograma del paciente que agrupa
/// todos los parámetros clínicos del pipeline DSP.
///
/// Contiene, para una corrida de prescripción:
/// - 12 ganancias EQ ([gainsDb])
/// - 12 ratios de compresión por banda ([compressionRatios])
/// - 12 kneepoints de compresión por banda ([compressionKneesDbSpl])
/// - 12 valores del perfil MPO por banda ([mpoProfileDbSpl])
/// - el nivel de NR sugerido ([nrLevel])
/// - los tiempos WDRC sugeridos ([wdrcAttackMs], [wdrcReleaseMs])
/// - el knee de expansión broadband ([expansionKneeDbSpl])
/// - los descriptores clínicos ([lossType], [prescriptionMode], [mode])
/// - el escalado del modo Amplificador ([gainScale])
/// - el timestamp de derivación ([derivedAt]).
///
/// El bundle es la fuente única de verdad de toda aplicación al motor DSP.
/// Todos los flujos (presets manuales, EnvironmentProfile, Smart Scene,
/// presets personalizados) lo consumen vía `ApplyAudiogramDrivenBundle`.
///
/// Soporta serialización JSON con [schemaVersion] para persistencia
/// (preset personalizado, snapshot del último bundle aplicado) y para
/// exportación clínica.
///
/// Requisitos: 1.2, 1.7, 1.8, 13.12
class AudiogramDrivenBundle extends Equatable {
  /// Versión del esquema JSON. Cambia cuando la forma del blob cambia.
  static const String schemaVersion = '1.0.0';

  /// Cantidad de bandas en los arrays de longitud fija (mismas 12
  /// frecuencias estándar de [Audiogram.standardFrequencies]).
  static const int bandCount = 12;

  // --- Rangos válidos por Requirement 1.2 / 13.12 ---------------------------

  /// Rango válido de ganancia EQ por banda en dB.
  static const double gainMinDb = 0.0;
  static const double gainMaxDb = 50.0;

  /// Rango válido de ratio de compresión adimensional.
  static const double compressionRatioMin = 1.0;
  static const double compressionRatioMax = 3.0;

  /// Rango válido del knee de compresión por banda en dB SPL.
  static const double compressionKneeMinDbSpl = 35.0;
  static const double compressionKneeMaxDbSpl = 65.0;

  /// Rango válido del MPO por banda en dB SPL.
  static const double mpoMinDbSpl = 80.0;
  static const double mpoMaxDbSpl = 132.0;

  /// Rango válido del nivel de NR (entero).
  static const int nrLevelMin = 0;
  static const int nrLevelMax = 3;

  /// Rango válido del attack WDRC en ms.
  static const double wdrcAttackMinMs = 1.0;
  static const double wdrcAttackMaxMs = 50.0;

  /// Rango válido del release WDRC en ms.
  static const double wdrcReleaseMinMs = 20.0;
  static const double wdrcReleaseMaxMs = 500.0;

  /// Rango válido del knee de expansión en dB SPL.
  static const double expansionKneeMinDbSpl = 20.0;
  static const double expansionKneeMaxDbSpl = 50.0;

  /// Rango válido del [gainScale] del modo Amplificador.
  static const double gainScaleMin = 0.10;
  static const double gainScaleMax = 1.00;

  // --- Campos del bundle ----------------------------------------------------

  /// Ganancias EQ por banda en dB. Longitud exacta = [bandCount] (12).
  /// Cada valor en [gainMinDb], [gainMaxDb] = [0, 50] dB.
  final List<double> gainsDb;

  /// Ratios de compresión por banda. Longitud exacta = [bandCount] (12).
  /// Cada valor en [compressionRatioMin], [compressionRatioMax] = [1.0, 3.0].
  final List<double> compressionRatios;

  /// Knee de compresión por banda en dB SPL. Longitud exacta = [bandCount] (12).
  /// Cada valor en [compressionKneeMinDbSpl], [compressionKneeMaxDbSpl] = [35, 65] dB SPL.
  final List<double> compressionKneesDbSpl;

  /// Perfil MPO por banda en dB SPL. Longitud exacta = [bandCount] (12).
  /// Cada valor en [mpoMinDbSpl], [mpoMaxDbSpl] = [80, 132] dB SPL.
  final List<double> mpoProfileDbSpl;

  /// Targets NAL-NL3 prescritos para 65 dB SPL input por banda en dB.
  /// Longitud exacta = [bandCount] (12).
  /// Estos son los targets "ideales" calculados por el prescriptor antes
  /// de aplicar ajustes manuales o gain scale. Se usan para verificación
  /// del fitting (AAA/ASHA recomienda ±5 dB de tolerancia).
  final List<double> prescribedTargetsDb;

  /// Nivel de NR sugerido. Entero en [nrLevelMin], [nrLevelMax] = [0, 3].
  final int nrLevel;

  /// Tiempo de attack del WDRC en ms.
  /// Valor en [wdrcAttackMinMs], [wdrcAttackMaxMs] = [1, 50] ms.
  final double wdrcAttackMs;

  /// Tiempo de release del WDRC en ms.
  /// Valor en [wdrcReleaseMinMs], [wdrcReleaseMaxMs] = [20, 500] ms.
  final double wdrcReleaseMs;

  /// Knee de expansión broadband en dB SPL.
  /// Valor en [expansionKneeMinDbSpl], [expansionKneeMaxDbSpl] = [20, 50] dB SPL.
  final double expansionKneeDbSpl;

  /// Tipo de pérdida auditiva detectada por [AudiogramClassifier].
  final LossType lossType;

  /// Modo de prescripción activo al momento de derivar el bundle.
  final PrescriptionMode prescriptionMode;

  /// Modo de operación de la app (Diagnóstico vs Amplificador).
  final OperatingMode mode;

  /// Factor de escala global de [gainsDb] usado en modo Amplificador.
  /// Valor en [gainScaleMin], [gainScaleMax] = [0.10, 1.00]. En modo
  /// Diagnóstico debe ser exactamente `1.0`.
  final double gainScale;

  /// Timestamp UTC de derivación, con resolución de milisegundos.
  /// El builder es responsable de inyectar el reloj (no usar
  /// `DateTime.now()` directo dentro de las funciones puras).
  final DateTime derivedAt;

  /// Construye un bundle inmutable. Todos los campos son requeridos.
  ///
  /// El constructor NO valida los rangos: usar [validate] para obtener
  /// la lista de violaciones, o [validateOrThrow] para lanzar
  /// [StateError] al primer error encontrado.
  const AudiogramDrivenBundle({
    required this.gainsDb,
    required this.compressionRatios,
    required this.compressionKneesDbSpl,
    required this.mpoProfileDbSpl,
    required this.prescribedTargetsDb,
    required this.nrLevel,
    required this.wdrcAttackMs,
    required this.wdrcReleaseMs,
    required this.expansionKneeDbSpl,
    required this.lossType,
    required this.prescriptionMode,
    required this.mode,
    required this.gainScale,
    required this.derivedAt,
  });

  // --- Validación -----------------------------------------------------------

  /// Verifica todas las restricciones de rango y longitud declaradas en
  /// Requirement 1.2. Retorna la lista de mensajes descriptivos de
  /// violaciones. Si la lista está vacía, el bundle es válido.
  ///
  /// Esta firma se elige para que el handler `_onApplyBundle` del bloc
  /// pueda emitir un estado de error con la lista completa de
  /// violaciones (Req 4.7).
  List<String> validate() {
    final errors = <String>[];

    _validateBandedList(
      values: gainsDb,
      name: 'gainsDb',
      min: gainMinDb,
      max: gainMaxDb,
      errors: errors,
    );
    _validateBandedList(
      values: compressionRatios,
      name: 'compressionRatios',
      min: compressionRatioMin,
      max: compressionRatioMax,
      errors: errors,
    );
    _validateBandedList(
      values: compressionKneesDbSpl,
      name: 'compressionKneesDbSpl',
      min: compressionKneeMinDbSpl,
      max: compressionKneeMaxDbSpl,
      errors: errors,
    );
    _validateBandedList(
      values: mpoProfileDbSpl,
      name: 'mpoProfileDbSpl',
      min: mpoMinDbSpl,
      max: mpoMaxDbSpl,
      errors: errors,
    );
    _validateBandedList(
      values: prescribedTargetsDb,
      name: 'prescribedTargetsDb',
      min: gainMinDb,
      max: gainMaxDb,
      errors: errors,
    );

    if (nrLevel < nrLevelMin || nrLevel > nrLevelMax) {
      errors.add(
        'nrLevel=$nrLevel fuera de rango [$nrLevelMin, $nrLevelMax]',
      );
    }

    _validateScalar(
      value: wdrcAttackMs,
      name: 'wdrcAttackMs',
      min: wdrcAttackMinMs,
      max: wdrcAttackMaxMs,
      errors: errors,
    );
    _validateScalar(
      value: wdrcReleaseMs,
      name: 'wdrcReleaseMs',
      min: wdrcReleaseMinMs,
      max: wdrcReleaseMaxMs,
      errors: errors,
    );
    _validateScalar(
      value: expansionKneeDbSpl,
      name: 'expansionKneeDbSpl',
      min: expansionKneeMinDbSpl,
      max: expansionKneeMaxDbSpl,
      errors: errors,
    );
    _validateScalar(
      value: gainScale,
      name: 'gainScale',
      min: gainScaleMin,
      max: gainScaleMax,
      errors: errors,
    );

    return errors;
  }

  /// Indica si el bundle pasa todas las validaciones de rango.
  bool get isValid => validate().isEmpty;

  /// Lanza [StateError] con la lista de violaciones si el bundle no es
  /// válido. Útil para tests y para invariantes locales.
  void validateOrThrow() {
    final errors = validate();
    if (errors.isNotEmpty) {
      throw StateError(
        'AudiogramDrivenBundle inválido: ${errors.join('; ')}',
      );
    }
  }

  static void _validateBandedList({
    required List<double> values,
    required String name,
    required double min,
    required double max,
    required List<String> errors,
  }) {
    if (values.length != bandCount) {
      errors.add(
        '$name longitud=${values.length} ≠ $bandCount bandas requeridas',
      );
      // No revisamos rango por banda si la longitud es incorrecta para
      // evitar inundar el reporte con índices inválidos.
      return;
    }
    for (var i = 0; i < values.length; i++) {
      final v = values[i];
      if (v.isNaN || v.isInfinite) {
        errors.add('$name[$i]=$v no es finito');
        continue;
      }
      if (v < min || v > max) {
        errors.add('$name[$i]=$v fuera de rango [$min, $max]');
      }
    }
  }

  static void _validateScalar({
    required double value,
    required String name,
    required double min,
    required double max,
    required List<String> errors,
  }) {
    if (value.isNaN || value.isInfinite) {
      errors.add('$name=$value no es finito');
      return;
    }
    if (value < min || value > max) {
      errors.add('$name=$value fuera de rango [$min, $max]');
    }
  }

  // --- Serialización JSON ---------------------------------------------------

  /// Serializa el bundle a un mapa JSON-compatible.
  ///
  /// El [derivedAt] se normaliza a UTC con resolución de milisegundos
  /// (sin microsegundos) para garantizar el round-trip exacto requerido
  /// por Requirement 1.7.
  Map<String, dynamic> toJson() {
    return {
      'schemaVersion': schemaVersion,
      'gainsDb': List<double>.from(gainsDb),
      'compressionRatios': List<double>.from(compressionRatios),
      'compressionKneesDbSpl': List<double>.from(compressionKneesDbSpl),
      'mpoProfileDbSpl': List<double>.from(mpoProfileDbSpl),
      'prescribedTargetsDb': List<double>.from(prescribedTargetsDb),
      'nrLevel': nrLevel,
      'wdrcAttackMs': wdrcAttackMs,
      'wdrcReleaseMs': wdrcReleaseMs,
      'expansionKneeDbSpl': expansionKneeDbSpl,
      'lossType': lossType.name,
      'prescriptionMode': prescriptionMode.name,
      'mode': mode.name,
      'gainScale': gainScale,
      'derivedAt': _toIsoUtcMs(derivedAt),
    };
  }

  /// Deserializa un bundle desde un mapa JSON con validación de
  /// [schemaVersion].
  ///
  /// Lanza [FormatException] si:
  /// - `schemaVersion` está ausente o no coincide con [schemaVersion]
  ///   (mensaje incluye versión esperada y recibida explícitamente,
  ///   Req 1.8).
  /// - algún campo obligatorio está ausente o tiene tipo incorrecto.
  /// - los enums no son reconocibles.
  factory AudiogramDrivenBundle.fromJson(Map<String, dynamic> json) {
    final version = json['schemaVersion'];
    if (version is! String || version != schemaVersion) {
      throw FormatException(
        'AudiogramDrivenBundle: schemaVersion incompatible. '
        'Esperada "$schemaVersion", recibida "${version ?? 'null'}".',
      );
    }

    final lossTypeStr = json['lossType'] as String?;
    if (lossTypeStr == null) {
      throw const FormatException(
        'AudiogramDrivenBundle: campo "lossType" ausente.',
      );
    }
    final lossType = LossType.values.firstWhere(
      (e) => e.name == lossTypeStr,
      orElse: () => throw FormatException(
        'AudiogramDrivenBundle: lossType "$lossTypeStr" no reconocido.',
      ),
    );

    final modeStr = json['prescriptionMode'] as String?;
    if (modeStr == null) {
      throw const FormatException(
        'AudiogramDrivenBundle: campo "prescriptionMode" ausente.',
      );
    }
    final prescriptionMode = PrescriptionMode.values.firstWhere(
      (e) => e.name == modeStr,
      orElse: () => throw FormatException(
        'AudiogramDrivenBundle: prescriptionMode "$modeStr" no reconocido.',
      ),
    );

    final operatingModeStr = json['mode'] as String?;
    if (operatingModeStr == null) {
      throw const FormatException(
        'AudiogramDrivenBundle: campo "mode" ausente.',
      );
    }
    final operatingMode = OperatingMode.values.firstWhere(
      (e) => e.name == operatingModeStr,
      orElse: () => throw FormatException(
        'AudiogramDrivenBundle: OperatingMode "$operatingModeStr" no reconocido.',
      ),
    );

    final derivedAtStr = json['derivedAt'] as String?;
    if (derivedAtStr == null) {
      throw const FormatException(
        'AudiogramDrivenBundle: campo "derivedAt" ausente.',
      );
    }
    final derivedAt = DateTime.parse(derivedAtStr).toUtc();

    return AudiogramDrivenBundle(
      gainsDb: _readDoubleList(json, 'gainsDb'),
      compressionRatios: _readDoubleList(json, 'compressionRatios'),
      compressionKneesDbSpl: _readDoubleList(json, 'compressionKneesDbSpl'),
      mpoProfileDbSpl: _readDoubleList(json, 'mpoProfileDbSpl'),
      prescribedTargetsDb: _tryReadDoubleList(json, 'prescribedTargetsDb', 'gainsDb'),
      nrLevel: _readInt(json, 'nrLevel'),
      wdrcAttackMs: _readDouble(json, 'wdrcAttackMs'),
      wdrcReleaseMs: _readDouble(json, 'wdrcReleaseMs'),
      expansionKneeDbSpl: _readDouble(json, 'expansionKneeDbSpl'),
      lossType: lossType,
      prescriptionMode: prescriptionMode,
      mode: operatingMode,
      gainScale: _readDouble(json, 'gainScale'),
      derivedAt: derivedAt,
    );
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

  static List<double> _readDoubleList(Map<String, dynamic> json, String key) {
    final raw = json[key];
    if (raw is! List) {
      throw FormatException(
        'AudiogramDrivenBundle: campo "$key" no es una lista.',
      );
    }
    return raw
        .map((e) => (e as num).toDouble())
        .toList(growable: false);
  }

  static double _readDouble(Map<String, dynamic> json, String key) {
    final raw = json[key];
    if (raw is! num) {
      throw FormatException(
        'AudiogramDrivenBundle: campo "$key" no es numérico.',
      );
    }
    return raw.toDouble();
  }

  static int _readInt(Map<String, dynamic> json, String key) {
    final raw = json[key];
    if (raw is! num) {
      throw FormatException(
        'AudiogramDrivenBundle: campo "$key" no es numérico.',
      );
    }
    return raw.toInt();
  }

  /// Lee una lista de doubles de [json] para la clave [key]. Si la clave
  /// está ausente, retorna la lista de la clave [fallbackKey].
  static List<double> _tryReadDoubleList(
    Map<String, dynamic> json,
    String key,
    String fallbackKey,
  ) {
    if (json.containsKey(key)) {
      return _readDoubleList(json, key);
    }
    if (json.containsKey(fallbackKey)) {
      return _readDoubleList(json, fallbackKey);
    }
    return List<double>.filled(bandCount, 0.0);
  }

  // --- Equatable ------------------------------------------------------------

  @override
  List<Object?> get props => [
        gainsDb,
        compressionRatios,
        compressionKneesDbSpl,
        mpoProfileDbSpl,
        prescribedTargetsDb,
        nrLevel,
        wdrcAttackMs,
        wdrcReleaseMs,
        expansionKneeDbSpl,
        lossType,
        prescriptionMode,
        mode,
        gainScale,
        derivedAt,
      ];
}
