// Feature: psk-mobile-hearing-aid, Property 5: Volume dB to linear conversion

/// Property-based test for volume dB to linear factor conversion.
///
/// Property 5: For any volume value in [-20, +10] dB, the linear factor
/// applied to audio SHALL be equal to 10^(volumeDb/20) with tolerance ±0.001.
///
/// **Validates: Requirements 5.3**
import 'dart:math';

import 'package:glados/glados.dart';

import 'dsp_models.dart';

void main() {
  group('Property 5: Volume dB to linear factor', () {
    Glados(any.doubleInRange(-20, 10), ExploreConfig(numRuns: 100)).test(
      'factor = 10^(dB/20) ±0.001',
      (volumeDb) {
        final factor = volumeDbToLinear(volumeDb);
        final expected = pow(10.0, volumeDb / 20.0).toDouble();

        expect(
          factor,
          closeTo(expected, 0.001),
          reason: 'Volume $volumeDb dB: factor=$factor, '
              'expected=$expected (10^($volumeDb/20))',
        );
      },
    );

    Glados(any.doubleInRange(-20, 10), ExploreConfig(numRuns: 100)).test(
      'factor is always positive',
      (volumeDb) {
        final factor = volumeDbToLinear(volumeDb);

        expect(
          factor,
          greaterThan(0.0),
          reason: 'Linear factor must always be positive for any dB value',
        );
      },
    );

    Glados(any.doubleInRange(-20, 10), ExploreConfig(numRuns: 100)).test(
      '0 dB produces factor 1.0, negative dB < 1.0, positive dB > 1.0',
      (volumeDb) {
        final factor = volumeDbToLinear(volumeDb);

        if (volumeDb < -0.01) {
          expect(
            factor,
            lessThan(1.0),
            reason: 'Negative dB ($volumeDb) should produce factor < 1.0, got $factor',
          );
        } else if (volumeDb > 0.01) {
          expect(
            factor,
            greaterThan(1.0),
            reason: 'Positive dB ($volumeDb) should produce factor > 1.0, got $factor',
          );
        } else {
          expect(
            factor,
            closeTo(1.0, 0.01),
            reason: '~0 dB ($volumeDb) should produce factor ~1.0, got $factor',
          );
        }
      },
    );

    Glados2(any.doubleInRange(-20, 10), any.doubleInRange(-20, 10),
        ExploreConfig(numRuns: 100)).test(
      'monotonicity: higher dB → higher factor',
      (dbA, dbB) {
        if ((dbA - dbB).abs() < 0.01) return; // Skip near-equal values

        final factorA = volumeDbToLinear(dbA);
        final factorB = volumeDbToLinear(dbB);

        if (dbA > dbB) {
          expect(
            factorA,
            greaterThan(factorB),
            reason: 'Monotonicity: $dbA dB > $dbB dB, '
                'but factor $factorA ≤ $factorB',
          );
        } else {
          expect(
            factorB,
            greaterThan(factorA),
            reason: 'Monotonicity: $dbB dB > $dbA dB, '
                'but factor $factorB ≤ $factorA',
          );
        }
      },
    );
  });
}
