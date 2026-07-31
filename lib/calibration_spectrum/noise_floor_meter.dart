/// @file noise_floor_meter.dart
/// @brief Mide el piso de ruido del ambiente antes de iniciar la secuencia.
///
/// Usa el `ToneAnalyzer` nativo en modo "sin frecuencia esperada":
/// configurado pero sin emitir tono y con expected_freq_hz = 0,
/// los snapshots reflejan solo el espectro del ambiente.
///
/// Polea durante 1 segundo (10 muestras a 10 Hz) y promedia en potencia.
///
/// REQ-1 del spec: rechaza si noise_floor_dbfs > -20 dB FS.

import 'dart:async';
import 'dart:math' as math;

import 'tone_method_channel.dart';

/// Resultado de la medición de piso de ruido.
class NoiseFloorResult {
  final double noiseFloorDbFs;
  final double noiseFloorAmplitudeLin;
  final bool isAcceptable; // true si <= -20 dB FS
  final String? rejectionReason;

  const NoiseFloorResult({
    required this.noiseFloorDbFs,
    required this.noiseFloorAmplitudeLin,
    required this.isAcceptable,
    this.rejectionReason,
  });
}

/// Medidor del piso de ruido.
class NoiseFloorMeter {
  final ToneMethodChannel _channel;
  final Duration _measurementDuration;
  final double _maxNoiseFloorDbFs;

  /// @param channel Canal nativo (default: instancia nueva).
  /// @param measurementDuration Duración (default 1 s).
  /// @param maxNoiseFloorDbFs Umbral de aceptación (default -20 dB FS, REQ-1.2).
  NoiseFloorMeter({
    ToneMethodChannel? channel,
    Duration measurementDuration = const Duration(seconds: 1),
    double maxNoiseFloorDbFs = -20.0,
  })  : _channel = channel ?? const ToneMethodChannel(),
        _measurementDuration = measurementDuration,
        _maxNoiseFloorDbFs = maxNoiseFloorDbFs;

  /// Mide el piso de ruido. Asume que el `ToneAnalyzer` ya está configurado
  /// y activo, y que NO hay tono emitido.
  Future<NoiseFloorResult> measure() async {
    // Asegurar que no estamos buscando un tono específico.
    await _channel.setExpectedFrequency(0.0);

    final samples = <double>[];
    const pollEvery = Duration(milliseconds: 100);
    final totalPolls = (_measurementDuration.inMilliseconds /
            pollEvery.inMilliseconds)
        .ceil();

    for (var i = 0; i < totalPolls; ++i) {
      await Future<void>.delayed(pollEvery);
      try {
        final snap = await _channel.getSnapshot();
        // Tomamos el "magnitud del pico" como proxy del nivel del ambiente:
        // sin tono presente, este valor refleja el ruido dominante.
        final dbfs = snap.peakMagnitudeDbfs;
        if (dbfs.isFinite) {
          samples.add(dbfs);
        }
      } catch (_) {
        // Snapshot inválido (por ejemplo el engine no inició aún): seguimos.
      }
    }

    if (samples.isEmpty) {
      return _invalidResult();
    }

    // Promediamos en potencia lineal y volvemos a dB.
    final powerSum = samples.fold<double>(0.0, (acc, dbfs) {
      final linPow = math.pow(10.0, dbfs / 10.0).toDouble();
      return acc + linPow;
    });
    final avgPower = powerSum / samples.length;
    if (avgPower <= 0 || !avgPower.isFinite) {
      return _invalidResult();
    }

    final avgDbfs = 10.0 * (math.log(avgPower) / math.ln10);
    final amplitudeLin = math.pow(10.0, avgDbfs / 20.0).toDouble();

    if (!avgDbfs.isFinite) {
      return _invalidResult();
    }

    final acceptable = avgDbfs <= _maxNoiseFloorDbFs;
    return NoiseFloorResult(
      noiseFloorDbFs: avgDbfs,
      noiseFloorAmplitudeLin: amplitudeLin,
      isAcceptable: acceptable,
      rejectionReason: acceptable
          ? null
          : 'ambiente ruidoso (${avgDbfs.toStringAsFixed(1)} dB FS), '
              'máximo permitido ${_maxNoiseFloorDbFs.toStringAsFixed(1)} dB FS',
    );
  }

  NoiseFloorResult _invalidResult() => const NoiseFloorResult(
        noiseFloorDbFs: double.nan,
        noiseFloorAmplitudeLin: 0.0,
        isAcceptable: false,
        rejectionReason: 'lectura inválida del micrófono',
      );
}
