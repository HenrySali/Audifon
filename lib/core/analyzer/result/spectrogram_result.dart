// Feature: in-app-diagnostic-analyzer
// Module: result/spectrogram_result
//
// Output of the SpectrogramAnalyzer. Two row-major Float32 matrices (pre,
// post) in dB clamped to [-120, 0] plus the time/frequency axes.

import 'dart:typed_data';

class SpectrogramResult {
  /// Pre channel spectrogram in dB, row-major (size = `rows × cols`).
  final Float32List preDb;

  /// Post channel spectrogram in dB, row-major.
  final Float32List postDb;

  /// Number of frequency bins (≤ 256).
  final int rows;

  /// Number of time frames (≤ 600).
  final int cols;

  /// Time axis (seconds), length `cols`.
  final Float64List timeSec;

  /// Frequency axis (Hz), length `rows`.
  final Float64List frequencyHz;

  const SpectrogramResult({
    required this.preDb,
    required this.postDb,
    required this.rows,
    required this.cols,
    required this.timeSec,
    required this.frequencyHz,
  });
}
