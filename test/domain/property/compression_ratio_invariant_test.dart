// Feature: nal-nl3-prescriptor, Property 2: Output invariant (compression ratios)

/// Property-based test para Property 2: los ratios de compresión NL3 siempre
/// son 12 valores en el rango [1.0, 3.0] para cualquier audiograma, loss type
/// y modo de prescripción.
///
/// **Validates: Requirements 10.1, 10.5**
library;

import 'package:glados/glados.dart';
import 'package:hearing_aid_app/domain/entities/audiogram.dart';
import 'package:hearing_aid_app/domain/entities/prescription_mode.dart';
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

/// Selecciona un PrescriptionMode según el seed (uniforme entre los 3).
PrescriptionMode _seedToMode(double seed) {
  final modes = PrescriptionMode.values;
  final idx = (seed.abs() * 1000).floor() % modes.length;
  return modes[idx];
}

void main() {
  final prescriber = GainPrescriberNL3();

  group('Property 2: NL3 compression ratios invariant', () {
    Glados2(
      any.doubleInRange(0, 120),
      any.doubleInRange(0, 100),
      ExploreConfig(numRuns: 200),
    ).test(
      'all 12 compression ratios are in [1.0, 3.0]',
      (thresholdSeed, modeSeed) {
        final audiogram = Audiogram(thresholds: _seedToThresholds(thresholdSeed));
        final mode = _seedToMode(modeSeed);

        final result = prescriber.prescribeFromAudiogram(audiogram, mode: mode);

        expect(result.compressionRatios.length, equals(12));
        for (int i = 0; i < 12; i++) {
          expect(
            result.compressionRatios[i],
            inInclusiveRange(1.0, 3.0),
            reason: 'Band ${Audiogram.standardFrequencies[i]} Hz '
                '(mode=$mode): ratio=${result.compressionRatios[i]} '
                'fuera de [1.0, 3.0]',
          );
        }
      },
    );
  });
}
