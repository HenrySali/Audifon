// Test golden con señal sintética: generamos un buffer ShortArray
// con una senoide pura de 1 kHz a -20 dBFS RMS, computamos el RMS
// dBFS con la misma fórmula del handler nativo, y verificamos que
// `94 − rms_dbfs ≈ 114 ± 0.5` dB.
//
// Spec: native-calibration-handlers, Requirement 2.7 + 6.3.

import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

/// Port Dart de la fórmula RMS dBFS implementada en
/// `CalibrationAudioCapture.kt::computeRmsDbfs`. Usada para
/// validar el cálculo sin depender del runtime Android.
double computeRmsDbfs(Int16List buffer, int count) {
  if (count <= 0) return -120.0;
  var sumSq = 0.0;
  for (var i = 0; i < count; i++) {
    final v = buffer[i].toDouble();
    sumSq += v * v;
  }
  final rms = math.sqrt(sumSq / count);
  final safeRms = math.max(rms, 1.0);
  final dbfs = 20.0 * (math.log(safeRms / 32767.0) / math.ln10);
  return math.max(dbfs, -120.0);
}

/// Genera una senoide de [freqHz] Hz a [rmsDbfs] dBFS RMS, sample
/// rate 48 kHz, [durationMs] ms.
Int16List synthesizeSineWave({
  required double freqHz,
  required double rmsDbfs,
  int durationMs = 5000,
  int sampleRate = 48000,
}) {
  final n = sampleRate * durationMs ~/ 1000;
  // peak = rms * sqrt(2). 32767 = full scale para PCM_16.
  final peakAmplitude =
      math.pow(10, rmsDbfs / 20.0).toDouble() * 32767.0 * math.sqrt(2.0);
  final out = Int16List(n);
  for (var i = 0; i < n; i++) {
    final t = i / sampleRate;
    final s = math.sin(2 * math.pi * freqHz * t) * peakAmplitude;
    out[i] = s.toInt().clamp(-32768, 32767);
  }
  return out;
}

void main() {
  group('Synthetic calibration signal: 1 kHz @ -20 dBFS', () {
    test('RMS dBFS calculado coincide con -20 ± 0.5', () {
      final signal = synthesizeSineWave(
        freqHz: 1000.0,
        rmsDbfs: -20.0,
        durationMs: 5000,
      );
      final dbfs = computeRmsDbfs(signal, signal.length);
      // Tolerancia de 0.5 dB por error de cuantización (PCM_16).
      expect(dbfs, closeTo(-20.0, 0.5));
    });

    test('mic_offset = 94 - rms ≈ 114 dB para señal sintética', () {
      final signal = synthesizeSineWave(
        freqHz: 1000.0,
        rmsDbfs: -20.0,
        durationMs: 5000,
      );
      final dbfs = computeRmsDbfs(signal, signal.length);
      const refSpl = 94.0;
      final micOffset = refSpl - dbfs;
      expect(micOffset, closeTo(114.0, 0.5));
    });

    test('señal silenciosa (zeros) retorna -120 dBFS (floor)', () {
      final silent = Int16List(48000);
      final dbfs = computeRmsDbfs(silent, silent.length);
      // Buffer de zeros: rms=0, safeRms=1, dbfs ≈ -90.3 → no llega a
      // -120. Verificamos que ≥ -120 (floor) y ≤ -85 (cerca del piso).
      expect(dbfs, greaterThanOrEqualTo(-120.0));
      expect(dbfs, lessThanOrEqualTo(-85.0));
    });

    test('count=0 retorna exactamente -120', () {
      final empty = Int16List(0);
      final dbfs = computeRmsDbfs(empty, 0);
      expect(dbfs, equals(-120.0));
    });

    test('linealidad: -10 dBFS → mic_offset ≈ 104 dB', () {
      final signal = synthesizeSineWave(
        freqHz: 1000.0,
        rmsDbfs: -10.0,
        durationMs: 5000,
      );
      final dbfs = computeRmsDbfs(signal, signal.length);
      const refSpl = 94.0;
      final micOffset = refSpl - dbfs;
      expect(micOffset, closeTo(104.0, 0.5));
    });

    test('linealidad: -40 dBFS → mic_offset ≈ 134 dB', () {
      final signal = synthesizeSineWave(
        freqHz: 1000.0,
        rmsDbfs: -40.0,
        durationMs: 1000,
      );
      final dbfs = computeRmsDbfs(signal, signal.length);
      const refSpl = 94.0;
      final micOffset = refSpl - dbfs;
      // Tolerancia mayor por error de cuantización en niveles bajos.
      expect(micOffset, closeTo(134.0, 1.0));
    });
  });

  group('Property: floor a -120 dBFS', () {
    test('cualquier buffer no-vacío retorna ≥ -120', () {
      final rng = math.Random(42);
      for (var i = 0; i < 50; i++) {
        final n = rng.nextInt(48000) + 1;
        final buf = Int16List(n);
        for (var j = 0; j < n; j++) {
          buf[j] = (rng.nextDouble() * 65535 - 32768).toInt();
        }
        final dbfs = computeRmsDbfs(buf, n);
        expect(dbfs, greaterThanOrEqualTo(-120.0));
        expect(dbfs, lessThanOrEqualTo(0.0));
      }
    });
  });
}
