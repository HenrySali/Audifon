import 'package:equatable/equatable.dart';

/// Preset de ecualización con ganancias predefinidas para 12 bandas.
///
/// Cada preset representa un perfil de amplificación basado en el grado
/// de pérdida auditiva (Normal, Mild, Moderate, Severe, Profound, Custom).
///
/// Las frecuencias de las 12 bandas son:
/// 250, 500, 750, 1000, 1500, 2000, 2500, 3000, 3500, 4000, 6000, 8000 Hz
class EqPreset extends Equatable {
  /// Nombre del preset.
  final String name;

  /// Descripción breve del preset.
  final String description;

  /// Ganancias en dB para cada una de las 12 bandas [0, 50].
  final List<double> gains;

  /// Parámetros WDRC recomendados para este preset.
  final double compressionRatio;
  final double compressionKnee;
  final double expansionKnee;

  const EqPreset({
    required this.name,
    required this.description,
    required this.gains,
    this.compressionRatio = 2.0,
    this.compressionKnee = 55.0,
    this.expansionKnee = 35.0,
  });

  /// Frecuencias centrales de las 12 bandas del EQ.
  static const List<int> bandFrequencies = [
    250, 500, 750, 1000, 1500, 2000, 2500, 3000, 3500, 4000, 6000, 8000,
  ];

  /// Etiquetas cortas para las bandas.
  static const List<String> bandLabels = [
    '250', '500', '750', '1k', '1.5k', '2k',
    '2.5k', '3k', '3.5k', '4k', '6k', '8k',
  ];

  // ─── Presets predefinidos ─────────────────────────────────────────────
  // Basados en NAL-NL2 (National Acoustic Laboratories, Australia) para
  // input de 65 dB SPL (habla conversacional). Ganancias limitadas a ≤14 dB
  // por banda para compatibilidad con arquitectura biquad en serie.
  //
  // Referencias:
  // - Keidser et al. (2011) "The NAL-NL2 Prescription Procedure" PMC4627149
  // - FDA OTC Rule 2022: OSPL90 ≤ 110 dB SPL (21 CFR 800.30)
  // - Hearing Review: "Real World Evidence on Gain and Output Settings"
  // - ADA Consensus: peak OSPL90 ≤ 110 dB SPL for OTC
  //
  // Bandas: 250, 500, 750, 1000, 1500, 2000, 2500, 3000, 3500, 4000, 6000, 8000 Hz

  /// Normal: sin amplificación. Para audición normal o referencia.
  static const normal = EqPreset(
    name: 'Normal',
    description: 'Sin pérdida auditiva',
    gains: [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0],
    compressionRatio: 1.2,
    compressionKnee: 60.0,
  );

  /// Mild High: pérdida leve en frecuencias altas (20-30 dB HL en 2-8kHz).
  /// Patrón más común en presbiacusia temprana.
  /// NAL-NL2 para sloping loss 20-30 dB HL @ 65 dB input.
  static const mildHigh = EqPreset(
    name: 'Mild High',
    description: 'Pérdida leve en agudos (20-30 dB HL)',
    gains: [0, 0, 1, 2, 4, 6, 7, 8, 8, 7, 5, 4],
    compressionRatio: 1.3,
    compressionKnee: 58.0,
  );

  /// Mild Flat: pérdida leve plana (25-35 dB HL en todas las frecuencias).
  /// NAL-NL2 para flat loss 30 dB HL @ 65 dB input.
  static const mildFlat = EqPreset(
    name: 'Mild Flat',
    description: 'Pérdida leve plana (25-35 dB HL)',
    gains: [2, 3, 4, 5, 6, 7, 7, 7, 7, 6, 5, 4],
    compressionRatio: 1.4,
    compressionKnee: 56.0,
  );

  /// Moderate High: pérdida moderada en frecuencias altas (35-50 dB HL en 2-8kHz).
  /// Patrón típico de presbiacusia moderada.
  /// NAL-NL2 para sloping loss 35-50 dB HL @ 65 dB input.
  static const moderateHigh = EqPreset(
    name: 'Moderate High',
    description: 'Pérdida moderada en agudos (35-50 dB HL)',
    gains: [0, 2, 3, 5, 7, 9, 10, 11, 11, 10, 8, 6],
    compressionRatio: 1.5,
    compressionKnee: 55.0,
  );

  /// Moderate Flat: pérdida moderada plana (40-50 dB HL).
  /// NAL-NL2 para flat loss 45 dB HL @ 65 dB input.
  static const moderateFlat = EqPreset(
    name: 'Moderate Flat',
    description: 'Pérdida moderada plana (40-50 dB HL)',
    gains: [4, 6, 7, 9, 10, 11, 12, 12, 12, 11, 9, 7],
    compressionRatio: 1.8,
    compressionKnee: 52.0,
  );

