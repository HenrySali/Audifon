// Feature: in-app-diagnostic-analyzer
// Module: dsp/stft
//
// Hann-windowed Short-Time Fourier Transform with `nfft = 1024` and
// `hop = 512`. Returns dB magnitudes `20·log10(|X| + 1e-20)` clamped to
// the range [-120, 0].

import 'dart:math' as math;
import 'dart:typed_data';

import '../constants.dart';
import 'fft.dart';
import 'window.dart';

class StftFrame {
  /// Magnitudes in dB, length = `nfft / 2 + 1`.
  final Float64List magnitudesDb;
  const StftFrame(this.magnitudesDb);
}

class StftResult {
  /// Number of frames (time axis).
  final int frameCount;

  /// Number of frequency bins (= nfft / 2 + 1).
  final int binCount;

  /// Row-major matrix of dB magnitudes, size = `frameCount × binCount`.
  /// frame f, bin b → `data[f · binCount + b]`.
  final Float64List data;

  /// Centers of each frame in seconds.
  final Float64List timeSec;

  /// Frequency axis in Hz, length `binCount`.
  final Float64List frequencyHz;

  const StftResult({
    required this.frameCount,
    required this.binCount,
    required this.data,
    required this.timeSec,
    required this.frequencyHz,
  });
}

class Stft {
  final int nfft;
  final int hop;

  Stft({
    this.nfft = kNfftSpectrogram,
    this.hop = kHopSpectrogram,
  });

  /// Computes the STFT of `signal` sampled at `sampleRate`.
  StftResult compute(Float64List signal, int sampleRate) {
    final window = Window.hann(nfft);
    final fft = Fft(nfft);
    final binCount = nfft ~/ 2 + 1;

    // Number of complete frames whose start fits in the signal (zero-pad
    // semantics not used here — match the Octave reference's truncation).
    int frameCount = 0;
    if (signal.length >= nfft) {
      frameCount = ((signal.length - nfft) ~/ hop) + 1;
    }

    final data = Float64List(frameCount * binCount);
    final timeSec = Float64List(frameCount);
    final freqHz = Float64List(binCount);
    final df = sampleRate / nfft;
    for (int b = 0; b < binCount; b++) {
      freqHz[b] = b * df;
    }

    final fftInput = Float64List(nfft);
    final reBuf = Float64List(binCount);
    final imBuf = Float64List(binCount);

    for (int f = 0; f < frameCount; f++) {
      final start = f * hop;
      for (int i = 0; i < nfft; i++) {
        fftInput[i] = signal[start + i] * window[i];
      }
      fft.forwardReal(fftInput, reBuf, imBuf);
      final base = f * binCount;
      for (int k = 0; k < binCount; k++) {
        final mag = math.sqrt(reBuf[k] * reBuf[k] + imBuf[k] * imBuf[k]);
        final db = 20.0 * (math.log(mag + kPsdEpsilon) / math.ln10);
        // Clamp to [-120, 0].
        if (db < -120.0) {
          data[base + k] = -120.0;
        } else if (db > 0.0) {
          data[base + k] = 0.0;
        } else {
          data[base + k] = db;
        }
      }
      timeSec[f] = (start + nfft / 2.0) / sampleRate;
    }

    return StftResult(
      frameCount: frameCount,
      binCount: binCount,
      data: data,
      timeSec: timeSec,
      frequencyHz: freqHz,
    );
  }
}
