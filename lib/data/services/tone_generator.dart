import 'dart:math';
import 'dart:typed_data';

import 'package:just_audio/just_audio.dart';

/// Generador de tonos puros para el test de audiometría.
///
/// Genera tonos sinusoidales a frecuencias y niveles específicos,
/// los codifica como WAV en memoria, y los reproduce usando just_audio.
class ToneGenerator {
  final AudioPlayer _player = AudioPlayer();

  /// Sample rate para la generación de tonos.
  static const int sampleRate = 44100;

  /// Duración del tono en segundos.
  static const double toneDurationSec = 1.5;

  /// Genera y reproduce un tono puro.
  ///
  /// [frequencyHz] — Frecuencia del tono (250-8000 Hz)
  /// [levelDb] — Nivel en dB (0-80, donde 0 es silencio y 80 es máximo)
  /// [ear] — 'left' o 'right' para seleccionar canal
  Future<void> playTone({
    required int frequencyHz,
    required double levelDb,
    required String ear,
  }) async {
    // Convertir nivel dB a amplitud lineal (0 dB = silencio, 80 dB = máximo)
    // Usamos una escala donde 80 dB = amplitud 0.9, 0 dB = amplitud ~0.0001
    final amplitude = _dbToAmplitude(levelDb);

    // Generar samples
    final numSamples = (sampleRate * toneDurationSec).toInt();
    final samples = Float64List(numSamples);

    for (int i = 0; i < numSamples; i++) {
      final t = i / sampleRate;
      samples[i] = amplitude * sin(2 * pi * frequencyHz * t);

      // Aplicar fade in/out de 20ms para evitar clicks
      final fadeInSamples = (0.02 * sampleRate).toInt();
      final fadeOutStart = numSamples - fadeInSamples;
      if (i < fadeInSamples) {
        samples[i] *= i / fadeInSamples;
      } else if (i > fadeOutStart) {
        samples[i] *= (numSamples - i) / fadeInSamples;
      }
    }

    // Crear WAV stereo (para seleccionar oído)
    final wavBytes = _createStereoWav(samples, ear);

    // Reproducir
    await _player.setAudioSource(
      _WavAudioSource(wavBytes),
    );
    await _player.play();
  }

  /// Detiene la reproducción actual.
  Future<void> stop() async {
    await _player.stop();
  }

  /// Libera recursos.
  Future<void> dispose() async {
    await _player.dispose();
  }

  /// Convierte nivel en dB a amplitud lineal.
  /// 80 dB → 0.9 (casi máximo)
  /// 0 dB → ~0.00009 (inaudible)
  double _dbToAmplitude(double levelDb) {
    // Escala: 0 dB HL ≈ umbral de audición normal
    // Mapeamos 0-80 dB a amplitudes útiles para el parlante del celular
    // 80 dB → amplitud 0.9
    // 70 dB → amplitud 0.28
    // 60 dB → amplitud 0.09
    // 50 dB → amplitud 0.028
    // 40 dB → amplitud 0.009
    // 30 dB → amplitud 0.0028
    // 20 dB → amplitud 0.0009
    // 10 dB → amplitud 0.00028
    final normalized = levelDb.clamp(0.0, 80.0) / 80.0;
    return 0.9 * pow(10, (normalized - 1) * 2).toDouble();
  }

  /// Crea un archivo WAV stereo en memoria.
  /// Si ear='right', solo el canal derecho tiene audio.
  /// Si ear='left', solo el canal izquierdo tiene audio.
  /// Si ear='both', ambos canales tienen audio.
  Uint8List _createStereoWav(Float64List monoSamples, String ear) {
    final numSamples = monoSamples.length;
    final numChannels = 2;
    final bitsPerSample = 16;
    final bytesPerSample = bitsPerSample ~/ 8;
    final dataSize = numSamples * numChannels * bytesPerSample;
    final fileSize = 44 + dataSize;

    final buffer = ByteData(fileSize);
    int offset = 0;

    // RIFF header
    buffer.setUint8(offset++, 0x52); // R
    buffer.setUint8(offset++, 0x49); // I
    buffer.setUint8(offset++, 0x46); // F
    buffer.setUint8(offset++, 0x46); // F
    buffer.setUint32(offset, fileSize - 8, Endian.little);
    offset += 4;
    buffer.setUint8(offset++, 0x57); // W
    buffer.setUint8(offset++, 0x41); // A
    buffer.setUint8(offset++, 0x56); // V
    buffer.setUint8(offset++, 0x45); // E

    // fmt chunk
    buffer.setUint8(offset++, 0x66); // f
    buffer.setUint8(offset++, 0x6D); // m
    buffer.setUint8(offset++, 0x74); // t
    buffer.setUint8(offset++, 0x20); // (space)
    buffer.setUint32(offset, 16, Endian.little); // chunk size
    offset += 4;
    buffer.setUint16(offset, 1, Endian.little); // PCM format
    offset += 2;
    buffer.setUint16(offset, numChannels, Endian.little);
    offset += 2;
    buffer.setUint32(offset, sampleRate, Endian.little);
    offset += 4;
    buffer.setUint32(
        offset, sampleRate * numChannels * bytesPerSample, Endian.little);
    offset += 4;
    buffer.setUint16(offset, numChannels * bytesPerSample, Endian.little);
    offset += 2;
    buffer.setUint16(offset, bitsPerSample, Endian.little);
    offset += 2;

    // data chunk
    buffer.setUint8(offset++, 0x64); // d
    buffer.setUint8(offset++, 0x61); // a
    buffer.setUint8(offset++, 0x74); // t
    buffer.setUint8(offset++, 0x61); // a
    buffer.setUint32(offset, dataSize, Endian.little);
    offset += 4;

    // Write interleaved stereo samples
    for (int i = 0; i < numSamples; i++) {
      final sample = (monoSamples[i] * 32767).round().clamp(-32768, 32767);

      // Left channel
      final leftSample = (ear == 'right') ? 0 : sample;
      buffer.setInt16(offset, leftSample, Endian.little);
      offset += 2;

      // Right channel
      final rightSample = (ear == 'left') ? 0 : sample;
      buffer.setInt16(offset, rightSample, Endian.little);
      offset += 2;
    }

    return buffer.buffer.asUint8List();
  }
}

/// AudioSource que reproduce un WAV desde bytes en memoria.
class _WavAudioSource extends StreamAudioSource {
  final Uint8List _wavBytes;

  _WavAudioSource(this._wavBytes);

  @override
  Future<StreamAudioResponse> request([int? start, int? end]) async {
    final effectiveStart = start ?? 0;
    final effectiveEnd = end ?? _wavBytes.length;
    return StreamAudioResponse(
      sourceLength: _wavBytes.length,
      contentLength: effectiveEnd - effectiveStart,
      offset: effectiveStart,
      stream: Stream.value(
        _wavBytes.sublist(effectiveStart, effectiveEnd),
      ),
      contentType: 'audio/wav',
    );
  }
}
