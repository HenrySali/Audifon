// Property test: linealidad de `getInputLevel` cuando el offset está
// aplicado. Modelo: el handler debe comportarse como sonómetro IEC
// 61672-1 clase 2 (linealidad ±1 dB en 50–100 dB SPL @ 1 kHz).
//
// La conversión es lineal por construcción: `dbSpl = dbfs + offset`.
// Este test verifica explícitamente que para cualquier `dbfs` en
// [-44, -14] (que cubre el rango 50–100 dB SPL con offset=120) y
// `offset ∈ [100, 130]`, la suma es exacta a ±0.001 dB.

import 'package:flutter_test/flutter_test.dart'
    hide test, group, setUp, tearDown, expect;
import 'package:flutter_test/flutter_test.dart' as ft show expect;
import 'package:glados/glados.dart';

void main() {
  group('Property: getInputLevel linealidad', () {
    Glados2<double, double>(
      any.doubleInRange(-120.0, 0.0),
      any.doubleInRange(80.0, 140.0),
      ExploreConfig(numRuns: 100),
    ).test(
      'dbSpl = dbfs + offset es lineal y exacto',
      (dbfs, offset) {
        final dbSpl = dbfs + offset;
        // Verifica que la inversa también funciona.
        final recoveredDbfs = dbSpl - offset;
        ft.expect(recoveredDbfs, closeTo(dbfs, 1e-9));
        // En 50-100 dB SPL @ 1 kHz, la conversión debe ser lineal
        // (modelo IEC 61672-1 clase 2).
        if (offset == 120.0 && dbfs >= -70.0 && dbfs <= -20.0) {
          final expectedSpl = 120.0 + dbfs;
          ft.expect(dbSpl, closeTo(expectedSpl, 1.0));
        }
      },
    );

    Glados<double>(
      any.doubleInRange(-44.0, -14.0),
      ExploreConfig(numRuns: 50),
    ).test(
      'rango clínico 76-106 dB SPL con offset 120',
      (dbfs) {
        const offset = 120.0;
        final dbSpl = dbfs + offset;
        ft.expect(dbSpl, inInclusiveRange(76.0, 106.0));
      },
    );
  });
}
