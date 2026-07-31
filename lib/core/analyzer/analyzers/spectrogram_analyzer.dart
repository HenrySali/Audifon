// Feature: in-app-diagnostic-analyzer
// Module: analyzers/spectrogram_analyzer
//
// Runs the STFT on both channels and downsamples the result to the
// rendering budget: ≤ 600 columns × ≤ 256 rows. Output is row-major
// `Float32List` matrices clamped to [-120, 0] dB.

import 'dart:typed_data';

import '../dsp/stft.dart';
import '../result/spectrogram_result.dart';

class SpectrogramAnalyzer {
  /// Maximum time columns in the downsampled output.
  final int maxCols;

  /// Maximum frequency rows in the downsampled output.
  final int maxRows;

  SpectrogramAnalyzer({this.maxCols = 600, this.maxRows = 256});

  SpectrogramResult analyze({
    required Float64List pre,
    required Float64List post,
    required int sampleRate,
  }) {
    final stft = Stft();
    final stftPre = stft.compute(pre, sampleRate);
    final stftPost = stft.compute(post, sampleRate);

    if (stftPre.frameCount != stftPost.frameCount ||
        stftPre.binCount != stftPost.binCount) {
      throw StateError(
        'STFT shape mismatch (${stftPre.frameCount}×${stftPre.binCount} '
        'vs ${stftPost.frameCount}×${stftPost.binCount})',
      );
    }

    // Decimation strides.
    final timeStride = stftPre.frameCount <= maxCols
        ? 1
        : ((stftPre.frameCount + maxCols - 1) ~/ maxCols);
    final freqStride = stftPre.binCount <= maxRows
        ? 1
        : ((stftPre.binCount + maxRows - 1) ~/ maxRows);

    final cols = (stftPre.frameCount + timeStride - 1) ~/ timeStride;
    final rows = (stftPre.binCount + freqStride - 1) ~/ freqStride;

    final preDb = Float32List(rows * cols);
    final postDb = Float32List(rows * cols);
    final timeSec = Float64List(cols);
    final freqHz = Float64List(rows);

    for (int c = 0; c < cols; c++) {
      final f = c * timeStride;
      timeSec[c] = stftPre.timeSec[f];
      for (int r = 0; r < rows; r++) {
        final b = r * freqStride;
        // row-major: row r, col c → index r·cols + c
        final pPre = stftPre.data[f * stftPre.binCount + b];
        final pPost = stftPost.data[f * stftPost.binCount + b];
        preDb[r * cols + c] = _clamp32(pPre);
        postDb[r * cols + c] = _clamp32(pPost);
      }
    }
    for (int r = 0; r < rows; r++) {
      final b = r * freqStride;
      freqHz[r] = stftPre.frequencyHz[b];
    }

    return SpectrogramResult(
      preDb: preDb,
      postDb: postDb,
      rows: rows,
      cols: cols,
      timeSec: timeSec,
      frequencyHz: freqHz,
    );
  }

  static double _clamp32(double v) {
    if (v < -120.0) return -120.0;
    if (v > 0.0) return 0.0;
    return v;
  }
}
