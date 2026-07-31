/// Tests unitarios para GainPrescriberNL3.prescribeWithCompensation.
///
/// Verifica que la compensación de auricular se aplica correctamente
/// sobre las ganancias NL3 prescritas, usando la fórmula:
///   finalGain[i] = clamp(prescribed[i] + compensation[freq_i], 0, 50)
///
/// Requisitos validados: 7.3, 7.4
import 'package:flutter_test/flutter_test.dart';
import 'package:hearing_aid_app/domain/gain_prescriber_nl3.dart';
import 'package:hearing_aid_app/domain/entities/audiogram.dart';
import 'package:hearing_aid_app/domain/entities/patient_profile.dart';
import 'package:hearing_aid_app/domain/entities/prescription_mode.dart';

void main() {
  late GainPrescriberNL3 prescriber;

  setUp(() {
    prescriber = GainPrescriberNL3();
  });

  group('GainPrescriberNL3 - prescribeWithCompensation', () {
    test('retorna 12 finalGains y 12 prescribedGains', () {
      final audiogram = Audiogram.defaultAudiogram();
      final compensation = <int, double>{};

      final result = prescriber.prescribeWithCompensation(
        audiogram,
        compensation,
      );

      expect(result.prescribedGains.length, equals(12));
      expect(result.finalGains.length, equals(12));
    });

    test('sin compensación, finalGains == prescribedGains', () {
      final audiogram = Audiogram.defaultAudiogram();
      final compensation = <int, double>{};

      final result = prescriber.prescribeWithCompensation(
        audiogram,
        compensation,
      );

      // Sin compensación, las ganancias finales deben ser iguales a las prescritas.
      for (int i = 0; i < 12; i++) {
        expect(
          result.finalGains[i],
          equals(result.prescribedGains[i]),
          reason: 'Banda $i: finalGains debería ser igual a prescribedGains '
              'sin compensación',
        );
      }
    });

    test('compensación positiva suma ganancia (con clamp a 50)', () {
      // Audiograma con pérdida moderada para tener ganancias altas.
      final audiogram = const Audiogram(thresholds: {
        250: 60, 500: 60, 750: 60, 1000: 60, 1500: 60,
        2000: 60, 2500: 60, 3000: 60, 3500: 60, 4000: 60, 6000: 60, 8000: 60,
      });
      final compensation = <int, double>{
        250: 5.0, 500: 5.0, 750: 5.0, 1000: 5.0, 1500: 5.0,
        2000: 5.0, 2500: 5.0, 3000: 5.0, 3500: 5.0, 4000: 5.0,
        6000: 5.0, 8000: 5.0,
      };

      final result = prescriber.prescribeWithCompensation(
        audiogram,
        compensation,
      );

      for (int i = 0; i < 12; i++) {
        final expected = (result.prescribedGains[i] + 5.0).clamp(0.0, 50.0);
        expect(
          result.finalGains[i],
          closeTo(expected, 0.001),
          reason: 'Banda $i: finalGains debería ser prescribed + 5 (clamped)',
        );
      }
    });

    test('compensación negativa resta ganancia (con clamp a 0)', () {
      final audiogram = Audiogram.defaultAudiogram();
      // Compensación muy negativa para forzar clamp a 0.
      final compensation = <int, double>{
        250: -100.0, 500: -100.0, 750: -100.0, 1000: -100.0, 1500: -100.0,
        2000: -100.0, 2500: -100.0, 3000: -100.0, 3500: -100.0,
        4000: -100.0, 6000: -100.0, 8000: -100.0,
      };

      final result = prescriber.prescribeWithCompensation(
        audiogram,
        compensation,
      );

      // Todas las ganancias deberían ser 0 (clamped al mínimo).
      for (int i = 0; i < 12; i++) {
        expect(
          result.finalGains[i],
          equals(0.0),
          reason: 'Banda $i: finalGains debería ser 0 con compensación -100',
        );
      }
    });

    test('compensación alta clampea a 50 dB', () {
      // Audiograma con pérdida alta → ganancias altas + compensación positiva.
      final audiogram = const Audiogram(thresholds: {
        250: 80, 500: 80, 750: 80, 1000: 80, 1500: 80,
        2000: 80, 2500: 80, 3000: 80, 3500: 80, 4000: 80, 6000: 80, 8000: 80,
      });
      final compensation = <int, double>{
        250: 20.0, 500: 20.0, 750: 20.0, 1000: 20.0, 1500: 20.0,
        2000: 20.0, 2500: 20.0, 3000: 20.0, 3500: 20.0, 4000: 20.0,
        6000: 20.0, 8000: 20.0,
      };

      final result = prescriber.prescribeWithCompensation(
        audiogram,
        compensation,
      );

      for (int i = 0; i < 12; i++) {
        expect(
          result.finalGains[i],
          inInclusiveRange(0.0, 50.0),
          reason: 'Banda $i: finalGains debe estar en [0, 50]',
        );
      }
    });

    test('frecuencia sin compensación en el mapa asume 0 dB', () {
      final audiogram = const Audiogram(thresholds: {
        250: 40, 500: 40, 750: 40, 1000: 40, 1500: 40,
        2000: 40, 2500: 40, 3000: 40, 3500: 40, 4000: 40, 6000: 40, 8000: 40,
      });
      // Solo compensación parcial (solo 250 y 8000 Hz).
      final compensation = <int, double>{
        250: 3.0,
        8000: -2.0,
      };

      final result = prescriber.prescribeWithCompensation(
        audiogram,
        compensation,
      );

      // prescribedGains no cambia (referencia).
      final baseResult = prescriber.prescribeFromAudiogram(audiogram);

      // 250 Hz (banda 0): prescribed + 3
      expect(
        result.finalGains[0],
        closeTo((baseResult.prescribedGains[0] + 3.0).clamp(0.0, 50.0), 0.001),
      );

      // 8000 Hz (banda 11): prescribed - 2
      expect(
        result.finalGains[11],
        closeTo(
          (baseResult.prescribedGains[11] - 2.0).clamp(0.0, 50.0), 0.001),
      );

      // Bandas intermedias sin compensación: finalGains == prescribedGains.
      for (int i = 1; i < 11; i++) {
        expect(
          result.finalGains[i],
          closeTo(baseResult.prescribedGains[i], 0.001),
          reason: 'Banda $i sin compensación debería ser igual a prescribed',
        );
      }
    });

    test('acepta PatientProfile y PrescriptionMode opcionales', () {
      final audiogram = const Audiogram(thresholds: {
        250: 50, 500: 50, 750: 50, 1000: 50, 1500: 50,
        2000: 50, 2500: 50, 3000: 50, 3500: 50, 4000: 50, 6000: 50, 8000: 50,
      });
      final compensation = <int, double>{1000: 2.0, 2000: -1.0};
      final profile = PatientProfile(experienceMonths: 12);

      final result = prescriber.prescribeWithCompensation(
        audiogram,
        compensation,
        profile: profile,
        mode: PrescriptionMode.comfortInNoise,
      );

      expect(result.prescribedGains.length, equals(12));
      expect(result.finalGains.length, equals(12));
      expect(result.mode, equals(PrescriptionMode.comfortInNoise));
      expect(result.cinActive, isTrue);
    });

    test('preserva metadata del resultado NL3', () {
      final audiogram = const Audiogram(thresholds: {
        250: 40, 500: 40, 750: 40, 1000: 40, 1500: 40,
        2000: 40, 2500: 40, 3000: 40, 3500: 40, 4000: 40, 6000: 40, 8000: 40,
      });
      final compensation = <int, double>{1000: 1.0};

      final result = prescriber.prescribeWithCompensation(
        audiogram,
        compensation,
      );

      // Verificar que la metadata se preserva correctamente.
      expect(result.compressionRatios.length, equals(12));
      expect(result.lossType, isNotNull);
      expect(result.mode, equals(PrescriptionMode.quiet));
      expect(result.timestamp, isNotNull);
    });

    test('throws ArgumentError para audiograma vacío', () {
      final audiogram = const Audiogram(thresholds: {});
      final compensation = <int, double>{};

      expect(
        () => prescriber.prescribeWithCompensation(audiogram, compensation),
        throwsArgumentError,
      );
    });

    test('throws ArgumentError para audiograma incompleto', () {
      final audiogram = const Audiogram(thresholds: {250: 30, 500: 30});
      final compensation = <int, double>{};

      expect(
        () => prescriber.prescribeWithCompensation(audiogram, compensation),
        throwsArgumentError,
      );
    });
  });
}
