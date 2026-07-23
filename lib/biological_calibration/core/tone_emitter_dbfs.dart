/// @file tone_emitter_dbfs.dart
/// @brief Emisor de tonos puros para calibración biológica (Hughson-Westlake).
///
/// A diferencia de `lib/calibration_spectrum/tone_emitter.dart` (que toma niveles
/// en dB SPL nominal y aplica una heurística SPL→amplitud), este emisor recibe
/// el nivel directamente en **dBFS** y lo convierte a amplitud lineal vía
/// `dBFSToAmplitude`. Esto es clave para Hughson-Westlake: el algoritmo opera
/// en el dominio digital y la conversión a dB HL se hace después con la
/// referencia biológica (mediana de umbrales de normoyentes).
///
/// Genera senoidal puro PCM 16-bit, mono, 48 kHz, con envolvente raised-cosine
/// de 25 ms (cumple ≥20 ms IEC 60645-1, igual al `ToneEmitter` existente).

import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:just_audio/just_audio.dart';

/// Emisor de tonos puros parametrizados en dBFS.
class ToneEmitterDbfs {
  /// Frecuencia de muestreo del WAV generado.
  static const int sampleRate = 48000;

  /// Duración (ms) de la rampa raised-cosine de onset/offset.
  static const int rampMs = 25;

  /// PCM mono.
  static const int channels = 1;

  /// PCM 16-bit signed.
  static const int bitsPerSample = 16;

  final AudioPlayer _player = AudioPlayer();
  bool _disposed = false;

  /// Convierte un nivel en dBFS a amplitud lineal en [0, 1].
  ///
  /// Se aplica clamp a [-80, -1] dBFS:
  ///   - -80 dBFS evita ruidos sub-piso indistinguibles
  ///   - -1 dBFS evita clipping del WAV PCM 16-bit
  ///
  /// Fórmula: amplitude = 10^(dbFS/20).
  static double dBFSToAmplitude(double dbFS) {
    final clamped = dbFS.clamp(-80.0, -1.0);
    return math.pow(10.0, clamped / 20.0).toDouble();
  }

  /// Reproduce un tono puro a `freqHz` con nivel `levelDbFS` durante
  /// `durationMs` milisegundos. La llamada vuelve cuando comienza la
  /// reproducción; usar `stop()` para detener antes del final.
  Future<void> playToneAtDbFS({
    required double freqHz,
    required double levelDbFS,
    required int durationMs,
  }) async {
    if (_disposed) return;
    final amplitude = dBFSToAmplitude(levelDbFS);
    final wav = _generateToneWav(
      freqHz: freqHz,
      durationMs: durationMs,
      amplitudeNormalized: amplitude,
    );
    await _player.setVolume(1.0);
    await _player.setAudioSource(_WavAudioSource(wav));
    await _player.play();
  }

  /// Detiene la reproducción actual sin liberar recursos.
  Future<void> stop() async {
    if (_disposed) return;
    try {
      await _player.stop();
    } catch (_) {
      // ignorable
    }
  }

  /// Libera el `AudioPlayer` interno. Posteriores llamadas a `playToneAtDbFS`
  /// son no-op.
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    try {
      await _player.dispose();
    } catch (_) {
      // ignorable
    }
  }

  // ───────────────────────────────────────────────────────────────────────

  /// Genera un WAV PCM 16-bit mono con tono puro y envelope raised-cosine
  /// usando `amplitudeNormalized` ∈ [0, 1] como pico (sin transformación
  /// adicional de nivel).
  Uint8List _generateToneWav({
    required double freqHz,
    required int durationMs,
    required double amplitudeNormalized,
  }) {
    final totalSamples = (sampleRate * durationMs / 1000).round();
    final rampSamples = math.max(
      1,
      math.min(
        (sampleRate * rampMs / 1000).round(),
        totalSamples ~/ 2,
      ),
    );
    final omega = 2.0 * math.pi * freqHz / sampleRate;
    final samples = Int16List(totalSamples);

    for (int n = 0; n < totalSamples; n++) {
      double envelope;
      if (n < rampSamples) {
        envelope = 0.5 * (1.0 - math.cos(math.pi * n / rampSamples));
      } else if (n >= totalSamples - rampSamples) {
        final k = totalSamples - 1 - n;
        envelope = 0.5 * (1.0 - math.cos(math.pi * k / rampSamples));
      } else {
        envelope = 1.0;
      }
      final s = amplitudeNormalized * envelope * math.sin(omega * n);
      samples[n] = (s * 32767.0).round().clamp(-32768, 32767);
    }

    return _wrapWav(samples);
  }

  /// Envuelve un buffer PCM 16-bit en un contenedor WAV/RIFF.
  Uint8List _wrapWav(Int16List pcm) {
    final byteRate = sampleRate * channels * bitsPerSample ~/ 8;
    final blockAlign = channels * bitsPerSample ~/ 8;
    final dataSize = pcm.lengthInBytes;
    final fileSize = 36 + dataSize;

    final bb = BytesBuilder();
    bb.add(_str('RIFF'));
    bb.add(_u32(fileSize));
    bb.add(_str('WAVE'));
    bb.add(_str('fmt '));
    bb.add(_u32(16));
    bb.add(_u16(1));               // formato PCM
    bb.add(_u16(channels));
    bb.add(_u32(sampleRate));
    bb.add(_u32(byteRate));
    bb.add(_u16(blockAlign));
    bb.add(_u16(bitsPerSample));
    bb.add(_str('data'));
    bb.add(_u32(dataSize));
    bb.add(pcm.buffer.asUint8List(pcm.offsetInBytes, pcm.lengthInBytes));
    return bb.toBytes();
  }

  Uint8List _str(String s) => Uint8List.fromList(s.codeUnits);

  Uint8List _u32(int v) {
    final b = ByteData(4);
    b.setUint32(0, v, Endian.little);
    return b.buffer.asUint8List();
  }

  Uint8List _u16(int v) {
    final b = ByteData(2);
    b.setUint16(0, v, Endian.little);
    return b.buffer.asUint8List();
  }
}

/// `StreamAudioSource` que entrega un WAV en memoria a `just_audio`.
class _WavAudioSource extends StreamAudioSource {
  final Uint8List _bytes;

  _WavAudioSource(this._bytes);

  @override
  Future<StreamAudioResponse> request([int? start, int? end]) async {
    start ??= 0;
    end ??= _bytes.length;
    return StreamAudioResponse(
      sourceLength: _bytes.length,
      contentLength: end - start,
      offset: start,
      stream: Stream.value(_bytes.sublist(start, end)),
      contentType: 'audio/wav',
    );
  }
}
