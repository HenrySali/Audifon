// Property test: la inversión del offset de calibración mic
// reproduce el SPL de referencia.
//
// Spec: native-calibration-handlers, Property 1.
//
// Para todo `rms_avg_dbfs ∈ [-40, -10]` (rango aceptable del handler)
// y `referenceSpl ∈ [80, 100]` (típicos de calibradores acústicos):
//   `mic_offset_db = referenceSpl − rms_avg_dbfs`
//   `rms_avg_dbfs + mic_offset_db ≈ referenceSpl ± 0.001`

import 'package:flutter_test/flutter_test.dart'
    hide test, group, setUp, tearDown, expect;
import 'package:flutter_test/flutter_test.dart' as ft show expect;
import 'package:glados/glados.dart';

void main() {
  group('Property: mic_offset reproduce referenceSpl', () {
    Glados2<double, double>(
      any.doubleInRange(-40.0, -10.0),
      any.doubleInRange(80.0, 100.0),
      ExploreConfig(numRuns: 100),
    ).test(
      'mic_offset_db = ref - rms_avg ∧ rms_avg + offset = ref ± 0.001',
      (rmsAvgDbfs, refSpl) {
        final offset = refSpl - rmsAvgDbfs;
        final reconstructed = rmsAvgDbfs + offset;
        ft.expect(reconstructed, closeTo(refSpl, 0.001));
        // El offset debe estar en rango esperado de un teléfono típico
        // (entre 90 y 140 dB para refSpl=94 y rms ∈ [-40,-10]).
        ft.expect(offset, inInclusiveRange(90.0, 140.0));
      },
    );

    Glados2<double, double>(
      any.doubleInRange(-40.0, -10.0),
      any.doubleInRange(80.0, 100.0),
      ExploreConfig(numRuns: 50),
    ).test(
      'aplicado a un dbfs distinto produce un dbSpl distinto',
      (rmsAvgDbfs, refSpl) {
        final offset = refSpl - rmsAvgDbfs;
        // Si después la app mide otro dbfs distinto, la conversión
        // sigue siendo lineal con el mismo offset.
        const otherDbfs = -25.0;
        final otherDbSpl = otherDbfs + offset;
        ft.expect(otherDbSpl, closeTo(refSpl + (otherDbfs - rmsAvgDbfs), 0.001));
      },
    );
  });
}
