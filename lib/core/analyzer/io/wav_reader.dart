// Feature: in-app-diagnostic-analyzer
// Module: io/wav_reader
//
// Pure-Dart WAV parser for the dual-channel Recording_Package emitted by
// the upstream `dsp-diagnostic-recorder` feature.
//
// Validates the RIFF/`WAVE`/`fmt `/`data` chunks and rejects any non-PCM
// or non-stereo file with a `WavFormatException` whose Spanish message
// names the offending field. De-interleaves to two `Float64List` channels
// normalized by `s / 32768.0` (matches the `audioread` convention used by
// the Octave golden reference).

import 'dart:io';
import 'dart:typed_data';

import '../constants.dart';

/// De-interleaved WAV samples plus header metadata.
class WavData {
  /// Pre_DSP_Channel (left) samples in [-1.0, 1.0].
  final Float64List left;

  /// Post_DSP_Channel (right) samples in [-1.0, 1.0].
  final Float64List right;

  /// Sampling rate in Hz.
  final int sampleRate;

  /// Number of frames per channel.
  final int frameCount;

  /// Duration in seconds (`frameCount / sampleRate`).
  final double durationSec;

  const WavData({
    required this.left,
    required this.right,
    required this.sampleRate,
    required this.frameCount,
    required this.durationSec,
  });
}

/// Thrown when the WAV header does not satisfy the four invariants
/// required by the analyzer (audioFormat=1, channels=2, sampleRate=48000,
/// bitsPerSample=16). Carries a Spanish-language field-named message.
class WavFormatException implements Exception {
  final String field;
  final String message;

  const WavFormatException({required this.field, required this.message});

  @override
  String toString() => 'WavFormatException($field): $message';
}

/// PCM 16-bit stereo WAV reader, validating the four invariants required
/// by the analyzer.
class WavReader {
  /// Reads `path` from disk and returns the de-interleaved samples.
  Future<WavData> read(String path) async {
    final bytes = await File(path).readAsBytes();
    return parse(bytes);
  }

  /// Parses an in-memory WAV byte buffer. Surfaced separately for
  /// property tests (Property 1).
  WavData parse(Uint8List bytes) {
    if (bytes.length < 44) {
      throw const WavFormatException(
        field: 'header',
        message: 'Encabezado WAV incompleto: archivo demasiado corto.',
      );
    }
    final bd = ByteData.sublistView(bytes);

    // RIFF / WAVE
    if (_readAscii(bytes, 0, 4) != 'RIFF') {
      throw const WavFormatException(
        field: 'RIFF',
        message: 'El archivo no comienza con la cabecera RIFF.',
      );
    }
    if (_readAscii(bytes, 8, 4) != 'WAVE') {
      throw const WavFormatException(
        field: 'WAVE',
        message: 'El archivo no es un contenedor WAVE.',
      );
    }

    // Walk chunks looking for `fmt ` and `data`.
    int? fmtOffset;
    int? fmtSize;
    int? dataOffset;
    int? dataSize;
    int cursor = 12;
    while (cursor + 8 <= bytes.length) {
      final id = _readAscii(bytes, cursor, 4);
      final size = bd.getUint32(cursor + 4, Endian.little);
      final payload = cursor + 8;
      if (id == 'fmt ') {
        fmtOffset = payload;
        fmtSize = size;
      } else if (id == 'data') {
        dataOffset = payload;
        dataSize = size;
      }
      // Pad chunk size to even byte (RIFF spec).
      cursor = payload + size + (size.isOdd ? 1 : 0);
      if (fmtOffset != null && dataOffset != null) break;
    }

    if (fmtOffset == null || fmtSize == null) {
      throw const WavFormatException(
        field: 'fmt ',
        message: 'No se encontró el bloque "fmt " en el archivo WAV.',
      );
    }
    if (dataOffset == null || dataSize == null) {
      throw const WavFormatException(
        field: 'data',
        message: 'No se encontró el bloque "data" en el archivo WAV.',
      );
    }
    if (fmtSize < 16) {
      throw WavFormatException(
        field: 'fmt size',
        message: 'El bloque "fmt " mide $fmtSize bytes, se esperaban al menos 16.',
      );
    }

    final audioFormat = bd.getUint16(fmtOffset, Endian.little);
    final channels = bd.getUint16(fmtOffset + 2, Endian.little);
    final sampleRate = bd.getUint32(fmtOffset + 4, Endian.little);
    // bytesPerSec at +8, blockAlign at +12 — not validated here.
    final bitsPerSample = bd.getUint16(fmtOffset + 14, Endian.little);

    if (audioFormat != 1) {
      throw WavFormatException(
        field: 'audioFormat',
        message:
            'El audioFormat debe ser 1 (PCM), se recibió $audioFormat.',
      );
    }
    if (channels != 2) {
      throw WavFormatException(
        field: 'channels',
        message: 'Se requiere audio estéreo (2 canales), se recibió $channels.',
      );
    }
    if (sampleRate != kSampleRate) {
      throw WavFormatException(
        field: 'sampleRate',
        message:
            'La frecuencia de muestreo debe ser $kSampleRate Hz, se recibió $sampleRate Hz.',
      );
    }
    if (bitsPerSample != 16) {
      throw WavFormatException(
        field: 'bitsPerSample',
        message: 'Se requieren 16 bits por muestra, se recibió $bitsPerSample.',
      );
    }

    // Each frame is 2 channels × 2 bytes = 4 bytes.
    if (dataSize % 4 != 0) {
      throw WavFormatException(
        field: 'data size',
        message:
            'El bloque "data" tiene $dataSize bytes, no es múltiplo de 4 (frame estéreo 16-bit).',
      );
    }

    final frameCount = dataSize ~/ 4;
    final left = Float64List(frameCount);
    final right = Float64List(frameCount);

    // De-interleave int16 LE → float64 in [-1.0, 1.0].
    int p = dataOffset;
    for (int i = 0; i < frameCount; i++) {
      final l = bd.getInt16(p, Endian.little);
      final r = bd.getInt16(p + 2, Endian.little);
      left[i] = l / 32768.0;
      right[i] = r / 32768.0;
      p += 4;
    }

    return WavData(
      left: left,
      right: right,
      sampleRate: sampleRate,
      frameCount: frameCount,
      durationSec: frameCount / sampleRate,
    );
  }

  static String _readAscii(Uint8List bytes, int offset, int length) {
    final buf = StringBuffer();
    for (int i = 0; i < length; i++) {
      buf.writeCharCode(bytes[offset + i]);
    }
    return buf.toString();
  }
}
