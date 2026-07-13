/// @file catch_trial_stats.dart
/// @brief Estadísticas de catch trials de un sujeto.
///
/// Los catch trials son presentaciones silenciosas (sin tono) usadas para
/// detectar respuestas falsas positivas (sujetos que dicen "lo escucho" sin
/// haber escuchado nada). Si la tasa de falsos positivos supera 33% (1/3),
/// la sesión se considera no válida.
///
/// Referencias: design.md §6, Requirement 2.7-2.8.

/// Estadísticas agregadas de los catch trials aplicados a un sujeto.
class CatchTrialStats {
  /// Cantidad total de catch trials presentados al sujeto.
  final int total;

  /// Cantidad de catch trials respondidos como positivos (falsos positivos).
  final int falsePositives;

  const CatchTrialStats({
    required this.total,
    required this.falsePositives,
  });

  /// Tasa de falsos positivos en [0.0, 1.0]. Si no hubo catch trials
  /// presentados (`total == 0`), la tasa se define como 0.0.
  double get rate => total == 0 ? 0.0 : falsePositives / total;

  /// La sesión es válida cuando la tasa de falsos positivos no supera 33%.
  bool get valid => rate <= 0.33;

  Map<String, dynamic> toJson() => {
        'total': total,
        'false_positives': falsePositives,
        'rate': rate,
      };

  factory CatchTrialStats.fromJson(Map<String, dynamic> j) {
    return CatchTrialStats(
      total: (j['total'] as num).toInt(),
      falsePositives: (j['false_positives'] as num).toInt(),
    );
  }
}
