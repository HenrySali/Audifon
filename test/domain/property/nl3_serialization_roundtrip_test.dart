// Feature: nal-nl3-prescriptor, Property 9: Serialization round-trip

/// Property-based test para Property 9: para cualquier `NL3PrescriptionResult`
/// válido, `NL3PrescriptionResult.fromJson(result.toJson())` produce un
/// objeto igual al original (Equatable.==).
///
/// El timestamp se construye con precisión de milisegundos para evitar
/// pérdida de microsegundos durante el round-trip via toIso8601String.
///
/// **Validates: Requirements 11.1, 11.2**
library;

import 'package:glados/glados.dart';
import 'package:hearing_aid_app/domain/entities/loss_type.dart';
import 'package:hearing_aid_app/domain/entities/nl3_prescription_result.dart';
import 'package:hearing_aid_app/domain/entities/prescription_mode.dart';
import 'package:hearing_aid_app/domain/entities/wdrc_params.dart';

/// Genera un NL3PrescriptionResult a partir de dos seeds.
///
/// Mantiene los rangos válidos de los campos para que el resultado sea
/// representativo del espacio que produce el prescriptor real.
NL3PrescriptionResult _seedToResult(double seedA, double seedB) {
  final prescribed = <double>[];
  final finalGains = <double>[];
  final ratios = <double>[];
  for (int i = 0; i < 12; i++) {
    // Ganancias en [0, 50] derivadas de seedA.
    prescribed.add(((seedA * (i + 1) * 7.3) % 50.0).abs());
    finalGains.add(((seedA * (i + 1) * 11.1) % 50.0).abs());
    // Ratios en [1.0, 3.0] derivados de seedB.
    ratios.add(1.0 + ((seedB * (i + 1) * 5.3) % 2.0).abs());
  }

  // Loss type y modo derivados del seed.
  final lossType = LossType.values[(seedA.abs() * 100).floor() % LossType.values.length];
  final mode =
      PrescriptionMode.values[(seedB.abs() * 100).floor() % PrescriptionMode.values.length];
  final cinActive = mode == PrescriptionMode.comfortInNoise;
  final ptaWarning = (seedB.abs() * 1000).floor() % 2 == 0;

  // Incluir wdrcOverrides solo si CIN está activo (refleja la lógica real).
  final WdrcParams? wdrcOverrides = cinActive
      ? const WdrcParams(attackMs: 10.0, releaseMs: 150.0)
      : null;

  // Timestamp con precisión de milisegundos: garantiza round-trip exacto vía
  // toIso8601String (que sí preserva ms; los microsegundos pueden truncarse).
  final ms = ((seedA.abs() + seedB.abs()) * 1000000).floor();
  final timestamp = DateTime.fromMillisecondsSinceEpoch(ms, isUtc: true);

  return NL3PrescriptionResult(
    prescribedGains: prescribed,
    finalGains: finalGains,
    compressionRatios: ratios,
    lossType: lossType,
    mode: mode,
    cinActive: cinActive,
    wdrcOverrides: wdrcOverrides,
    ptaWarning: ptaWarning,
    timestamp: timestamp,
  );
}

void main() {
  group('Property 9: NL3PrescriptionResult JSON round-trip', () {
    Glados2(
      any.doubleInRange(0, 120),
      any.doubleInRange(0, 120),
      ExploreConfig(numRuns: 200),
    ).test(
      'fromJson(toJson(result)) == result',
      (seedA, seedB) {
        final original = _seedToResult(seedA, seedB);
        final json = original.toJson();
        final roundtrip = NL3PrescriptionResult.fromJson(json);

        // Equatable.== compara todos los campos incluido timestamp.
        expect(roundtrip, equals(original));
      },
    );
  });
}
