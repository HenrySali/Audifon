/// Clasificación de forma de audiograma y clasificador estático.
///
/// Define el enum [LossType] con los tipos de pérdida auditiva
/// reconocidos y la clase estática [AudiogramClassifier] que analiza
/// un audiograma de 12 frecuencias para determinar su forma.
///
/// Requisitos: 1.1, 1.2, 1.3, 1.4, 1.5, 1.6, 1.7, 1.8, 8.3
library;

import 'audiogram.dart';

/// Tipo de pérdida auditiva clasificada por forma del audiograma.
///
/// Cada valor representa un patrón reconocido de la curva audiométrica.
/// La clasificación se usa para aplicar correcciones específicas al
/// prescriptor NL3-inspired.
enum LossType {
  /// Pérdida plana: sin diferencias significativas entre bandas.
  flat,

  /// Pérdida descendente: umbrales altos en frecuencias agudas.
  sloping,

  /// Pérdida ascendente (pendiente inversa): peor en graves que en agudos.
  reverseSlope,

  /// Pérdida en forma de "galletita": peor en medios que en extremos.
  cookieBite,

  /// Muesca (notch): caída abrupta en una sola frecuencia (3k–6k Hz).
  notch,

  /// Componente conductivo: gap aire-hueso significativo (≥ 2 frecuencias).
  mixed,
}

/// Clasificador de forma de audiograma.
///
/// Función pura que analiza los 12 umbrales de un [Audiogram] y retorna
/// exactamente un [LossType]. No tiene estado interno ni efectos secundarios.
///
/// Prioridad de clasificación:
/// mixed > notch > cookie_bite > reverse_slope > sloping > flat.
///
/// Requisitos: 1.1, 1.2, 1.3, 1.4, 1.5, 1.6, 1.7, 1.8, 8.3
abstract class AudiogramClassifier {
  /// Frecuencias de la banda baja para cálculo de promedio.
  static const List<int> _lowFrequencies = [250, 500, 750, 1000];

  /// Frecuencias de la banda media para cálculo de promedio.
  static const List<int> _midFrequencies = [1500, 2000, 2500, 3000];

  /// Frecuencias de la banda alta para cálculo de promedio.
  static const List<int> _highFrequencies = [3500, 4000, 6000, 8000];

  /// Frecuencias donde se busca una muesca (notch): 3000–6000 Hz.
  static const List<int> _notchCandidateFrequencies = [3000, 3500, 4000, 6000];

  /// Umbral de diferencia para clasificación sloping (dB).
  static const double _slopingThreshold = 20.0;

  /// Umbral de diferencia para clasificación reverse slope (dB).
  static const double _reverseSlopeThreshold = 15.0;

  /// Umbral de diferencia para clasificación cookie bite (dB).
  static const double _cookieBiteThreshold = 15.0;

  /// Umbral de prominencia para detección de notch (dB).
  static const double _notchProminence = 15.0;

  /// Umbral de air-bone gap para componente conductivo (dB).
  static const double _airBoneGapThreshold = 10.0;

  /// Mínimo de frecuencias con air-bone gap para clasificar como mixed.
  static const int _minMixedFrequencies = 2;

  /// Clasifica el audiograma en un tipo de pérdida auditiva.
  ///
  /// [audiogram] debe tener exactamente 12 umbrales en las frecuencias
  /// estándar [250, 500, 750, 1000, 1500, 2000, 2500, 3000, 3500, 4000,
  /// 6000, 8000] Hz.
  ///
  /// [boneConduction] audiograma de conducción ósea opcional. Mapa de
  /// frecuencia (Hz) a umbral (dB HL). Se usa para detectar componente
  /// conductivo (mixed). Si es nulo, no se evalúa mixed.
  ///
  /// Retorna exactamente un [LossType] del conjunto
  /// {flat, sloping, reverseSlope, cookieBite, notch, mixed}.
  ///
  /// Throws [ArgumentError] si el audiograma es nulo, vacío o incompleto
  /// (menos de 12 frecuencias estándar).
  ///
  /// Ejemplo:
  /// ```dart
  /// final audiogram = Audiogram(thresholds: {...});
  /// final lossType = AudiogramClassifier.classify(audiogram);
  /// ```
  static LossType classify(
    Audiogram audiogram, {
    Map<int, double>? boneConduction,
  }) {
    // Validar que el audiograma tenga los 12 umbrales requeridos.
    _validateAudiogram(audiogram);

    // Calcular promedios por banda frecuencial.
    final avgLow = _calculateAvgLow(audiogram);
    final avgMid = _calculateAvgMid(audiogram);
    final avgHigh = _calculateAvgHigh(audiogram);

    // Prioridad 1: Mixed (componente conductivo)
    if (_hasMixedComponent(audiogram, boneConduction)) {
      return LossType.mixed;
    }

    // Prioridad 2: Notch (muesca en 3k–6k Hz)
    if (_hasNotch(audiogram)) {
      return LossType.notch;
    }

    // Prioridad 3: Cookie bite (peor en medios que en extremos)
    if (avgMid > avgLow + _cookieBiteThreshold &&
        avgMid > avgHigh + _cookieBiteThreshold) {
      return LossType.cookieBite;
    }

    // Prioridad 4: Reverse slope (peor en graves que en agudos)
    if (avgLow > avgHigh + _reverseSlopeThreshold) {
      return LossType.reverseSlope;
    }

    // Prioridad 5: Sloping (peor en agudos que en graves)
    if (avgHigh > avgLow + _slopingThreshold) {
      return LossType.sloping;
    }

    // Default: Flat (sin diferencias significativas)
    return LossType.flat;
  }

