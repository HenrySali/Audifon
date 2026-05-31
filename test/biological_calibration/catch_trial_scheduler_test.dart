/// Tests unitarios para CatchTrialScheduler.
///
/// Verifica las reglas de inserción de catch trials descritas en
/// `investigaciones/calibracion-biologica-parametros-tecnicos.md` §8.3:
/// - Ratio configurable (1/N catch trials por bloque).
/// - Nunca dos catch trials consecutivos.
/// - Idempotencia: mismo índice → mismo resultado.
/// - Determinismo con `seed`.
///
/// Requisitos validados: 2
import 'package:flutter_test/flutter_test.dart';
import 'package:hearing_aid_app/biological_calibration/core/catch_trial_scheduler.dart';

void main() {
  group('CatchTrialScheduler - ratio', () {
    test('ratio 1/6 cumplido: 600 presentaciones → exactamente 100 catch trials',
        () {
      final scheduler = CatchTrialScheduler(ratio: 6, seed: 42);

      var count = 0;
      for (var i = 0; i < 600; i++) {
        if (scheduler.shouldBeCatchTrial(i)) count++;
      }

      expect(count, equals(100));
    });

    test('ratio 4 funciona: 400 presentaciones → exactamente 100 catch trials',
        () {
      final scheduler = CatchTrialScheduler(ratio: 4, seed: 1);

      var count = 0;
      for (var i = 0; i < 400; i++) {
        if (scheduler.shouldBeCatchTrial(i)) count++;
      }

      expect(count, equals(100));
    });
  });

  group('CatchTrialScheduler - regla de no consecutivos', () {
    test('nunca hay dos catch trials consecutivos en 600 presentaciones', () {
      final scheduler = CatchTrialScheduler(ratio: 6, seed: 42);

      final flags = List<bool>.generate(
        600,
        (i) => scheduler.shouldBeCatchTrial(i),
      );

      for (var i = 0; i < flags.length - 1; i++) {
        if (flags[i] && flags[i + 1]) {
          fail(
            'Catch trials consecutivos detectados en índices $i y ${i + 1}',
          );
        }
      }
    });
  });

  group('CatchTrialScheduler - idempotencia', () {
    test('llamadas repetidas con el mismo índice devuelven el mismo resultado',
        () {
      final scheduler = CatchTrialScheduler(ratio: 6, seed: 42);

      final first = scheduler.shouldBeCatchTrial(10);
      for (var i = 0; i < 50; i++) {
        expect(scheduler.shouldBeCatchTrial(10), equals(first));
      }
    });

    test('idempotencia se mantiene aunque se intercalen otros índices', () {
      final scheduler = CatchTrialScheduler(ratio: 6, seed: 7);

      final r10 = scheduler.shouldBeCatchTrial(10);
      final r25 = scheduler.shouldBeCatchTrial(25);

      // Tocar otros índices no debe alterar los resultados cacheados.
      for (var i = 0; i < 60; i++) {
        scheduler.shouldBeCatchTrial(i);
      }

      expect(scheduler.shouldBeCatchTrial(10), equals(r10));
      expect(scheduler.shouldBeCatchTrial(25), equals(r25));
    });
  });

  group('CatchTrialScheduler - índices inválidos', () {
    test('shouldBeCatchTrial(-1) devuelve false', () {
      final scheduler = CatchTrialScheduler(ratio: 6, seed: 42);
      expect(scheduler.shouldBeCatchTrial(-1), isFalse);
    });

    test('shouldBeCatchTrial(-100) devuelve false', () {
      final scheduler = CatchTrialScheduler(ratio: 6, seed: 42);
      expect(scheduler.shouldBeCatchTrial(-100), isFalse);
    });
  });

  group('CatchTrialScheduler - reset()', () {
    test('reset() limpia el cache y el ratio total se mantiene', () {
      final scheduler = CatchTrialScheduler(ratio: 6, seed: 42);

      // Primer pase: 600 presentaciones → 100 catch trials.
      var firstPassCount = 0;
      for (var i = 0; i < 600; i++) {
        if (scheduler.shouldBeCatchTrial(i)) firstPassCount++;
      }
      expect(firstPassCount, equals(100));

      // reset() borra el cache; el `Random` interno sigue avanzando, así que
      // las posiciones específicas pueden diferir, pero el ratio total se
      // mantiene en 1/6.
      scheduler.reset();

      var secondPassCount = 0;
      for (var i = 0; i < 600; i++) {
        if (scheduler.shouldBeCatchTrial(i)) secondPassCount++;
      }
      expect(secondPassCount, equals(100));
    });
  });

  group('CatchTrialScheduler - determinismo con seed', () {
    test('dos instancias con el mismo seed producen las mismas posiciones', () {
      final a = CatchTrialScheduler(ratio: 6, seed: 12345);
      final b = CatchTrialScheduler(ratio: 6, seed: 12345);

      for (var i = 0; i < 60; i++) {
        expect(
          a.shouldBeCatchTrial(i),
          equals(b.shouldBeCatchTrial(i)),
          reason: 'Divergencia en índice $i con el mismo seed',
        );
      }
    });
  });

  group('CatchTrialScheduler - precondiciones', () {
    test('ratio < 2 lanza AssertionError', () {
      expect(
        () => CatchTrialScheduler(ratio: 1),
        throwsA(isA<AssertionError>()),
      );
    });
  });
}
