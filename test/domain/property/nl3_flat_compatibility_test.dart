// Feature: nal-nl3-prescriptor, Property 5: Flat audiogram NL2 compatibility

/// Property-based test para Property 5: para audiogramas planos clasificados
/// como `flat`, perfil experimentado y modo quiet, las ganancias NL3 deben
/// estar dentro de 1 dB de las ganancias NL2 base en cada banda.
///
/// **Validates: Requirements 9.2**
library;

import 'package:glados/glados.dart';
import 'package:hearing_aid_app/domain/entities/audiogram.dart';
import 'package:hearing_aid_app/domain/entities/loss_type.dart';
import 'package:hearing_aid_app/domain/entities/patient_profile.dart';
import 'package:hearing_aid_app/domain/entities/prescription_mode.dart';
import 'package:hearing_aid_app/domain/gain_prescriber.dart';
import 'package:hearing_aid_app/domain/gain_prescriber_nl3.dart';

/// Convierte un par de seeds en un audiograma plano:
/// nivel base ∈ [30, 60] dB y variación por banda ≤ ±5 dB.
Map<int, double> _seedToFlatThresholds(double baseSeed, double jitterSeed) {
  final freqs = Audiogram.standardFrequencies;
  // Nivel base en [30, 60] (a partir del seed normalizado).
  final base = 30.0 + (baseSeed.abs() % 30.0);
  final map = <int, double>{};
  for (int i = 0; i < 12; i++) {
    // Jitter pseudo-aleatorio en [-5, 5] derivado del seed.
    final raw = (jitterSeed * (i + 1) * 13.7) % 10.0;
    final jitter = raw - 5.0; // [-5, 5]
    map[freqs[i]] = (base + jitter).clamp(0.0, 120.0);
  }
  return map;
}

void main() {
  final nl2 = GainPrescriber();
  final nl3 = GainPrescriberNL3(nl2Prescriber: nl2);

  group('Property 5: Flat audiogram NL2 compatibility', () {
    Glados2(
      any.doubleInRange(0, 100),
      any.doubleInRange(0, 100),
      ExploreConfig(numRuns: 200),
    ).test(
      '|NL3 - NL2| <= 1 dB per band when flat + experienced + quiet',
      (baseSeed, jitterSeed) {
        final thresholds = _seedToFlatThresholds(baseSeed, jitterSeed);
        final audiogram = Audiogram(thresholds: thresholds);

        // Verificar que el audiograma sea efectivamente clasificado como flat.
        // Si por casualidad caye en otra clasificación, lo ignoramos para no
        // ensuciar el espacio de la propiedad (el test es sobre flat).
        final lossType = AudiogramClassifier.classify(audiogram);
        if (lossType != LossType.flat) return;

        final nl2Gains = nl2.prescribeFromAudiogram(audiogram);
        final nl3Result = nl3.prescribeFromAudiogram(
          audiogram,
          profile: const PatientProfile(experienceMonths: 24),
          mode: PrescriptionMode.quiet,
        );

        for (int i = 0; i < 12; i++) {
          final diff = (nl3Result.prescribedGains[i] - nl2Gains[i]).abs();
          expect(
            diff,
            lessThanOrEqualTo(1.0),
            reason: 'Band ${Audiogram.standardFrequencies[i]} Hz: '
                'NL3=${nl3Result.prescribedGains[i]}, NL2=${nl2Gains[i]}, '
                'diff=$diff > 1.0',
          );
        }
      },
    );
  });
}
