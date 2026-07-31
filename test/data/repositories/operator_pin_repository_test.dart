// Feature: system-audit-fix, Task 10.4: Tests del OperatorPinRepository
//
// Valida la fix del hallazgo C-1 (Auditoría 2026-06-05): el PIN del
// operador ya no es literal en código sino aleatorio de 6 dígitos
// persistido como SHA-256 en la box Hive `service_settings_box`.
//
// Casos cubiertos:
//   - `hasPin()` retorna false antes de cualquier setup.
//   - `generateAndStoreInitialPin()` retorna un PIN de 6 dígitos numéricos.
//   - Tras generar, `hasPin()` retorna true.
//   - El PIN devuelto pasa `verifyPin(pin)` → true.
//   - PIN incorrecto → `verifyPin('wrong')` → false.
//   - El hash persistido NO es el PIN plain (verificado leyendo la box).
//   - El hash persistido es SHA-256 (64 chars hex).
//   - Dos llamadas consecutivas a `generateAndStoreInitialPin()` producen
//     PINs distintos (validación de aleatoriedad).
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';

import 'package:hearing_aid_app/data/repositories/operator_pin_repository.dart';

const String _kBoxName = 'service_settings_box';
const String _kPinHashKey = 'operator_pin_hash';

void main() {
  late Directory hiveTempDir;
  late OperatorPinRepository repo;

  setUpAll(() {
    // Inicializar Hive en un directorio temporal — mismo patrón que
    // amplification_bloc_test.dart.
    hiveTempDir = Directory.systemTemp.createTempSync('hive_op_pin_test_');
    Hive.init(hiveTempDir.path);
  });

  tearDownAll(() async {
    await Hive.close();
    if (hiveTempDir.existsSync()) {
      hiveTempDir.deleteSync(recursive: true);
    }
  });

  setUp(() async {
    // Garantizar box limpia entre tests para que `hasPin()` arranque false.
    final box = await Hive.openBox(_kBoxName);
    await box.clear();
    repo = OperatorPinRepository();
  });

  group('OperatorPinRepository', () {
    test('hasPin() returns false before any setup', () async {
      expect(await repo.hasPin(), isFalse);
    });

    test('generateAndStoreInitialPin() returns a 6-digit numeric PIN',
        () async {
      final pin = await repo.generateAndStoreInitialPin();
      expect(pin.length, 6);
      expect(RegExp(r'^\d{6}$').hasMatch(pin), isTrue,
          reason: 'PIN debe ser exactamente 6 dígitos numéricos');
    });

    test('hasPin() returns true after generateAndStoreInitialPin()', () async {
      await repo.generateAndStoreInitialPin();
      expect(await repo.hasPin(), isTrue);
    });

    test('verifyPin(correct) returns true', () async {
      final pin = await repo.generateAndStoreInitialPin();
      expect(await repo.verifyPin(pin), isTrue);
    });

    test('verifyPin(wrong) returns false', () async {
      await repo.generateAndStoreInitialPin();
      expect(await repo.verifyPin('wrong'), isFalse);
      expect(await repo.verifyPin('000000'), isFalse,
          reason: 'PIN distinto al generado debe fallar');
    });

    test('verifyPin returns false when no PIN has been stored', () async {
      // No setup previo → no hay hash → cualquier input retorna false.
      expect(await repo.verifyPin('123456'), isFalse);
    });

    test('stored value is NOT the plain PIN (hashed at rest)', () async {
      final pin = await repo.generateAndStoreInitialPin();
      final box = await Hive.openBox(_kBoxName);
      final stored = box.get(_kPinHashKey);

      expect(stored, isA<String>(),
          reason: 'Debe persistirse algún string en la box');
      expect(stored, isNot(equals(pin)),
          reason: 'El PIN plain NUNCA debe quedar persistido (hallazgo C-1)');
    });

    test('stored hash is SHA-256 (64 hex chars)', () async {
      await repo.generateAndStoreInitialPin();
      final box = await Hive.openBox(_kBoxName);
      final stored = box.get(_kPinHashKey) as String;

      expect(stored.length, 64,
          reason: 'SHA-256 hex digest tiene exactamente 64 caracteres');
      expect(RegExp(r'^[0-9a-f]{64}$').hasMatch(stored), isTrue,
          reason: 'Debe ser hex lowercase válido (sha256.convert().toString())');
    });

    test('two consecutive generations yield different PINs (randomness)',
        () async {
      final pin1 = await repo.generateAndStoreInitialPin();
      final pin2 = await repo.generateAndStoreInitialPin();
      // La probabilidad de colisión entre dos PINs aleatorios de 6 dígitos
      // es 1/1_000_000. Para un test que corre miles de veces, este check
      // es estadísticamente seguro y cataliza un fallo si alguien rompe la
      // aleatoriedad (e.g. semilla fija).
      expect(pin1, isNot(equals(pin2)),
          reason: 'PINs sucesivos deben ser distintos (Random.secure)');
    });

    test('verifyPin still works after a regeneration overrides the hash',
        () async {
      final pin1 = await repo.generateAndStoreInitialPin();
      final pin2 = await repo.generateAndStoreInitialPin();

      expect(await repo.verifyPin(pin2), isTrue);
      // El PIN viejo ya no es válido tras la regeneración.
      expect(await repo.verifyPin(pin1), isFalse,
          reason: 'Una nueva generación debe invalidar el PIN anterior');
    });
  });
}
