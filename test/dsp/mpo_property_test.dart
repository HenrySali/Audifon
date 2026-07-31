// Feature: psk-mobile-hearing-aid, Property 4: MPO output limiting
// Feature: psk-mobile-hearing-aid, Property 8: MPO impulse response

/// Property-based tests for MPO limiter.
///
/// **Validates: Requirements 2.6, 7.3, 9.1, 9.5**
import 'dart:math';

import 'package:glados/glados.dart';

import 'dsp_models.dart';

/// Generate a 64-sample buffer from a seed value.
List<double> _seedToBuffer(double seed, double range) {
  final rng = Random(seed.hashCode);
  return List.generate(64, (_) => (rng.nextDouble() * 2 - 1) * range);
}

void main() {
  // MPO threshold: 0.316 linear ≈ -10 dBFS
  const mpoThresholdLinear = 0.316;

  group('Property 4: MPO limits output — no sample exceeds threshold', () {
    Glados(any.doubleInRange(-1000, 1000), ExploreConfig(numRuns: 100)).test(
      'no output sample exceeds threshold after attack time',
      (seed) {
        final buffer = _seedToBuffer(seed, 2.0); // Range [-2, +2]

        final output = mpoLimit(
          buffer: buffer,
          thresholdLinear: mpoThresholdLinear,
        );

        expect(output.length, equals(64));

        // After attack time (16 samples), all samples should be limited
        for (int i = 16; i < output.length; i++) {
          expect(
            output[i].abs(),
            lessThanOrEqualTo(mpoThresholdLinear * 1.05),
            reason: 'Sample $i: |${output[i]}| exceeds threshold $mpoThresholdLinear',
          );
        }
      },
    );

    Glados(any.doubleInRange(-1000, 1000), ExploreConfig(numRuns: 100)).test(
      'MPO never amplifies — output magnitude ≤ input magnitude',
      (seed) {
        final buffer = _seedToBuffer(seed, 2.0);

        final output = mpoLimit(
          buffer: buffer,
          thresholdLinear: mpoThresholdLinear,
        );

        for (int i = 0; i < output.length; i++) {
          expect(
            output[i].abs(),
            lessThanOrEqualTo(buffer[i].abs() + 0.001),
            reason: 'MPO amplified sample $i: input=${buffer[i]}, output=${output[i]}',
          );
        }
      },
    );
  });

  group('Property 8: MPO impulse response within 16 samples', () {
    Glados(any.doubleInRange(0.4, 2.0), ExploreConfig(numRuns: 100)).test(
      'attenuation reduces output below threshold within 16 samples',
      (amplitude) {
        // Create a buffer with a single impulse followed by silence
        final buffer = List<double>.filled(64, 0.0);
        buffer[0] = amplitude;

        final output = mpoLimit(
          buffer: buffer,
          thresholdLinear: mpoThresholdLinear,
        );

        // After 16 samples, the output should be below threshold
        for (int i = 16; i < output.length; i++) {
          expect(
            output[i].abs(),
            lessThanOrEqualTo(mpoThresholdLinear * 1.01),
            reason: 'After impulse, sample $i should be below threshold. '
                'Got ${output[i].abs()}, threshold=$mpoThresholdLinear',
          );
        }
      },
    );

    Glados(any.doubleInRange(0.4, 2.0), ExploreConfig(numRuns: 100)).test(
      'sustained over-threshold signal is continuously limited',
      (amplitude) {
        final buffer = List<double>.filled(64, amplitude);

        final output = mpoLimit(
          buffer: buffer,
          thresholdLinear: mpoThresholdLinear,
        );

        // After attack time (16 samples), all output should be limited
        for (int i = 16; i < output.length; i++) {
          expect(
            output[i].abs(),
            lessThanOrEqualTo(mpoThresholdLinear * 1.05),
            reason: 'Sustained signal: sample $i = ${output[i].abs()} '
                'exceeds threshold $mpoThresholdLinear',
          );
        }
      },
    );
  });
}
