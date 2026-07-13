// Feature: nal-nl3-prescriptor, Property 1: NL3 output invariant (gains)

/// Property-based test para Property 1: las ganancias NL3 siempre tienen
/// 12 valores en [0, 50] dB, para cualquier audiograma, perfil y modo.
///
/// **Validates: Requirements 2.7, 3.7, 7.1, 7.2**
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
    // Distribución pseudo-hash desde el seed para variar por banda.
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

/// Genera un perfil con experiencia y conducción ósea opcional según seed.
PatientProfile _seedToProfile(double seed) {
  final months = ((seed.abs() * 100).floor() % 30); // [0, 30) meses
  return PatientProfile(experienceMonths: months);
}

void main() {
  final prescriber = GainPrescriberNL3();

  group('Property 1: NL3 output invariant (gains)', () {
    Glados2(
      any.doubleInRange(0, 120),
      any.doubleInRange(0, 100),
      ExploreConfig(numRuns: 200),
    ).test(
      'all 12 prescribedGains are in [0, 50] dB for any audiogram/profile/mode',
      (thresholdSeed, profileSeed) {
        final thresholds = _seedToThresholds(thresholdSeed);
        final audiogram = Audiogram(thresholds: thresholds);
        final profile = _seedToProfile(profileSeed);
        final mode = _seedToMode(profileSeed);

        final result = prescriber.prescribeFromAudiogram(
          audiogram,
          profile: profile,
          mode: mode,
        );

        expect(result.prescribedGains.length, equals(12));
        for (int i = 0; i < 12; i++) {
          expect(
            result.prescribedGains[i],
            inInclusiveRange(0.0, 50.0),
            reason:
                'Band ${Audiogram.standardFrequencies[i]} Hz (mode=$mode): '
                '${result.prescribedGains[i]} dB out of [0, 50]',
          );
        }
        // El array de finalGains comparte la misma invariante.
        expect(result.finalGains.length, equals(12));
        for (int i = 0; i < 12; i++) {
          expect(
            result.finalGains[i],
            inInclusiveRange(0.0, 50.0),
            reason: 'finalGains[$i] = ${result.finalGains[i]} fuera de [0, 50]',
          );
        }
      },
    );
  });
}
