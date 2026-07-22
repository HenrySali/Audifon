/// Tests unitarios para CinModule (Comfort in Noise).
///
/// Verifica la lógica de reducción selectiva de ganancia en bandas
/// no-speech, preservación de la banda de habla, y overrides WDRC.
///
/// Requisitos validados: 3.1, 3.2, 3.3, 3.4, 3.5, 3.6, 3.7
import 'package:flutter_test/flutter_test.dart';
import 'package:hearing_aid_app/domain/cin_module.dart';

void main() {
  group('CinModule.apply', () {
    test('retorna 12 valores de ganancia', () {
      final coreGains = List<double>.filled(12, 20.0);
      final coreRatios = List<double>.filled(12, 1.5);

      final result = CinModule.apply(coreGains, coreRatios);

      expect(result.gains.length, equals(12));
    });

    test('retorna 12 ratios de compresión', () {
      final coreGains = List<double>.filled(12, 20.0);
      final coreRatios = List<double>.filled(12, 1.5);

      final result = CinModule.apply(coreGains, coreRatios);

      expect(result.compressionRatios.length, equals(12));
    });

    test('todas las ganancias están en rango [0, 50] dB', () {
      final coreGains = List<double>.filled(12, 25.0);
      final coreRatios = List<double>.filled(12, 1.5);

      final result = CinModule.apply(coreGains, coreRatios);

      for (int i = 0; i < 12; i++) {
        expect(
          result.gains[i],
          inInclusiveRange(0.0, 50.0),
          reason: 'Banda $i: ${result.gains[i]} fuera de rango [0, 50]',
        );
      }
    });

    test('reduce ganancia 3–6 dB en bandas no-speech (índices 0, 10, 11)', () {
      // Ganancias moderadas para que la reducción sea visible.
      final coreGains = List<double>.filled(12, 30.0);
      final coreRatios = List<double>.filled(12, 1.5);

      final result = CinModule.apply(coreGains, coreRatios);

      // Bandas no-speech: 250 Hz (idx 0), 6000 Hz (idx 10), 8000 Hz (idx 11).
      const nonSpeechIndices = [0, 10, 11];
      for (final idx in nonSpeechIndices) {
        final reduction = coreGains[idx] - result.gains[idx];
        expect(
          reduction,
          inInclusiveRange(3.0, 6.0),
          reason:
              'Banda no-speech idx=$idx: reducción de $reduction dB '
              'fuera del rango [3, 6]',
        );
      }
    });

    test('preserva banda de habla (500–4000 Hz) dentro de 1 dB del core', () {
      final coreGains = List<double>.filled(12, 25.0);
      final coreRatios = List<double>.filled(12, 1.5);

      final result = CinModule.apply(coreGains, coreRatios);

      // Banda de habla: índices 1–9 (500, 750, 1000, ..., 4000 Hz).
      for (int i = 1; i <= 9; i++) {
        final diff = (result.gains[i] - coreGains[i]).abs();
        expect(
          diff,
          lessThanOrEqualTo(1.0),
          reason:
              'Banda de habla idx=$i: diferencia de $diff dB '
              'excede el límite de 1 dB',
        );
      }
    });

    test('WDRC overrides: attack=10ms, release=150ms', () {
      final coreGains = List<double>.filled(12, 20.0);
      final coreRatios = List<double>.filled(12, 1.5);

      final result = CinModule.apply(coreGains, coreRatios);

      expect(result.wdrcOverrides.attackMs, equals(10.0));
      expect(result.wdrcOverrides.releaseMs, equals(150.0));
    });

    test('reducción total broadband no excede 6 dB', () {
      // Ganancias altas para maximizar reducción.
      final coreGains = List<double>.filled(12, 50.0);
      final coreRatios = List<double>.filled(12, 2.0);

      final result = CinModule.apply(coreGains, coreRatios);

      // Reducción broadband = promedio de todas las reducciones.
      double totalReduction = 0.0;
      for (int i = 0; i < 12; i++) {
        totalReduction += (coreGains[i] - result.gains[i]);
      }
      final avgReduction = totalReduction / 12.0;

      expect(
        avgReduction,
        lessThanOrEqualTo(6.0),
        reason:
            'Reducción broadband promedio de $avgReduction dB '
            'excede el límite de 6 dB',
      );
    });

    test('ganancias no bajan de 0 dB (clamp inferior)', () {
      // Ganancias bajas donde la reducción podría resultar en negativo.
      final coreGains = [2.0, 20.0, 20.0, 20.0, 20.0, 20.0, 20.0, 20.0, 20.0, 20.0, 2.0, 2.0];
      final coreRatios = List<double>.filled(12, 1.5);

      final result = CinModule.apply(coreGains, coreRatios);

      for (int i = 0; i < 12; i++) {
        expect(
          result.gains[i],
          greaterThanOrEqualTo(0.0),
          reason: 'Banda $i: ganancia ${result.gains[i]} menor que 0',
        );
      }
    });

    test('reducción proporcional: mayor ganancia → mayor reducción', () {
      // Banda 250 Hz con ganancia alta, bandas 6k/8k con ganancia baja.
      final coreGains = [45.0, 20.0, 20.0, 20.0, 20.0, 20.0, 20.0, 20.0, 20.0, 20.0, 10.0, 10.0];
      final coreRatios = List<double>.filled(12, 1.5);

      final result = CinModule.apply(coreGains, coreRatios);

      final reduction250 = coreGains[0] - result.gains[0];
      final reduction6k = coreGains[10] - result.gains[10];
      final reduction8k = coreGains[11] - result.gains[11];

      // La reducción en 250 Hz (ganancia=45) debe ser mayor que en 6k/8k (ganancia=10).
      expect(
        reduction250,
        greaterThan(reduction6k),
        reason:
            'Reducción en 250 Hz ($reduction250) debería ser mayor '
            'que en 6000 Hz ($reduction6k)',
      );
      expect(
        reduction250,
        greaterThan(reduction8k),
        reason:
            'Reducción en 250 Hz ($reduction250) debería ser mayor '
            'que en 8000 Hz ($reduction8k)',
      );
    });

    test('ratios de compresión reducidos en 0.2 con piso en 1.0', () {
      final coreGains = List<double>.filled(12, 20.0);
      final coreRatios = [1.1, 1.2, 1.3, 1.5, 1.8, 2.0, 2.2, 2.0, 1.8, 1.5, 1.3, 1.1];

      final result = CinModule.apply(coreGains, coreRatios);

      for (int i = 0; i < 12; i++) {
        final expected = (coreRatios[i] - 0.2).clamp(1.0, double.infinity);
        expect(
          result.compressionRatios[i],
          closeTo(expected, 0.001),
          reason:
              'Ratio banda $i: esperado $expected, obtenido '
              '${result.compressionRatios[i]}',
        );
      }
    });

    test('ratio no baja de 1.0 aunque core sea 1.0', () {
      final coreGains = List<double>.filled(12, 20.0);
      final coreRatios = List<double>.filled(12, 1.0);

      final result = CinModule.apply(coreGains, coreRatios);

      for (int i = 0; i < 12; i++) {
        expect(
          result.compressionRatios[i],
          greaterThanOrEqualTo(1.0),
          reason: 'Ratio banda $i menor que 1.0',
        );
      }
    });
  });
}
