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

/// Convert a seed value to a clinically realistic descending audiogram
/// (presbycusis profile: HL grows with frequency, the common case where
/// NAL-NL2 emphasizes 2-4 kHz for speech intelligibility).
Map<int, double> _seedToDescendingAudiogram(double seed) {
  final freqs = Audiogram.standardFrequencies;
  final map = <int, double>{};
  // Base HL at 250 Hz in [10, 50], slope 1-4 dB per band toward 8 kHz.
  final base = 10.0 + (seed * 7.0) % 40.0;
  final slope = 1.0 + (seed * 3.1) % 3.0;
  for (int i = 0; i < 12; i++) {
    map[freqs[i]] = (base + slope * i).clamp(0.0, 120.0);
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
      '2-4 kHz emphasis on descending (presbycusis-like) audiograms',
      (seed) {
        // NAL-NL2 emphasizes 2-4 kHz for speech intelligibility *when the
        // audiogram has more loss in that region*. With pseudo-random
        // multiplicative seeds the per-band HL pattern can be erratic
        // (low band 17 dB, mid band 34 dB, high band 8 dB, etc.), and
        // the 2-4 kHz emphasis is a property of the audiogram shape
        // rather than of the prescriber. We therefore restrict the
        // property to clinically realistic descending profiles.
        final thresholds = _seedToDescendingAudiogram(seed);
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
          reason: 'Avg 2-4kHz ($avg2to4kHz) should be >= avg outside '
              '($avgOutside) for descending profile thresholds=$thresholds',
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
