/// Tests para [QcAuditRepositoryImpl] (tarea 15.3 del spec
/// `audiogram-driven-presets`).
///
/// Cubre:
///   - Round-trip Hive: `append` + `getAll` devuelve el record exacto.
///   - JSON serialization round-trip (`toJson`/`fromJson` simétricos
///     incluyendo `QcMeasurement`).
///   - Generación de PDF: bytes != null, length > 0 y magic header
///     `%PDF-` (RFC 8118 / ISO 32000-1 §7.5.2 — todo PDF válido empieza
///     con esa firma).
///
/// Hive se inicializa contra un directorio temporal por test para
/// aislamiento entre runs.
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';

import 'package:hearing_aid_app/data/repositories/qc_audit_repository_impl.dart';
import 'package:hearing_aid_app/domain/entities/qc_audit_record.dart';

QcAuditRecord _buildSampleRecord({
  DateTime? timestamp,
  bool allPass = true,
}) {
  final ts = timestamp ?? DateTime.utc(2026, 5, 12, 10, 30, 45, 123);
  // Matriz mínima de 6 mediciones (2 audiogramas × 3 frecuencias × 1 input).
  final measurements = <QcMeasurement>[];
  const audiograms = ['Bisgaard N2', 'Plano 30 dB HL'];
  const frequencies = [250, 1000, 4000];
  for (final a in audiograms) {
    for (final f in frequencies) {
      const expected = 65.0 + 10.0;
      final delta = allPass ? 1.5 : 8.5;
      measurements.add(
        QcMeasurement.compute(
          audiogramName: a,
          frequencyHz: f,
          inputLevelDbSpl: 65.0,
          expectedDbSpl: expected,
          measuredDbSpl: expected + delta,
        ),
      );
    }
  }
  return QcAuditRecord.compute(
    timestamp: ts,
    operator: 'Audio. Pérez',
    operatorCertification: 'MN 1234',
    appVersion: '1.4.2',
    appCommitHash: 'a1b2c3d',
    hearingAidModel: 'PSK Mobile v1',
    hearingAidSerial: 'PSK-0001',
    hearingAidFirmware: 'fw-3.2.1',
    micModel: 'GRAS 40AG',
    micSerial: 'MIC-9876',
    micCalibrationDate: DateTime.utc(2026, 1, 15),
    couplerModel: 'IEC 60318-5 (2cc)',
    splMeterModel: 'B&K 2270',
    splMeterSerial: 'BK-5555',
    measurements: measurements,
    notes: 'Sesión de QC inicial',
  );
}

