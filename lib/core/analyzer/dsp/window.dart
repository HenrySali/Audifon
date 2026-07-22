// Feature: in-app-diagnostic-analyzer
// Module: dsp/window
//
// Hann window plus a tiny utility for window-energy normalization.

import 'dart:math' as math;
import 'dart:typed_data';

class Window {
  /// Periodic Hann window of length `n` (matches `0.5·(1 − cos(2πi/(n−1)))`,
  /// i.e. Octave's `hanning(n)` convention).
  static Float64List hann(int n) {
    final w = Float64List(n);
    if (n <= 1) {
      if (n == 1) w[0] = 1.0;
      return w;
    }
    final denom = (n - 1).toDouble();
    for (int i = 0; i < n; i++) {
      w[i] = 0.5 * (1.0 - math.cos(2.0 * math.pi * i / denom));
    }
    return w;
  }

  /// Sum of squares of `w`, used for Welch normalization.
  static double sumOfSquares(Float64List w) {
    double s = 0.0;
    for (int i = 0; i < w.length; i++) {
      s += w[i] * w[i];
    }
    return s;
  }
}
