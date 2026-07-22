// Feature: psk-mobile-hearing-aid, Property 3: WDRC 3-region model

/// Property-based test for WDRC gain factor behavior per region.
///
/// Property 3: For any input level in dB SPL:
/// (a) input < expansionKnee → gainFactor < 1.0, decreasing monotonically
/// (b) expansionKnee ≤ input ≤ compressionKnee → gainFactor = 1.0
/// (c) input > compressionKnee → gainFactor < 1.0, decreasing monotonically
///
/// **Validates: Requirements 2.5, 9.2, 9.4**
import 'package:glados/glados.dart';

import 'dsp_models.dart';

void main() {
  // Default WDRC parameters
  const expansionKnee = 35.0;
  const expansionRatio = 2.0;
  const compressionKnee = 55.0;
  const compressionRatio = 2.0;

  group('Property 3: WDRC 3-region model', () {
    Glados(any.doubleInRange(0, 120), ExploreConfig(numRuns: 100)).test(
      '(a) input < expansionKnee → gainFactor < 1.0',
      (inputLevel) {
        if (inputLevel >= expansionKnee) return; // Only test expansion region

        final gainFactor = computeWdrcGainFactor(
          inputLevelDb: inputLevel,
          expansionKnee: expansionKnee,
          expansionRatio: expansionRatio,
          compressionKnee: compressionKnee,
          compressionRatio: compressionRatio,
        );

        expect(
          gainFactor,
          lessThan(1.0),
          reason: 'In expansion region (input=$inputLevel < knee=$expansionKnee), '
              'gainFactor=$gainFactor should be < 1.0',
        );
        expect(gainFactor, greaterThan(0.0));
      },
    );

    Glados(any.doubleInRange(0, 120), ExploreConfig(numRuns: 100)).test(
      '(b) expansionKnee ≤ input ≤ compressionKnee → gainFactor = 1.0',
      (inputLevel) {
        if (inputLevel < expansionKnee || inputLevel > compressionKnee) return;

        final gainFactor = computeWdrcGainFactor(
          inputLevelDb: inputLevel,
          expansionKnee: expansionKnee,
          expansionRatio: expansionRatio,
          compressionKnee: compressionKnee,
          compressionRatio: compressionRatio,
        );

        expect(
          gainFactor,
          closeTo(1.0, 0.0001),
          reason: 'In linear region (input=$inputLevel), '
              'gainFactor=$gainFactor should be 1.0',
        );
      },
    );

    Glados(any.doubleInRange(0, 120), ExploreConfig(numRuns: 100)).test(
      '(c) input > compressionKnee → gainFactor < 1.0',
      (inputLevel) {
        if (inputLevel <= compressionKnee) return;

        final gainFactor = computeWdrcGainFactor(
          inputLevelDb: inputLevel,
          expansionKnee: expansionKnee,
          expansionRatio: expansionRatio,
          compressionKnee: compressionKnee,
          compressionRatio: compressionRatio,
        );

        expect(
          gainFactor,
          lessThan(1.0),
          reason: 'In compression region (input=$inputLevel > knee=$compressionKnee), '
              'gainFactor=$gainFactor should be < 1.0',
        );
        expect(gainFactor, greaterThan(0.0));
      },
    );

    Glados2(any.doubleInRange(0, 34.9), any.doubleInRange(0, 34.9),
        ExploreConfig(numRuns: 100)).test(
      'expansion region: monotonically decreasing with distance from knee',
      (levelA, levelB) {
        if ((levelA - levelB).abs() < 0.01) return;

        final gainA = computeWdrcGainFactor(
          inputLevelDb: levelA,
          expansionKnee: expansionKnee,
          expansionRatio: expansionRatio,
          compressionKnee: compressionKnee,
          compressionRatio: compressionRatio,
        );
        final gainB = computeWdrcGainFactor(
          inputLevelDb: levelB,
          expansionKnee: expansionKnee,
          expansionRatio: expansionRatio,
          compressionKnee: compressionKnee,
          compressionRatio: compressionRatio,
        );

        // Lower input → more attenuation → lower gainFactor
        if (levelA < levelB) {
          expect(gainA, lessThanOrEqualTo(gainB + 0.0001));
        } else {
          expect(gainB, lessThanOrEqualTo(gainA + 0.0001));
        }
      },
    );

    Glados2(any.doubleInRange(55.1, 120), any.doubleInRange(55.1, 120),
        ExploreConfig(numRuns: 100)).test(
      'compression region: monotonically decreasing with distance from knee',
      (levelA, levelB) {
        if ((levelA - levelB).abs() < 0.01) return;

        final gainA = computeWdrcGainFactor(
          inputLevelDb: levelA,
          expansionKnee: expansionKnee,
          expansionRatio: expansionRatio,
          compressionKnee: compressionKnee,
          compressionRatio: compressionRatio,
        );
        final gainB = computeWdrcGainFactor(
          inputLevelDb: levelB,
          expansionKnee: expansionKnee,
          expansionRatio: expansionRatio,
          compressionKnee: compressionKnee,
          compressionRatio: compressionRatio,
        );

        // Higher input → more compression → lower gainFactor
        if (levelA > levelB) {
          expect(gainA, lessThanOrEqualTo(gainB + 0.0001));
        } else {
          expect(gainB, lessThanOrEqualTo(gainA + 0.0001));
        }
      },
    );
  });
}
