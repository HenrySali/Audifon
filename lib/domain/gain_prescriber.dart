/// Motor de prescripción de ganancia para audífono digital.
///
/// Implementa prescripción NAL-NL2 simplificada basada en tabla de lookup,
/// con interpolación para valores intermedios de pérdida auditiva y
/// frecuencias intermedias del EQ de 12 bandas.
///
/// Requisitos: 2.3, 4.2, 4.3
library;

import 'dart:math';

import 'entities/audiogram.dart';

/// Resultado de prescripción con compensación de auricular aplicada.
class PrescriptionResult {
  /// Ganancias prescritas por NAL-NL2 (12 bandas, dB).
  final List<double> prescribedGains;

  /// Ganancias finales con compensación de auricular aplicada (12 bandas, dB).
  final List<double> finalGains;

  const PrescriptionResult({
    required this.prescribedGains,
    required this.finalGains,
  });
}

/// Motor de prescripción de ganancia NAL-NL2.
///
/// Calcula ganancias de inserción objetivo para las 12 bandas del EQ
/// basándose en el audiograma del paciente, usando la tabla de prescripción
/// NAL-NL2 simplificada para input de 65 dB SPL.
///
/// Soporta:
/// - Interpolación bilineal para valores de HL intermedios (entre filas de la tabla)
/// - Interpolación logarítmica para frecuencias intermedias (750, 1500, 2500, 3000, 3500 Hz)
/// - Compensación de auricular: finalGain[f] = prescribed[f] + compensation[f]
/// - Clamping a rango [0, 50] dB
///
/// Referencia: NAL-NL2 (Keidser et al., 2011)
class GainPrescriber {
  /// Frecuencias centrales de las 12 bandas del ecualizador (Hz).
  static const List<int> bandFrequencies = [
    250, 500, 750, 1000, 1500, 2000, 2500, 3000, 3500, 4000, 6000, 8000,
  ];

  /// Ganancia mínima permitida (dB).
  static const double minGainDb = 0.0;

  /// Ganancia máxima permitida (dB).
  static const double maxGainDb = 50.0;

  /// Frecuencias de referencia NAL-NL2 (columnas de la tabla).
  static const List<int> _nalFrequencies = [
    250, 500, 1000, 2000, 3000, 4000, 6000, 8000,
  ];

  /// Niveles de HL de referencia NAL-NL2 (filas de la tabla).
  static const List<double> _nalHlLevels = [
    20, 30, 40, 50, 60, 70, 80,
  ];

  /// Tabla de prescripción NAL-NL2 simplificada para input 65 dB SPL.
  ///
  /// Filas: HL levels [20, 30, 40, 50, 60, 70, 80]
  /// Columnas: frecuencias [250, 500, 1000, 2000, 3000, 4000, 6000, 8000]
  ///
  /// Fuente: NAL-NL2 (Keidser et al., 2011) — valores aproximados para
  /// adulto, oído derecho, primera vez. Niños: +3-5 dB adicionales.
  static const List<List<double>> _nalTable = [
    //  250  500  1k   2k   3k   4k   6k   8k
    [0, 2, 3, 5, 5, 4, 3, 2], // HL = 20
    [2, 4, 6, 9, 9, 8, 6, 5], // HL = 30
    [4, 7, 10, 14, 14, 12, 10, 8], // HL = 40
    [6, 10, 14, 18, 18, 16, 14, 11], // HL = 50
    [8, 13, 18, 23, 22, 20, 17, 14], // HL = 60
    [10, 16, 22, 27, 26, 24, 20, 17], // HL = 70
    [12, 19, 25, 30, 29, 27, 23, 19], // HL = 80
  ];

  /// Prescribe ganancias NAL-NL2 a partir de un [Audiogram].
  ///
  /// Retorna 12 valores de ganancia (dB) para las 12 bandas del EQ,
  /// con énfasis en 2-4 kHz para pérdida en frecuencias altas.
  /// Todas las ganancias están en el rango [0, 50] dB.
  ///
  /// Para frecuencias intermedias (750, 1500, 2500, 3000, 3500 Hz),
  /// se interpola entre las frecuencias NAL-NL2 adyacentes.
  ///
  /// Requisitos: 2.3, 4.2
  List<double> prescribeFromAudiogram(Audiogram audiogram) {
    final gains = <double>[];

    for (final freq in bandFrequencies) {
      // Obtener el umbral HL para esta frecuencia del audiograma
      final hl = _getThresholdFromAudiogram(audiogram, freq);

      // Calcular ganancia NAL-NL2 usando la tabla con interpolación
      final gain = _lookupNalGain(freq, hl);

      gains.add(_clampGain(gain));
    }

    return gains;
  }

