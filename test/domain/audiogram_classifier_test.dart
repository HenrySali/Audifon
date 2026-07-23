/// Tests unitarios para AudiogramClassifier.
///
/// Verifica la clasificación de forma del audiograma en cada uno de los
/// tipos de pérdida reconocidos (flat, sloping, reverseSlope, cookieBite,
/// notch, mixed) y los edge cases de entrada inválida.
///
/// Requisitos validados: 1.1, 1.2, 1.3, 1.4, 1.5, 1.6, 1.7, 1.8
import 'package:flutter_test/flutter_test.dart';
import 'package:hearing_aid_app/domain/entities/audiogram.dart';
import 'package:hearing_aid_app/domain/entities/loss_type.dart';

void main() {
  group('AudiogramClassifier - clasificación canónica por LossType', () {
    test('clasifica audiograma plano como flat', () {
      // Todos los umbrales similares (~40 dB): sin diferencias significativas.
      final audiogram = const Audiogram(thresholds: {
        250: 40,
        500: 40,
        750: 40,
        1000: 40,
        1500: 40,
        2000: 40,
        2500: 40,
        3000: 40,
        3500: 40,
        4000: 40,
        6000: 40,
        8000: 40,
      });

      final result = AudiogramClassifier.classify(audiogram);

      expect(result, equals(LossType.flat));
    });

    test('clasifica audiograma descendente como sloping', () {
      // Umbrales bajos en graves (20 dB), altos en agudos (60+ dB).
      // avgLow = 20, avgHigh = 65 → avgHigh - avgLow = 45 > 20
      final audiogram = const Audiogram(thresholds: {
        250: 20,
        500: 20,
        750: 20,
        1000: 20,
        1500: 30,
        2000: 35,
        2500: 40,
        3000: 45,
        3500: 60,
        4000: 65,
        6000: 70,
        8000: 65,
      });

      final result = AudiogramClassifier.classify(audiogram);

      expect(result, equals(LossType.sloping));
    });

    test('clasifica audiograma con pendiente inversa como reverseSlope', () {
      // Umbrales altos en graves (60+ dB), bajos en agudos (25 dB).
      // avgLow = 60, avgHigh = 25 → avgLow - avgHigh = 35 > 15
      final audiogram = const Audiogram(thresholds: {
        250: 60,
        500: 60,
        750: 60,
        1000: 60,
        1500: 50,
        2000: 45,
        2500: 40,
        3000: 35,
        3500: 25,
        4000: 25,
        6000: 25,
        8000: 25,
      });

      final result = AudiogramClassifier.classify(audiogram);

      expect(result, equals(LossType.reverseSlope));
    });

    test('clasifica audiograma con forma de galletita como cookieBite', () {
      // Medios altos (55 dB), extremos bajos (30 dB).
      // avgLow = 30, avgMid = 55, avgHigh = 30
      // avgMid - avgLow = 25 > 15, avgMid - avgHigh = 25 > 15
      // Transición gradual para no disparar notch en 3k–6k Hz.
      // Notch check en 3000: adj = (2500=55, 3500=45) → avg=50, diff=55-50=5 < 15 ✓
      // Notch check en 3500: adj = (3000=55, 4000=35) → avg=45, diff=45-45=0 < 15 ✓
      final audiogram = const Audiogram(thresholds: {
        250: 30,
        500: 30,
        750: 30,
        1000: 30,
        1500: 55,
        2000: 55,
        2500: 55,
        3000: 55,
        3500: 45,
        4000: 35,
        6000: 25,
        8000: 15,
      });

      final result = AudiogramClassifier.classify(audiogram);

      expect(result, equals(LossType.cookieBite));
    });

    test('clasifica audiograma con muesca como notch', () {
      // Una frecuencia en 3k–6k Hz mucho mayor que sus adyacentes (≥15 dB).
      // 4000 Hz = 60 dB, adyacentes (3500=30, 6000=30) → promedio adyacentes = 30
      // Diferencia = 60 - 30 = 30 ≥ 15
      final audiogram = const Audiogram(thresholds: {
        250: 30,
        500: 30,
        750: 30,
        1000: 30,
        1500: 30,
        2000: 30,
        2500: 30,
        3000: 30,
        3500: 30,
        4000: 60,
        6000: 30,
        8000: 30,
      });

      final result = AudiogramClassifier.classify(audiogram);

      expect(result, equals(LossType.notch));
    });

    test('clasifica audiograma con componente conductivo como mixed', () {
      // Air-bone gap > 10 dB en 2 o más frecuencias.
      // Conducción aérea: 50 dB en todas las frecuencias.
      // Conducción ósea: 20 dB en las mismas → gap = 30 dB en cada una.
      final audiogram = const Audiogram(thresholds: {
        250: 50,
        500: 50,
        750: 50,
        1000: 50,
        1500: 50,
        2000: 50,
        2500: 50,
        3000: 50,
        3500: 50,
        4000: 50,
        6000: 50,
        8000: 50,
      });

      final boneConduction = <int, double>{
        500: 20,
        1000: 20,
        2000: 20,
        4000: 20,
      };

      final result = AudiogramClassifier.classify(
        audiogram,
        boneConduction: boneConduction,
      );

      expect(result, equals(LossType.mixed));
    });
  });

  group('AudiogramClassifier - edge cases de entrada inválida', () {
    test('audiograma vacío lanza ArgumentError', () {
      final audiogram = const Audiogram(thresholds: {});

      expect(
        () => AudiogramClassifier.classify(audiogram),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('audiograma incompleto (menos de 12 frecuencias) lanza ArgumentError', () {
      // Solo 4 frecuencias: faltan 8 de las 12 requeridas.
      final audiogram = const Audiogram(thresholds: {
        250: 40,
        500: 40,
        1000: 40,
        2000: 40,
      });

      expect(
        () => AudiogramClassifier.classify(audiogram),
        throwsA(isA<ArgumentError>()),
      );
    });
  });
}
