// Feature: nal-nl3-prescriptor, Property 3: Classifier totality

/// Property-based test para Property 3: para cualquier vector de 12 umbrales
/// en [0, 120] dB HL, el `AudiogramClassifier.classify` retorna exactamente
/// un `LossType` válido sin lanzar excepciones.
///
/// Esta propiedad es crítica (función total): se ejecuta con 500 iteraciones.
///
/// **Validates: Requirements 1.1, 9.3**
library;

import 'package:glados/glados.dart';
import 'package:hearing_aid_app/domain/entities/audiogram.dart';
import 'package:hearing_aid_app/domain/entities/loss_type.dart';

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
  group('Property 3: AudiogramClassifier totality', () {
    // Propiedad crítica → 500 iteraciones para mayor cobertura del espacio.
    Glados(any.doubleInRange(0, 120), ExploreConfig(numRuns: 500)).test(
      'classify returns exactly one LossType without throwing',
      (seed) {
        final audiogram = Audiogram(thresholds: _seedToThresholds(seed));

        // No debe lanzar ninguna excepción.
        late LossType result;
        expect(
          () => result = AudiogramClassifier.classify(audiogram),
          returnsNormally,
          reason: 'classify lanzó excepción para audiograma '
              '${audiogram.thresholds}',
        );

        // El resultado debe ser uno de los valores válidos del enum.
        expect(LossType.values, contains(result));
      },
    );
  });
}
