/// Modelo de una observación del técnico/paciente sobre el entorno acústico.
///
/// Una observación captura:
/// - Texto libre del usuario describiendo lo que experimenta
/// - Snapshot DSP del momento (telemetría del pipeline)
/// - Clase de escena detectada automáticamente
/// - Timestamp
///
/// El módulo de aprendizaje acumula observaciones y las envía a Hermes
/// para que genere ajustes DSP personalizados.
library;

import '../../scene/scene_snapshot.dart' show SceneClass;

/// Estado de una observación en su ciclo de vida.
enum ObservationStatus {
  /// Recién creada, pendiente de análisis.
  pending,

  /// Enviada a Hermes, esperando sugerencia.
  analyzing,

  /// Hermes respondió con sugerencia de ajuste.
  suggestionReady,

  /// El técnico aplicó la sugerencia.
  applied,

  /// El técnico descartó la sugerencia.
  dismissed,
}

/// Snapshot de la telemetría DSP al momento de la observación.
class DspTelemetrySnapshot {
  final double inputLevelDb;
  final double outputLevelDb;
  final double postNrLevelDb;
  final double postEqLevelDb;
  final double postWdrcLevelDb;
  final double peakSample;
  final int clipCount;
  final int wdrcRegion; // 0=expansion, 1=linear, 2=compression
  final double wdrcGainFactor;
  final double mpoLimitingFraction;
  final bool mpoLimitingSustained;
  final int environmentClass; // 0-7 → SceneClass
  final int nrLevel;
  final List<double> eqGains; // 12 bandas
  final double volumeDb;

  const DspTelemetrySnapshot({
    required this.inputLevelDb,
    required this.outputLevelDb,
    required this.postNrLevelDb,
    required this.postEqLevelDb,
    required this.postWdrcLevelDb,
    required this.peakSample,
    required this.clipCount,
    required this.wdrcRegion,
    required this.wdrcGainFactor,
    required this.mpoLimitingFraction,
    required this.mpoLimitingSustained,
    required this.environmentClass,
    required this.nrLevel,
    required this.eqGains,
    required this.volumeDb,
  });

  Map<String, dynamic> toJson() => {
        'inputLevelDb': inputLevelDb,
        'outputLevelDb': outputLevelDb,
        'postNrLevelDb': postNrLevelDb,
        'postEqLevelDb': postEqLevelDb,
        'postWdrcLevelDb': postWdrcLevelDb,
        'peakSample': peakSample,
        'clipCount': clipCount,
        'wdrcRegion': wdrcRegion,
        'wdrcGainFactor': wdrcGainFactor,
        'mpoLimitingFraction': mpoLimitingFraction,
        'mpoLimitingSustained': mpoLimitingSustained,
        'environmentClass': environmentClass,
        'nrLevel': nrLevel,
        'eqGains': eqGains,
        'volumeDb': volumeDb,
      };

  factory DspTelemetrySnapshot.fromJson(Map<String, dynamic> json) {
    return DspTelemetrySnapshot(
      inputLevelDb: (json['inputLevelDb'] as num?)?.toDouble() ?? -80.0,
      outputLevelDb: (json['outputLevelDb'] as num?)?.toDouble() ?? -80.0,
      postNrLevelDb: (json['postNrLevelDb'] as num?)?.toDouble() ?? -80.0,
      postEqLevelDb: (json['postEqLevelDb'] as num?)?.toDouble() ?? -80.0,
      postWdrcLevelDb: (json['postWdrcLevelDb'] as num?)?.toDouble() ?? -80.0,
      peakSample: (json['peakSample'] as num?)?.toDouble() ?? 0.0,
      clipCount: (json['clipCount'] as num?)?.toInt() ?? 0,
      wdrcRegion: (json['wdrcRegion'] as num?)?.toInt() ?? 1,
      wdrcGainFactor: (json['wdrcGainFactor'] as num?)?.toDouble() ?? 1.0,
      mpoLimitingFraction:
          (json['mpoLimitingFraction'] as num?)?.toDouble() ?? 0.0,
      mpoLimitingSustained: json['mpoLimitingSustained'] as bool? ?? false,
      environmentClass: (json['environmentClass'] as num?)?.toInt() ?? 0,
      nrLevel: (json['nrLevel'] as num?)?.toInt() ?? 1,
      eqGains: (json['eqGains'] as List<dynamic>?)
              ?.map((e) => (e as num).toDouble())
              .toList() ??
          List<double>.filled(12, 0.0),
      volumeDb: (json['volumeDb'] as num?)?.toDouble() ?? 0.0,
    );
  }
}

