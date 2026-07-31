// Feature: in-app-diagnostic-analyzer
// Module: dsp/welch_psd
//
// Welch's averaged-periodogram PSD with Hann window. Matches `my_pwelch`
// in the Octave golden reference exactly:
//   - seg_len = nfft = 8192 (default)
//   - 50% overlap → step = seg_len / 2 = 4096
//   - normalization 1 / (sampleRate · Σ w²)
//   - average across complete segments (one-sided spectrum: bins
//     [1 .. n/2 − 1] doubled, DC and Nyquist left as-is)
//
// Throws `PsdInputException` with the Spanish message "Señal demasiado
// corta para el cálculo de PSD" when the signal is shorter than the
// segment length.

import 'dart:typed_data';

import '../constants.dart';
import '../result/psd_result.dart';
import 'fft.dart';
import 'window.dart';

class PsdInputException implements Exception {
  final String message;
  const PsdInputException(this.message);

  @override
  String toString() => 'PsdInputException: $message';
}

class WelchPsd {
  final int nfft;
  final int segmentLength;
  final int overlap;

  WelchPsd({
    int nfft = kNfftDefault,
    int? segmentLength,
    int? overlap,
  })  : nfft = nfft,
        segmentLength = segmentLength ?? nfft,
        overlap = overlap ?? (segmentLength ?? nfft) ~/ 2 {
    if (this.segmentLength > nfft) {
      throw ArgumentError(
        'segmentLength (${this.segmentLength}) must be ≤ nfft ($nfft)',
      );
    }
    if (this.overlap < 0 || this.overlap >= this.segmentLength) {
      throw ArgumentError(
        'overlap (${this.overlap}) must be in [0, segmentLength).',
      );
    }
  }

  /// Computes the Welch PSD of a real `signal` sampled at `sampleRate`.
  PsdResult compute(Float64List signal, int sampleRate) {
    if (signal.length < segmentLength) {
      throw const PsdInputException(
        'Señal demasiado corta para el cálculo de PSD',
      );
    }
    final fft = Fft(nfft);
    final window = Window.hann(segmentLength);
    final winSumSq = Window.sumOfSquares(window);
    final step = segmentLength - overlap;

    final binCount = nfft ~/ 2 + 1;
    final accum = Float64List(binCount);
    final reBuf = Float64List(binCount);
    final imBuf = Float64List(binCount);
    final fftInput = Float64List(nfft);

    int segCount = 0;
    int start = 0;
    while (start + segmentLength <= signal.length) {
      // Window the segment, zero-pad to nfft length if needed.
      for (int i = 0; i < segmentLength; i++) {
        fftInput[i] = signal[start + i] * window[i];
      }
      for (int i = segmentLength; i < nfft; i++) {
        fftInput[i] = 0.0;
      }
      fft.forwardReal(fftInput, reBuf, imBuf);
      for (int k = 0; k < binCount; k++) {
        final r = reBuf[k];
        final im = imBuf[k];
        accum[k] += r * r + im * im;
      }
      segCount++;
      start += step;
    }

    if (segCount == 0) {
      // Defensive — should not happen given the length guard above.
      throw const PsdInputException(
        'Señal demasiado corta para el cálculo de PSD',
      );
    }

    // Normalize: average across segments, divide by fs · Σw², then
    // double interior bins for the one-sided spectrum.
    final norm = 1.0 / (sampleRate * winSumSq);
    final power = Float64List(binCount);
    for (int k = 0; k < binCount; k++) {
      power[k] = (accum[k] / segCount) * norm;
    }
    for (int k = 1; k < binCount - 1; k++) {
      power[k] *= 2.0;
    }
    // (DC and Nyquist remain unchanged.)

    final freqs = Float64List(binCount);
    final df = sampleRate / nfft;
    for (int k = 0; k < binCount; k++) {
      freqs[k] = k * df;
    }

    return PsdResult(
      frequencies: freqs,
      power: power,
      nfft: nfft,
      sampleRate: sampleRate,
    );
  }
}
