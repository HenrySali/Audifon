/// @file tone_emitter.dart
/// @brief Emisor de tonos puros para la secuencia de validación.
///
/// Genera senoidal puro PCM 16-bit, mono, con envolvente coseno de
/// ataque/release ≥ 25 ms (REQ-2.5, IEC 60645-1).
///
/// Reproduce vía `just_audio` y `StreamAudioSource`, mismo patrón que
/// el `tone_generator.dart` existente — pero esta clase es **independiente**
/// y vive bajo `lib/calibration_spectrum/` para cumplir REQ-14.3
/// (no se modifica `tone_generator.dart`).

import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:just_audio/just_audio.dart';

/// Configuración del emitter.
class ToneEmitterConfig {
  final int sampleRate;          // 48000 (default coincide con AudioEngine)
  final int envelopeMs;          // 25 ms ataque/release (REQ-2.5)
  final double softLevelGain;    // multiplicador adicional del nivel base.

  const ToneEmitterConfig({
    this.sampleRate = 48000,
    this.envelopeMs = 25,
    this.softLevelGain = 1.0,
  });
}

/// Emisor de tonos puros aislado del módulo de calibración existente.
class ToneEmitter {
  final AudioPlayer _player = AudioPlayer();
  final ToneEmitterConfig _cfg;
  bool _disposed = false;

  ToneEmitter({ToneEmitterConfig config = const ToneEmitterConfig()})
      : _cfg = config;

  /// Reproduce un tono puro durante `durationMs` ms al `levelDbSpl` indicado.
  /// El nivel se mapea a un volumen lineal aproximado: el volumen real
  /// depende del path de audio del dispositivo (sistema + parlante/auricular).
  Future<void> playTone({
    required double freqHz,
    required double levelDbSpl,
    required int durationMs,
  }) async {
    if (_disposed) return;

    final wav = _generateToneWav(
      freqHz: freqHz,
      durationMs: durationMs,
      sampleRate: _cfg.sampleRate,
      envelopeMs: _cfg.envelopeMs,
      amplitudeNormalized: _levelToAmplitude(levelDbSpl) * _cfg.softLevelGain,
    );

    await _player.setVolume(1.0);
    await _player.setAudioSource(_WavAudioSource(wav));
    await _player.play();
  }

  /// Detiene la reproducción inmediatamente.
  Future<void> stop() async {
    if (_disposed) return;
    try {
      await _player.stop();
    } catch (_) {
      // ignorable
    }
  }

  /// Libera recursos.
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    await _player.dispose();
  }

  // ───────────────────────────────────────────────────────────────────────

  /// Mapea un nivel SPL nominal a una amplitud normalizada [0, 1].
  /// Heurística: 30 dB SPL → ~0.05, 90 dB SPL → 1.0 con escala log.
  /// La calibración fina la hace el técnico ajustando volumen del sistema.
  double _levelToAmplitude(double dbSpl) {
    final clamped = dbSpl.clamp(20.0, 90.0);
    final dbAboveBase = clamped - 90.0;
    return math.pow(10.0, dbAboveBase / 20.0).toDouble();
  }

  /// Genera un WAV mono PCM 16-bit con tono puro + envolvente coseno.
  Uint8List _generateToneWav({
    required double freqHz,
    required int durationMs,
    required int sampleRate,
    required int envelopeMs,
    required double amplitudeNormalized,
  }) {
    final totalSamples = (sampleRate * durationMs / 1000).round();
    final envSamples = math.max(
      1,
      math.min(
        (sampleRate * envelopeMs / 1000).round(),
        totalSamples ~/ 2,
      ),
    );
    final amp = amplitudeNormalized.clamp(0.0, 1.0) * 32767.0;
    final w = 2.0 * math.pi * freqHz / sampleRate;

    final pcm = Int16List(totalSamples);
    for (var i = 0; i < totalSamples; ++i) {
      double envelope;
      if (i < envSamples) {
        envelope = 0.5 * (1.0 - math.cos(math.pi * i / envSamples));
      } else if (i >= totalSamples - envSamples) {
        final j = totalSamples - 1 - i;
        envelope = 0.5 * (1.0 - math.cos(math.pi * j / envSamples));
      } else {
        envelope = 1.0;
      }
      final sample = amp * envelope * math.sin(w * i);
      pcm[i] = sample.round().clamp(-32768, 32767);
    }

    return _wrapWav(pcm: pcm, sampleRate: sampleRate);
  }

  /// Envuelve un PCM 16-bit en formato WAV.
  Uint8List _wrapWav({required Int16List pcm, required int sampleRate}) {
    const numChannels = 1;
    const bitsPerSample = 16;
    final byteRate = sampleRate * numChannels * bitsPerSample ~/ 8;
    final dataSize = pcm.lengthInBytes;
    final fileSize = 36 + dataSize;

    final buf = BytesBuilder();
    void writeStr(String s) => buf.add(Uint8List.fromList(s.codeUnits));
    void writeU32(int v) {
      final b = ByteData(4);
      b.setUint32(0, v, Endian.little);
      buf.add(b.buffer.asUint8List());
    }
    void writeU16(int v) {
      final b = ByteData(2);
      b.setUint16(0, v, Endian.little);
      buf.add(b.buffer.asUint8List());
    }

    writeStr('RIFF');
    writeU32(fileSize);
    writeStr('WAVE');
    writeStr('fmt ');
    writeU32(16);
    writeU16(1);                  // PCM
    writeU16(numChannels);
    writeU32(sampleRate);
    writeU32(byteRate);
    writeU16(numChannels * bitsPerSample ~/ 8);  // block align
    writeU16(bitsPerSample);
    writeStr('data');
    writeU32(dataSize);
    buf.add(pcm.buffer.asUint8List(pcm.offsetInBytes, pcm.lengthInBytes));

    return buf.toBytes();
  }
}

/// AudioSource que reproduce un WAV desde bytes en memoria.
class _WavAudioSource extends StreamAudioSource {
  final Uint8List _wavBytes;

  _WavAudioSource(this._wavBytes);

  @override
  Future<StreamAudioResponse> request([int? start, int? end]) async {
    start ??= 0;
    end ??= _wavBytes.length;
    return StreamAudioResponse(
      sourceLength: _wavBytes.length,
      contentLength: end - start,
      offset: start,
      stream: Stream.value(_wavBytes.sublist(start, end)),
      contentType: 'audio/wav',
    );
  }
}
