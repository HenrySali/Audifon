/// Tests unitarios para la serialización JSON de NL3PrescriptionResult.
///
/// Verifica el round-trip toJson()/fromJson(), la validación de schemaVersion,
/// el campo prescriptionMethod, y el manejo de wdrcOverrides opcionales.
///
/// Requisitos validados: 11.1, 11.2, 11.3, 11.4
import 'package:flutter_test/flutter_test.dart';
import 'package:hearing_aid_app/domain/entities/loss_type.dart';
import 'package:hearing_aid_app/domain/entities/nl3_prescription_result.dart';
import 'package:hearing_aid_app/domain/entities/prescription_mode.dart';
import 'package:hearing_aid_app/domain/entities/wdrc_params.dart';

/// Construye un NL3PrescriptionResult de ejemplo con valores realistas
/// para un audiograma sloping con CIN activo.
NL3PrescriptionResult buildSampleResult({
  bool cinActive = true,
  WdrcParams? wdrcOverrides,
}) {
  return NL3PrescriptionResult(
    prescribedGains: [8.0, 12.0, 14.5, 18.0, 20.5, 22.0, 21.0, 19.5, 18.0, 16.5, 13.0, 10.5],
    finalGains: [6.0, 10.0, 12.5, 16.0, 18.5, 20.0, 19.0, 17.5, 16.0, 14.5, 11.0, 8.5],
    compressionRatios: [1.2, 1.3, 1.4, 1.8, 2.0, 2.2, 2.1, 2.0, 1.9, 1.8, 1.5, 1.3],
    lossType: LossType.sloping,
    mode: PrescriptionMode.comfortInNoise,
    cinActive: cinActive,
    wdrcOverrides: wdrcOverrides,
    ptaWarning: false,
    timestamp: DateTime.utc(2026, 6, 7, 14, 30),
  );
}

void main() {
  group('NL3PrescriptionResult - serialización JSON', () {
    test('round-trip: fromJson(toJson(result)) produce un objeto igual', () {
      // Verificamos que serializar y deserializar preserva todos los campos.
      final original = buildSampleResult(
        cinActive: true,
        wdrcOverrides: const WdrcParams(attackMs: 10.0, releaseMs: 150.0),
      );

      final json = original.toJson();
      final restored = NL3PrescriptionResult.fromJson(json);

      expect(restored.prescribedGains, equals(original.prescribedGains));
      expect(restored.finalGains, equals(original.finalGains));
      expect(restored.compressionRatios, equals(original.compressionRatios));
      expect(restored.lossType, equals(original.lossType));
      expect(restored.mode, equals(original.mode));
      expect(restored.cinActive, equals(original.cinActive));
      expect(restored.wdrcOverrides, equals(original.wdrcOverrides));
      expect(restored.ptaWarning, equals(original.ptaWarning));
      expect(restored.timestamp, equals(original.timestamp));
      expect(restored, equals(original));
    });

    test('schemaVersion en el JSON de salida es "1.0.0"', () {
      final result = buildSampleResult(
        cinActive: true,
        wdrcOverrides: const WdrcParams(attackMs: 10.0, releaseMs: 150.0),
      );

      final json = result.toJson();

      expect(json['schemaVersion'], equals('1.0.0'));
    });

    test('prescriptionMethod en el JSON de salida es "NAL-NL3-inspired"', () {
      final result = buildSampleResult(
        cinActive: true,
        wdrcOverrides: const WdrcParams(attackMs: 10.0, releaseMs: 150.0),
      );

      final json = result.toJson();

      expect(json['prescriptionMethod'], equals('NAL-NL3-inspired'));
    });

    test('fromJson con schemaVersion "2.0.0" lanza FormatException', () {
      // Simulamos un JSON con versión no soportada.
      final result = buildSampleResult(
        cinActive: true,
        wdrcOverrides: const WdrcParams(attackMs: 10.0, releaseMs: 150.0),
      );
      final json = result.toJson();
      json['schemaVersion'] = '2.0.0';

      expect(
        () => NL3PrescriptionResult.fromJson(json),
        throwsA(isA<FormatException>()),
      );
    });

    test('fromJson con schemaVersion null lanza FormatException', () {
      // Simulamos un JSON sin campo schemaVersion.
      final result = buildSampleResult(
        cinActive: true,
        wdrcOverrides: const WdrcParams(attackMs: 10.0, releaseMs: 150.0),
      );
      final json = result.toJson();
      json['schemaVersion'] = null;

      expect(
        () => NL3PrescriptionResult.fromJson(json),
        throwsA(isA<FormatException>()),
      );
    });

    test('round-trip con wdrcOverrides null (cinActive=false) funciona correctamente', () {
      // Cuando CIN no está activo, wdrcOverrides es null.
      final original = buildSampleResult(
        cinActive: false,
        wdrcOverrides: null,
      );

      final json = original.toJson();
      final restored = NL3PrescriptionResult.fromJson(json);

      expect(restored.cinActive, isFalse);
      expect(restored.wdrcOverrides, isNull);
      expect(restored, equals(original));
    });

    test('round-trip con wdrcOverrides presente (cinActive=true) funciona correctamente', () {
      // Cuando CIN está activo, wdrcOverrides tiene parámetros personalizados.
      final original = buildSampleResult(
        cinActive: true,
        wdrcOverrides: const WdrcParams(
          expansionKnee: 30.0,
          expansionRatio: 1.5,
          compressionKnee: 60.0,
          compressionRatio: 2.5,
          attackMs: 10.0,
          releaseMs: 150.0,
        ),
      );

      final json = original.toJson();
      final restored = NL3PrescriptionResult.fromJson(json);

      expect(restored.cinActive, isTrue);
      expect(restored.wdrcOverrides, isNotNull);
      expect(restored.wdrcOverrides!.attackMs, equals(10.0));
      expect(restored.wdrcOverrides!.releaseMs, equals(150.0));
      expect(restored.wdrcOverrides!.expansionKnee, equals(30.0));
      expect(restored.wdrcOverrides!.expansionRatio, equals(1.5));
      expect(restored.wdrcOverrides!.compressionKnee, equals(60.0));
      expect(restored.wdrcOverrides!.compressionRatio, equals(2.5));
      expect(restored, equals(original));
    });
  });
}