/// Sugerencia de ajuste DSP generada por Hermes.
class DspAdjustmentSuggestion {
  /// Ganancias EQ sugeridas (12 bandas, dB).
  final List<double> suggestedGains;

  /// Nivel de NR sugerido [0-3].
  final int suggestedNrLevel;

  /// Volumen sugerido (dB).
  final double suggestedVolumeDb;

  /// Razón textual de Hermes explicando el ajuste.
  final String reasoning;

  /// Confianza de Hermes en la sugerencia [0.0 - 1.0].
  final double confidence;

  const DspAdjustmentSuggestion({
    required this.suggestedGains,
    required this.suggestedNrLevel,
    required this.suggestedVolumeDb,
    required this.reasoning,
    required this.confidence,
  });

  Map<String, dynamic> toJson() => {
        'suggestedGains': suggestedGains,
        'suggestedNrLevel': suggestedNrLevel,
        'suggestedVolumeDb': suggestedVolumeDb,
        'reasoning': reasoning,
        'confidence': confidence,
      };

  factory DspAdjustmentSuggestion.fromJson(Map<String, dynamic> json) {
    return DspAdjustmentSuggestion(
      suggestedGains: (json['suggestedGains'] as List<dynamic>?)
              ?.map((e) => (e as num).toDouble())
              .toList() ??
          List<double>.filled(12, 0.0),
      suggestedNrLevel: (json['suggestedNrLevel'] as num?)?.toInt() ?? 1,
      suggestedVolumeDb: (json['suggestedVolumeDb'] as num?)?.toDouble() ?? 0.0,
      reasoning: json['reasoning'] as String? ?? '',
      confidence: (json['confidence'] as num?)?.toDouble() ?? 0.0,
    );
  }
}

/// Una observación completa con su contexto y posible sugerencia.
class LearningObservation {
  final int id; // microsecondsSinceEpoch
  final DateTime timestamp;
  final String userText;
  final DspTelemetrySnapshot telemetry;
  final SceneClass detectedScene;
  final ObservationStatus status;
  final DspAdjustmentSuggestion? suggestion;
  final bool? feedback; // true=👍, false=👎, null=sin respuesta

  const LearningObservation({
    required this.id,
    required this.timestamp,
    required this.userText,
    required this.telemetry,
    required this.detectedScene,
    required this.status,
    this.suggestion,
    this.feedback,
  });

  LearningObservation copyWith({
    ObservationStatus? status,
    DspAdjustmentSuggestion? suggestion,
    bool? feedback,
  }) {
    return LearningObservation(
      id: id,
      timestamp: timestamp,
      userText: userText,
      telemetry: telemetry,
      detectedScene: detectedScene,
      status: status ?? this.status,
      suggestion: suggestion ?? this.suggestion,
      feedback: feedback ?? this.feedback,
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'timestamp': timestamp.toIso8601String(),
        'userText': userText,
        'telemetry': telemetry.toJson(),
        'detectedScene': detectedScene.index,
        'status': status.name,
        'suggestion': suggestion?.toJson(),
        'feedback': feedback,
      };

  factory LearningObservation.fromJson(Map<String, dynamic> json) {
    final sceneIdx = (json['detectedScene'] as num?)?.toInt() ?? 0;
    final scene = (sceneIdx >= 0 && sceneIdx < SceneClass.values.length)
        ? SceneClass.values[sceneIdx]
        : SceneClass.unknown;

    final statusName = json['status'] as String? ?? 'pending';
    final status = ObservationStatus.values.firstWhere(
      (s) => s.name == statusName,
      orElse: () => ObservationStatus.pending,
    );

    return LearningObservation(
      id: (json['id'] as num).toInt(),
      timestamp: DateTime.parse(json['timestamp'] as String),
      userText: json['userText'] as String? ?? '',
      telemetry: DspTelemetrySnapshot.fromJson(
          json['telemetry'] as Map<String, dynamic>? ?? {}),
      detectedScene: scene,
      status: status,
      suggestion: json['suggestion'] != null
          ? DspAdjustmentSuggestion.fromJson(
              json['suggestion'] as Map<String, dynamic>)
          : null,
      feedback: json['feedback'] as bool?,
    );
  }
}
