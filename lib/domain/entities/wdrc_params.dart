import 'package:equatable/equatable.dart';

/// Parámetros del compresor WDRC (Wide Dynamic Range Compression).
///
/// Modelo de 3 regiones:
/// - Expansión: input < expansionKnee → atenúa ruido
/// - Lineal: expansionKnee ≤ input ≤ compressionKnee → ganancia completa
/// - Compresión: input > compressionKnee → protege de sonidos fuertes
class WdrcParams extends Equatable {
  /// Knee de expansión en dB SPL (default: 35).
  /// Señales por debajo de este nivel se atenúan.
  final double expansionKnee;

  /// Ratio de expansión input:output (default: 2.0).
  /// Ratio 2:1 significa que por cada 2 dB de reducción de input,
  /// la salida se reduce 1 dB adicional.
  final double expansionRatio;

  /// Knee de compresión en dB SPL (default: 55).
  /// Señales por encima de este nivel se comprimen.
  final double compressionKnee;

  /// Ratio de compresión input:output (default: 2.0).
  /// Ratio 2:1 significa que un incremento de 2 dB en input
  /// produce solo 1 dB de incremento en output.
  final double compressionRatio;

  /// Tiempo de ataque en ms (default: 5).
  /// Qué tan rápido el compresor reacciona a incrementos de nivel.
  final double attackMs;

  /// Tiempo de liberación en ms (default: 100).
  /// Qué tan rápido el compresor vuelve a ganancia unitaria.
  final double releaseMs;

  const WdrcParams({
    this.expansionKnee = 35.0,
    this.expansionRatio = 2.0,
    this.compressionKnee = 55.0,
    this.compressionRatio = 2.0,
    this.attackMs = 5.0,
    this.releaseMs = 100.0,
  });

  @override
  List<Object?> get props => [
        expansionKnee,
        expansionRatio,
        compressionKnee,
        compressionRatio,
        attackMs,
        releaseMs,
      ];
}
