// Feature: psk-mobile-hearing-aid, Property 1: NAL-NL2 prescription produces valid gains with 2-4 kHz emphasis
// Feature: psk-mobile-hearing-aid, Property 9: Headphone compensation applied correctly to EQ

/// Property-based tests for GainPrescriber.
///
/// **Validates: Requirements 2.3, 4.2, Calibración de auriculares**
import 'package:glados/glados.dart';
import 'package:hearing_aid_app/domain/gain_prescriber.dart';
import 'package:hearing_aid_app/domain/entities/audiogram.dart';

/// Convert a seed value to 12 varied threshold values in [0, 120].
Map<int, double> _seedToThresholds(double seed) {
  final freqs = Audiogram.standardFrequencies;
  final map = <int, double>{};
  for (int i = 0; i < 12; i++) {
    // Create varied values from seed using simple hash-like distribution
    map[freqs[i]] = ((seed * (i + 1) * 7.3) % 120.0).abs();
  }
  return map;
}

/// Convert a seed value to 12 varied compensation values in [-20, 20].
Map<int, double> _seedToCompensation(double seed) {
  final freqs = GainPrescriber.bandFrequencies;
  final map = <int, double>{};
  for (int i = 0; i < 12; i++) {
    map[freqs[i]] = ((seed * (i + 1) * 3.7) % 40.0).abs() - 20.0;
  }
  return map;
}

void main() {
  final prescriber = GainPrescriber();

  group('Property 1: NAL-NL2 prescription produces valid gains with 2-4 kHz emphasis', () {
    Glados(any.doubleInRange(0, 120), ExploreConfig(numRuns: 100)).test(
      'all 12 gains are in [0, 50] dB for any valid audiogram',
      (seed) {
        final thresholds = _seedToThresholds(seed);
        final audiogram = Audiogram(thresholds: thresholds);
        final gains = prescriber.prescribeFromAudiogram(audiogram);

        expect(gains.length, equals(12));
        for (int i = 0; i < 12; i++) {
          expect(
            gains[i],
            inInclusiveRange(0.0, 50.0),
            reason: 'Band ${GainPrescriber.bandFrequencies[i]} Hz: '
                '${gains[i]} dB out of range [0, 50]',
          );
        }
      },
    );

    Glados(any.doubleInRange(30, 120), ExploreConfig(numRuns: 100)).test(
      '2-4 kHz emphasis when average HL > 20 dB',
      (seed) {
        final thresholds = _seedToThresholds(seed);
        final avgHl = thresholds.values.reduce((a, b) => a + b) / 12.0;
        if (avgHl <= 20.0) return;

        final audiogram = Audiogram(thresholds: thresholds);
        final gains = prescriber.prescribeFromAudiogram(audiogram);

        // Average gain in 2-4 kHz (bands 5-9: 2000, 2500, 3000, 3500, 4000 Hz)
        final avg2to4kHz =
            (gains[5] + gains[6] + gains[7] + gains[8] + gains[9]) / 5.0;

        // Average gain outside 2-4 kHz (bands 0-4, 10-11)
        final avgOutside =
            (gains[0] + gains[1] + gains[2] + gains[3] + gains[4] +
                gains[10] + gains[11]) / 7.0;

        expect(
          avg2to4kHz,
          greaterThanOrEqualTo(avgOutside),
          reason: 'Avg 2-4kHz ($avg2to4kHz) should be >= avg outside ($avgOutside) '
              'for avgHL=$avgHl',
        );
      },
    );
  });

  group('Property 9: Headphone compensation applied correctly', () {
    Glados2(any.doubleInRange(0, 120), any.doubleInRange(-20, 20),
        ExploreConfig(numRuns: 100)).test(
      'finalGain = prescribed + compensation, clamped [0, 50]',
      (thresholdSeed, compSeed) {
        final thresholds = _seedToThresholds(thresholdSeed);
        final compensation = _seedToCompensation(compSeed);
        final audiogram = Audiogram(thresholds: thresholds);

        final result =
            prescriber.prescribeWithCompensation(audiogram, compensation);

        expect(result.prescribedGains.length, equals(12));
        expect(result.finalGains.length, equals(12));

        for (int i = 0; i < 12; i++) {
          final freq = GainPrescriber.bandFrequencies[i];
          final comp = compensation[freq] ?? 0.0;
          final expected =
              (result.prescribedGains[i] + comp).clamp(0.0, 50.0);
          expect(
            result.finalGains[i],
            closeTo(expected, 0.001),
            reason: 'Band $freq Hz: prescribed=${result.prescribedGains[i]}, '
                'comp=$comp, expected=$expected, got=${result.finalGains[i]}',
          );
        }
      },
    );
  });
}
