import 'package:equatable/equatable.dart';

/// Resultado de una medición individual del protocolo de loopback QC
/// (audiograma × frecuencia × input level).
///
/// Cada registro representa un par esperado/medido en dB SPL para una
/// combinación específica de:
///   - audiograma de prueba (Bisgaard N2/N4/S2 o planos 30/60 dB HL)
///   - frecuencia de tono warble (250, 1000, 4000 Hz)
///   - input level (50, 65, 80 dB SPL)
///
/// El veredicto pass/fail se basa en la tolerancia clínica BAA REMS 2018:
/// `|measuredDbSpl − expectedDbSpl| ≤ 5 dB SPL` (Req 15.13).
///
/// Requisitos: 15.11, 15.12, 15.13, 15.14
class QcMeasurement extends Equatable {
  /// Nombre del audiograma probado (p.ej. "Bisgaard N2", "Plano 30 dB HL").
  final String audiogramName;

  /// Frecuencia del tono warble en Hz (típicamente 250, 1000, 4000).
  final int frequencyHz;

  /// Nivel de entrada en dB SPL del tono warble inyectado en el coupler.
  final double inputLevelDbSpl;

  /// SPL esperado en el coupler según `BundleBuilder` (HL → SPL via RECD).
  final double expectedDbSpl;

  /// SPL realmente medido por el SPL meter calibrado (IEC 61672 Class 2).
  final double measuredDbSpl;

  /// Delta `measuredDbSpl − expectedDbSpl` (signo conservado, en dB).
  final double deltaDb;

  /// `true` si `|deltaDb| ≤ 5.0` dB (tolerancia BAA REMS 2018).
  final bool passed;

  const QcMeasurement({
    required this.audiogramName,
    required this.frequencyHz,
    required this.inputLevelDbSpl,
    required this.expectedDbSpl,
    required this.measuredDbSpl,
    required this.deltaDb,
    required this.passed,
  });

  /// Construye una medición computando `deltaDb` y `passed` a partir de
  /// `expectedDbSpl` y `measuredDbSpl`.
  factory QcMeasurement.compute({
    required String audiogramName,
    required int frequencyHz,
    required double inputLevelDbSpl,
    required double expectedDbSpl,
    required double measuredDbSpl,
    double toleranceDb = 5.0,
  }) {
    final delta = measuredDbSpl - expectedDbSpl;
    return QcMeasurement(
      audiogramName: audiogramName,
      frequencyHz: frequencyHz,
      inputLevelDbSpl: inputLevelDbSpl,
      expectedDbSpl: expectedDbSpl,
      measuredDbSpl: measuredDbSpl,
      deltaDb: delta,
      passed: delta.abs() <= toleranceDb,
    );
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
        'audiogramName': audiogramName,
        'frequencyHz': frequencyHz,
        'inputLevelDbSpl': inputLevelDbSpl,
        'expectedDbSpl': expectedDbSpl,
        'measuredDbSpl': measuredDbSpl,
        'deltaDb': deltaDb,
        'passed': passed,
      };

  factory QcMeasurement.fromJson(Map<String, dynamic> json) => QcMeasurement(
        audiogramName: json['audiogramName'] as String,
        frequencyHz: (json['frequencyHz'] as num).toInt(),
        inputLevelDbSpl: (json['inputLevelDbSpl'] as num).toDouble(),
        expectedDbSpl: (json['expectedDbSpl'] as num).toDouble(),
        measuredDbSpl: (json['measuredDbSpl'] as num).toDouble(),
        deltaDb: (json['deltaDb'] as num).toDouble(),
        passed: json['passed'] as bool,
      );

  @override
  List<Object?> get props => <Object?>[
        audiogramName,
        frequencyHz,
        inputLevelDbSpl,
        expectedDbSpl,
        measuredDbSpl,
        deltaDb,
        passed,
      ];
}

/// Registro de auditoría completo de una sesión de loopback QC, persistido
/// en `audit_trail_box` y exportado como PDF firmado para el release gate
/// (Req 15.14, 15.15, 16.4).
///
/// Captura:
/// - quién (operador + certificación)
/// - cuándo (`timestamp` ISO-8601)
/// - con qué (mic, coupler, SPL meter, audífono)
/// - qué se midió (lista de `QcMeasurement`, típicamente 5 audiogramas × 3
///   frecuencias × 3 inputs = 45 mediciones)
/// - veredicto final (`overallPassed`: AND lógico de todas las mediciones)
///
/// Schema versionado para futuras migraciones (`schemaVersion = "1.0.0"`).
class QcAuditRecord extends Equatable {
  /// Versión actual del schema de serialización.
  static const String currentSchemaVersion = '1.0.0';

  /// Fecha y hora de la sesión de QC (ISO-8601 al persistir).
  final DateTime timestamp;

  /// Nombre del operador que ejecuta el QC.
  final String operator;

  /// Certificación / matrícula profesional del operador
  /// (p.ej. "Audiología MN 1234").
  final String operatorCertification;

  /// Versión semver de la app bajo prueba (p.ej. "1.4.2").
  final String appVersion;

  /// Hash de commit corto (p.ej. "a1b2c3d") para trazabilidad de release.
  final String appCommitHash;

  /// Modelo del audífono probado (p.ej. "PSK Mobile v1").
  final String hearingAidModel;

  /// Número de serie del audífono.
  final String hearingAidSerial;

  /// Versión de firmware del audífono.
  final String hearingAidFirmware;

  /// Modelo del micrófono usado para validación (IEC 61672 Class 2).
  final String micModel;

  /// Número de serie del micrófono.
  final String micSerial;