  /// Valida que el audiograma contenga las 12 frecuencias estándar.
  ///
  /// Throws [ArgumentError] si está vacío o incompleto.
  static void _validateAudiogram(Audiogram audiogram) {
    if (audiogram.thresholds.isEmpty) {
      throw ArgumentError(
        'Audiograma vacío o nulo: se requieren 12 umbrales.',
      );
    }

    final requiredFreqs = Audiogram.standardFrequencies;
    final missingCount =
        requiredFreqs.where((f) => !audiogram.thresholds.containsKey(f)).length;

    if (missingCount > 0) {
      final foundCount = requiredFreqs.length - missingCount;
      throw ArgumentError(
        'Audiograma incompleto: se encontraron $foundCount de 12 frecuencias requeridas.',
      );
    }
  }

  /// Calcula el promedio de umbrales en frecuencias bajas (250–1000 Hz).
  static double _calculateAvgLow(Audiogram audiogram) {
    return _averageThresholds(audiogram, _lowFrequencies);
  }

  /// Calcula el promedio de umbrales en frecuencias medias (1500–3000 Hz).
  static double _calculateAvgMid(Audiogram audiogram) {
    return _averageThresholds(audiogram, _midFrequencies);
  }

  /// Calcula el promedio de umbrales en frecuencias altas (3500–8000 Hz).
  static double _calculateAvgHigh(Audiogram audiogram) {
    return _averageThresholds(audiogram, _highFrequencies);
  }

  /// Calcula el promedio de umbrales para un grupo de frecuencias.
  static double _averageThresholds(Audiogram audiogram, List<int> frequencies) {
    double sum = 0.0;
    for (final freq in frequencies) {
      sum += audiogram.thresholds[freq]!;
    }
    return sum / frequencies.length;
  }

  /// Detecta componente conductivo (mixed).
  ///
  /// Retorna true si hay air-bone gap > 10 dB en 2 o más frecuencias.
  /// Si [boneConduction] es nulo, no se puede evaluar → retorna false.
  static bool _hasMixedComponent(
    Audiogram audiogram,
    Map<int, double>? boneConduction,
  ) {
    if (boneConduction == null || boneConduction.isEmpty) {
      return false;
    }

    int gapCount = 0;
    for (final entry in boneConduction.entries) {
      final freq = entry.key;
      final boneThreshold = entry.value;
      final airThreshold = audiogram.thresholds[freq];

      if (airThreshold == null) continue;

      final gap = airThreshold - boneThreshold;
      if (gap > _airBoneGapThreshold) {
        gapCount++;
      }
    }

    return gapCount >= _minMixedFrequencies;
  }

  /// Detecta muesca (notch) en el rango 3000–6000 Hz.
  ///
  /// Retorna true si alguna frecuencia candidata tiene un umbral que
  /// excede el promedio de sus dos frecuencias adyacentes por 15 dB o más.
  static bool _hasNotch(Audiogram audiogram) {
    final sortedFreqs = Audiogram.standardFrequencies;

    for (final freq in _notchCandidateFrequencies) {
      final freqIdx = sortedFreqs.indexOf(freq);
      if (freqIdx <= 0 || freqIdx >= sortedFreqs.length - 1) continue;

      final threshold = audiogram.thresholds[freq]!;
      final prevThreshold = audiogram.thresholds[sortedFreqs[freqIdx - 1]]!;
      final nextThreshold = audiogram.thresholds[sortedFreqs[freqIdx + 1]]!;

      final adjacentAvg = (prevThreshold + nextThreshold) / 2.0;

      if (threshold - adjacentAvg >= _notchProminence) {
        return true;
      }
    }

    return false;
  }
}
