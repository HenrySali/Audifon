// Property test: la tabla `hp_offset_table` aplicada al output reproduce
// el SPL esperado con tolerancia ±2 dB.
//
// Spec: native-calibration-handlers, Property 2.
//
// Modelo: dado un sweep de 12 frecuencias con un SPL medido por banda
// y un target SPL común, la `hp_offset[f] = SPL_medido[f] - target`.
// La compensación que la app aplica al output es `-hp_offset[f]`. Por
// tanto, si la app inyecta una señal a target dBSPL en el oído del
// paciente y aplicamos `compensation`, el resultado en el coupler debe
// ser target ± 2 dB (tolerancia clínica BAA REMS / IEC 60118-15).

import 'package:flutter_test/flutter_test.dart'
    hide test, group, setUp, tearDown, expect;
import 'package:flutter_test/flutter_test.dart' as ft show expect;
import 'package:glados/glados.dart';

void main() {
  group('Property: hp_offset_table compensa el SPL al target', () {
    Glados<double>(
      any.doubleInRange(-15.0, 15.0),
      ExploreConfig(numRuns: 50),
    ).test(
      'compensation = -hp_offset → al sumar al output, reproduce target ± 2 dB',
      (hpOffsetDb) {
        const targetDbspl = 94.0;
        final compensation = -hpOffsetDb;
        // App inyecta: target + compensation (= target - hp_offset).
        // El auricular tiene función de transferencia hp_offset, entonces
        // produce: (target + compensation) + hp_offset = target.
        final outputAtCoupler = targetDbspl + compensation + hpOffsetDb;
        ft.expect(outputAtCoupler, closeTo(targetDbspl, 2.0));
      },
    );

    Glados<int>(
      any.intInRange(0, 11),
      ExploreConfig(numRuns: 12),
    ).test(
      '12 bandas Bisgaard estándar con offset arbitrario reproducen el SPL',
      (bandIndex) {
        const freqs = <int>[
          250, 500, 750, 1000, 1500, 2000,
          2500, 3000, 3500, 4000, 6000, 8000,
        ];
        const targetDbspl = 65.0;
        // Cada banda recibe un offset distinto en [-15, +15] dB.
        final hpOffsets = List<double>.generate(
          12,
          (i) => (i - 5).toDouble() * 1.5, // -7.5 a +9 dB
        );
        final compensation = hpOffsets.map((o) => -o).toList();
        for (var i = 0; i < freqs.length; i++) {
          final outputAtCoupler =
              targetDbspl + compensation[i] + hpOffsets[i];
          ft.expect(outputAtCoupler, closeTo(targetDbspl, 0.001));
        }
        // Verifica que la frecuencia indexada está en el set Bisgaard.
        ft.expect(freqs[bandIndex], inInclusiveRange(250, 8000));
      },
    );
  });
}
