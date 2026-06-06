import 'package:equatable/equatable.dart';

import '../entities/audiogram.dart';
import 'audiogram_driven_bundle.dart';
import 'manual_adjustment_delta.dart';

/// Blob unificado persistido por el [ProfileRepository] para los
/// presets personalizados.
///
/// Captura todo el contexto clínico necesario para reconstruir
/// fielmente el estado del paciente: audiograma medido, bundle
/// derivado completo, estilo aplicado, override de NR y delta manual.
/// Es la fuente de verdad para preset personalizado (Req 8.1, 8.2).
///
/// El record incluye además flags de ciclo de vida:
/// - [stale]: el audiograma actual difiere en más de 5 dB MAD respecto
///   al audiograma del preset (Req 9.2).
/// - [migrated]: el blob persistido tenía un `schemaVersion` legacy y
///   el repositorio recomputó el bundle al esquema actual (Req 8.4).
///
/// El record NO valida los rangos en el constructor; usar [validate]
/// para obtener la lista de violaciones antes de retornar el record
/// al caller (Req 8.5).
///
/// Requisitos: 8.1, 8.2, 8.3, 8.4, 8.5, 8.7, 9.2, 9.5
class CustomPresetRecord extends Equatable {
  /// Versión del esquema del blob. Cuando el blob persistido tiene
  /// otro valor (o el campo está ausente) el repositorio dispara la
  /// migración descrita en Req 8.4.
  static const String schemaVersion = '1.0.0';

  /// Tamaño máximo del blob serializado (en bytes UTF-8).
  /// Si el `jsonEncode(toJson()).length` excede este valor el
  /// repositorio rechaza el guardado con `StateError` (Req 8.3).
  static const int maxBlobSizeBytes = 64 * 1024; // 64 KB

  /// Frecuencias estándar usadas para validar el audiograma del
  /// preset. Coinciden con [Audiogram.standardFrequencies] (12).
  static List<int> get _requiredFrequencies =>
      Audiogram.standardFrequencies;

  /// Bound inferior aceptado para los umbrales del audiograma
  /// persistido (dB HL). Por debajo el preset se considera corrupto.
  static const double audiogramHlMinDb = -10.0;

  /// Bound superior aceptado para los umbrales del audiograma
  /// persistido (dB HL). Por encima el preset se considera corrupto.
  static const double audiogramHlMaxDb = 120.0;

  // --- Campos del record ----------------------------------------------------

  /// Nombre del preset (clave única en el `profiles_box`).
  final String name;

  /// Audiograma del paciente al momento de crear el preset.
  final Audiogram audiogram;

  /// Bundle clínico completo derivado del audiograma + estilo + override.
  final AudiogramDrivenBundle bundle;

  /// Nombre del estilo aplicado al construir el bundle (`Normal`,
  /// `Voice Clarity`, etc.). Cuando el preset se guardó sin estilo
  /// activo se persiste como cadena vacía.
  final String appliedStyleName;

  /// Override aditivo aplicado sobre `bundle.nrLevel` al guardar el
  /// preset. Rango `[-3, +3]` (igual que `EnvironmentProfile.nrDelta`).
  final int nrOverride;

  /// Delta manual activo al guardar el preset. `null` cuando el delta
  /// es neutro / no se aplicó ajuste manual.
  final ManualAdjustmentDelta? manualDelta;

  /// Timestamp UTC de creación. Resolución milisegundos.
  final DateTime createdAt;

  /// Marca el preset como obsoleto cuando el audiograma actual del
  /// paciente difiere significativamente del audiograma del preset
  /// (MAD por banda > 5 dB, Req 9.2).
  final bool stale;

  /// Marca el preset como migrado cuando el repositorio detectó un
  /// `schemaVersion` legacy y recomputó el bundle desde el audiograma
  /// + estilo + override (Req 8.4, 8.7).
  final bool migrated;

  const CustomPresetRecord({
    required this.name,
    required this.audiogram,
    required this.bundle,
    required this.appliedStyleName,
    required this.nrOverride,
    required this.manualDelta,
    required this.createdAt,
    this.stale = false,
    this.migrated = false,
  });

  /// Construye una copia del record sustituyendo los campos provistos.
  ///
  /// Usar `setManualDelta: true` con `manualDelta: null` para limpiar
  /// el delta del record (no se puede usar el parámetro opcional con
  /// `null` directo porque el ?? colapsaría con el valor previo).
  CustomPresetRecord copyWith({
    String? name,
    Audiogram? audiogram,
    AudiogramDrivenBundle? bundle,
    String? appliedStyleName,
    int? nrOverride,
    ManualAdjustmentDelta? manualDelta,
    bool clearManualDelta = false,
    DateTime? createdAt,
    bool? stale,
    bool? migrated,
  }) {
    return CustomPresetRecord(
      name: name ?? this.name,
      audiogram: audiogram ?? this.audiogram,
      bundle: bundle ?? this.bundle,
      appliedStyleName: appliedStyleName ?? this.appliedStyleName,
      nrOverride: nrOverride ?? this.nrOverride,
      manualDelta:
          clearManualDelta ? null : (manualDelta ?? this.manualDelta),
      createdAt: createdAt ?? this.createdAt,
      stale: stale ?? this.stale,
      migrated: migrated ?? this.migrated,
    );
  }

