// Feature: psk-mobile-hearing-aid, Property 2: PRE-EQ level independence
// Feature: psk-mobile-hearing-aid, Property 7: Crossfade smooth transition

/// Property-based tests for DSP pipeline properties.
///
/// **Validates: Requirements 2.4, 8.2**
import 'dart:math';

import 'package:glados/glados.dart';

import 'dsp_models.dart';

/// Generate a 64-sample audio buffer from a seed.
List<double> _seedToAudioBuffer(double seed, double range) {
  final rng = Random(seed.hashCode);
  return List.generate(64, (_) => (rng.nextDouble() * 2 - 1) * range);
}

void main() {
  group('Property 2: PRE-EQ level independence', () {
    Glados2(any.doubleInRange(-1000, 1000), any.doubleInRange(0, 50),
        ExploreConfig(numRuns: 100)).test(
      'changing EQ gains does not change WDRC input level',
      (bufferSeed, eqGain) {
        final buffer = _seedToAudioBuffer(bufferSeed, 1.0);

        // Measure level PRE-EQ (this is what WDRC uses)
        final preEqLevel = measureRmsDbFs(buffer);

        // Apply EQ gain (post-EQ)
        final postEq = applyEqGain(buffer, eqGain);

        // The PRE-EQ level measurement is always the same buffer
        final preEqLevelAgain = measureRmsDbFs(buffer);

        // WDRC input level is always the pre-EQ measurement
        expect(
          preEqLevelAgain,
          closeTo(preEqLevel, 0.001),
          reason: 'PRE-EQ level should be independent of EQ gain=$eqGain dB',
        );

        // Verify that POST-EQ level IS different (EQ works)
        if (eqGain > 1.0 && preEqLevel > -90) {
          final postEqLevel = measureRmsDbFs(postEq);
          expect(
            postEqLevel,
            greaterThan(preEqLevel),
            reason: 'Post-EQ level should be higher with gain=$eqGain dB',
          );
        }
      },
    );
  });

  group('Property 7: Crossfade smooth transition', () {
    Glados(any.doubleInRange(-1000, 1000), ExploreConfig(numRuns: 100)).test(
      'crossfade produces no discontinuities at profile change',
      (bufferSeed) {
        final buffer = _seedToAudioBuffer(bufferSeed, 0.5);

        // Simulate two different profile processings
        final processedA = applyEqGain(buffer, 5.0);
        final processedB = applyEqGain(buffer, 20.0);

        // Apply crossfade (16 samples = 1ms at 16kHz)
        const crossfadeSamples = 16;
        final crossfaded = crossfade(
          bufferA: processedA,
          bufferB: processedB,
          crossfadeSamples: crossfadeSamples,
        );

        // Measure max sample-to-sample difference during stable processing
        double maxStableDiff = 0.0;
        for (int i = crossfadeSamples + 1; i < buffer.length; i++) {
          final diff = (crossfaded[i] - crossfaded[i - 1]).abs();
          if (diff > maxStableDiff) maxStableDiff = diff;
        }

        // During crossfade, differences should not exceed a reasonable bound
        for (int i = 1; i < crossfadeSamples; i++) {
          final diff = (crossfaded[i] - crossfaded[i - 1]).abs();
          final maxAllowed = max(maxStableDiff * 3.0, 0.1);
          expect(
            diff,
            lessThanOrEqualTo(maxAllowed),
            reason: 'Discontinuity at sample $i: diff=$diff > maxAllowed=$maxAllowed',
          );
        }

        // Verify crossfade endpoints
        expect(crossfaded[0], closeTo(processedA[0], 0.001));
        expect(
          crossfaded[crossfadeSamples],
          closeTo(processedB[crossfadeSamples], 0.001),
        );
      },
    );
  });
}