  /// Prescribe ganancias y aplica compensación de auricular.
  ///
  /// Calcula la prescripción NAL-NL2 y luego aplica la compensación
  /// del auricular: `finalGain[f] = prescribed[f] + compensation[f]`,
  /// limitado al rango [0, 50] dB.
  ///
  /// [audiogram] Audiograma del usuario.
  /// [compensation] Mapa de frecuencia (Hz) a compensación (dB).
  ///   Valores positivos añaden ganancia, negativos la reducen.
  ///   Rango esperado: [-20, +20] dB por banda.
  ///
  /// Requisitos: 4.2, 4.3, Calibración de auriculares
  PrescriptionResult prescribeWithCompensation(
    Audiogram audiogram,
    Map<int, double> compensation,
  ) {
    final prescribed = prescribeFromAudiogram(audiogram);
    final finalGains = applyHeadphoneCompensation(prescribed, compensation);

    return PrescriptionResult(
      prescribedGains: prescribed,
      finalGains: finalGains,
    );
  }

  /// Aplica compensación de auricular a ganancias prescritas.
  ///
  /// Para cada banda: `finalGain[i] = prescribed[i] + compensation[freq_i]`,
  /// limitado al rango [0, 50] dB.
  ///
  /// [prescribedGains] Lista de 12 ganancias prescritas (dB).
  /// [compensation] Mapa de frecuencia (Hz) a compensación (dB).
  ///
  /// Retorna lista de 12 ganancias finales en [0, 50] dB.
  List<double> applyHeadphoneCompensation(
    List<double> prescribedGains,
    Map<int, double> compensation,
  ) {
    assert(prescribedGains.length == 12);

    final finalGains = <double>[];

    for (int i = 0; i < 12; i++) {
      final freq = bandFrequencies[i];
      final comp = compensation[freq] ?? 0.0;
      final gain = prescribedGains[i] + comp;
      finalGains.add(_clampGain(gain));
    }

    return finalGains;
  }

  /// Busca la ganancia NAL-NL2 para una frecuencia y nivel HL dados.
  ///
  /// Usa interpolación bilineal:
  /// 1. Interpola en HL (entre filas de la tabla) para las frecuencias
  ///    NAL-NL2 adyacentes a [freq].
  /// 2. Interpola en frecuencia (escala log) entre las dos frecuencias
  ///    NAL-NL2 adyacentes.
  ///
  /// Para HL < 20: extrapola linealmente desde las dos primeras filas.
  /// Para HL > 80: extrapola linealmente desde las dos últimas filas.
  double _lookupNalGain(int freq, double hl) {
    // Si la frecuencia es una de las frecuencias NAL-NL2 directas
    final freqIdx = _nalFrequencies.indexOf(freq);
    if (freqIdx >= 0) {
      return _interpolateHl(freqIdx, hl);
    }

    // Frecuencia intermedia: interpolar entre las dos frecuencias
    // NAL-NL2 adyacentes en escala logarítmica
    final neighbors = _findAdjacentFrequencies(freq);
    final lowerFreqIdx = neighbors[0];
    final upperFreqIdx = neighbors[1];

    final gainLower = _interpolateHl(lowerFreqIdx, hl);
    final gainUpper = _interpolateHl(upperFreqIdx, hl);

    // Interpolación logarítmica en frecuencia
    final logFreq = log(freq.toDouble()) / ln10;
    final logLower = log(_nalFrequencies[lowerFreqIdx].toDouble()) / ln10;
    final logUpper = log(_nalFrequencies[upperFreqIdx].toDouble()) / ln10;

    final ratio = (logFreq - logLower) / (logUpper - logLower);
    return gainLower + ratio * (gainUpper - gainLower);
  }

