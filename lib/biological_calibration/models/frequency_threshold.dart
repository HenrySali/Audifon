/// @file frequency_threshold.dart
/// @brief Umbral promediado por frecuencia con estadística de calidad.
///
/// Agrega los umbrales individuales de N sujetos (N >= 1) en una sola
/// frecuencia. Calcula la media, la desviación estándar muestral, la
/// dispersión (max - min), y deriva un nivel de confianza categórico:
///
///   - high   : spread <= 5 dB  (sujetos consistentes)
///   - medium : spread <= 10 dB (variabilidad aceptable)
///   - low    : spread > 10 dB  (advertir al operador)
///
/// El "máximo HL alcanzable" se calcula como `-1.0 - meanThresholdDbFS` y
/// representa el nivel HL más alto que el dispositivo puede emitir sin pasar
/// el techo digital de -1 dBFS (margen anti-clipping).
///
/// Referencias: design.md §6 y §"Algoritmo de promediado final".

import 'dart:math' as math;

/// Niveles de confianza posibles para un umbral promediado.
class ThresholdConfidence {
  static const String high = 'high';
  static const String medium = 'medium';
  static const String low = 'low';

  /// Evita instanciación. Solo es un namespace de constantes.
  ThresholdConfidence._();
}

/// Umbral promediado en una frecuencia (Hz) con estadísticas asociadas.
class FrequencyThreshold {
  /// Frecuencia en Hz (250, 500, 1000, 2000, 4000, 8000, ...).
  final int freqHz;

  /// Umbral promedio en dBFS (negativo, ej: -50.0).
  final double meanThresholdDbFS;

  /// Desviación estándar muestral en dB.
  final double stdDb;

  /// Dispersión (max - min) de los valores individuales en dB.
  final double spreadDb;

  /// Valores individuales que se promediaron (uno por sujeto válido).
  final List<double> individualValues;

  /// Máximo nivel HL emitible sin clipear: `-1.0 - meanThresholdDbFS`.
  final double maxHLAchievable;

  /// 'high' | 'medium' | 'low' según `spreadDb`.
  final String confidence;

  const FrequencyThreshold({
    required this.freqHz,
    required this.meanThresholdDbFS,
    required this.stdDb,
    required this.spreadDb,
    required this.individualValues,
    required this.maxHLAchievable,
    required this.confidence,
  });

  /// Construye un `FrequencyThreshold` calculando todas las estadísticas a
  /// partir de los valores individuales.
  ///
  /// Lanza [ArgumentError] si `values` está vacío.
  factory FrequencyThreshold.compute({
    required int freqHz,
    required List<double> values,
  }) {
    if (values.isEmpty) {
      throw ArgumentError.value(
        values,
        'values',
        'No se puede calcular un umbral con lista vacía',
      );
    }

    final n = values.length;
    final mean = values.reduce((a, b) => a + b) / n;

    double std;
    if (n < 2) {
      std = 0.0;
    } else {
      double sumSq = 0.0;
      for (final v in values) {
        final d = v - mean;
        sumSq += d * d;
      }
      // Desviación estándar muestral (n-1) — convención metrológica.
      std = math.sqrt(sumSq / (n - 1));
    }

    final maxV = values.reduce(math.max);
    final minV = values.reduce(math.min);
    final spread = maxV - minV;

    final String confidence;
    if (spread <= 5.0) {
      confidence = ThresholdConfidence.high;
    } else if (spread <= 10.0) {
      confidence = ThresholdConfidence.medium;
    } else {
      confidence = ThresholdConfidence.low;
    }

    final maxHL = -1.0 - mean;

    return FrequencyThreshold(
      freqHz: freqHz,
      meanThresholdDbFS: mean,
      stdDb: std,
      spreadDb: spread,
      individualValues: List<double>.unmodifiable(values),
      maxHLAchievable: maxHL,
      confidence: confidence,
    );
  }

  Map<String, dynamic> toJson() => {
        'freq_hz': freqHz,
        'mean_threshold_dBFS': meanThresholdDbFS,
        'std_dB': stdDb,
        'spread_dB': spreadDb,
        'individual_values': individualValues,
        'max_HL_achievable': maxHLAchievable,
        'confidence': confidence,
      };

  factory FrequencyThreshold.fromJson(Map<String, dynamic> j) {
    final raw = (j['individual_values'] as List?) ?? const <dynamic>[];
    final values = raw.map((e) => (e as num).toDouble()).toList();
    return FrequencyThreshold(
      freqHz: (j['freq_hz'] as num).toInt(),
      meanThresholdDbFS: (j['mean_threshold_dBFS'] as num).toDouble(),
      stdDb: (j['std_dB'] as num).toDouble(),
      spreadDb: (j['spread_dB'] as num).toDouble(),
      individualValues: List<double>.unmodifiable(values),
      maxHLAchievable: (j['max_HL_achievable'] as num).toDouble(),
      confidence: j['confidence'] as String,
    );
  }
}