void main() {
  late Directory tempDir;
  late Box<dynamic> box;
  late QcAuditRepositoryImpl repo;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('qc_audit_repo_test_');
    Hive.init(tempDir.path);
    box = await Hive.openBox<dynamic>(qcAuditTrailBoxName);
    repo = QcAuditRepositoryImpl(box);
  });

  tearDown(() async {
    await box.clear();
    await Hive.close();
    if (tempDir.existsSync()) {
      tempDir.deleteSync(recursive: true);
    }
  });

  group('Hive round-trip (append + getAll)', () {
    test('append + getAll devuelve el record exacto', () async {
      final record = _buildSampleRecord();

      await repo.append(record);
      final all = await repo.getAll();

      expect(all, hasLength(1));
      expect(all.first, equals(record));
    });

    test('getAll devuelve los records en orden cronológico ascendente',
        () async {
      final older = _buildSampleRecord(
        timestamp: DateTime.utc(2026, 1, 1, 12),
      );
      final newer = _buildSampleRecord(
        timestamp: DateTime.utc(2026, 6, 1, 12),
      );

      // Insertamos el nuevo primero para forzar al repo a re-ordenar.
      await repo.append(newer);
      await repo.append(older);

      final all = await repo.getAll();
      expect(all, hasLength(2));
      expect(all[0].timestamp, equals(older.timestamp));
      expect(all[1].timestamp, equals(newer.timestamp));
    });

    test('append rechaza un timestamp duplicado con StateError', () async {
      final record = _buildSampleRecord();
      await repo.append(record);

      expect(
        () => repo.append(record),
        throwsA(isA<StateError>()),
      );
    });

    test('append + getAll preserva un record con overallPassed=false',
        () async {
      final failing = _buildSampleRecord(allPass: false);
      expect(failing.overallPassed, isFalse);

      await repo.append(failing);
      final all = await repo.getAll();

      expect(all, hasLength(1));
      expect(all.first.overallPassed, isFalse);
      expect(
        all.first.measurements.every((m) => !m.passed),
        isTrue,
      );
    });
  });

  group('JSON serialization round-trip', () {
    test('QcAuditRecord toJson/fromJson es simétrico', () {
      final record = _buildSampleRecord();

      final json = record.toJson();
      final restored = QcAuditRecord.fromJson(json);

      expect(restored, equals(record));
    });

    test('QcMeasurement toJson/fromJson es simétrico', () {
      final m = QcMeasurement.compute(
        audiogramName: 'Bisgaard N4',
        frequencyHz: 4000,
        inputLevelDbSpl: 80.0,
        expectedDbSpl: 102.5,
        measuredDbSpl: 100.0,
      );

      final restored = QcMeasurement.fromJson(m.toJson());

      expect(restored, equals(m));
      expect(restored.deltaDb, closeTo(-2.5, 1e-9));
      expect(restored.passed, isTrue);
    });

    test('fromJson rechaza schemaVersion incompatible', () {
      final record = _buildSampleRecord();
      final json = record.toJson();
      json['schemaVersion'] = '99.0.0';

      expect(
        () => QcAuditRecord.fromJson(json),
        throwsA(isA<FormatException>()),
      );
    });

    test('overallPassed se computa correctamente con AND lógico', () {
      final allPass = _buildSampleRecord();
      final oneFails = _buildSampleRecord(allPass: false);

      expect(allPass.overallPassed, isTrue);
      expect(oneFails.overallPassed, isFalse);
    });

    test('QcMeasurement.passed honra la tolerancia BAA REMS 2018 (±5 dB)', () {
      final justPass = QcMeasurement.compute(
        audiogramName: 'X',
        frequencyHz: 1000,
        inputLevelDbSpl: 65.0,
        expectedDbSpl: 75.0,
        measuredDbSpl: 80.0, // Δ = +5.0 → pass
      );
      final justFail = QcMeasurement.compute(
        audiogramName: 'X',
        frequencyHz: 1000,
        inputLevelDbSpl: 65.0,
        expectedDbSpl: 75.0,
        measuredDbSpl: 80.001, // Δ = +5.001 → fail
      );

      expect(justPass.passed, isTrue);
      expect(justFail.passed, isFalse);
    });
  });

  group('PDF generation', () {
    test('generatePdf produce bytes no vacíos con magic header %PDF-',
        () async {
      final record = _buildSampleRecord();

      final bytes = await repo.generatePdf(record);

      expect(bytes, isNotNull);
      expect(bytes.length, greaterThan(0));
      // ISO 32000-1 §7.5.2 — todo PDF válido empieza con `%PDF-`
      // (los 5 primeros bytes son ASCII 0x25 0x50 0x44 0x46 0x2D).
      expect(bytes.length, greaterThanOrEqualTo(5));
      expect(bytes[0], equals(0x25)); // %
      expect(bytes[1], equals(0x50)); // P
      expect(bytes[2], equals(0x44)); // D
      expect(bytes[3], equals(0x46)); // F
      expect(bytes[4], equals(0x2D)); // -
    });

    test('generatePdf no muta el record original ni el audit trail', () async {
      final record = _buildSampleRecord();

      await repo.append(record);
      final beforeAll = await repo.getAll();
      await repo.generatePdf(record);
      final afterAll = await repo.getAll();

      expect(afterAll, equals(beforeAll));
    });

    test('generatePdf funciona también con un record de FAIL', () async {
      final failing = _buildSampleRecord(allPass: false);

      final bytes = await repo.generatePdf(failing);

      expect(bytes.length, greaterThan(0));
      expect(bytes[0], equals(0x25));
      expect(bytes[4], equals(0x2D));
    });
  });
}
