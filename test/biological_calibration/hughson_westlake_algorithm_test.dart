/// Tests unitarios para HughsonWestlakeAlgorithm (Wave 5 — task 11).
///
/// Cubre:
///   - Fase de familiarización (transición a descending, ramp-up,
///     invalidación al exceder maxDbFS).
///   - Fase descending (paso de bajada, transición a ascending,
///     clamp en minDbFS).
///   - Fase ascending (criterio 2/3, fallo de criterio que sube,
///     out-of-range al exceder maxDbFS).
///   - Convergencia con umbrales verdaderos simulados (helper determinista).
///   - Catch trials (no afectan el estado).
///   - reset() restaura el estado inicial.
///
/// Requisitos validados: 2, 8.
import 'package:flutter_test/flutter_test.dart';
import 'package:hearing_aid_app/biological_calibration/core/hughson_westlake_algorithm.dart';

void main() {
  group('familiarization', () {
    test('si el primer response es heard=true, transiciona a descending',
        () {
      final hw = HughsonWestlakeAlgorithm();
      expect(hw.state, HwState.familiarization);
      expect(hw.currentLevelDbFS, -30.0);

      hw.recordResponse(true);

      expect(hw.state, HwState.descending);
      // El nivel no cambia al pasar de familiarization a descending: el
      // siguiente recordResponse en descending es el que decidirá el paso.
      expect(hw.currentLevelDbFS, -30.0);
    });

    test(
        'si no responde, sube familiarizationStepUp (10 dB) hasta el siguiente step',
        () {
      final hw = HughsonWestlakeAlgorithm();

      hw.recordResponse(false);

      expect(hw.state, HwState.familiarization);
      expect(hw.currentLevelDbFS, -20.0); // -30 + 10
    });

    test('si llega a maxDbFS sin respuesta, state = invalid', () {
      final hw = HughsonWestlakeAlgorithm();
      // Cada miss añade 10 dB. Empezando en -30 con maxDbFS=-5:
      //   miss #1: -30 → -20 (ok, -20 ≤ -5)
      //   miss #2: -20 → -10 (ok)
      //   miss #3: -10 → 0  (0 > -5 → invalid)
      hw.recordResponse(false);
      hw.recordResponse(false);
      expect(hw.state, HwState.familiarization);
      expect(hw.currentLevelDbFS, -10.0);

      hw.recordResponse(false);

      expect(hw.state, HwState.invalid);
    });
  });

  group('descending', () {
    HughsonWestlakeAlgorithm makeDescending() {
      final hw = HughsonWestlakeAlgorithm();
      hw.recordResponse(true); // familiarization heard → descending
      return hw;
    }

    test('si responde, baja stepDown (10 dB)', () {
      final hw = makeDescending();
      expect(hw.state, HwState.descending);
      expect(hw.currentLevelDbFS, -30.0);

      hw.recordResponse(true);

      expect(hw.state, HwState.descending);
      expect(hw.currentLevelDbFS, -40.0); // -30 - 10
    });

    test(
        'si no responde, transiciona a ascending y sube stepUp (5 dB)',
        () {
      final hw = makeDescending();
      // Bajamos un par de pasos primero para no estar al borde.
      hw.recordResponse(true); // -30 → -40
      hw.recordResponse(true); // -40 → -50
      expect(hw.currentLevelDbFS, -50.0);

      hw.recordResponse(false); // miss en descending → ascending

      expect(hw.state, HwState.ascending);
      expect(hw.currentLevelDbFS, -45.0); // -50 + 5
    });

    test('clampa a minDbFS si baja demasiado', () {
      final hw = makeDescending();
      // Bajamos hasta -80 (minDbFS) con respuestas afirmativas: 5 pasos
      // de 10 dB nos llevan a -80; un 6º paso pediría -90 y debe clamparse.
      hw.recordResponse(true); // -30 → -40
      hw.recordResponse(true); // -40 → -50
      hw.recordResponse(true); // -50 → -60
      hw.recordResponse(true); // -60 → -70
      hw.recordResponse(true); // -70 → -80
      expect(hw.currentLevelDbFS, -80.0);
      expect(hw.state, HwState.descending);

      hw.recordResponse(true); // pediría -90 → clamp en -80

      expect(hw.state, HwState.descending);
      expect(hw.currentLevelDbFS, -80.0);
    });
  });

  group('ascending', () {
    /// Helper: lleva el algoritmo a estado ascending en un nivel concreto.
    HughsonWestlakeAlgorithm makeAscendingAt(double levelDbFS) {
      final hw = HughsonWestlakeAlgorithm();
      hw.recordResponse(true); // familiarization → descending @ -30
      // Bajar hasta levelDbFS - 5 (porque al fallar en descending sube +5).
      var lvl = -30.0;
      while (lvl - 10.0 >= levelDbFS - 5.0) {
        hw.recordResponse(true);
        lvl -= 10.0;
      }
      // En descending @ lvl. Falla → ascending @ lvl + 5.
      hw.recordResponse(false);
      assert(hw.state == HwState.ascending);
      assert((hw.currentLevelDbFS - levelDbFS).abs() < 1e-9,
          'expected $levelDbFS got ${hw.currentLevelDbFS}');
      return hw;
    }

    test('si responde 2 veces consecutivas al mismo nivel, thresholdFound',
        () {
      final hw = makeAscendingAt(-45.0);
      expect(hw.state, HwState.ascending);

      hw.recordResponse(true); // 1 / 1
      expect(hw.state, HwState.ascending);

      hw.recordResponse(true); // 2 / 2 → criterio cumplido

      expect(hw.state, HwState.thresholdFound);
      expect(hw.threshold, -45.0);
    });

    test('si responde 1 de 2 al mismo nivel, sigue subiendo (no avanza aún)',
        () {
      final hw = makeAscendingAt(-45.0);

      hw.recordResponse(true); // 1 / 1
      hw.recordResponse(false); // 1 / 2 — todavía no son 3 presentaciones

      expect(hw.state, HwState.ascending);
      expect(hw.currentLevelDbFS, -45.0); // mismo nivel
      expect(hw.threshold, isNull);
    });

    test(
        'si llega a 3 presentaciones sin alcanzar 2/3, sube stepUp y resetea contadores',
        () {
      final hw = makeAscendingAt(-45.0);

      hw.recordResponse(false); // 0 / 1
      hw.recordResponse(false); // 0 / 2
      hw.recordResponse(false); // 0 / 3 → step up + reset

      expect(hw.state, HwState.ascending);
      expect(hw.currentLevelDbFS, -40.0); // -45 + 5
    });

    test('si stepUp excede maxDbFS, state = outOfRange', () {
      // Llevamos el algoritmo a ascending @ -5 (maxDbFS).
      // Truco: en familiarización fallamos hasta -10, luego respondemos
      // (heard) → descending @ -10, luego fallamos en descending → ascending
      // @ -10 + 5 = -5.
      final hw = HughsonWestlakeAlgorithm();
      hw.recordResponse(false); // -30 → -20
      hw.recordResponse(false); // -20 → -10
      hw.recordResponse(true); // familiarization heard → descending @ -10
      expect(hw.state, HwState.descending);
      expect(hw.currentLevelDbFS, -10.0);

      hw.recordResponse(false); // descending miss → ascending @ -5
      expect(hw.state, HwState.ascending);
      expect(hw.currentLevelDbFS, -5.0);

      // 3 misses al mismo nivel → step up = 0 > maxDbFS=-5 → outOfRange.
      hw.recordResponse(false);
      hw.recordResponse(false);
      hw.recordResponse(false);

      expect(hw.state, HwState.outOfRange);
    });
  });

  group('convergence', () {
    /// Modelo determinista del usuario: oye el tono si y solo si el nivel
    /// presentado es igual o más alto que su umbral verdadero. Como dBFS
    /// es negativo, "más alto" significa más cercano a 0, es decir que el
    /// nivel presentado es ≥ al umbral.
    bool simulateUserResponse(
      double currentLevelDbFS,
      double trueThresholdDbFS,
    ) {
      return currentLevelDbFS >= trueThresholdDbFS;
    }

    /// Itera el algoritmo hasta llegar a un estado terminal o agotar pasos.
    HughsonWestlakeAlgorithm runUntilTerminal(double trueThresholdDbFS) {
      final hw = HughsonWestlakeAlgorithm();
      const maxSteps = 200; // guardarraíl: la convergencia real es ≪ 200.
      var steps = 0;
      while (hw.state != HwState.thresholdFound &&
          hw.state != HwState.invalid &&
          hw.state != HwState.outOfRange) {
        final heard = simulateUserResponse(
          hw.currentLevelDbFS,
          trueThresholdDbFS,
        );
        hw.recordResponse(heard);
        steps++;
        if (steps > maxSteps) {
          fail('Algorithm did not converge in $maxSteps steps for '
              'threshold=$trueThresholdDbFS (state=${hw.state}, '
              'level=${hw.currentLevelDbFS})');
        }
      }
      return hw;
    }

    test('converge a ±5 dB con umbral verdadero -50 dBFS', () {
      final hw = runUntilTerminal(-50.0);

      expect(hw.state, HwState.thresholdFound);
      expect(hw.threshold, isNotNull);
      expect((hw.threshold! - (-50.0)).abs(), lessThanOrEqualTo(5.0));
    });

    test('converge a ±5 dB con umbral verdadero -30 dBFS', () {
      final hw = runUntilTerminal(-30.0);

      expect(hw.state, HwState.thresholdFound);
      expect(hw.threshold, isNotNull);
      expect((hw.threshold! - (-30.0)).abs(), lessThanOrEqualTo(5.0));
    });

    test('converge a ±5 dB con umbral verdadero -40 dBFS', () {
      final hw = runUntilTerminal(-40.0);

      expect(hw.state, HwState.thresholdFound);
      expect(hw.threshold, isNotNull);
      expect((hw.threshold! - (-40.0)).abs(), lessThanOrEqualTo(5.0));
    });

    test('converge a ±5 dB con umbral verdadero -60 dBFS', () {
      final hw = runUntilTerminal(-60.0);

      expect(hw.state, HwState.thresholdFound);
      expect(hw.threshold, isNotNull);
      expect((hw.threshold! - (-60.0)).abs(), lessThanOrEqualTo(5.0));
    });

    test('converge a ±5 dB con umbral verdadero -70 dBFS', () {
      final hw = runUntilTerminal(-70.0);

      expect(hw.state, HwState.thresholdFound);
      expect(hw.threshold, isNotNull);
      expect((hw.threshold! - (-70.0)).abs(), lessThanOrEqualTo(5.0));
    });
  });

  group('catch trials', () {
    test('recordResponse(true, wasCatchTrial: true) NO altera el estado', () {
      final hw = HughsonWestlakeAlgorithm();
      final stateBefore = hw.state;
      final levelBefore = hw.currentLevelDbFS;

      hw.recordResponse(true, wasCatchTrial: true);

      expect(hw.state, stateBefore);
      expect(hw.currentLevelDbFS, levelBefore);
      expect(hw.threshold, isNull);
    });

    test('recordResponse(false, wasCatchTrial: true) NO altera el estado',
        () {
      // Movemos el algoritmo a descending para asegurarnos que el catch
      // trial no avance ni retroceda desde un estado no inicial.
      final hw = HughsonWestlakeAlgorithm();
      hw.recordResponse(true); // familiarization → descending @ -30
      final stateBefore = hw.state;
      final levelBefore = hw.currentLevelDbFS;

      hw.recordResponse(false, wasCatchTrial: true);

      expect(hw.state, stateBefore);
      expect(hw.currentLevelDbFS, levelBefore);
      expect(hw.threshold, isNull);
    });
  });

  group('reset', () {
    test('después de algunos pasos, reset() vuelve al estado inicial', () {
      final hw = HughsonWestlakeAlgorithm();
      // Algunos pasos arbitrarios para mover el estado interno.
      hw.recordResponse(true); // → descending
      hw.recordResponse(true); // -30 → -40
      hw.recordResponse(true); // -40 → -50
      hw.recordResponse(false); // descending miss → ascending @ -45
      hw.recordResponse(true); // 1/1 en ascending
      expect(hw.state, isNot(HwState.familiarization));
      expect(hw.currentLevelDbFS, isNot(-30.0));

      hw.reset();

      expect(hw.state, HwState.familiarization);
      expect(hw.currentLevelDbFS, -30.0);
      expect(hw.threshold, isNull);
      expect(hw.ascendingCount, 0);
    });
  });
}
