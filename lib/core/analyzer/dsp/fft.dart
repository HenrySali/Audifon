// Feature: in-app-diagnostic-analyzer
// Module: dsp/fft
//
// Pure-Dart radix-2 Cooley-Tukey FFT. Decimation-in-time, bit-reversal
// permutation, twiddle factors precomputed per `nfft`. Hot-path sensitive
// — the buffers are reused across calls so `forwardReal` is allocation-
// free.

import 'dart:math' as math;
import 'dart:typed_data';

class Fft {
  /// FFT length (power of 2).
  final int nfft;

  // Precomputed twiddle factors, length `nfft / 2`.
  final Float64List _twReal;
  final Float64List _twImag;

  // Bit-reversal permutation, length `nfft`.
  final Int32List _brev;

  // Reusable work buffer (interleaved real,imag) of length `2 · nfft`.
  final Float64List _work;

  Fft._(this.nfft, this._twReal, this._twImag, this._brev, this._work);

  factory Fft(int nfft) {
    if (nfft < 2 || (nfft & (nfft - 1)) != 0) {
      throw ArgumentError(
        'nfft must be a power of 2 ≥ 2 (got $nfft)',
      );
    }
    final tr = Float64List(nfft ~/ 2);
    final ti = Float64List(nfft ~/ 2);
    for (int k = 0; k < nfft ~/ 2; k++) {
      final phi = -2.0 * math.pi * k / nfft;
      tr[k] = math.cos(phi);
      ti[k] = math.sin(phi);
    }
    final br = Int32List(nfft);
    final logN = _log2Int(nfft);
    for (int i = 0; i < nfft; i++) {
      int rev = 0;
      int x = i;
      for (int b = 0; b < logN; b++) {
        rev = (rev << 1) | (x & 1);
        x >>= 1;
      }
      br[i] = rev;
    }
    return Fft._(nfft, tr, ti, br, Float64List(2 * nfft));
  }

  /// Forward FFT of a real signal of length `nfft`. Writes the complex
  /// spectrum into `reOut` and `imOut` (length ≥ `nfft / 2 + 1`). Bins
  /// above Nyquist are not written.
  ///
  /// `input` MUST have length `nfft`. The function is allocation-free.
  void forwardReal(
    Float64List input,
    Float64List reOut,
    Float64List imOut,
  ) {
    if (input.length != nfft) {
      throw ArgumentError(
        'input.length (${input.length}) != nfft ($nfft)',
      );
    }
    final w = _work;
    // Apply bit-reversal permutation while loading the work buffer.
    for (int i = 0; i < nfft; i++) {
      final j = _brev[i];
      w[2 * i] = input[j];
      w[2 * i + 1] = 0.0;
    }

    // Iterative radix-2 butterflies.
    int size = 2;
    while (size <= nfft) {
      final half = size >> 1;
      final tableStep = nfft ~/ size;
      for (int i = 0; i < nfft; i += size) {
        int k = 0;
        for (int j = i; j < i + half; j++) {
          final twR = _twReal[k];
          final twI = _twImag[k];
          final rIdx = 2 * j;
          final iIdx = rIdx + 1;
          final r1Idx = 2 * (j + half);
          final i1Idx = r1Idx + 1;

          final tR = w[r1Idx] * twR - w[i1Idx] * twI;
          final tI = w[r1Idx] * twI + w[i1Idx] * twR;

          w[r1Idx] = w[rIdx] - tR;
          w[i1Idx] = w[iIdx] - tI;
          w[rIdx] = w[rIdx] + tR;
          w[iIdx] = w[iIdx] + tI;

          k += tableStep;
        }
      }
      size <<= 1;
    }

    // Copy out the one-sided spectrum (DC..Nyquist).
    final half = nfft ~/ 2;
    for (int k = 0; k <= half; k++) {
      reOut[k] = w[2 * k];
      imOut[k] = w[2 * k + 1];
    }
  }

  static int _log2Int(int n) {
    int l = 0;
    while ((1 << l) < n) {
      l++;
    }
    return l;
  }
}