  /// Fecha de la última calibración del micrófono.
  final DateTime micCalibrationDate;

  /// Modelo del coupler IEC 60318-5 (2cc) o equivalente.
  final String couplerModel;

  /// Modelo del SPL meter calibrado.
  final String splMeterModel;

  /// Número de serie del SPL meter.
  final String splMeterSerial;

  /// Tabla completa de mediciones realizadas.
  final List<QcMeasurement> measurements;

  /// `true` si TODAS las mediciones pasaron (tolerancia ±5 dB).
  final bool overallPassed;

  /// Notas libres del operador (opcional).
  final String? notes;

  const QcAuditRecord({
    required this.timestamp,
    required this.operator,
    required this.operatorCertification,
    required this.appVersion,
    required this.appCommitHash,
    required this.hearingAidModel,
    required this.hearingAidSerial,
    required this.hearingAidFirmware,
    required this.micModel,
    required this.micSerial,
    required this.micCalibrationDate,
    required this.couplerModel,
    required this.splMeterModel,
    required this.splMeterSerial,
    required this.measurements,
    required this.overallPassed,
    this.notes,
  });

  /// Construye un record computando `overallPassed` como AND lógico de las
  /// mediciones (true sólo si todas pasaron).
  factory QcAuditRecord.compute({
    required DateTime timestamp,
    required String operator,
    required String operatorCertification,
    required String appVersion,
    required String appCommitHash,
    required String hearingAidModel,
    required String hearingAidSerial,
    required String hearingAidFirmware,
    required String micModel,
    required String micSerial,
    required DateTime micCalibrationDate,
    required String couplerModel,
    required String splMeterModel,
    required String splMeterSerial,
    required List<QcMeasurement> measurements,
    String? notes,
  }) {
    final allPassed =
        measurements.isNotEmpty && measurements.every((m) => m.passed);
    return QcAuditRecord(
      timestamp: timestamp,
      operator: operator,
      operatorCertification: operatorCertification,
      appVersion: appVersion,
      appCommitHash: appCommitHash,
      hearingAidModel: hearingAidModel,
      hearingAidSerial: hearingAidSerial,
      hearingAidFirmware: hearingAidFirmware,
      micModel: micModel,
      micSerial: micSerial,
      micCalibrationDate: micCalibrationDate,
      couplerModel: couplerModel,
      splMeterModel: splMeterModel,
      splMeterSerial: splMeterSerial,
      measurements: List<QcMeasurement>.unmodifiable(measurements),
      overallPassed: allPassed,
      notes: notes,
    );
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
        'schemaVersion': currentSchemaVersion,
        'timestamp': timestamp.toUtc().toIso8601String(),
        'operator': operator,
        'operatorCertification': operatorCertification,
        'appVersion': appVersion,
        'appCommitHash': appCommitHash,
        'hearingAidModel': hearingAidModel,
        'hearingAidSerial': hearingAidSerial,
        'hearingAidFirmware': hearingAidFirmware,
        'micModel': micModel,
        'micSerial': micSerial,
        'micCalibrationDate': micCalibrationDate.toUtc().toIso8601String(),
        'couplerModel': couplerModel,
        'splMeterModel': splMeterModel,
        'splMeterSerial': splMeterSerial,
        'measurements': measurements.map((m) => m.toJson()).toList(),
        'overallPassed': overallPassed,
        'notes': notes,
      };

  factory QcAuditRecord.fromJson(Map<String, dynamic> json) {
    final schema = json['schemaVersion'] as String?;
    if (schema != null && schema != currentSchemaVersion) {
      throw FormatException(
        'QcAuditRecord schemaVersion mismatch: expected '
        '$currentSchemaVersion, got $schema',
      );
    }
    final rawMeasurements = json['measurements'] as List<dynamic>;
    final parsedMeasurements = rawMeasurements
        .map((dynamic m) => QcMeasurement.fromJson(
              Map<String, dynamic>.from(m as Map),
            ))
        .toList(growable: false);
    return QcAuditRecord(
      timestamp: DateTime.parse(json['timestamp'] as String),
      operator: json['operator'] as String,
      operatorCertification: json['operatorCertification'] as String,
      appVersion: json['appVersion'] as String,
      appCommitHash: json['appCommitHash'] as String,
      hearingAidModel: json['hearingAidModel'] as String,
      hearingAidSerial: json['hearingAidSerial'] as String,
      hearingAidFirmware: json['hearingAidFirmware'] as String,
      micModel: json['micModel'] as String,
      micSerial: json['micSerial'] as String,
      micCalibrationDate: DateTime.parse(json['micCalibrationDate'] as String),
      couplerModel: json['couplerModel'] as String,
      splMeterModel: json['splMeterModel'] as String,
      splMeterSerial: json['splMeterSerial'] as String,
      measurements: List<QcMeasurement>.unmodifiable(parsedMeasurements),
      overallPassed: json['overallPassed'] as bool,
      notes: json['notes'] as String?,
    );
  }

  /// Clave canónica para indexar en `audit_trail_box` (ISO-8601 UTC).
  /// Único por sesión y ordenable lexicográficamente por fecha.
  String get storageKey => timestamp.toUtc().toIso8601String();

  @override
  List<Object?> get props => <Object?>[
        timestamp.toUtc(),
        operator,
        operatorCertification,
        appVersion,
        appCommitHash,
        hearingAidModel,
        hearingAidSerial,
        hearingAidFirmware,
        micModel,
        micSerial,
        micCalibrationDate.toUtc(),
        couplerModel,
        splMeterModel,
        splMeterSerial,
        measurements,
        overallPassed,
        notes,
      ];
}
