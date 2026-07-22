// Feature: nal-nl3-prescriptor, Property 10: Monotonicity

/// Property-based test para Property 10: aumentar el threshold en una
/// frecuencia individual por 10 dB no debería disminuir la ganancia
/// prescrita en esa frecuencia (con tolerancia para casos de aclimatización
/// o cambios de notch).
///
/// La monotonicidad puede romperse cuando un cambio de threshold cambia el
/// `LossType` clasificado (por ejemplo cuando aparece un notch). En ese caso
/// se filtra el test — solo verificamos cuando ambos resultados tienen el
/// mismo `lossType`.
///
/// **Validates: Requirements 9.6**
library;

import 'package:glados/glados.dart';
import 'package:hearing_aid_app/domain/entities/audiogram.dart';
import 'package:hearing_aid_app/domain/entities/patient_profile.dart';
import 'package:hearing_aid_app/domain/entities/prescription_mode.dart';
import 'package:hearing_aid_app/domain/gain_prescriber_nl3.dart';

/// Convierte un seed a 12 umbrales variados en [0, 100] dB HL.
/// Se acota a 100 para dar lugar al incremento de 10 dB sin chocar con 120.
Map<int, double> _seedToThresholds(double seed) {
  final freqs = Audiogram.standardFrequencies;
  final map = <int, double>{};
  for (int i = 0; i < 12; i++) {
    map[freqs[i]] = ((seed * (i + 1) * 7.3) % 100.0).abs();
  }
  return map;
}

void main() {
  final prescriber = GainPrescriberNL3();
  final freqs = Audiogram.standardFrequencies;

  group('Property 10: NL3 monotonicity (gain non-decreasing in HL)', () {
    Glados2(
      any.doubleInRange(0, 120),
      any.doubleInRange(0, 11.999),
      ExploreConfig(numRuns: 200),
    ).test(
      'increasing HL by 10 dB at one freq does not decrease its gain',
      (thresholdSeed, idxSeed) {
        final base = _seedToThresholds(thresholdSeed);
        final bumpIdx = idxSeed.floor().clamp(0, 11);
        final bumpFreq = freqs[bumpIdx];

        // Audiograma original.
        final a1 = Audiogram(thresholds: Map<int, double>.from(base));

        // Audiograma con +10 dB en una sola frecuencia.
        final base2 = Map<int, double>.from(base);
        base2[bumpFreq] = (base2[bumpFreq]! + 10.0).clamp(0.0, 120.0);
        final a2 = Audiogram(thresholds: base2);

        final r1 = prescriber.prescribeFromAudiogram(
          a1,
          profile: const PatientProfile(experienceMonths: 24),
          mode: PrescriptionMode.quiet,
        );
        final r2 = prescriber.prescribeFromAudiogram(
          a2,
          profile: const PatientProfile(experienceMonths: 24),
          mode: PrescriptionMode.quiet,
        );

        // Si el LossType cambia, la propiedad se relaja (cambio de régimen).
        if (r1.lossType != r2.lossType) return;

        // Tolerancia 0.001 dB para errores de coma flotante.
        expect(
          r2.prescribedGains[bumpIdx],
          greaterThanOrEqualTo(r1.prescribedGains[bumpIdx] - 0.001),
          reason: 'Freq $bumpFreq Hz: gain antes=${r1.prescribedGains[bumpIdx]}, '
              'gain después=${r2.prescribedGains[bumpIdx]} '
              '(loss=${r1.lossType.name})',
        );
      },
    );
  });
}
