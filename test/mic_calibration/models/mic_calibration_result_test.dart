/// Tests unitarios del modelo [MicCalibrationResult].
///
/// Cubre los 8 casos exigidos por la task 1.1 del spec
/// `microphone-and-biological-calibration-extension`:
///
///   1. Construcción válida con todos los campos requeridos.
///   2. ArgumentError si splOffset < 60.0.
///   3. ArgumentError si splOffset > 130.0.
///   4. Round-trip toJson() / fromJson() preserva todos los campos.
///   5. fromJson() rechaza schemaVersion incorrecta con FormatException.
///   6. computeSha256() es determinístico.
///   7. withSha256().verifySha256() siempre devuelve true.
///   8. Modificar un campo después de withSha256() rompe verifySha256().
///
/// Validates: Requirements R1, R3, R4, R9.
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:hearing_aid_app/mic_calibration/models/mic_calibration_result.dart';

void main() {
  // Helper: construye un resultado válido típico (modo automático).
  // El deviceId es un hex SHA-256 ficticio de 64 chars (Android ID hash).
  const sampleDeviceId =
      'a1b2c3d4e5f60718293a4b5c6d7e8f9012345678901234567890abcdef012345';
  MicCalibrationResult buildValid({
    double splOffset = 94.7,
    String method = MicCalibrationMethod.automaticTone,
    DateTime? date,
    String? operatorId = 'audiologist@clinica-bsas.com.ar',
    List<String>? qualityFlags,
    double? referenceSpl = 94.0,
    double? detectedFrequencyHz = 1000.3,
    double? capturedRmsDbfs = -26.1,
  }) {
    return MicCalibrationResult(
      deviceId: sampleDeviceId,
      deviceModel: 'SM-G998B',
      splOffset: splOffset,
      calibrationDate: date ?? DateTime.utc(2026, 6, 2, 15, 30, 0),
      method: method,
      referenceSpl: referenceSpl,
      detectedFrequencyHz: detectedFrequencyHz,
      capturedRmsDbfs: capturedRmsDbfs,
      qualityFlags: qualityFlags,
      operatorId: operatorId,
      appVersion: '2.5.0',
      firmwareVersion: '1.3.0',
    );
  }

  // ---------------------------------------------------------------------------
  // Test 1 — Construcción válida con todos los campos requeridos.
  // ---------------------------------------------------------------------------
  group('Construcción', () {
    test('Test 1: construye correctamente con todos los campos requeridos',
        () {
      final result = buildValid();

      expect(result.deviceId.length, 64);
      expect(result.deviceModel, 'SM-G998B');
      expect(result.splOffset, closeTo(94.7, 1e-12));
      expect(result.calibrationDate.isUtc, isTrue);
      expect(result.method, MicCalibrationMethod.automaticTone);
      expect(result.appVersion, '2.5.0');
      expect(result.firmwareVersion, '1.3.0');
      expect(result.qualityFlags, isEmpty);
      expect(result.sha256, isNull);
      expect(MicCalibrationResult.schemaVersion, '2.0');
    });

    test('qualityFlags es una lista inmutable', () {
      final result = buildValid(qualityFlags: ['noisy_environment']);
      expect(result.qualityFlags, equals(['noisy_environment']));
      expect(
        () => result.qualityFlags.add('otro'),
        throwsUnsupportedError,
        reason: 'qualityFlags debe ser inmutable para integridad de audit',
      );
    });

    test('acepta los tres métodos válidos', () {
      for (final m in MicCalibrationMethod.all) {
        expect(() => buildValid(method: m), returnsNormally);
      }
    });

    test('rechaza método desconocido', () {
      expect(
        () => buildValid(method: 'magic'),
        throwsArgumentError,
      );
    });
  });

  // ---------------------------------------------------------------------------
  // Test 2 / Test 3 — Validación de rango del splOffset.
  // ---------------------------------------------------------------------------
  group('Validación de rango splOffset', () {
    test('Test 2: ArgumentError si splOffset < 60.0', () {
      expect(
        () => buildValid(splOffset: 59.99),
        throwsA(isA<Error>()),
      );
      expect(
        () => buildValid(splOffset: 0.0),
        throwsA(isA<Error>()),
      );
      expect(
        () => buildValid(splOffset: -10.0),
        throwsA(isA<Error>()),
      );
    });

    test('Test 3: ArgumentError si splOffset > 130.0', () {
      expect(
        () => buildValid(splOffset: 130.01),
        throwsA(isA<Error>()),
      );
      expect(
        () => buildValid(splOffset: 200.0),
        throwsA(isA<Error>()),
      );
    });

    test('acepta exactamente los límites [60.0, 130.0]', () {
      expect(() => buildValid(splOffset: 60.0), returnsNormally);
      expect(() => buildValid(splOffset: 130.0), returnsNormally);
      expect(() => buildValid(splOffset: 93.0), returnsNormally);
    });
  });

  // ---------------------------------------------------------------------------
  // Test 4 — Round-trip JSON.
  // ---------------------------------------------------------------------------
  group('Serialización JSON', () {
    test('Test 4: toJson() / fromJson() preserva todos los campos', () {
      final original = buildValid(
        qualityFlags: ['noisy_environment', 'frequency_off_target'],
      );

      final json = original.toJson();
      // Debe incluir el schemaVersion explícito.
      expect(json['schemaVersion'], '2.0');
      // Las claves deben ser camelCase.
      expect(json.containsKey('splOffset'), isTrue);
      expect(json.containsKey('calibrationDate'), isTrue);
      expect(json.containsKey('detectedFrequencyHz'), isTrue);
      // La fecha debe estar serializada como ISO 8601 UTC (sufijo Z).
      final dateStr = json['calibrationDate'] as String;
      expect(dateStr.endsWith('Z'), isTrue);

      final encoded = jsonEncode(json);
      final decoded = jsonDecode(encoded) as Map<String, dynamic>;
      final restored = MicCalibrationResult.fromJson(decoded);

      expect(restored, equals(original));
      expect(restored.deviceId, original.deviceId);
      expect(restored.deviceModel, original.deviceModel);
      expect(restored.splOffset, closeTo(original.splOffset, 1e-12));
      expect(restored.calibrationDate.toUtc(),
          original.calibrationDate.toUtc());
      expect(restored.method, original.method);
      expect(restored.referenceSpl, original.referenceSpl);
      expect(restored.detectedFrequencyHz, original.detectedFrequencyHz);
      expect(restored.capturedRmsDbfs, original.capturedRmsDbfs);
      expect(restored.qualityFlags, equals(original.qualityFlags));
      expect(restored.operatorId, original.operatorId);
      expect(restored.appVersion, original.appVersion);
      expect(restored.firmwareVersion, original.firmwareVersion);
      expect(restored.sha256, original.sha256);
    });

    test('roundtrip con todos los campos opcionales nulos', () {
      final original = buildValid(
        method: MicCalibrationMethod.manual,
        operatorId: null,
        referenceSpl: null,
        detectedFrequencyHz: null,
        capturedRmsDbfs: null,
      );

      final restored = MicCalibrationResult.fromJson(
        jsonDecode(jsonEncode(original.toJson())) as Map<String, dynamic>,
      );

      expect(restored, equals(original));
      expect(restored.operatorId, isNull);
      expect(restored.referenceSpl, isNull);
      expect(restored.detectedFrequencyHz, isNull);
      expect(restored.capturedRmsDbfs, isNull);
    });

    // Test 5 — Rechazo de schemaVersion incompatible.
    test('Test 5: fromJson() rechaza schemaVersion ausente con FormatException',
        () {
      final json = buildValid().toJson()..remove('schemaVersion');
      expect(
        () => MicCalibrationResult.fromJson(json),
        throwsA(isA<FormatException>()),
      );
    });

    test('Test 5b: fromJson() rechaza schemaVersion 1.0', () {
      final json = buildValid().toJson()..['schemaVersion'] = '1.0';
      expect(
        () => MicCalibrationResult.fromJson(json),
        throwsA(isA<FormatException>()),
      );
    });

    test('Test 5c: fromJson() rechaza schemaVersion futura desconocida', () {
      final json = buildValid().toJson()..['schemaVersion'] = '3.0';
      expect(
        () => MicCalibrationResult.fromJson(json),
        throwsA(isA<FormatException>()),
      );
    });
  });

  // ---------------------------------------------------------------------------
  // Test 6 / 7 / 8 — SHA-256 helpers.
  // ---------------------------------------------------------------------------
  group('SHA-256', () {
    test('Test 6: computeSha256() es determinístico para el mismo payload',
        () {
      final r1 = buildValid();
      final r2 = buildValid();

      final h1 = r1.computeSha256();
      final h2 = r2.computeSha256();

      expect(h1, equals(h2));
      // Debe ser hex de 64 chars (256 bits / 4).
      expect(h1.length, 64);
      expect(RegExp(r'^[0-9a-f]{64}$').hasMatch(h1), isTrue);
    });

    test('computeSha256() ignora el propio campo sha256', () {
      final r = buildValid();
      final hashSinCampo = r.computeSha256();
      // Asignar un sha256 dummy y recomputar: debe dar el mismo hash, porque
      // el cálculo excluye el campo `sha256` de su entrada.
      final rWithFakeHash = r.copyWith(sha256: 'deadbeef' * 8);
      final hashConCampo = rWithFakeHash.computeSha256();
      expect(hashConCampo, equals(hashSinCampo));
    });

    test('Test 7: withSha256().verifySha256() siempre devuelve true', () {
      final original = buildValid();
      final firmado = original.withSha256();

      expect(firmado.sha256, isNotNull);
      expect(firmado.sha256!.length, 64);
      expect(firmado.verifySha256(), isTrue);

      // Idempotencia: firmar dos veces no cambia el hash.
      final dobleFirmado = firmado.withSha256();
      expect(dobleFirmado.sha256, equals(firmado.sha256));
    });

    test('verifySha256() devuelve true cuando sha256 es null (sin firma)',
        () {
      final r = buildValid();
      expect(r.sha256, isNull);
      expect(r.verifySha256(), isTrue,
          reason:
              'Sin sha256 se considera trivialmente verificado para soportar '
              'exports legacy.');
    });

    test(
        'Test 8: modificar un campo después de withSha256() invalida el hash',
        () {
      final firmado = buildValid().withSha256();
      expect(firmado.verifySha256(), isTrue);

      // Cambiar splOffset preservando el sha256 viejo => debe fallar verify.
      final modificado = firmado.copyWith(splOffset: 95.5);
      expect(modificado.sha256, equals(firmado.sha256));
      expect(modificado.verifySha256(), isFalse);

      // También cambiar deviceModel debe invalidar.
      final modificado2 = firmado.copyWith(deviceModel: 'OTRO-MODEL');
      expect(modificado2.verifySha256(), isFalse);

      // Cambiar la fecha debe invalidar.
      final modificado3 = firmado.copyWith(
        calibrationDate: DateTime.utc(2027, 1, 1),
      );
      expect(modificado3.verifySha256(), isFalse);
    });

    test('hashes distintos para resultados con offsets distintos', () {
      final r1 = buildValid(splOffset: 94.7);
      final r2 = buildValid(splOffset: 94.8);
      expect(r1.computeSha256(), isNot(equals(r2.computeSha256())));
    });
  });

  // ---------------------------------------------------------------------------
  // Igualdad estructural / toString.
  // ---------------------------------------------------------------------------
  group('Igualdad y representación', () {
    test('== compara estructuralmente', () {
      expect(buildValid(), equals(buildValid()));
      expect(buildValid(splOffset: 90.0), isNot(equals(buildValid())));
    });

    test('hashCode coincide para objetos iguales', () {
      expect(buildValid().hashCode, equals(buildValid().hashCode));
    });

    test('toString incluye datos clave para debug', () {
      final s = buildValid().toString();
      expect(s, contains('SM-G998B'));
      expect(s, contains('automatic_tone'));
      expect(s, contains('94.70'));
    });
  });
}
