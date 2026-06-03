// Feature: nal-nl3-prescriptor, Property 6: CIN speech band preservation

/// Property-based test para Property 6: el módulo CIN preserva la banda de
/// habla (500–4000 Hz, índices 1..9) dentro de ±1 dB respecto a las ganancias
/// core de la prescripción quiet.
///
/// **Validates: Requirements 3.3, 9.4**
library;

import 'package:glados/glados.dart';
import 'package:hearing_aid_app/domain/cin_module.dart';
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
  final freqs = Audiogram.standardFrequencies;

  group('Property 6: CIN preserves speech band (500–4000 Hz)', () {
    Glados(any.doubleInRange(0, 120), ExploreConfig(numRuns: 200)).test(
      '|cin.gains[i] - core[i]| <= 1 dB for speech indices 1..9',
      (seed) {
        final audiogram = Audiogram(thresholds: _seedToThresholds(seed));

        // Prescripción core (modo quiet, sin CIN aplicado).
        final core = prescriber.prescribeFromAudiogram(
          audiogram,
          mode: PrescriptionMode.quiet,
        );

        // Aplicar CIN al output core.
        final cin = CinModule.apply(
          core.prescribedGains,
          core.compressionRatios,
        );

        // Bandas de habla: índices 1..9 (500, 750, 1000, 1500, 2000, 2500,
        // 3000, 3500, 4000 Hz).
        for (int i = 1; i <= 9; i++) {
          final delta = (cin.gains[i] - core.prescribedGains[i]).abs();
          expect(
            delta,
            lessThanOrEqualTo(1.0),
            reason: 'Band ${freqs[i]} Hz: core=${core.prescribedGains[i]}, '
                'cin=${cin.gains[i]}, |delta|=$delta > 1.0',
          );
        }
      },
    );
  });
}
