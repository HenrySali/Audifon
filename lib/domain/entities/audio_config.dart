import 'package:equatable/equatable.dart';

import 'wdrc_params.dart';

/// Configuración completa del motor de audio DSP.
///
/// Contiene todos los parámetros necesarios para iniciar y configurar
/// el pipeline de procesamiento de audio nativo:
/// - Parámetros de captura (sampleRate, bufferSize, channels, bitsPerSample)
/// - Ganancias del EQ de 12 bandas
/// - Volumen maestro
/// - Parámetros WDRC
/// - Nivel de reducción de ruido
/// - Threshold del MPO
///
/// Requisitos: 1.1, 2.1, 2.2
class AudioConfig extends Equatable {
  /// Frecuencia de muestreo en Hz (48000 Hz nativo para Oboe).
  final int sampleRate;

  /// Tamaño del buffer en muestras (256 = ~5.3 ms a 48 kHz).
  final int bufferSize;

  /// Número de canales (1 = mono).
  final int channels;

  /// Bits por muestra (16 = PCM16).
  final int bitsPerSample;

  /// Ganancias del ecualizador de 12 bandas en dB [0, 50].
  /// Orden: 250, 500, 750, 1000, 1500, 2000, 2500, 3000, 3500, 4000, 6000, 8000 Hz.
  final List<double> eqGains;

  /// Volumen maestro en dB [-20, +10].
  final double volumeDb;

  /// Parámetros del compresor WDRC.
  final WdrcParams wdrcParams;

  /// Nivel de reducción de ruido: 0=off, 1=bajo, 2=medio, 3=alto.
  final int nrLevel;

  /// Threshold del limitador MPO en dB SPL (default: 100).
  final double mpoThresholdDbSpl;

  const AudioConfig({
    this.sampleRate = 48000,
    this.bufferSize = 256,
    this.channels = 1,
    this.bitsPerSample = 16,
    required this.eqGains,
    required this.volumeDb,
    required this.wdrcParams,
    required this.nrLevel,
    this.mpoThresholdDbSpl = 100.0,
  });

  @override
  List<Object?> get props => [
        sampleRate,
        bufferSize,
        channels,
        bitsPerSample,
        eqGains,
        volumeDb,
        wdrcParams,
        nrLevel,
        mpoThresholdDbSpl,
      ];
}
