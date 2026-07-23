// Feature: nal-nl3-prescriptor, Property 12: Headphone compensation correctness

/// Property-based test para Property 12: para cualquier audiograma y mapa
/// de compensación de auricular (offsets en [-20, +20] dB), las ganancias
/// finales son `clamp(prescribed[i] + compensation[freq_i], 0, 50)` por banda.
///
/// **Validates: Requirements 7.3**
library;

import 'package:glados/glados.dart';
import 'package:hearing_aid_app/domain/entities/audiogram.dart';
import 'package:hearing_aid_app/domain/gain_prescriber_nl3.dart';

/// Convierte un seed a 12 umbrales variados en [0, 120] dB HL.
Map<int, double> _seedToThresholds(double seed) {
  final freqs = Audiogram.standardFrequencies;
  final map = <int, double>{};
  for (int i = 0; i < 12; i++) {
    map[freqs[i]] = ((seed * (i + 1) * 7.3) % 120.0).abs();
  }
  return map;
}

/// Convierte un seed a 12 valores de compensación en [-20, +20] dB.
Map<int, double> _seedToCompensation(double seed) {
  final freqs = Audiogram.standardFrequencies;
  final map = <int, double>{};
  for (int i = 0; i < 12; i++) {
    final raw = ((seed * (i + 1) * 3.7) % 40.0).abs();
    map[freqs[i]] = raw - 20.0; // [-20, 20]
  }
  return map;
}

void main() {
  final prescriber = GainPrescriberNL3();
  final freqs = Audiogram.standardFrequencies;

  group('Property 12: Headphone compensation correctness', () {
    Glados2(
      any.doubleInRange(0, 120),
      any.doubleInRange(-20, 20),
      ExploreConfig(numRuns: 200),
    ).test(
      'finalGain[i] == clamp(prescribed[i] + comp[freq_i], 0, 50)',
      (thresholdSeed, compSeed) {
        final audiogram = Audiogram(thresholds: _seedToThresholds(thresholdSeed));
        final compensation = _seedToCompensation(compSeed);

        final result =
            prescriber.prescribeWithCompensation(audiogram, compensation);

        expect(result.prescribedGains.length, equals(12));
        expect(result.finalGains.length, equals(12));

        for (int i = 0; i < 12; i++) {
          final freq = freqs[i];
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
