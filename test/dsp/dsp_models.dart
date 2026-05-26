/// Dart-side DSP model functions for property-based testing.
///
/// These replicate the C++ DSP algorithms in pure Dart so we can
/// verify correctness properties without calling native code.
///
/// Feature: psk-mobile-hearing-aid
library;

import 'dart:math';

/// Computes the WDRC gain factor for a given input level (dB SPL).
///
/// 3-region model:
/// - Expansion: input < expansionKnee → gainFactor < 1.0
/// - Linear: expansionKnee ≤ input ≤ compressionKnee → gainFactor = 1.0
/// - Compression: input > compressionKnee → gainFactor < 1.0
double computeWdrcGainFactor({
  required double inputLevelDb,
  required double expansionKnee,
  required double expansionRatio,
  required double compressionKnee,
  required double compressionRatio,
}) {
  if (inputLevelDb < expansionKnee) {
    // EXPANSION: attenuate noise
    final belowKnee = expansionKnee - inputLevelDb;
    final reductionDb = belowKnee * (1.0 - 1.0 / expansionRatio);
    return pow(10.0, -reductionDb / 20.0).toDouble();
  } else if (inputLevelDb > compressionKnee) {
    // COMPRESSION: protect from loud sounds
    final aboveKnee = inputLevelDb - compressionKnee;
    final reductionDb = aboveKnee * (1.0 - 1.0 / compressionRatio);
    return pow(10.0, -reductionDb / 20.0).toDouble();
  }
  // LINEAR: full gain
  return 1.0;
}

/// MPO peak limiter — processes a buffer sample-by-sample.
///
/// Returns the limited buffer. No output sample exceeds [thresholdLinear].
List<double> mpoLimit({
  required List<double> buffer,
  required double thresholdLinear,
  double attackCoeff = 0.125, // ~0.5ms at 16kHz
  double releaseCoeff = 0.006, // ~10ms at 16kHz
}) {
  final output = List<double>.filled(buffer.length, 0.0);
  double gain = 1.0;

  for (int i = 0; i < buffer.length; i++) {
    final absSample = buffer[i].abs();
    if (absSample * gain > thresholdLinear) {
      // Need to reduce gain
      final targetGain =
          absSample > 0 ? thresholdLinear / absSample : 1.0;
      gain += attackCoeff * (targetGain - gain);
    } else {
      // Release back to unity
      gain += releaseCoeff * (1.0 - gain);
    }
    // Clamp gain to [0, 1]
    gain = gain.clamp(0.0, 1.0);
    output[i] = buffer[i] * gain;
  }
  return output;
}

/// Converts volume in dB to linear factor.
///
/// factor = 10^(volumeDb / 20)
double volumeDbToLinear(double volumeDb) {
  return pow(10.0, volumeDb / 20.0).toDouble();
}

/// Measures RMS level of a buffer in dBFS.
double measureRmsDbFs(List<double> buffer) {
  if (buffer.isEmpty) return -100.0;
  double sumSquares = 0.0;
  for (final sample in buffer) {
    sumSquares += sample * sample;
  }
  final rms = sqrt(sumSquares / buffer.length);
  if (rms < 1e-10) return -100.0;
  return 20.0 * log(rms) / ln10;
}

/// Computes SPL from dBFS + offset.
double computeSpl({required double rmsDbFs, required double offset}) {
  return rmsDbFs + offset;
}

/// Applies EQ gains to a buffer (simplified model for testing).
///
/// In reality, EQ uses biquad filters. For property testing of
/// level independence, we just scale the buffer by a gain factor.
List<double> applyEqGain(List<double> buffer, double gainDb) {
  final factor = pow(10.0, gainDb / 20.0).toDouble();
  return buffer.map((s) => s * factor).toList();
}

/// Crossfade between two processed buffers.
///
/// Returns a buffer where the first half fades from [bufferA] to [bufferB]
/// using a linear crossfade.
List<double> crossfade({
  required List<double> bufferA,
  required List<double> bufferB,
  required int crossfadeSamples,
}) {
  assert(bufferA.length == bufferB.length);
  final length = bufferA.length;
  final output = List<double>.filled(length, 0.0);

  for (int i = 0; i < length; i++) {
    if (i < crossfadeSamples) {
      final alpha = i / crossfadeSamples;
      output[i] = bufferA[i] * (1.0 - alpha) + bufferB[i] * alpha;
    } else {
      output[i] = bufferB[i];
    }
  }
  return output;
}
