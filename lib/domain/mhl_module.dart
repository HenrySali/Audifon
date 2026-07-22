/// Módulo MHL — Minimal Hearing Loss.
///
/// Prescribe ganancia mínima flat para activar features de reducción de ruido
/// en pacientes con audiograma normal o pérdida mínima. El modo MHL aplica
/// amplificación lineal (compresión 1.0:1) con nivel máximo de reducción
/// de ruido, priorizando mejora de SNR sobre amplificación.
///
/// Requisitos: 4.1, 4.2, 4.3, 4.4, 4.5, 4.6
library;

import 'entities/audiogram.dart';

/// Resultado del módulo MHL.
///
/// Contiene las ganancias prescritas (flat, en [5, 10] dB), ratios de
/// compresión (lineales, 1.0:1), nivel de reducción de ruido y flag de
/// advertencia PTA para pacientes que podrían beneficiarse de un modo
/// de prescripción estándar.
class MhlResult {
  /// Ganancias prescritas (12 valores iguales en [5, 10] dB).
  final List<double> gains;

  /// Ratios de compresión (12 valores = 1.0, amplificación lineal).
  final List<double> compressionRatios;

  /// Nivel de reducción de ruido (3 = máximo).
  final int noiseReductionLevel;

  /// Indica si el PTA del paciente supera 25 dB HL.
  /// En ese caso se recomienda un modo de prescripción estándar.
  final bool ptaWarning;

  /// PTA (Pure Tone Average) calculado a partir de 500, 1000, 2000, 4000 Hz.
  final double pta;

  const MhlResult({
    required this.gains,
    required this.compressionRatios,
    required this.noiseReductionLevel,
    required this.ptaWarning,
    required this.pta,
  });
}

/// Módulo MHL — Minimal Hearing Loss.
///
/// Clase estática que prescribe ganancia mínima flat para pacientes con
/// audiograma normal que reportan dificultad en ruido. La amplificación
/// mínima habilita los algoritmos de reducción de ruido del pipeline DSP
/// sin alterar significativamente la percepción del nivel sonoro.
///
/// Ejemplo de uso:
/// ```dart
/// final result = MhlModule.prescribe(audiogram, mhlGainDb: 8.0);
/// print(result.gains); // [8.0, 8.0, ..., 8.0] (12 valores)
/// print(result.ptaWarning); // false si PTA <= 25 dB
/// ```
///
/// Requisitos: 4.1, 4.2, 4.3, 4.4
abstract class MhlModule {
  /// Número de bandas del ecualizador (frecuencias estándar).
  static const int _bandCount = 12;

  /// Ganancia mínima permitida en modo MHL (dB).
  static const double _minGainDb = 5.0;

  /// Ganancia máxima permitida en modo MHL (dB).
  static const double _maxGainDb = 10.0;

  /// Umbral de PTA para emitir advertencia (dB HL).
  static const double _ptaWarningThreshold = 25.0;

  /// Nivel máximo de reducción de ruido del pipeline DSP.
  static const int _maxNoiseReductionLevel = 3;

  /// Frecuencias usadas para calcular el PTA (Hz).
  static const List<int> _ptaFrequencies = [500, 1000, 2000, 4000];

  /// Prescribe ganancia MHL (flat en [5, 10] dB, compresión 1.0:1).
  ///
  /// Calcula una prescripción de ganancia plana (igual en las 12 bandas)
  /// con compresión lineal y reducción de ruido al máximo. El modo MHL
  /// está diseñado para pacientes con audiograma normal que necesitan
  /// mejora de SNR en ambientes ruidosos.
  ///
  /// [audiogram] Se usa para calcular el PTA y determinar si corresponde
  ///   emitir una advertencia de que el paciente podría beneficiarse de
  ///   un modo de prescripción estándar (quiet o CIN).
  /// [mhlGainDb] Ganancia flat deseada en dB. Default: 8.0 dB.
  ///   Se clampea al rango [5, 10] si está fuera de rango.
  ///
  /// Retorna [MhlResult] con las 12 ganancias iguales, ratios de
  /// compresión lineales (1.0), nivel de NR máximo y flag de PTA.
  static MhlResult prescribe(
    Audiogram audiogram, {
    double mhlGainDb = 8.0,
  }) {
    // Clampear la ganancia solicitada al rango válido [5, 10] dB.
    final clampedGain = mhlGainDb.clamp(_minGainDb, _maxGainDb);

    // Generar ganancia flat: misma ganancia en las 12 bandas.
    final gains = List<double>.filled(_bandCount, clampedGain);

    // Compresión lineal (1.0:1) en todas las bandas.
    final compressionRatios = List<double>.filled(_bandCount, 1.0);

    // Calcular PTA (promedio de umbrales en 500, 1000, 2000, 4000 Hz).
    final pta = _calculatePTA(audiogram);

    // Emitir advertencia si el PTA indica que la pérdida no es mínima.
    final ptaWarning = pta > _ptaWarningThreshold;

    return MhlResult(
      gains: gains,
      compressionRatios: compressionRatios,
      noiseReductionLevel: _maxNoiseReductionLevel,
      ptaWarning: ptaWarning,
      pta: pta,
    );
  }

  /// Calcula el PTA (Pure Tone Average) a partir del audiograma.
  ///
  /// Promedia los umbrales en 500, 1000, 2000 y 4000 Hz. Si alguna
  /// de esas frecuencias falta en el audiograma, se excluye del promedio.
  /// Si ninguna frecuencia PTA está presente, retorna 0.0.
  static double _calculatePTA(Audiogram audiogram) {
    double sum = 0.0;
    int count = 0;

    for (final freq in _ptaFrequencies) {
      final threshold = audiogram.thresholds[freq];
      if (threshold != null) {
        sum += threshold;
        count++;
      }
    }

    if (count == 0) return 0.0;
    return sum / count;
  }
}
