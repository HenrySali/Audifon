// Feature: nal-nl3-prescriptor, Property 8: MHL flat gain invariant

/// Property-based test para Property 8: en modo MHL, las 12 ganancias
/// prescritas están en el rango [5, 10] dB Y son iguales entre sí (flat),
/// independientemente del audiograma.
///
/// **Validates: Requirements 4.1**
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

void main() {
  final prescriber = GainPrescriberNL3();

  group('Property 8: MHL produces flat gain in [5, 10] dB', () {
    Glados(any.doubleInRange(0, 120), ExploreConfig(numRuns: 200)).test(
      'all 12 gains in [5, 10] dB and equal to each other (flat)',
      (seed) {
        final audiogram = Audiogram(thresholds: _seedToThresholds(seed));

        final result = prescriber.prescribeFromAudiogram(
          audiogram,
          mode: PrescriptionMode.mhl,
        );

        expect(result.prescribedGains.length, equals(12));

        // Cada ganancia en [5, 10] dB.
        for (int i = 0; i < 12; i++) {
          expect(
            result.prescribedGains[i],
            inInclusiveRange(5.0, 10.0),
            reason: 'Band ${Audiogram.standardFrequencies[i]} Hz: '
                'gain=${result.prescribedGains[i]} fuera de [5, 10]',
          );
        }

        // Todas las ganancias iguales entre sí (audiograma flat MHL).
        final first = result.prescribedGains[0];
        for (int i = 1; i < 12; i++) {
          expect(
            result.prescribedGains[i],
            equals(first),
            reason: 'Band ${Audiogram.standardFrequencies[i]} Hz: '
                'gain=${result.prescribedGains[i]} != gain[0]=$first '
                '(MHL debe ser flat)',
          );
        }
      },
    );
  });
}
