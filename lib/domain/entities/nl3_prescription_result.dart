import 'package:equatable/equatable.dart';

import 'loss_type.dart';
import 'prescription_mode.dart';
import 'wdrc_params.dart';

/// Resultado completo de prescripción NL3 con metadata y serialización JSON.
///
/// Contiene las ganancias prescritas, ganancias finales (con compensación),
/// ratios de compresión, tipo de pérdida detectada, modo activo, estado CIN,
/// y parámetros WDRC override opcionales.
///
/// Soporta serialización JSON con versionado de esquema para persistencia,
/// exportación clínica y comparación histórica.
///
/// Requisitos: 7.1, 7.2, 7.5, 11.1, 11.2, 11.3, 11.4
class NL3PrescriptionResult extends Equatable {
  /// Ganancias prescritas por el algoritmo NL3 (12 bandas, dB).
  /// Rango esperado: [0, 50].
  final List<double> prescribedGains;

  /// Ganancias finales con compensación de auricular aplicada (12 bandas, dB).
  /// Rango esperado: [0, 50].
  final List<double> finalGains;

  /// Ratios de compresión por banda (12 valores).
  /// Rango esperado: [1.0, 3.0].
  final List<double> compressionRatios;

  /// Tipo de pérdida auditiva detectada por el clasificador.
  final LossType lossType;

  /// Modo de prescripción activo al momento de generar este resultado.
  final PrescriptionMode mode;

  /// Indica si el módulo CIN (Comfort in Noise) está activo.
  final bool cinActive;

  /// Parámetros WDRC override cuando CIN está activo.
  /// Null si CIN no está activo.
  final WdrcParams? wdrcOverrides;

  /// Warning de MHL: true si PTA > 25 dB HL en modo MHL.
  final bool ptaWarning;

  /// Timestamp de generación de la prescripción.
  final DateTime timestamp;

  /// Versión del esquema de serialización JSON.
  static const String schemaVersion = '1.0.0';

  /// Método de prescripción identificador.
  static const String prescriptionMethod = 'NAL-NL3-inspired';

  const NL3PrescriptionResult({
    required this.prescribedGains,
    required this.finalGains,
    required this.compressionRatios,
    required this.lossType,
    required this.mode,
    required this.cinActive,
    this.wdrcOverrides,
    required this.ptaWarning,
    required this.timestamp,
  });

  /// Serializa el resultado a JSON con schema versioning.
  ///
  /// Incluye `schemaVersion` y `prescriptionMethod` como metadatos
  /// para compatibilidad futura y trazabilidad clínica.
  Map<String, dynamic> toJson() {
    return {
      'schemaVersion': schemaVersion,
      'prescriptionMethod': prescriptionMethod,
      'timestamp': timestamp.toIso8601String(),
      'lossType': lossType.name,
      'mode': mode.name,
      'cinActive': cinActive,
      'ptaWarning': ptaWarning,
      'gains': prescribedGains,
      'finalGains': finalGains,
      'compressionRatios': compressionRatios,
      'wdrcOverrides': wdrcOverrides != null
          ? {
              'expansionKnee': wdrcOverrides!.expansionKnee,
              'expansionRatio': wdrcOverrides!.expansionRatio,
              'compressionKnee': wdrcOverrides!.compressionKnee,
              'compressionRatio': wdrcOverrides!.compressionRatio,
              'attackMs': wdrcOverrides!.attackMs,
              'releaseMs': wdrcOverrides!.releaseMs,
            }
          : null,
    };
  }

  /// Deserializa desde JSON con validación de schema version.
  ///
  /// Lanza [FormatException] si `schemaVersion` no es soportada
  /// o si hay campos faltantes/tipos incorrectos.
  factory NL3PrescriptionResult.fromJson(Map<String, dynamic> json) {
    // Validar schema version.
    final version = json['schemaVersion'] as String?;
    if (version == null || version != schemaVersion) {
      throw FormatException(
        'Schema version "${version ?? 'null'}" no soportada. '
        'Se esperaba "$schemaVersion".',
      );
    }

    // Parsear lossType desde string.
    final lossTypeStr = json['lossType'] as String;
    final lossType = LossType.values.firstWhere(
      (e) => e.name == lossTypeStr,
      orElse: () => throw FormatException(
        'LossType "$lossTypeStr" no reconocido.',
      ),
    );

    // Parsear mode desde string.
    final modeStr = json['mode'] as String;
    final mode = PrescriptionMode.values.firstWhere(
      (e) => e.name == modeStr,
      orElse: () => throw FormatException(
        'PrescriptionMode "$modeStr" no reconocido.',
      ),
    );

    // Parsear listas de gains y ratios.
    final gains = (json['gains'] as List<dynamic>)
        .map((e) => (e as num).toDouble())
        .toList();
    final finalGains = (json['finalGains'] as List<dynamic>)
        .map((e) => (e as num).toDouble())
        .toList();
    final compressionRatios = (json['compressionRatios'] as List<dynamic>)
        .map((e) => (e as num).toDouble())
        .toList();

    // Parsear wdrcOverrides si está presente.
    WdrcParams? wdrcOverrides;
    if (json['wdrcOverrides'] != null) {
      final wdrc = json['wdrcOverrides'] as Map<String, dynamic>;
      wdrcOverrides = WdrcParams(
        expansionKnee: (wdrc['expansionKnee'] as num).toDouble(),
        expansionRatio: (wdrc['expansionRatio'] as num).toDouble(),
        compressionKnee: (wdrc['compressionKnee'] as num).toDouble(),
        compressionRatio: (wdrc['compressionRatio'] as num).toDouble(),
        attackMs: (wdrc['attackMs'] as num).toDouble(),
        releaseMs: (wdrc['releaseMs'] as num).toDouble(),
      );
    }

    return NL3PrescriptionResult(
      prescribedGains: gains,
      finalGains: finalGains,
      compressionRatios: compressionRatios,
      lossType: lossType,
      mode: mode,
      cinActive: json['cinActive'] as bool,
      wdrcOverrides: wdrcOverrides,
      ptaWarning: json['ptaWarning'] as bool,
      timestamp: DateTime.parse(json['timestamp'] as String),
    );
  }

  @override
  List<Object?> get props => [
        prescribedGains,
        finalGains,
        compressionRatios,
        lossType,
        mode,
        cinActive,
        wdrcOverrides,
        ptaWarning,
        timestamp,
      ];
}
