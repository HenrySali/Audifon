// Feature: in-app-diagnostic-analyzer
// Module: result/psd_result
//
// Welch_PSD output. Linear power spectrum (V²/Hz) with frequency axis from
// DC to Nyquist.

import 'dart:typed_data';

class PsdResult {
  /// Frequency axis (Hz). Length = `nfft / 2 + 1`.
  final Float64List frequencies;

  /// One-sided power spectrum in V²/Hz (linear units, interior bins
  /// already doubled).
  final Float64List power;

  /// FFT length used.
  final int nfft;

  /// Sampling rate used.
  final int sampleRate;

  const PsdResult({
    required this.frequencies,
    required this.power,
    required this.nfft,
    required this.sampleRate,
  });
}