  /// Moderate Plus: pérdida moderada-severa en altas (45-55 dB HL en 2-8kHz).
  /// Máxima amplificación segura para arquitectura biquad en serie.
  /// NAL-NL2 para sloping loss 45-55 dB HL @ 65 dB input.
  static const moderatePlus = EqPreset(
    name: 'Moderate+',
    description: 'Pérdida moderada-severa en agudos (45-55 dB HL)',
    gains: [2, 4, 6, 8, 10, 12, 13, 14, 14, 12, 9, 7],
    compressionRatio: 2.0,
    compressionKnee: 50.0,
  );

  /// Voice Clarity: optimizado para inteligibilidad del habla.
  /// Enfatiza 1-4 kHz (rango de consonantes fricativas s, f, th).
  /// Basado en Speech Intelligibility Index (SII) weighting.
  static const voiceClarity = EqPreset(
    name: 'Voice Clarity',
    description: 'Optimizado para claridad de voz',
    gains: [0, 1, 3, 6, 9, 11, 12, 12, 11, 9, 6, 3],
    compressionRatio: 1.6,
    compressionKnee: 53.0,
  );

  /// Music: respuesta más plana con énfasis suave en medios-altos.
  /// Basado en Moore (2012) "Effects of Bandwidth on Preferences for Amplified Music".
  /// Evita picos >10 dB para preservar naturalidad musical.
  static const music = EqPreset(
    name: 'Music',
    description: 'Optimizado para escuchar música',
    gains: [3, 4, 5, 6, 7, 8, 8, 7, 6, 5, 4, 3],
    compressionRatio: 1.3,
    compressionKnee: 58.0,
  );

  /// Outdoor: reducción de graves (viento/rumble) + boost de medios-altos.
  /// Para ambientes exteriores con ruido de baja frecuencia.
  static const outdoor = EqPreset(
    name: 'Outdoor',
    description: 'Exteriores (reduce viento, mejora voces)',
    gains: [0, 0, 2, 5, 8, 10, 11, 11, 10, 9, 6, 4],
    compressionRatio: 1.7,
    compressionKnee: 52.0,
  );

  /// TV/Media: boost moderado en rango de voz (500-4000 Hz).
  /// Para mejorar diálogos en televisión y medios.
  static const tvMedia = EqPreset(
    name: 'TV/Media',
    description: 'Mejora diálogos en TV y medios',
    gains: [0, 3, 5, 8, 10, 11, 11, 10, 9, 7, 4, 2],
    compressionRatio: 1.5,
    compressionKnee: 55.0,
  );

  /// Custom: placeholder para configuración manual del usuario.
  static EqPreset custom({List<double>? gains}) => EqPreset(
    name: 'Custom',
    description: 'Configuración manual',
    gains: gains ?? List.filled(12, 0.0),
    compressionRatio: 2.0,
    compressionKnee: 50.0,
  );

  /// Lista de todos los presets predefinidos (10 presets).
  static const List<EqPreset> allPresets = [
    normal,
    mildHigh,
    mildFlat,
    moderateHigh,
    moderateFlat,
    moderatePlus,
    voiceClarity,
    music,
    outdoor,
    tvMedia,
  ];

  /// Busca un preset por nombre. Retorna null si no existe.
  static EqPreset? findByName(String name) {
    for (final preset in allPresets) {
      if (preset.name == name) return preset;
    }
    return null;
  }

  /// Serializa a Map para persistencia en Hive/JSON.
  Map<String, dynamic> toJson() => {
    'name': name,
    'description': description,
    'gains': gains,
    'compressionRatio': compressionRatio,
    'compressionKnee': compressionKnee,
    'expansionKnee': expansionKnee,
  };

  /// Deserializa desde Map.
  static EqPreset fromJson(Map<String, dynamic> json) {
    return EqPreset(
      name: json['name'] as String? ?? 'Custom',
      description: json['description'] as String? ?? '',
      gains: (json['gains'] as List<dynamic>?)
          ?.map((e) => (e as num).toDouble())
          .toList() ?? List.filled(12, 0.0),
      compressionRatio: (json['compressionRatio'] as num?)?.toDouble() ?? 2.0,
      compressionKnee: (json['compressionKnee'] as num?)?.toDouble() ?? 55.0,
      expansionKnee: (json['expansionKnee'] as num?)?.toDouble() ?? 35.0,
    );
  }

  @override
  List<Object?> get props => [name, gains];
}
