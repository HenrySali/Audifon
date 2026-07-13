/// @file iso17025_calibration.dart
/// @brief Procedimiento de calibración conforme ISO/IEC 17025 §7.6
///        (Type A uncertainty: mediciones repetidas + desviación estándar)
///        y ANSI S3.6 / ISO 389-7 para targets en dB SPL.
///
/// Flujo automático:
///   1) Por cada frecuencia, hacer N mediciones (default 3).
///   2) Promedio = mean(measurements).
///   3) Desviación estándar muestral σ = √(Σ(xᵢ-x̄)²/(n-1)).
///   4) Incertidumbre estándar Type A = σ/√n.
///   5) Incertidumbre expandida U (k=2, ~95% confianza) = 2 × σ/√n.
///   6) Offset de calibración = target_norma - promedio.
///   7) Reproducir tono con offset aplicado y medir 1 vez como validación.
///   8) Verdict: PASS si la validación cae dentro de tolerancia ±3 dB
///      AND la incertidumbre expandida U < 2 dB.

import 'dart:math' as math;

class FrequencyMeasurement {
  final double freqHz;
  final List<double> dbSplSamples;     // 3 mediciones (Phase 1).
  final List<double> dbFsSamples;      // mismas N mediciones en dBFS.
  final double targetDbSpl;            // de ISO 389-7 + nivel HL.
  final double toleranceDb;            // ANSI S3.6: ±3 dB ≤4kHz, ±5 dB >4kHz.
  final double? validationDbFs;        // Phase 2: medición post-corrección.
  final double? validationDbSpl;       // Phase 2: SPL inferido.

  const FrequencyMeasurement({
    required this.freqHz,
    required this.dbSplSamples,
    required this.dbFsSamples,
    required this.targetDbSpl,
    this.toleranceDb = 3.0,
    this.validationDbFs,
    this.validationDbSpl,
  });

  int get n => dbSplSamples.length;

  double get meanDbSpl =>
      dbSplSamples.fold<double>(0.0, (a, b) => a + b) / n;

  double get meanDbFs =>
      dbFsSamples.fold<double>(0.0, (a, b) => a + b) / n;

  /// Desviación estándar muestral (n-1 denominator, Bessel correction).
  double get stdDevDbSpl {
    if (n < 2) return 0.0;
    final m = meanDbSpl;
    final sumSq =
        dbSplSamples.fold<double>(0.0, (acc, x) => acc + (x - m) * (x - m));
    return math.sqrt(sumSq / (n - 1));
  }

  /// Incertidumbre estándar Type A (ISO 17025 §7.6, GUM).
  double get standardUncertainty => stdDevDbSpl / math.sqrt(n);

  /// Incertidumbre expandida k=2 (~95% confianza).
  double get expandedUncertainty => 2.0 * standardUncertainty;

  /// Offset que se debe aplicar al gain de salida para corregir.
  /// Si meanDbSpl = 65 y target = 70, offset = +5 (subir 5 dB).
  double get correctionOffsetDb => targetDbSpl - meanDbSpl;

  /// Diferencia entre validación post-corrección y target. Null si no hay validación.
  double? get validationErrorDb {
    final v = validationDbSpl;
    return v == null ? null : (v - targetDbSpl);
  }

  /// PASS final: validación post-corrección dentro de tolerancia AND U bajo.
  bool get isPass {
    final lowUncertainty = expandedUncertainty < 3.0;
    final v = validationErrorDb;
    if (v == null) {
      // Sin validación todavía: solo chequea que el offset esté en rango razonable
      // y la incertidumbre baja.
      return correctionOffsetDb.abs() <= 30.0 && lowUncertainty;
    }
    return v.abs() <= toleranceDb && lowUncertainty;
  }

  FrequencyMeasurement withValidation(double valDbFs, double valDbSpl) {
    return FrequencyMeasurement(
      freqHz: freqHz,
      dbSplSamples: dbSplSamples,
      dbFsSamples: dbFsSamples,
      targetDbSpl: targetDbSpl,
      toleranceDb: toleranceDb,
      validationDbFs: valDbFs,
      validationDbSpl: valDbSpl,
    );
  }

  Map<String, dynamic> toJson() => {
        'freq_hz': freqHz,
        'target_dbspl': targetDbSpl,
        'tolerance_db': toleranceDb,
        'samples_dbspl': dbSplSamples,
        'samples_dbfs': dbFsSamples,
        'n': n,
        'mean_dbspl': meanDbSpl,
        'mean_dbfs': meanDbFs,
        'std_dev_db': stdDevDbSpl,
        'standard_uncertainty_db': standardUncertainty,
        'expanded_uncertainty_db_k2': expandedUncertainty,
        'correction_offset_db': correctionOffsetDb,
        'validation_dbfs': validationDbFs,
        'validation_dbspl': validationDbSpl,
        'validation_error_db': validationErrorDb,
        'is_pass': isPass,
      };
}

class CalibrationProcedure {
  final DateTime timestamp;
  final List<FrequencyMeasurement> measurements;
  final double targetLevelHL;     // Nivel de prueba (ej. 70 dB HL).
  final String standardRef;        // "ISO 389-7 / ANSI S3.6 / ISO 17025"

  const CalibrationProcedure({
    required this.timestamp,
    required this.measurements,
    required this.targetLevelHL,
    this.standardRef = 'ISO 389-7:2019 + ANSI S3.6 + ISO/IEC 17025:2017',
  });

  bool get globalPass =>
      measurements.isNotEmpty && measurements.every((m) => m.isPass);

  Map<String, dynamic> toJson() => {
        'timestamp': timestamp.toIso8601String(),
        'standard_ref': standardRef,
        'target_level_hl': targetLevelHL,
        'global_pass': globalPass,
        'measurements': measurements.map((m) => m.toJson()).toList(),
      };
}