  // --- Validación -----------------------------------------------------------

  /// Valida el record contra los requisitos clínicos:
  /// - el audiograma contiene las 12 frecuencias estándar con umbrales
  ///   finitos en `[audiogramHlMinDb, audiogramHlMaxDb]` (Req 8.5);
  /// - el bundle pasa [AudiogramDrivenBundle.validate] (Req 1.2).
  ///
  /// Retorna la lista de mensajes descriptivos. Si la lista está
  /// vacía, el record es válido y puede aplicarse.
  List<String> validate() {
    final errors = <String>[];

    // Validar el audiograma persistido.
    final thresholds = audiogram.thresholds;
    final missingFreqs = <int>[];
    for (final f in _requiredFrequencies) {
      if (!thresholds.containsKey(f)) {
        missingFreqs.add(f);
      }
    }
    if (missingFreqs.isNotEmpty) {
      errors.add(
        'audiogram: faltan frecuencias ${missingFreqs.join(', ')} Hz',
      );
    }

    for (final entry in thresholds.entries) {
      final hl = entry.value;
      if (hl.isNaN || hl.isInfinite) {
        errors.add('audiogram[${entry.key} Hz]=$hl no es finito');
        continue;
      }
      if (hl < audiogramHlMinDb || hl > audiogramHlMaxDb) {
        errors.add(
          'audiogram[${entry.key} Hz]=$hl fuera de rango '
          '[$audiogramHlMinDb, $audiogramHlMaxDb] dB HL',
        );
      }
    }

    // Validar el bundle (rangos por banda y scalars).
    final bundleViolations = bundle.validate();
    for (final v in bundleViolations) {
      errors.add('bundle: $v');
    }

    return errors;
  }

  /// Indica si el record pasa todas las validaciones de rango.
  bool get isValid => validate().isEmpty;

  // --- Serialización JSON ---------------------------------------------------

  /// Serializa el record a un mapa JSON-compatible.
  ///
  /// Conserva los campos legacy (`nrLevel`, `compressionRatio`,
  /// `expansionKnee`, `compressionKnee`) derivados del bundle como
  /// "vista" backward-compatible para versiones anteriores del repo
  /// (Req 8.2). Estos valores NO se leen en el path nuevo: la fuente
  /// de verdad es siempre el `bundle` y el `audiogram`.
  Map<String, dynamic> toJson() {
    final legacyView = _legacyEnvironmentProfileView();
    return {
      'schemaVersion': schemaVersion,
      'name': name,
      'audiogram': _audiogramToJson(audiogram),
      'bundle': bundle.toJson(),
      'appliedStyleName': appliedStyleName,
      'nrOverride': nrOverride,
      'manualDelta': manualDelta?.toJson(),
      'createdAt': _toIsoUtcMs(createdAt),
      'stale': stale,
      'migrated': migrated,
      // Legacy fields (read-only for backward compat).
      'nrLevel': legacyView.nrLevel,
      'compressionRatio': legacyView.compressionRatio,
      'expansionKnee': legacyView.expansionKnee,
      'compressionKnee': legacyView.compressionKnee,
    };
  }

