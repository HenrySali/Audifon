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

  /// Normal: sin amplificación significativa.
  static const normal = EqPreset(
    name: 'Normal',
    description: 'Sin pérdida auditiva',
    gains: [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0],
    compressionRatio: 1.2,
    compressionKnee: 60.0,
  );

  /// Mild: pérdida leve en frecuencias altas (20-40 dB HL).
  /// Basado en NAL-NL2 para pérdida leve descendente.
  static const mild = EqPreset(
    name: 'Mild',
    description: 'Pérdida leve (20-40 dB HL)',
    gains: [0, 2, 3, 5, 7, 9, 10, 11, 11, 10, 8, 6],
    compressionRatio: 1.5,
    compressionKnee: 55.0,
  );

  /// Moderate: pérdida moderada (40-55 dB HL).
  /// Basado en NAL-NL2 para pérdida moderada descendente.
  static const moderate = EqPreset(
    name: 'Moderate',
    description: 'Pérdida moderada (40-55 dB HL)',
    gains: [4, 7, 10, 14, 16, 18, 19, 20, 20, 18, 14, 11],
    compressionRatio: 2.0,
    compressionKnee: 50.0,
  );

  /// Severe: pérdida severa (55-70 dB HL).
  /// Basado en NAL-NL2 para pérdida severa descendente.
  static const severe = EqPreset(
    name: 'Severe',
    description: 'Pérdida severa (55-70 dB HL)',
    gains: [8, 13, 18, 22, 24, 27, 28, 28, 27, 26, 20, 17],
    compressionRatio: 2.5,
    compressionKnee: 45.0,
  );

  /// Profound: pérdida profunda (>70 dB HL).
  /// Basado en NAL-NL2 para pérdida profunda.
  static const profound = EqPreset(
    name: 'Profound',
    description: 'Pérdida profunda (>70 dB HL)',
    gains: [12, 19, 25, 30, 32, 35, 36, 36, 35, 33, 27, 22],
    compressionRatio: 3.0,
    compressionKnee: 40.0,
  );

  /// Custom: placeholder para configuración manual del usuario.
  static EqPreset custom({List<double>? gains}) => EqPreset(
    name: 'Custom',
    description: 'Configuración manual',
    gains: gains ?? List.filled(12, 0.0),
    compressionRatio: 2.0,
    compressionKnee: 50.0,
  );

  /// Lista de todos los presets predefinidos.
  static const List<EqPreset> allPresets = [
    normal,
    mild,
    moderate,
    severe,
    profound,
  ];

  @override
  List<Object?> get props => [name, gains];
}