  /// Interpola la ganancia en la dimensión HL para una columna de frecuencia.
  ///
  /// [freqColIdx] Índice de la columna en la tabla NAL-NL2.
  /// [hl] Nivel de pérdida auditiva en dB HL.
  double _interpolateHl(int freqColIdx, double hl) {
    // Caso: HL <= primer nivel de la tabla (20 dB)
    if (hl <= _nalHlLevels.first) {
      // Extrapolar linealmente hacia abajo desde las dos primeras filas
      final g0 = _nalTable[0][freqColIdx];
      final g1 = _nalTable[1][freqColIdx];
      final hlStep = _nalHlLevels[1] - _nalHlLevels[0]; // 10
      final slope = (g1 - g0) / hlStep;
      return g0 + slope * (hl - _nalHlLevels[0]);
    }

    // Caso: HL >= último nivel de la tabla (80 dB)
    if (hl >= _nalHlLevels.last) {
      // Extrapolar linealmente hacia arriba desde las dos últimas filas
      final lastIdx = _nalHlLevels.length - 1;
      final gPrev = _nalTable[lastIdx - 1][freqColIdx];
      final gLast = _nalTable[lastIdx][freqColIdx];
      final hlStep = _nalHlLevels[lastIdx] - _nalHlLevels[lastIdx - 1]; // 10
      final slope = (gLast - gPrev) / hlStep;
      return gLast + slope * (hl - _nalHlLevels[lastIdx]);
    }

    // Caso: HL está entre dos filas de la tabla — interpolar linealmente
    for (int i = 0; i < _nalHlLevels.length - 1; i++) {
      if (hl >= _nalHlLevels[i] && hl <= _nalHlLevels[i + 1]) {
        final g0 = _nalTable[i][freqColIdx];
        final g1 = _nalTable[i + 1][freqColIdx];
        final ratio =
            (hl - _nalHlLevels[i]) / (_nalHlLevels[i + 1] - _nalHlLevels[i]);
        return g0 + ratio * (g1 - g0);
      }
    }

    // Fallback (no debería llegar aquí)
    return 0.0;
  }

  /// Encuentra los índices de las dos frecuencias NAL-NL2 adyacentes
  /// a [targetFreq].
  ///
  /// Retorna [lowerIdx, upperIdx] en la lista _nalFrequencies.
  List<int> _findAdjacentFrequencies(int targetFreq) {
    for (int i = 0; i < _nalFrequencies.length - 1; i++) {
      if (targetFreq >= _nalFrequencies[i] &&
          targetFreq <= _nalFrequencies[i + 1]) {
        return [i, i + 1];
      }
    }
    // Si está por debajo del rango, usar las dos primeras
    if (targetFreq < _nalFrequencies.first) {
      return [0, 1];
    }
    // Si está por encima del rango, usar las dos últimas
    return [_nalFrequencies.length - 2, _nalFrequencies.length - 1];
  }

  /// Obtiene el umbral HL de un [Audiogram] para una frecuencia dada.
  ///
  /// Si la frecuencia exacta existe en el audiograma, la retorna directamente.
  /// Si no, interpola linealmente en escala log-frecuencia entre los puntos
  /// adyacentes del audiograma.
  double _getThresholdFromAudiogram(Audiogram audiogram, int targetFreq) {
    // Coincidencia exacta
    if (audiogram.thresholds.containsKey(targetFreq)) {
      return audiogram.thresholds[targetFreq]!;
    }

    // Interpolar entre frecuencias adyacentes del audiograma
    final sortedFreqs = audiogram.thresholds.keys.toList()..sort();

    if (sortedFreqs.isEmpty) return 0.0;
    if (targetFreq <= sortedFreqs.first) {
      return audiogram.thresholds[sortedFreqs.first]!;
    }
    if (targetFreq >= sortedFreqs.last) {
      return audiogram.thresholds[sortedFreqs.last]!;
    }

    for (int i = 0; i < sortedFreqs.length - 1; i++) {
      if (sortedFreqs[i] <= targetFreq && sortedFreqs[i + 1] >= targetFreq) {
        final f1 = sortedFreqs[i].toDouble();
        final f2 = sortedFreqs[i + 1].toDouble();
        final t1 = audiogram.thresholds[sortedFreqs[i]]!;
        final t2 = audiogram.thresholds[sortedFreqs[i + 1]]!;

        // Interpolación lineal en escala log-frecuencia
        final logF1 = log(f1) / ln10;
        final logF2 = log(f2) / ln10;
        final logTarget = log(targetFreq.toDouble()) / ln10;

        final ratio = (logTarget - logF1) / (logF2 - logF1);
        return t1 + ratio * (t2 - t1);
      }
    }

    return 0.0;
  }

  /// Limita la ganancia al rango permitido [0, 50] dB.
  double _clampGain(double gain) {
    return gain.clamp(minGainDb, maxGainDb);
  }
}