  /// Deserializa un record desde un mapa JSON.
  ///
  /// Asume que [json] tiene `schemaVersion == [schemaVersion]`. La
  /// migración desde versiones legacy es responsabilidad del
  /// repositorio (no de esta factoría) — ver
  /// `ProfileRepositoryImpl._loadCustomPresetRecord`.
  ///
  /// Lanza [FormatException] si algún campo obligatorio está ausente
  /// o tiene tipo incorrecto.
  factory CustomPresetRecord.fromJson(Map<String, dynamic> json) {
    final version = json['schemaVersion'];
    if (version is! String || version != schemaVersion) {
      throw FormatException(
        'CustomPresetRecord: schemaVersion incompatible. '
        'Esperada "$schemaVersion", recibida "${version ?? 'null'}".',
      );
    }

    final name = json['name'];
    if (name is! String) {
      throw const FormatException(
        'CustomPresetRecord: campo "name" ausente o no String.',
      );
    }

    final audiogramRaw = json['audiogram'];
    if (audiogramRaw is! Map) {
      throw const FormatException(
        'CustomPresetRecord: campo "audiogram" ausente o no Map.',
      );
    }
    final audiogram = _audiogramFromJson(
      Map<String, dynamic>.from(audiogramRaw),
    );

    final bundleRaw = json['bundle'];
    if (bundleRaw is! Map) {
      throw const FormatException(
        'CustomPresetRecord: campo "bundle" ausente o no Map.',
      );
    }
    final bundle = AudiogramDrivenBundle.fromJson(
      Map<String, dynamic>.from(bundleRaw),
    );

    final appliedStyleName = json['appliedStyleName'];
    if (appliedStyleName is! String) {
      throw const FormatException(
        'CustomPresetRecord: campo "appliedStyleName" ausente o no String.',
      );
    }

    final nrOverrideRaw = json['nrOverride'];
    if (nrOverrideRaw is! num) {
      throw const FormatException(
        'CustomPresetRecord: campo "nrOverride" ausente o no numérico.',
      );
    }
    final nrOverride = nrOverrideRaw.toInt();

    ManualAdjustmentDelta? manualDelta;
    final deltaRaw = json['manualDelta'];
    if (deltaRaw is Map) {
      manualDelta =
          ManualAdjustmentDelta.fromJson(Map<String, dynamic>.from(deltaRaw));
    }

    final createdAtStr = json['createdAt'];
    if (createdAtStr is! String) {
      throw const FormatException(
        'CustomPresetRecord: campo "createdAt" ausente o no String.',
      );
    }
    final createdAt = DateTime.parse(createdAtStr).toUtc();

    final stale = json['stale'] is bool ? json['stale'] as bool : false;
    final migrated =
        json['migrated'] is bool ? json['migrated'] as bool : false;

    return CustomPresetRecord(
      name: name,
      audiogram: audiogram,
      bundle: bundle,
      appliedStyleName: appliedStyleName,
      nrOverride: nrOverride,
      manualDelta: manualDelta,
      createdAt: createdAt,
      stale: stale,
      migrated: migrated,
    );
  }

  // --- Helpers internos -----------------------------------------------------

  /// Vista legacy del bundle como tupla de scalars compatible con el
  /// shape del `EnvironmentProfile` antiguo. Permite que versiones
  /// anteriores del repo lean los presets sin romper si encuentran un
  /// blob nuevo (Req 8.2).
  _LegacyEnvironmentView _legacyEnvironmentProfileView() {
    // Promedio simple sobre las 12 bandas para el ratio (compatible
    // con el campo broadband del schema legacy).
    double sumCr = 0;
    for (final cr in bundle.compressionRatios) {
      sumCr += cr;
    }
    final avgCr = bundle.compressionRatios.isEmpty
        ? 1.0
        : sumCr / bundle.compressionRatios.length;

    double sumKnee = 0;
    for (final k in bundle.compressionKneesDbSpl) {
      sumKnee += k;
    }
    final avgKnee = bundle.compressionKneesDbSpl.isEmpty
        ? 50.0
        : sumKnee / bundle.compressionKneesDbSpl.length;

    return _LegacyEnvironmentView(
      nrLevel: bundle.nrLevel,
      compressionRatio: avgCr,
      expansionKnee: bundle.expansionKneeDbSpl,
      compressionKnee: avgKnee,
    );
  }

  /// Serializa el [Audiogram] al shape esperado por [Audiogram.fromJson]
  /// dentro del blob: `{ thresholds: { "freq": "value" } }` con
  /// claves String para compatibilidad con Hive/JSON.
  static Map<String, dynamic> _audiogramToJson(Audiogram a) {
    final thresholdsMap = <String, double>{};
    for (final entry in a.thresholds.entries) {
      thresholdsMap[entry.key.toString()] = entry.value;
    }
    return {
      'thresholds': thresholdsMap,
    };
  }

  /// Deserializa un [Audiogram] del shape `{ thresholds: { "freq": value } }`.
  static Audiogram _audiogramFromJson(Map<String, dynamic> json) {
    final raw = json['thresholds'];
    if (raw is! Map) {
      throw const FormatException(
        'CustomPresetRecord.audiogram: campo "thresholds" ausente o no Map.',
      );
    }
    final thresholds = <int, double>{};
    raw.forEach((key, value) {
      final freq = key is int ? key : int.parse(key.toString());
      final hl = (value as num).toDouble();
      thresholds[freq] = hl;
    });
    return Audiogram(thresholds: thresholds);
  }

  /// Convierte [DateTime] a ISO 8601 UTC truncando microsegundos
  /// para conservar resolución de milisegundos en el round-trip.
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
        name,
        audiogram,
        bundle,
        appliedStyleName,
        nrOverride,
        manualDelta,
        createdAt,
        stale,
        migrated,
      ];
}

/// Vista legacy del bundle exportada en el blob para retrocompatibilidad
/// de lectura desde versiones anteriores del [ProfileRepository].
class _LegacyEnvironmentView {
  final int nrLevel;
  final double compressionRatio;
  final double expansionKnee;
  final double compressionKnee;

  const _LegacyEnvironmentView({
    required this.nrLevel,
    required this.compressionRatio,
    required this.expansionKnee,
    required this.compressionKnee,
  });
}
