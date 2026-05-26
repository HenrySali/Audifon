/// Tests unitarios para GainPrescriber (NAL-NL2 con tabla de lookup).
///
/// Verifica el cálculo de ganancia usando la tabla NAL-NL2 simplificada
/// con interpolación para valores intermedios de HL y frecuencias.
///
/// Requisitos validados: 2.3, 4.2, 4.3
import 'package:flutter_test/flutter_test.dart';
import 'package:hearing_aid_app/domain/gain_prescriber.dart';
import 'package:hearing_aid_app/domain/entities/audiogram.dart';

void main() {
  late GainPrescriber prescriber;

  setUp(() {
    prescriber = GainPrescriber();
  });

  group('GainPrescriber - prescribeFromAudiogram', () {
    test('retorna 12 valores de ganancia', () {
      final audiogram = Audiogram.defaultAudiogram();
      final gains = prescriber.prescribeFromAudiogram(audiogram);
      expect(gains.length, equals(12));
    });

    test('todas las ganancias están en rango [0, 50] dB', () {
      final audiogram = Audiogram.defaultAudiogram();
      final gains = prescriber.prescribeFromAudiogram(audiogram);

      for (int i = 0; i < gains.length; i++) {
        expect(
          gains[i],
          inInclusiveRange(0.0, 50.0),
          reason:
              'Banda ${GainPrescriber.bandFrequencies[i]} Hz: '
              '${gains[i].toStringAsFixed(1)} dB fuera de rango [0, 50]',
        );
      }
    });

    test('audiograma con pérdida 0 dB HL produce ganancias bajas', () {
      final audiogram = const Audiogram(thresholds: {
        250: 0, 500: 0, 750: 0, 1000: 0, 1500: 0,
        2000: 0, 2500: 0, 3000: 0, 3500: 0, 4000: 0, 6000: 0, 8000: 0,
      });
      final gains = prescriber.prescribeFromAudiogram(audiogram);

      // Con HL=0 (por debajo de la tabla que empieza en 20),
      // la extrapolación produce valores negativos que se clampean a 0
      for (final gain in gains) {
        expect(gain, equals(0.0));
      }
    });

    test('audiograma con pérdida uniforme 40 dB HL coincide con tabla', () {
      final audiogram = const Audiogram(thresholds: {
        250: 40, 500: 40, 750: 40, 1000: 40, 1500: 40,
        2000: 40, 2500: 40, 3000: 40, 3500: 40, 4000: 40, 6000: 40, 8000: 40,
      });
      final gains = prescriber.prescribeFromAudiogram(audiogram);

      // Tabla NAL-NL2 para HL=40:
      // [4, 7, 10, 14, 14, 12, 10, 8]
      // Bandas directas: 250, 500, 1000, 2000, 3000, 4000, 6000, 8000
      expect(gains[0], closeTo(4.0, 0.01)); // 250 Hz
      expect(gains[1], closeTo(7.0, 0.01)); // 500 Hz
      expect(gains[3], closeTo(10.0, 0.01)); // 1000 Hz
      expect(gains[5], closeTo(14.0, 0.01)); // 2000 Hz
      expect(gains[7], closeTo(14.0, 0.01)); // 3000 Hz
      expect(gains[9], closeTo(12.0, 0.01)); // 4000 Hz
      expect(gains[10], closeTo(10.0, 0.01)); // 6000 Hz
      expect(gains[11], closeTo(8.0, 0.01)); // 8000 Hz
    });

    test('audiograma con pérdida uniforme 60 dB HL coincide con tabla', () {
      final audiogram = const Audiogram(thresholds: {
        250: 60, 500: 60, 750: 60, 1000: 60, 1500: 60,
        2000: 60, 2500: 60, 3000: 60, 3500: 60, 4000: 60, 6000: 60, 8000: 60,
      });
      final gains = prescriber.prescribeFromAudiogram(audiogram);

      // Tabla NAL-NL2 para HL=60:
      // [8, 13, 18, 23, 22, 20, 17, 14]
      expect(gains[0], closeTo(8.0, 0.01)); // 250 Hz
      expect(gains[1], closeTo(13.0, 0.01)); // 500 Hz
      expect(gains[3], closeTo(18.0, 0.01)); // 1000 Hz
      expect(gains[5], closeTo(23.0, 0.01)); // 2000 Hz
      expect(gains[7], closeTo(22.0, 0.01)); // 3000 Hz
      expect(gains[9], closeTo(20.0, 0.01)); // 4000 Hz
      expect(gains[10], closeTo(17.0, 0.01)); // 6000 Hz
      expect(gains[11], closeTo(14.0, 0.01)); // 8000 Hz
    });

    test('interpolación HL: pérdida 35 dB produce valores entre filas 30 y 40', () {
      final audiogram = const Audiogram(thresholds: {
        250: 35, 500: 35, 750: 35, 1000: 35, 1500: 35,
        2000: 35, 2500: 35, 3000: 35, 3500: 35, 4000: 35, 6000: 35, 8000: 35,
      });
      final gains = prescriber.prescribeFromAudiogram(audiogram);

      // HL=35 está a mitad entre HL=30 y HL=40
      // 250Hz: (2+4)/2 = 3, 500Hz: (4+7)/2 = 5.5, 1kHz: (6+10)/2 = 8
      expect(gains[0], closeTo(3.0, 0.01)); // 250 Hz
      expect(gains[1], closeTo(5.5, 0.01)); // 500 Hz
      expect(gains[3], closeTo(8.0, 0.01)); // 1000 Hz
      expect(gains[5], closeTo(11.5, 0.01)); // 2000 Hz: (9+14)/2
    });

    test('interpolación frecuencia: 750 Hz interpola entre 500 y 1000', () {
      final audiogram = const Audiogram(thresholds: {
        250: 50, 500: 50, 750: 50, 1000: 50, 1500: 50,
        2000: 50, 2500: 50, 3000: 50, 3500: 50, 4000: 50, 6000: 50, 8000: 50,
      });
      final gains = prescriber.prescribeFromAudiogram(audiogram);

      // 750 Hz interpola entre G500=10 y G1k=14 (HL=50)
      // log(750) está entre log(500) y log(1000)
      // ratio = (log750 - log500) / (log1000 - log500) ≈ 0.585
      // gain = 10 + 0.585 * (14 - 10) = 10 + 2.34 ≈ 12.34
      expect(gains[2], greaterThan(10.0));
      expect(gains[2], lessThan(14.0));
    });

    test('interpolación frecuencia: 1500 Hz interpola entre 1000 y 2000', () {
      final audiogram = const Audiogram(thresholds: {
        250: 50, 500: 50, 750: 50, 1000: 50, 1500: 50,
        2000: 50, 2500: 50, 3000: 50, 3500: 50, 4000: 50, 6000: 50, 8000: 50,
      });
      final gains = prescriber.prescribeFromAudiogram(audiogram);

      // 1500 Hz interpola entre G1k=14 y G2k=18 (HL=50)
      expect(gains[4], greaterThan(14.0));
      expect(gains[4], lessThan(18.0));
    });

    test('interpolación frecuencia: 2500 Hz interpola entre 2000 y 3000', () {
      final audiogram = const Audiogram(thresholds: {
        250: 50, 500: 50, 750: 50, 1000: 50, 1500: 50,
        2000: 50, 2500: 50, 3000: 50, 3500: 50, 4000: 50, 6000: 50, 8000: 50,
      });
      final gains = prescriber.prescribeFromAudiogram(audiogram);

      // 2500 Hz interpola entre G2k=18 y G3k=18 (HL=50) → 18
      expect(gains[6], closeTo(18.0, 0.1));
    });

    test('interpolación frecuencia: 3500 Hz interpola entre 3000 y 4000', () {
      final audiogram = const Audiogram(thresholds: {
        250: 50, 500: 50, 750: 50, 1000: 50, 1500: 50,
        2000: 50, 2500: 50, 3000: 50, 3500: 50, 4000: 50, 6000: 50, 8000: 50,
      });
      final gains = prescriber.prescribeFromAudiogram(audiogram);

      // 3500 Hz interpola entre G3k=18 y G4k=16 (HL=50)
      expect(gains[8], greaterThan(16.0));
      expect(gains[8], lessThan(18.0));
    });

    test('énfasis en 2-4 kHz para pérdida en frecuencias altas', () {
      // Audiograma predeterminado: pérdida en frecuencias altas
      final audiogram = Audiogram.defaultAudiogram();
      final gains = prescriber.prescribeFromAudiogram(audiogram);

      // Ganancia promedio en 2-4 kHz (bandas 5-9: 2000, 2500, 3000, 3500, 4000)
      final avg2to4kHz =
          (gains[5] + gains[6] + gains[7] + gains[8] + gains[9]) / 5.0;

      // Ganancia promedio fuera de 2-4 kHz
      final avgOutside =
          (gains[0] + gains[1] + gains[2] + gains[3] + gains[4] +
              gains[10] + gains[11]) / 7.0;

      expect(
        avg2to4kHz,
        greaterThan(avgOutside),
        reason:
            'Ganancia promedio 2-4 kHz (${avg2to4kHz.toStringAsFixed(1)} dB) '
            'debe ser mayor que fuera (${avgOutside.toStringAsFixed(1)} dB)',
      );
    });

    test('pérdida severa (HL=80) produce ganancias altas pero dentro de [0,50]', () {
      final audiogram = const Audiogram(thresholds: {
        250: 80, 500: 80, 750: 80, 1000: 80, 1500: 80,
        2000: 80, 2500: 80, 3000: 80, 3500: 80, 4000: 80, 6000: 80, 8000: 80,
      });
      final gains = prescriber.prescribeFromAudiogram(audiogram);

      // Tabla NAL-NL2 para HL=80:
      // [12, 19, 25, 30, 29, 27, 23, 19]
      expect(gains[0], closeTo(12.0, 0.01)); // 250 Hz
      expect(gains[5], closeTo(30.0, 0.01)); // 2000 Hz
      expect(gains[7], closeTo(29.0, 0.01)); // 3000 Hz

      for (final gain in gains) {
        expect(gain, inInclusiveRange(0.0, 50.0));
      }
    });

    test('extrapolación: HL > 80 produce ganancias mayores (clamped a 50)', () {
      final audiogram = const Audiogram(thresholds: {
        250: 120, 500: 120, 750: 120, 1000: 120, 1500: 120,
        2000: 120, 2500: 120, 3000: 120, 3500: 120, 4000: 120,
        6000: 120, 8000: 120,
      });
      final gains = prescriber.prescribeFromAudiogram(audiogram);

      // Con HL=120, la extrapolación produce valores altos, clamped a 50
      for (final gain in gains) {
        expect(gain, inInclusiveRange(0.0, 50.0));
      }

      // La ganancia en 2kHz debería ser alta (extrapolada)
      expect(gains[5], greaterThan(30.0));
    });
  });

  group('GainPrescriber - applyHeadphoneCompensation', () {
    test('compensación cero no cambia las ganancias', () {
      final prescribed = [4.0, 7.0, 8.5, 10.0, 12.0, 14.0, 14.0, 14.0, 13.0, 12.0, 10.0, 8.0];
      final compensation = <int, double>{
        250: 0, 500: 0, 750: 0, 1000: 0, 1500: 0,
        2000: 0, 2500: 0, 3000: 0, 3500: 0, 4000: 0, 6000: 0, 8000: 0,
      };

      final result = prescriber.applyHeadphoneCompensation(prescribed, compensation);

      for (int i = 0; i < 12; i++) {
        expect(result[i], equals(prescribed[i]));
      }
    });

    test('compensación positiva aumenta la ganancia', () {
      final prescribed = [10.0, 10.0, 10.0, 10.0, 10.0, 10.0, 10.0, 10.0, 10.0, 10.0, 10.0, 10.0];
      final compensation = <int, double>{
        250: 5, 500: 5, 750: 5, 1000: 5, 1500: 5,
        2000: 5, 2500: 5, 3000: 5, 3500: 5, 4000: 5, 6000: 5, 8000: 5,
      };

      final result = prescriber.applyHeadphoneCompensation(prescribed, compensation);

      for (int i = 0; i < 12; i++) {
        expect(result[i], equals(15.0));
      }
    });

    test('compensación negativa reduce la ganancia', () {
      final prescribed = [10.0, 10.0, 10.0, 10.0, 10.0, 10.0, 10.0, 10.0, 10.0, 10.0, 10.0, 10.0];
      final compensation = <int, double>{
        250: -5, 500: -5, 750: -5, 1000: -5, 1500: -5,
        2000: -5, 2500: -5, 3000: -5, 3500: -5, 4000: -5, 6000: -5, 8000: -5,
      };

      final result = prescriber.applyHeadphoneCompensation(prescribed, compensation);

      for (int i = 0; i < 12; i++) {
        expect(result[i], equals(5.0));
      }
    });

    test('resultado clamped a [0, 50] cuando compensación produce valores fuera de rango', () {
      final prescribed = [5.0, 5.0, 5.0, 5.0, 5.0, 45.0, 45.0, 45.0, 45.0, 45.0, 5.0, 5.0];
      final compensation = <int, double>{
        250: -10, 500: -10, 750: -10, 1000: -10, 1500: -10,
        2000: 10, 2500: 10, 3000: 10, 3500: 10, 4000: 10, 6000: -10, 8000: -10,
      };

      final result = prescriber.applyHeadphoneCompensation(prescribed, compensation);

      // 5 + (-10) = -5 → clamped to 0
      expect(result[0], equals(0.0));
      expect(result[1], equals(0.0));

      // 45 + 10 = 55 → clamped to 50
      expect(result[5], equals(50.0));
      expect(result[6], equals(50.0));
    });

    test('compensación parcial (no todas las frecuencias) usa 0 para las faltantes', () {
      final prescribed = [10.0, 10.0, 10.0, 10.0, 10.0, 10.0, 10.0, 10.0, 10.0, 10.0, 10.0, 10.0];
      // Solo compensar algunas frecuencias
      final compensation = <int, double>{
        2000: 5,
        4000: -3,
      };

      final result = prescriber.applyHeadphoneCompensation(prescribed, compensation);

      // Frecuencias sin compensación mantienen su valor
      expect(result[0], equals(10.0)); // 250 Hz
      expect(result[3], equals(10.0)); // 1000 Hz

      // Frecuencias con compensación
      expect(result[5], equals(15.0)); // 2000 Hz: 10 + 5
      expect(result[9], equals(7.0)); // 4000 Hz: 10 + (-3)
    });
  });

  group('GainPrescriber - prescribeWithCompensation', () {
    test('retorna prescripción y ganancias finales correctas', () {
      final audiogram = const Audiogram(thresholds: {
        250: 40, 500: 40, 750: 40, 1000: 40, 1500: 40,
        2000: 40, 2500: 40, 3000: 40, 3500: 40, 4000: 40, 6000: 40, 8000: 40,
      });
      final compensation = <int, double>{
        250: 2, 500: 2, 750: 2, 1000: 2, 1500: 2,
        2000: -3, 2500: -3, 3000: -3, 3500: -3, 4000: -3, 6000: 2, 8000: 2,
      };

      final result = prescriber.prescribeWithCompensation(audiogram, compensation);

      expect(result.prescribedGains.length, equals(12));
      expect(result.finalGains.length, equals(12));

      // Verificar que finalGains = prescribed + compensation (clamped)
      for (int i = 0; i < 12; i++) {
        final freq = GainPrescriber.bandFrequencies[i];
        final comp = compensation[freq] ?? 0.0;
        final expected = (result.prescribedGains[i] + comp).clamp(0.0, 50.0);
        expect(result.finalGains[i], closeTo(expected, 0.001));
      }
    });

    test('prescripción sin compensación: finalGains == prescribedGains', () {
      final audiogram = Audiogram.defaultAudiogram();
      final compensation = <int, double>{};

      final result = prescriber.prescribeWithCompensation(audiogram, compensation);

      for (int i = 0; i < 12; i++) {
        expect(result.finalGains[i], equals(result.prescribedGains[i]));
      }
    });
  });

  group('GainPrescriber - audiograma predeterminado del usuario', () {
    test('audiograma predeterminado produce ganancias esperadas según tabla', () {
      // Audiograma predeterminado: 0 dB HL (250-750), 40 dB HL (1000),
      // +5 dB por frecuencia hasta 75 dB HL (8000)
      final audiogram = Audiogram.defaultAudiogram();
      final gains = prescriber.prescribeFromAudiogram(audiogram);

      // 250 Hz: HL=0 → extrapolación debajo de tabla → 0 (clamped)
      expect(gains[0], equals(0.0));

      // 500 Hz: HL=0 → 0 (clamped)
      expect(gains[1], equals(0.0));

      // 1000 Hz: HL=40 → tabla dice 10
      expect(gains[3], closeTo(10.0, 0.01));

      // 2000 Hz: HL=50 → tabla dice 18
      expect(gains[5], closeTo(18.0, 0.01));

      // 3000 Hz: HL=60 → tabla dice 22
      expect(gains[7], closeTo(22.0, 0.01));

      // 4000 Hz: HL=70 → tabla dice 24
      expect(gains[9], closeTo(24.0, 0.01));

      // 8000 Hz: HL=75 → interpola entre HL=70 (17) y HL=80 (19)
      // ratio = (75-70)/(80-70) = 0.5 → 17 + 0.5*(19-17) = 18
      expect(gains[11], closeTo(18.0, 0.01));
    });

    test('audiograma predeterminado: ganancias crecen con la frecuencia', () {
      final audiogram = Audiogram.defaultAudiogram();
      final gains = prescriber.prescribeFromAudiogram(audiogram);

      // Las ganancias deben crecer desde frecuencias bajas a altas
      // (porque la pérdida auditiva crece con la frecuencia)
      expect(gains[3], greaterThan(gains[0])); // 1kHz > 250Hz
      expect(gains[5], greaterThan(gains[3])); // 2kHz > 1kHz
      expect(gains[7], greaterThan(gains[5])); // 3kHz > 2kHz
      expect(gains[9], greaterThan(gains[7])); // 4kHz > 3kHz
    });
  });
}
