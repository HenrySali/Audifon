/// Módulo CIN — Comfort in Noise.
///
/// Transforma ganancias core para reducir fatiga auditiva en ambientes
/// ruidosos, preservando la banda de habla (500–4000 Hz).
///
/// El módulo es una función pura: mismos inputs → mismos outputs, sin
/// estado mutable ni dependencias externas.
///
/// Las 12 frecuencias estándar del EQ son:
/// [250, 500, 750, 1000, 1500, 2000, 2500, 3000, 3500, 4000, 6000, 8000] Hz.
///
/// Bandas no-speech: 250 Hz (índice 0), 6000 Hz (índice 10), 8000 Hz (índice 11).
/// Banda de habla: 500–4000 Hz (índices 1–9).
///
/// Requisitos: 3.1, 3.2, 3.3, 3.4, 3.5, 3.6, 3.7
library;

import 'dart:math';

import 'entities/wdrc_params.dart';

/// Resultado del módulo CIN.
///
/// Contiene las ganancias modificadas para confort en ruido,
/// los ratios de compresión ajustados y los overrides WDRC.
class CinResult {
  /// Ganancias modificadas por CIN (12 valores en [0, 50] dB).
  final List<double> gains;

  /// Ratios de compresión ajustados (12 valores en [1.0, 3.0]).
  final List<double> compressionRatios;

  /// Parámetros WDRC override: attack=10ms, release=150ms.
  final WdrcParams wdrcOverrides;

  const CinResult({
    required this.gains,
    required this.compressionRatios,
    required this.wdrcOverrides,
  });
}

/// Módulo CIN — Comfort in Noise.
///
/// Reduce selectivamente la ganancia en bandas no-speech para disminuir
/// la fatiga auditiva en ambientes ruidosos, manteniendo la inteligibilidad
/// en la banda de habla (500–4000 Hz).
///
/// Uso:
/// ```dart
/// final cinResult = CinModule.apply(coreGains, coreCompressionRatios);
/// ```
///
/// Requisitos: 3.1, 3.2, 3.3, 3.4, 3.5, 3.6, 3.7
abstract class CinModule {
  /// Índices de las bandas no-speech en el array de 12 frecuencias.
  /// 250 Hz (índice 0), 6000 Hz (índice 10), 8000 Hz (índice 11).
  static const List<int> _nonSpeechIndices = [0, 10, 11];

  /// Ganancia mínima permitida (dB).
  static const double _minGainDb = 0.0;

  /// Ganancia máxima permitida (dB).
  static const double _maxGainDb = 50.0;

  /// Reducción mínima en bandas no-speech (dB).
  static const double _minReduction = 3.0;

  /// Reducción máxima en bandas no-speech (dB).
  static const double _maxReduction = 6.0;

  /// Máxima reducción total broadband permitida (dB).
  static const double _maxBroadbandReduction = 6.0;

  /// Aplica reducción CIN a las ganancias core.
  ///
  /// Reduce ganancia 3–6 dB en bandas no-speech (250, 6000, 8000 Hz),
  /// proporcional al nivel de ganancia core (mayor ganancia → mayor
  /// reducción, hasta 6 dB). Preserva la banda de habla (500–4000 Hz)
  /// dentro de ±1 dB de los valores core.
  ///
  /// [coreGains] Ganancias prescritas en modo quiet (12 valores).
  /// [coreCompressionRatios] Ratios de compresión en modo quiet (12 valores).
  ///
  /// Retorna [CinResult] con ganancias y ratios modificados para
  /// confort en ruido, más los overrides WDRC (attack=10ms, release=150ms).
  ///
  /// Requisitos: 3.1, 3.2, 3.3, 3.4, 3.5, 3.6, 3.7
  static CinResult apply(
    List<double> coreGains,
    List<double> coreCompressionRatios,
  ) {
    assert(coreGains.length == 12, 'Se requieren exactamente 12 ganancias.');
    assert(
      coreCompressionRatios.length == 12,
      'Se requieren exactamente 12 ratios de compresión.',
    );

    final modifiedGains = List<double>.from(coreGains);

    // Reducir ganancia en bandas no-speech proporcionalmente.
    // Mayor ganancia core → mayor reducción (hasta 6 dB).
    for (final idx in _nonSpeechIndices) {
      final reduction = _computeReduction(coreGains[idx]);
      modifiedGains[idx] = coreGains[idx] - reduction;
    }

    // Verificar que la reducción total broadband no exceda 6 dB.
    // La reducción broadband se calcula como el promedio de todas las reducciones.
    _enforceBroadbandLimit(modifiedGains, coreGains);

    // Clamp todas las ganancias a [0, 50] dB.
    for (int i = 0; i < 12; i++) {
      modifiedGains[i] = modifiedGains[i].clamp(_minGainDb, _maxGainDb);
    }

    // Ratios de compresión: reducir 0.2 con piso en 1.0.
    final modifiedRatios = coreCompressionRatios
        .map((r) => max(1.0, r - 0.2))
        .toList();

    // WDRC overrides para CIN: attack=10ms, release=150ms.
    const wdrcOverrides = WdrcParams(attackMs: 10.0, releaseMs: 150.0);

    return CinResult(
      gains: modifiedGains,
      compressionRatios: modifiedRatios,
      wdrcOverrides: wdrcOverrides,
    );
  }

  /// Calcula la reducción proporcional para una banda no-speech.
  ///
  /// La reducción es proporcional a la ganancia core:
  /// - Ganancias bajas (≤ _minReduction): reducción mínima de 3 dB.
  /// - Ganancias altas (≥ _maxGainDb): reducción máxima de 6 dB.
  /// - Intermedias: interpolación lineal entre 3 y 6 dB.
  ///
  /// [coreGain] Ganancia core en la banda no-speech (dB).
  /// Retorna reducción en dB, en el rango [3, 6].
  static double _computeReduction(double coreGain) {
    if (coreGain <= 0) {
      // Si la ganancia es 0 o negativa, aplicar reducción mínima.
      return _minReduction;
    }

    // Interpolación lineal: de 3 dB (gain=0) a 6 dB (gain=50).
    // reduction = 3 + (gain / 50) * 3
    final normalized = (coreGain / _maxGainDb).clamp(0.0, 1.0);
    return _minReduction + normalized * (_maxReduction - _minReduction);
  }

  /// Asegura que la reducción total broadband no exceda 6 dB.
  ///
  /// Si la suma de reducciones promediada supera el límite, se escalan
  /// proporcionalmente las reducciones en bandas no-speech.
  ///
  /// [modifiedGains] Ganancias ya modificadas (se mutan in-place).
  /// [coreGains] Ganancias core originales para referencia.
  static void _enforceBroadbandLimit(
    List<double> modifiedGains,
    List<double> coreGains,
  ) {
    // Calcular la reducción total (suma de diferencias en todas las bandas).
    double totalReduction = 0.0;
    for (int i = 0; i < 12; i++) {
      totalReduction += (coreGains[i] - modifiedGains[i]);
    }

    // Reducción broadband promedio = total / 12.
    final avgReduction = totalReduction / 12.0;

    // Si la reducción promedio excede el límite, escalar las reducciones.
    if (avgReduction > _maxBroadbandReduction) {
      final scaleFactor = _maxBroadbandReduction / avgReduction;
      for (final idx in _nonSpeechIndices) {
        final originalReduction = coreGains[idx] - modifiedGains[idx];
        final scaledReduction = originalReduction * scaleFactor;
        modifiedGains[idx] = coreGains[idx] - scaledReduction;
      }
    }
  }
}
