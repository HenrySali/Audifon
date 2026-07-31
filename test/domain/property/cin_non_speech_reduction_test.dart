// Feature: nal-nl3-prescriptor, Property 7: CIN non-speech band reduction bounded

/// Property-based test para Property 7: el módulo CIN reduce la ganancia en
/// bandas no-speech (índices 0, 10, 11 → 250, 6000, 8000 Hz) entre 3 y 6 dB
/// respecto a la ganancia core, cuando la ganancia core es ≥ 6 dB en esas
/// bandas (para que el clamp inferior no enmascare la reducción).
///
/// **Validates: Requirements 3.2, 3.6**
library;

import 'package:glados/glados.dart';
import 'package:hearing_aid_app/domain/cin_module.dart';
import 'package:hearing_aid_app/domain/entities/audiogram.dart';

/// Genera un set de 12 ganancias core a partir de un seed.
///
/// Garantiza que en las bandas no-speech (índices 0, 10, 11) la ganancia
/// sea ≥ 6 dB para que la reducción CIN no quede enmascarada por el clamp
/// a [0, 50]. Las bandas de habla pueden tomar cualquier valor en [0, 50].
List<double> _seedToCoreGains(double seed) {
  final gains = <double>[];
  const nonSpeech = {0, 10, 11};
  for (int i = 0; i < 12; i++) {
    final raw = ((seed * (i + 1) * 11.7) % 50.0).abs();
    if (nonSpeech.contains(i)) {
      // Garantizar gain ≥ 6 en bandas no-speech.
      gains.add(6.0 + (raw % 44.0)); // [6, 50]
    } else {
      gains.add(raw); // [0, 50]
    }
  }
  return gains;
}

/// Genera 12 compression ratios en [1.0, 3.0] desde un seed.
List<double> _seedToRatios(double seed) {
  final ratios = <double>[];
  for (int i = 0; i < 12; i++) {
    final raw = ((seed * (i + 1) * 5.3) % 2.0).abs();
    ratios.add(1.0 + raw); // [1.0, 3.0]
  }
  return ratios;
}

void main() {
  final freqs = Audiogram.standardFrequencies;

  group('Property 7: CIN reduces non-speech bands by 3..6 dB', () {
    Glados(any.doubleInRange(0, 120), ExploreConfig(numRuns: 200)).test(
      'reduction in [3, 6] dB for indices {0, 10, 11} when core >= 6',
      (seed) {
        final core = _seedToCoreGains(seed);
        final ratios = _seedToRatios(seed);
        final cin = CinModule.apply(core, ratios);

        const nonSpeechIndices = [0, 10, 11];
        for (final idx in nonSpeechIndices) {
          final reduction = core[idx] - cin.gains[idx];
          expect(
            reduction,
            inInclusiveRange(3.0, 6.0),
            reason: 'Band ${freqs[idx]} Hz: core=${core[idx]}, '
                'cin=${cin.gains[idx]}, reduction=$reduction '
                '(esperado [3, 6])',
          );
        }
      },
    );
  });
}
