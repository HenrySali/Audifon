// Feature: nal-nl3-prescriptor, Property 4: Determinism (purity)

/// Property-based test para Property 4: dos llamadas consecutivas a
/// `prescribeFromAudiogram` con inputs idénticos producen outputs
/// bit-idénticos (excepto el timestamp, que es lectura del reloj).
///
/// **Validates: Requirements 1.8, 2.8, 9.5**
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

/// Selecciona un PrescriptionMode según el seed.
PrescriptionMode _seedToMode(double seed) {
  final modes = PrescriptionMode.values;
  final idx = (seed.abs() * 1000).floor() % modes.length;
  return modes[idx];
}

/// Genera un perfil determinístico desde el seed.
PatientProfile _seedToProfile(double seed) {
  final months = ((seed.abs() * 100).floor() % 30);
  return PatientProfile(experienceMonths: months);
}

void main() {
  final prescriber = GainPrescriberNL3();

  group('Property 4: NL3 determinism (purity)', () {
    Glados2(
      any.doubleInRange(0, 120),
      any.doubleInRange(0, 100),
      ExploreConfig(numRuns: 200),
    ).test(
      'prescribeFromAudiogram is pure: same inputs → same outputs',
      (thresholdSeed, profileSeed) {
        final audiogram = Audiogram(thresholds: _seedToThresholds(thresholdSeed));
        final profile = _seedToProfile(profileSeed);
        final mode = _seedToMode(profileSeed);

        final r1 = prescriber.prescribeFromAudiogram(
          audiogram,
          profile: profile,
          mode: mode,
        );
        final r2 = prescriber.prescribeFromAudiogram(
          audiogram,
          profile: profile,
          mode: mode,
        );

        // Ganancias bit-idénticas (mismo cálculo, sin floating-point drift).
        expect(r1.prescribedGains, equals(r2.prescribedGains));
        expect(r1.finalGains, equals(r2.finalGains));
        expect(r1.compressionRatios, equals(r2.compressionRatios));
        expect(r1.lossType, equals(r2.lossType));
        expect(r1.mode, equals(r2.mode));
        expect(r1.cinActive, equals(r2.cinActive));
        expect(r1.wdrcOverrides, equals(r2.wdrcOverrides));
        expect(r1.ptaWarning, equals(r2.ptaWarning));
        // El timestamp se excluye intencionalmente: depende del reloj.
      },
    );
  });
}
