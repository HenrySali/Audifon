// Feature: nal-nl3-prescriptor, Property 13: CIN compression ratio reduction

/// Property-based test para Property 13: los ratios de compresión en modo CIN
/// son `max(1.0, quietRatio - 0.2)` para cada banda, respecto al cálculo en
/// modo quiet con el mismo audiograma y loss type.
///
/// **Validates: Requirements 10.4**
library;

import 'dart:math' as math;

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

  group('Property 13: CIN ratio = max(1.0, quietRatio - 0.2)', () {
    Glados(any.doubleInRange(0, 120), ExploreConfig(numRuns: 200)).test(
      'CIN compression ratios derived from quiet ratios with floor 1.0',
      (seed) {
        final audiogram = Audiogram(thresholds: _seedToThresholds(seed));
        // Loss type clasificado a partir del audiograma; debe ser igual en
        // ambas llamadas para aislar el efecto del modo.
        final lossType = prescriber.classifyAudiogram(audiogram);

        final quietRatios = prescriber.computeCompressionRatios(
          audiogram,
          lossType,
          mode: PrescriptionMode.quiet,
        );
        final cinRatios = prescriber.computeCompressionRatios(
          audiogram,
          lossType,
          mode: PrescriptionMode.comfortInNoise,
        );

        for (int i = 0; i < 12; i++) {
          final expected = math.max(1.0, quietRatios[i] - 0.2);
          expect(
            cinRatios[i],
            closeTo(expected, 0.001),
            reason: 'Band ${Audiogram.standardFrequencies[i]} Hz '
                '(loss=${lossType.name}): quiet=${quietRatios[i]}, '
                'cin=${cinRatios[i]}, expected=$expected',
          );
        }
      },
    );
  });
}
