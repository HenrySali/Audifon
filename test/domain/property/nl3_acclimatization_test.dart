// Feature: nal-nl3-prescriptor, Property 11: New-user acclimatization offset

/// Property-based test para Property 11: las ganancias para un usuario nuevo
/// (experienceMonths < 6) son exactamente 3 dB menores que las de un usuario
/// experimentado (experienceMonths >= 6) en cada banda, antes del clamp.
///
/// El clamp a [0, 50] interfiere cuando la ganancia experimentada es < 3
/// (la del nuevo usuario quedaría < 0 y se clampea a 0) o cuando está cerca
/// del techo de 50. Esos casos se filtran.
///
/// **Validates: Requirements 2.6**
library;

import 'package:glados/glados.dart';
import 'package:hearing_aid_app/domain/entities/audiogram.dart';
import 'package:hearing_aid_app/domain/entities/patient_profile.dart';
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

  group('Property 11: NL3 new-user acclimatization offset (-3 dB)', () {
    Glados(any.doubleInRange(0, 120), ExploreConfig(numRuns: 200)).test(
      'new user gain == experienced gain - 3 dB per band (pre-clamp)',
      (seed) {
        final audiogram = Audiogram(thresholds: _seedToThresholds(seed));

        final experienced = prescriber.prescribeFromAudiogram(
          audiogram,
          profile: const PatientProfile(experienceMonths: 24),
          mode: PrescriptionMode.quiet,
        );
        final newUser = prescriber.prescribeFromAudiogram(
          audiogram,
          profile: const PatientProfile(experienceMonths: 3),
          mode: PrescriptionMode.quiet,
        );

        for (int i = 0; i < 12; i++) {
          final exp = experienced.prescribedGains[i];
          final newU = newUser.prescribedGains[i];

          if (exp > 3.0 && newU > 3.0) {
            // Ambas ganancias por encima del piso 0 (sin clamp interferente):
            // diferencia exacta de 3 dB con tolerancia de coma flotante.
            final diff = exp - newU;
            expect(
              diff,
              closeTo(3.0, 0.001),
              reason: 'Band ${Audiogram.standardFrequencies[i]} Hz: '
                  'experienced=$exp, newUser=$newU, diff=$diff '
                  '(esperado 3.0)',
            );
          } else {
            // Si experienced ≤ 3, el clamp a 0 reduce la diferencia: solo
            // garantizamos que la nueva ganancia no supere a la experimentada.
            expect(
              exp,
              greaterThanOrEqualTo(newU - 0.001),
              reason: 'Band ${Audiogram.standardFrequencies[i]} Hz: '
                  'experienced=$exp < newUser=$newU '
                  '(clamp esperado pero ordenamiento debe preservarse)',
            );
          }
        }
      },
    );
  });
}
