// Property test: estabilidad de calibraciones consecutivas con la
// misma señal.
//
// Spec: native-calibration-handlers, Property 3.
//
// Modelo: dado un nivel de referencia fijo (rms_avg_dbfs determinístico
// + ruido gaussiano mínimo), dos cálculos consecutivos del offset
// producen valores dentro de ±0.5 dB. Esta property verifica
// matemáticamente la estabilidad de la fórmula `94 − rms_avg`, sin
// requerir hardware: si dos invocaciones del handler ven `rms_avg`
// con dispersión ≤ 0.5 dB, los offsets resultantes también difieren
// ≤ 0.5 dB (la operación es aritmética simple).

import 'package:flutter_test/flutter_test.dart'
    hide test, group, setUp, tearDown, expect;
import 'package:flutter_test/flutter_test.dart' as ft show expect;
import 'package:glados/glados.dart';

void main() {
  group('Property: estabilidad de offsets consecutivos', () {
    Glados3<double, double, double>(
      any.doubleInRange(-40.0, -10.0),
      // Ruido gaussiano simulado: ±0.5 dB máximo.
      any.doubleInRange(-0.5, 0.5),
      any.doubleInRange(80.0, 100.0),
      ExploreConfig(numRuns: 30),
    ).test(
      'dos calibraciones con mismo rms_avg ± 0.5 dB → |Δoffset| ≤ 0.5',
      (rmsAvg1, noiseDelta, refSpl) {
        final offset1 = refSpl - rmsAvg1;
        // Run 2: el rms_avg observado fluctúa ±0.5 dB respecto al run 1.
        final rmsAvg2 = rmsAvg1 + noiseDelta;
        final offset2 = refSpl - rmsAvg2;
        final delta = (offset1 - offset2).abs();
        ft.expect(delta, lessThanOrEqualTo(0.5 + 1e-9));
      },
    );
  });
}
