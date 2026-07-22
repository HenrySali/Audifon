// Tests del CalibrationAuditRepository.
//
// Cubre:
//   1. canonicalJson ordena claves alfabéticamente.
//   2. canonicalJson es idempotente.
//   3. computeSha256 retorna 64 chars hex.
//   4. appendMicCalibration + getLatestMic round-trip.
//   5. appendHpCalibration + getLatestHp round-trip.
//   6. verifyIntegrity true para record íntegro.
//   7. verifyIntegrity false para record manipulado.
//   8. getAll(type: 'mic') filtra correctamente.
//   9. clear(forTests: false) lanza StateError.
//  10. PBT: canonicalJson es idempotente sobre payloads arbitrarios.
//  11. PBT: tampering en cualquier campo invalida la integridad.

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart'
    hide test, group, setUp, tearDown, expect;
import 'package:flutter_test/flutter_test.dart' as ft show expect;
import 'package:glados/glados.dart';
import 'package:hive/hive.dart';

import 'package:hearing_aid_app/data/services/calibration_audit_repository.dart';
import 'package:hearing_aid_app/domain/entities/calibration_audit_record.dart';

void main() {
  late Directory tempDir;
  late Box<dynamic> box;
  late CalibrationAuditRepository repo;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('calib_audit_test_');
    Hive.init(tempDir.path);
    box = await Hive.openBox<dynamic>(calibrationBoxName);
    repo = CalibrationAuditRepository(box);
  });

  tearDown(() async {
    if (Hive.isBoxOpen(calibrationBoxName)) {
      await Hive.box<dynamic>(calibrationBoxName).close();
    }
    await Hive.close();
    if (tempDir.existsSync()) {
      tempDir.deleteSync(recursive: true);
    }
  });

  // ───────────────────────────────────────────────────────────────────────
  // 1-2. canonicalJson: orden + idempotencia
  // ───────────────────────────────────────────────────────────────────────

  group('canonicalJson', () {
    test('ordena claves alfabéticamente en el primer nivel', () {
      final input = <String, dynamic>{'b': 2, 'a': 1, 'c': 3};
      final out = CalibrationAuditRepository.canonicalJson(input);
      expect(out, equals('{"a":1,"b":2,"c":3}'));
    });

    test('ordena claves recursivamente en niveles anidados', () {
      final input = <String, dynamic>{
        'outer': {'z': 1, 'a': 2, 'm': 3},
        'first': 'value',
      };
      final out = CalibrationAuditRepository.canonicalJson(input);
      expect(
        out,
        equals('{"first":"value","outer":{"a":2,"m":3,"z":1}}'),
      );
    });

    test('preserva orden de listas', () {
      final input = <String, dynamic>{
        'items': <int>[3, 1, 2],
      };
      final out = CalibrationAuditRepository.canonicalJson(input);
      expect(out, equals('{"items":[3,1,2]}'));
    });

    test('serializa DateTime a ISO-8601 UTC con Z', () {
      final dt = DateTime.utc(2026, 6, 6, 12, 30, 45);
      final input = <String, dynamic>{'ts': dt};
      final out = CalibrationAuditRepository.canonicalJson(input);
      expect(out, contains('2026-06-06T12:30:45.000Z'));
    });

    test('es idempotente sobre payload simple', () {
      final input = <String, dynamic>{
        'b': <String, dynamic>{'y': 'two', 'x': 1},
        'a': <int>[3, 2, 1],
      };
      final once = CalibrationAuditRepository.canonicalJson(input);
      final twice = CalibrationAuditRepository.canonicalJson(jsonDecode(once));
      expect(once, equals(twice));
    });
  });

  // ───────────────────────────────────────────────────────────────────────
  // 3. computeSha256
  // ───────────────────────────────────────────────────────────────────────

  group('computeSha256', () {
    test('retorna 64 chars hex', () {
      final h = CalibrationAuditRepository.computeSha256(
        <String, dynamic>{'foo': 'bar'},
      );
      expect(h.length, equals(64));
      expect(RegExp(r'^[0-9a-f]{64}$').hasMatch(h), isTrue);
    });

    test('ignora el campo sha256 en el input para evitar self-reference', () {
      final hWith = CalibrationAuditRepository.computeSha256(
        <String, dynamic>{'foo': 'bar', 'sha256': 'should-be-ignored'},
      );
      final hWithout = CalibrationAuditRepository.computeSha256(
        <String, dynamic>{'foo': 'bar'},
      );
      expect(hWith, equals(hWithout));
    });

    test('determinista: mismo input → mismo hash', () {
      final input = <String, dynamic>{'a': 1, 'b': <int>[1, 2, 3], 'c': 'x'};
      final h1 = CalibrationAuditRepository.computeSha256(input);
      final h2 = CalibrationAuditRepository.computeSha256(input);
      expect(h1, equals(h2));
    });

    test('orden de claves no afecta el hash', () {
      final h1 = CalibrationAuditRepository.computeSha256(
        <String, dynamic>{'a': 1, 'b': 2, 'c': 3},
      );
      final h2 = CalibrationAuditRepository.computeSha256(
        <String, dynamic>{'c': 3, 'b': 2, 'a': 1},
      );
      expect(h1, equals(h2));
    });
  });

  // ───────────────────────────────────────────────────────────────────────
  // 4. appendMicCalibration round-trip
  // ───────────────────────────────────────────────────────────────────────

  group('appendMicCalibration', () {
    test('persiste y retorna el último audit', () async {
      final ts = DateTime.utc(2026, 6, 6, 10, 0);
      final base = <String, dynamic>{
        'type': 'mic',
        'timestampUtc': ts.toIso8601String(),
        'referenceSplLevel': 94.0,
        'rmsAvgDbfs': -20.0,
        'rmsStdDbfs': 0.3,
        'micOffsetDb': 114.0,
        'calibratorModel': 'B&K 4231',
        'operatorId': 'op_abcdef12',
        'deviceModel': 'Pixel 7',
        'expectedFreqHz': 1000.0,
        'windowsUsed': 45,
      };
      final hash = CalibrationAuditRepository.computeSha256(base);
      final record = MicCalibrationAudit(
        timestampUtc: ts,
        referenceSplLevel: 94.0,
        rmsAvgDbfs: -20.0,
        rmsStdDbfs: 0.3,
        micOffsetDb: 114.0,
        calibratorModel: 'B&K 4231',
        operatorId: 'op_abcdef12',
        deviceModel: 'Pixel 7',
        expectedFreqHz: 1000.0,
        windowsUsed: 45,
        sha256: hash,
      );
      await repo.appendMicCalibration(record);

      final latest = await repo.getLatestMic();
      expect(latest, isNotNull);
      expect(latest!.micOffsetDb, equals(114.0));
      expect(latest.sha256, equals(hash));

      // Las claves vivas también se actualizaron.
      expect(box.get('mic_offset_db'), equals(114.0));
      expect(
        box.get('last_calibrated_at_mic'),
        equals(ts.toIso8601String()),
      );
    });

    test('lanza StateError si el SHA-256 del record no coincide', () async {
      final ts = DateTime.utc(2026, 6, 6, 10, 0);
      final record = MicCalibrationAudit(
        timestampUtc: ts,
        referenceSplLevel: 94.0,
        rmsAvgDbfs: -20.0,
        rmsStdDbfs: 0.3,
        micOffsetDb: 114.0,
        calibratorModel: 'X',
        operatorId: 'op',
        deviceModel: 'Pixel',
        expectedFreqHz: 1000.0,
        windowsUsed: 45,
        sha256: 'invalid-hash',
      );
      expect(
        () => repo.appendMicCalibration(record),
        throwsA(isA<StateError>()),
      );
    });

    test('rechaza colisión de timestamp', () async {
      final ts = DateTime.utc(2026, 6, 6, 10, 0);
      final base = <String, dynamic>{
        'type': 'mic',
        'timestampUtc': ts.toIso8601String(),
        'referenceSplLevel': 94.0,
        'rmsAvgDbfs': -20.0,
        'rmsStdDbfs': 0.3,
        'micOffsetDb': 114.0,
        'calibratorModel': 'B&K 4231',
        'operatorId': 'op',
        'deviceModel': 'Pixel',
        'expectedFreqHz': 1000.0,
        'windowsUsed': 45,
      };
      final hash = CalibrationAuditRepository.computeSha256(base);
      final record = MicCalibrationAudit(
        timestampUtc: ts,
        referenceSplLevel: 94.0,
        rmsAvgDbfs: -20.0,
        rmsStdDbfs: 0.3,
        micOffsetDb: 114.0,
        calibratorModel: 'B&K 4231',
        operatorId: 'op',
        deviceModel: 'Pixel',
        expectedFreqHz: 1000.0,
        windowsUsed: 45,
        sha256: hash,
      );
      await repo.appendMicCalibration(record);
      expect(
        () => repo.appendMicCalibration(record),
        throwsA(isA<StateError>()),
      );
    });
  });

  // ───────────────────────────────────────────────────────────────────────
  // 5. appendHpCalibration round-trip
  // ───────────────────────────────────────────────────────────────────────

  group('appendHpCalibration', () {
    test('persiste y retorna el último audit por headphoneId', () async {
      final ts = DateTime.utc(2026, 6, 6, 11, 0);
      final freqs = <int>[
        250, 500, 750, 1000, 1500, 2000,
        2500, 3000, 3500, 4000, 6000, 8000,
      ];
      final spl = List<double>.filled(12, 94.0);
      final hp = List<double>.filled(12, 0.0);
      final base = <String, dynamic>{
        'type': 'hp',
        'timestampUtc': ts.toIso8601String(),
        'headphoneId': 'wired_default',
        'headphoneName': 'Wired headphones',
        'couplerModel': 'HA-2',
        'operatorId': 'op',
        'deviceModel': 'Pixel',
        'micOffsetDb': 114.0,
        'targetDbspl': 94.0,
        'frequenciesHz': freqs,
        'splDbspl': spl,
        'hpOffsetDb': hp,
      };
      final hash = CalibrationAuditRepository.computeSha256(base);
      final record = HpCalibrationAudit(
        timestampUtc: ts,
        headphoneId: 'wired_default',
        headphoneName: 'Wired headphones',
        couplerModel: 'HA-2',
        operatorId: 'op',
        deviceModel: 'Pixel',
        micOffsetDb: 114.0,
        targetDbspl: 94.0,
        frequenciesHz: freqs,
        splDbspl: spl,
        hpOffsetDb: hp,
        sha256: hash,
      );
      await repo.appendHpCalibration(record);

      final latest = await repo.getLatestHp('wired_default');
      expect(latest, isNotNull);
      expect(latest!.headphoneId, equals('wired_default'));
      expect(latest.hpOffsetDb, equals(hp));

      // Tabla viva también se persiste.
      final liveTable = box.get('hp_offset_table.wired_default');
      expect(liveTable, isA<Map>());
    });
  });

  // ───────────────────────────────────────────────────────────────────────
  // 6. verifyIntegrity
  // ───────────────────────────────────────────────────────────────────────

  group('verifyIntegrity', () {
    test('true para record íntegro', () async {
      final ts = DateTime.utc(2026, 6, 6, 12, 0);
      final base = <String, dynamic>{
        'type': 'mic',
        'timestampUtc': ts.toIso8601String(),
        'referenceSplLevel': 94.0,
        'rmsAvgDbfs': -20.0,
        'rmsStdDbfs': 0.3,
        'micOffsetDb': 114.0,
        'calibratorModel': 'B&K 4231',
        'operatorId': 'op',
        'deviceModel': 'Pixel',
        'expectedFreqHz': 1000.0,
        'windowsUsed': 45,
      };
      final hash = CalibrationAuditRepository.computeSha256(base);
      final record = MicCalibrationAudit(
        timestampUtc: ts,
        referenceSplLevel: 94.0,
        rmsAvgDbfs: -20.0,
        rmsStdDbfs: 0.3,
        micOffsetDb: 114.0,
        calibratorModel: 'B&K 4231',
        operatorId: 'op',
        deviceModel: 'Pixel',
        expectedFreqHz: 1000.0,
        windowsUsed: 45,
        sha256: hash,
      );
      await repo.appendMicCalibration(record);
      final ok = await repo.verifyIntegrity(record);
      expect(ok, isTrue);
    });

    test('false para record con un campo modificado', () async {
      final ts = DateTime.utc(2026, 6, 6, 12, 0);
      final base = <String, dynamic>{
        'type': 'mic',
        'timestampUtc': ts.toIso8601String(),
        'referenceSplLevel': 94.0,
        'rmsAvgDbfs': -20.0,
        'rmsStdDbfs': 0.3,
        'micOffsetDb': 114.0,
        'calibratorModel': 'B&K 4231',
        'operatorId': 'op',
        'deviceModel': 'Pixel',
        'expectedFreqHz': 1000.0,
        'windowsUsed': 45,
      };
      final originalHash = CalibrationAuditRepository.computeSha256(base);
      // Construir un record con un offset distinto pero conservar el hash original
      final tampered = MicCalibrationAudit(
        timestampUtc: ts,
        referenceSplLevel: 94.0,
        rmsAvgDbfs: -20.0,
        rmsStdDbfs: 0.3,
        micOffsetDb: 999.0, // ← MANIPULADO
        calibratorModel: 'B&K 4231',
        operatorId: 'op',
        deviceModel: 'Pixel',
        expectedFreqHz: 1000.0,
        windowsUsed: 45,
        sha256: originalHash, // ← hash del original, no del tampered
      );
      final ok = await repo.verifyIntegrity(tampered);
      expect(ok, isFalse);
    });
  });

  // ───────────────────────────────────────────────────────────────────────
  // 7. getAll filtros
  // ───────────────────────────────────────────────────────────────────────

  group('getAll', () {
    test('filtra por type=mic', () async {
      final ts1 = DateTime.utc(2026, 6, 6, 9, 0);
      final ts2 = DateTime.utc(2026, 6, 6, 10, 0);
      // mic record
      final micBase = <String, dynamic>{
        'type': 'mic',
        'timestampUtc': ts1.toIso8601String(),
        'referenceSplLevel': 94.0,
        'rmsAvgDbfs': -20.0,
        'rmsStdDbfs': 0.3,
        'micOffsetDb': 114.0,
        'calibratorModel': 'X',
        'operatorId': 'op',
        'deviceModel': 'Pixel',
        'expectedFreqHz': 1000.0,
        'windowsUsed': 45,
      };
      final micHash = CalibrationAuditRepository.computeSha256(micBase);
      final mic = MicCalibrationAudit(
        timestampUtc: ts1,
        referenceSplLevel: 94.0,
        rmsAvgDbfs: -20.0,
        rmsStdDbfs: 0.3,
        micOffsetDb: 114.0,
        calibratorModel: 'X',
        operatorId: 'op',
        deviceModel: 'Pixel',
        expectedFreqHz: 1000.0,
        windowsUsed: 45,
        sha256: micHash,
      );
      await repo.appendMicCalibration(mic);

      // hp record
      final freqs = <int>[
        250, 500, 750, 1000, 1500, 2000,
        2500, 3000, 3500, 4000, 6000, 8000,
      ];
      final hpBase = <String, dynamic>{
        'type': 'hp',
        'timestampUtc': ts2.toIso8601String(),
        'headphoneId': 'wired_default',
        'headphoneName': 'Wired',
        'couplerModel': 'HA-2',
        'operatorId': 'op',
        'deviceModel': 'Pixel',
        'micOffsetDb': 114.0,
        'targetDbspl': 94.0,
        'frequenciesHz': freqs,
        'splDbspl': List<double>.filled(12, 94.0),
        'hpOffsetDb': List<double>.filled(12, 0.0),
      };
      final hpHash = CalibrationAuditRepository.computeSha256(hpBase);
      final hp = HpCalibrationAudit(
        timestampUtc: ts2,
        headphoneId: 'wired_default',
        headphoneName: 'Wired',
        couplerModel: 'HA-2',
        operatorId: 'op',
        deviceModel: 'Pixel',
        micOffsetDb: 114.0,
        targetDbspl: 94.0,
        frequenciesHz: freqs,
        splDbspl: List<double>.filled(12, 94.0),
        hpOffsetDb: List<double>.filled(12, 0.0),
        sha256: hpHash,
      );
      await repo.appendHpCalibration(hp);

      final all = await repo.getAll();
      expect(all.length, equals(2));
      final onlyMic = await repo.getAll(type: 'mic');
      expect(onlyMic.length, equals(1));
      expect(onlyMic.first, isA<MicCalibrationAudit>());
      final onlyHp = await repo.getAll(type: 'hp');
      expect(onlyHp.length, equals(1));
      expect(onlyHp.first, isA<HpCalibrationAudit>());
    });
  });

  // ───────────────────────────────────────────────────────────────────────
  // 8. clear
  // ───────────────────────────────────────────────────────────────────────

  group('clear', () {
    test('lanza StateError sin forTests=true', () {
      expect(
        () => repo.clear(forTests: false),
        throwsA(isA<StateError>()),
      );
    });

    test('borra todo bajo forTests=true', () async {
      final ts = DateTime.utc(2026, 6, 6, 12, 0);
      final base = <String, dynamic>{
        'type': 'mic',
        'timestampUtc': ts.toIso8601String(),
        'referenceSplLevel': 94.0,
        'rmsAvgDbfs': -20.0,
        'rmsStdDbfs': 0.3,
        'micOffsetDb': 114.0,
        'calibratorModel': 'X',
        'operatorId': 'op',
        'deviceModel': 'Pixel',
        'expectedFreqHz': 1000.0,
        'windowsUsed': 45,
      };
      final hash = CalibrationAuditRepository.computeSha256(base);
      await repo.appendMicCalibration(MicCalibrationAudit(
        timestampUtc: ts,
        referenceSplLevel: 94.0,
        rmsAvgDbfs: -20.0,
        rmsStdDbfs: 0.3,
        micOffsetDb: 114.0,
        calibratorModel: 'X',
        operatorId: 'op',
        deviceModel: 'Pixel',
        expectedFreqHz: 1000.0,
        windowsUsed: 45,
        sha256: hash,
      ));
      expect((await repo.getAll()).length, equals(1));
      await repo.clear(forTests: true);
      expect((await repo.getAll()).length, equals(0));
      expect(box.get('mic_offset_db'), isNull);
    });
  });

  // ───────────────────────────────────────────────────────────────────────
  // 10. PBT: canonicalJson idempotente
  // ───────────────────────────────────────────────────────────────────────

  group('Property: canonicalJson idempotente', () {
    Glados<int>(
      any.intInRange(0, 100),
      ExploreConfig(numRuns: 50),
    ).test(
      'canonical(canonical(payload)) == canonical(payload)',
      (seed) {
        // Construimos un payload semi-determinista a partir del seed.
        final payload = <String, dynamic>{
          'z_field': seed,
          'a_field': 'value-$seed',
          'm_field': <String, dynamic>{
            'inner_z': seed * 2,
            'inner_a': <int>[seed, seed + 1, seed + 2],
          },
          'list': <Map<String, dynamic>>[
            <String, dynamic>{'x': 1, 'a': 2},
            <String, dynamic>{'b': 3, 'c': 4},
          ],
        };
        final once = CalibrationAuditRepository.canonicalJson(payload);
        final twice = CalibrationAuditRepository.canonicalJson(
          jsonDecode(once),
        );
        ft.expect(once, equals(twice));
      },
    );
  });

  // ───────────────────────────────────────────────────────────────────────
  // 11. PBT: tampering invalida integridad
  // ───────────────────────────────────────────────────────────────────────

  group('Property: tampering invalida la integridad', () {
    Glados<double>(
      any.doubleInRange(-30.0, 30.0),
      ExploreConfig(numRuns: 30),
    ).test(
      'modificar micOffsetDb invalida verifyIntegrity',
      (deltaOffset) async {
        // Skip cero (no es tampering real).
        if (deltaOffset.abs() < 0.001) return;

        // No abrimos Hive: verifyIntegrity recompila el hash localmente
        // y solo compara con el campo `sha256` del record. Es una
        // operación pura sin dependencias de I/O.
        final ts = DateTime.utc(2026, 6, 6, 12, 0);
        final base = <String, dynamic>{
          'type': 'mic',
          'timestampUtc': ts.toIso8601String(),
          'referenceSplLevel': 94.0,
          'rmsAvgDbfs': -20.0,
          'rmsStdDbfs': 0.3,
          'micOffsetDb': 114.0,
          'calibratorModel': 'X',
          'operatorId': 'op',
          'deviceModel': 'Pixel',
          'expectedFreqHz': 1000.0,
          'windowsUsed': 45,
        };
        final originalHash = CalibrationAuditRepository.computeSha256(base);
        // Tampered: micOffsetDb difiere en `deltaOffset`, conservando
        // el hash original (simula manipulación post-persistencia).
        final tampered = MicCalibrationAudit(
          timestampUtc: ts,
          referenceSplLevel: 94.0,
          rmsAvgDbfs: -20.0,
          rmsStdDbfs: 0.3,
          micOffsetDb: 114.0 + deltaOffset,
          calibratorModel: 'X',
          operatorId: 'op',
          deviceModel: 'Pixel',
          expectedFreqHz: 1000.0,
          windowsUsed: 45,
          sha256: originalHash,
        );
        final ok = await repo.verifyIntegrity(tampered);
        ft.expect(ok, isFalse);
      },
    );
  });
}
