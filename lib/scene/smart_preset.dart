/// Smart Scene Engine — Fase 3.
///
/// Modelo del preset adaptativo que el `SceneEngine` arma a partir de la
/// clase detectada y, opcionalmente, del audiograma del usuario.
///
/// Es un POJO inmutable (sin Equatable para evitar dependencia opcional);
/// trae `toJson` / `fromJson` por si se quiere serializar en
/// `smart_scene_log` o pasarlo entre módulos.
///
/// Validates: Requirements 3.6, 3.7

import 'scene_snapshot.dart';

class SmartPreset {
  /// Nombre legible (típicamente "SmartScene_voiceInNoiseLow_1234").
  final String name;

  /// Verdadero si las ganancias salen del audiograma del paciente
  /// (NAL-NL2 + deltas de la escena). Falso = preset genérico por escena.
  final bool isPersonalized;

  /// Clase de escena que originó este preset.
  final SceneClass sceneClass;

  /// Ganancias por banda EQ (12 bandas, ya recortadas a [0, 50] dB).
  final List<double> gains;

  /// Compression Ratio del WDRC.
  final double compressionRatio;

  /// Compression Knee (dB SPL).
  final double compressionKnee;

  /// Expansion Knee (dB SPL).
  final double expansionKnee;

  /// Nivel de Noise Reduction recomendado [0, 3].
  final int nrLevel;

  /// Si Transient Noise Reduction debería estar activo.
  final bool tnrEnabled;

  /// Delta de volumen master (dB) sobre lo que el usuario tenga ahora.
  final double volumeDeltaDb;

  /// Confianza con la que se generó el preset, propagada del análisis.
  final double confidence;

  /// Índices de banda (0..11) cuya ganancia objetivo excedió el techo
  /// de headroom MPO por ≥ 0.1 dB y fue recortada por el clamp por banda.
  /// Lista vacía si ninguna banda tocó el clamp. La UI puede usar este
  /// metadata para resaltar al usuario que ciertas bandas están limitadas
  /// por el MPO del paciente (Req 10.6).
  final List<int> clampedBands;

  const SmartPreset({
    required this.name,
    required this.isPersonalized,
    required this.sceneClass,
    required this.gains,
    required this.compressionRatio,
    required this.compressionKnee,
    required this.expansionKnee,
    required this.nrLevel,
    required this.tnrEnabled,
    required this.volumeDeltaDb,
    required this.confidence,
    this.clampedBands = const <int>[],
  });

  SmartPreset copyWith({
    String? name,
    bool? isPersonalized,
    SceneClass? sceneClass,
    List<double>? gains,
    double? compressionRatio,
    double? compressionKnee,
    double? expansionKnee,
    int? nrLevel,
    bool? tnrEnabled,
    double? volumeDeltaDb,
    double? confidence,
    List<int>? clampedBands,
  }) {
    return SmartPreset(
      name: name ?? this.name,
      isPersonalized: isPersonalized ?? this.isPersonalized,
      sceneClass: sceneClass ?? this.sceneClass,
      gains: gains ?? this.gains,
      compressionRatio: compressionRatio ?? this.compressionRatio,
      compressionKnee: compressionKnee ?? this.compressionKnee,
      expansionKnee: expansionKnee ?? this.expansionKnee,
      nrLevel: nrLevel ?? this.nrLevel,
      tnrEnabled: tnrEnabled ?? this.tnrEnabled,
      volumeDeltaDb: volumeDeltaDb ?? this.volumeDeltaDb,
      confidence: confidence ?? this.confidence,
      clampedBands: clampedBands ?? this.clampedBands,
    );
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
        'name': name,
        'isPersonalized': isPersonalized,
        'sceneClass': sceneClass.index,
        'gains': gains,
        'compressionRatio': compressionRatio,
        'compressionKnee': compressionKnee,
        'expansionKnee': expansionKnee,
        'nrLevel': nrLevel,
        'tnrEnabled': tnrEnabled,
        'volumeDeltaDb': volumeDeltaDb,
        'confidence': confidence,
        'clampedBands': clampedBands,
      };

  static SmartPreset fromJson(Map<dynamic, dynamic> json) {
    final rawGains = (json['gains'] as List).cast<num>();
    final classIdx = (json['sceneClass'] as num).toInt();
    final cls = (classIdx >= 0 && classIdx < SceneClass.values.length)
        ? SceneClass.values[classIdx]
        : SceneClass.unknown;
    final rawClamped = json['clampedBands'];
    final clamped = rawClamped is List
        ? rawClamped.map((e) => (e as num).toInt()).toList(growable: false)
        : const <int>[];
    return SmartPreset(
      name: json['name'] as String,
      isPersonalized: json['isPersonalized'] as bool,
      sceneClass: cls,
      gains: rawGains.map((e) => e.toDouble()).toList(growable: false),
      compressionRatio: (json['compressionRatio'] as num).toDouble(),
      compressionKnee: (json['compressionKnee'] as num).toDouble(),
      expansionKnee: (json['expansionKnee'] as num).toDouble(),
      nrLevel: (json['nrLevel'] as num).toInt(),
      tnrEnabled: json['tnrEnabled'] as bool,
      volumeDeltaDb: (json['volumeDeltaDb'] as num).toDouble(),
      confidence: (json['confidence'] as num).toDouble(),
      clampedBands: clamped,
    );
  }
}
