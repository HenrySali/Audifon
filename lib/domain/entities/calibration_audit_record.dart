// Audit trail records for native calibration handlers.
//
// Cada calibración (mic + auricular) genera un registro inmutable con
// timestamp UTC, datos del operador, datos del equipamiento, payload
// medido y un hash SHA-256 del payload canonical-JSON-encoded para
// trazabilidad metrológica conforme a:
//   - IEC 60942 (calibrador acústico clase 1, mic).
//   - IEC 60318-4/5 (acoplador, auricular).
//   - IEC 61672-1 (sonómetro clase 2).
//   - ISO 13485 + ANMAT/INVIMA/FDA QSR (audit trail regulatorio).
//
// La fuente de verdad para los offsets en runtime sigue siendo el Hive
// box `calibration_box` con las claves `mic_offset_db` y
// `hp_offset_table.<id>`. Los audit records son SOLO trazabilidad y se
// persisten en el mismo box bajo prefijos `audit_mic_<iso>` /
// `audit_hp_<iso>`.

import 'package:equatable/equatable.dart';

/// Tipo discriminador del audit record. Útil para filtros en
/// `CalibrationAuditRepository.getAll(type: 'mic')`.
abstract class CalibrationAuditRecord extends Equatable {
  const CalibrationAuditRecord();

  /// `'mic'` o `'hp'`.
  String get type;

  /// Timestamp UTC ISO-8601 con resolución de milisegundos.
  DateTime get timestampUtc;

  /// Identificador anónimo del operador (típicamente PIN-hash truncado).
  String get operatorId;

  /// Modelo del dispositivo Android (`Build.MODEL`).
  String get deviceModel;

  /// SHA-256 hex de `canonicalJson(toJsonWithoutSha())`.
  String get sha256;

  /// Serialización completa con `sha256`. Usada para persistencia y export.
  Map<String, dynamic> toJson();

  /// Serialización SIN el campo `sha256`. Input para
  /// `CalibrationAuditRepository.computeSha256(...)`. Evita
  /// self-reference: el hash se calcula sobre la representación que NO
  /// incluye al hash mismo.
  Map<String, dynamic> toJsonWithoutSha();

  /// Clave Hive: `audit_<type>_<timestampUtc.toIso8601String()>`.
  String get storageKey =>
      'audit_${type}_${timestampUtc.toUtc().toIso8601String()}';
}

/// Audit record de una calibración de micrófono ejecutada con un
/// patrón acústico clase 1 (IEC 60942).
class MicCalibrationAudit extends CalibrationAuditRecord {
  @override
  final DateTime timestampUtc;
  final double referenceSplLevel;
  final double rmsAvgDbfs;
  final double rmsStdDbfs;
  final double micOffsetDb;
  final String calibratorModel;
  @override
  final String operatorId;
  @override
  final String deviceModel;
  final double expectedFreqHz;
  final int windowsUsed;
  @override
  final String sha256;

  const MicCalibrationAudit({
    required this.timestampUtc,
    required this.referenceSplLevel,
    required this.rmsAvgDbfs,
    required this.rmsStdDbfs,
    required this.micOffsetDb,
    required this.calibratorModel,
    required this.operatorId,
    required this.deviceModel,
    required this.expectedFreqHz,
    required this.windowsUsed,
    required this.sha256,
  });

  @override
  String get type => 'mic';

  @override
  Map<String, dynamic> toJsonWithoutSha() => <String, dynamic>{
        'type': type,
        'timestampUtc': timestampUtc.toUtc().toIso8601String(),
        'referenceSplLevel': referenceSplLevel,
        'rmsAvgDbfs': rmsAvgDbfs,
        'rmsStdDbfs': rmsStdDbfs,
        'micOffsetDb': micOffsetDb,
        'calibratorModel': calibratorModel,
        'operatorId': operatorId,
        'deviceModel': deviceModel,
        'expectedFreqHz': expectedFreqHz,
        'windowsUsed': windowsUsed,
      };

  @override
  Map<String, dynamic> toJson() => <String, dynamic>{
        ...toJsonWithoutSha(),
        'sha256': sha256,
      };

  factory MicCalibrationAudit.fromJson(Map<String, dynamic> json) {
    final type = json['type'] as String?;
    if (type != null && type != 'mic') {
      throw FormatException(
        'MicCalibrationAudit.fromJson: type esperado "mic", recibido "$type"',
      );
    }
    return MicCalibrationAudit(
      timestampUtc: DateTime.parse(json['timestampUtc'] as String).toUtc(),
      referenceSplLevel: (json['referenceSplLevel'] as num).toDouble(),
      rmsAvgDbfs: (json['rmsAvgDbfs'] as num).toDouble(),
      rmsStdDbfs: (json['rmsStdDbfs'] as num).toDouble(),
      micOffsetDb: (json['micOffsetDb'] as num).toDouble(),
      calibratorModel: json['calibratorModel'] as String,
      operatorId: json['operatorId'] as String,
      deviceModel: json['deviceModel'] as String,
      expectedFreqHz: (json['expectedFreqHz'] as num).toDouble(),
      windowsUsed: (json['windowsUsed'] as num).toInt(),
      sha256: json['sha256'] as String? ?? '',
    );
  }

  @override
  List<Object?> get props => <Object?>[
        timestampUtc,
        referenceSplLevel,
        rmsAvgDbfs,
        rmsStdDbfs,
        micOffsetDb,
        calibratorModel,
        operatorId,
        deviceModel,
        expectedFreqHz,
        windowsUsed,
        sha256,
      ];
}

/// Audit record de una calibración de auricular ejecutada con un
/// acoplador IEC 60318-4 (HA-2) o IEC 60318-5 (2 cc).
class HpCalibrationAudit extends CalibrationAuditRecord {
  @override
  final DateTime timestampUtc;
  final String headphoneId;
  final String headphoneName;
  final String couplerModel;
  @override
  final String operatorId;
  @override
  final String deviceModel;
  final double micOffsetDb;
  final double targetDbspl;
  final List<int> frequenciesHz;
  final List<double> splDbspl;
  final List<double> hpOffsetDb;
  @override
  final String sha256;

  const HpCalibrationAudit({
    required this.timestampUtc,
    required this.headphoneId,
    required this.headphoneName,
    required this.couplerModel,
    required this.operatorId,
    required this.deviceModel,
    required this.micOffsetDb,
    required this.targetDbspl,
    required this.frequenciesHz,
    required this.splDbspl,
    required this.hpOffsetDb,
    required this.sha256,
  });

  @override
  String get type => 'hp';

  @override
  Map<String, dynamic> toJsonWithoutSha() => <String, dynamic>{
        'type': type,
        'timestampUtc': timestampUtc.toUtc().toIso8601String(),
        'headphoneId': headphoneId,
        'headphoneName': headphoneName,
        'couplerModel': couplerModel,
        'operatorId': operatorId,
        'deviceModel': deviceModel,
        'micOffsetDb': micOffsetDb,
        'targetDbspl': targetDbspl,
        'frequenciesHz': frequenciesHz,
        'splDbspl': splDbspl,
        'hpOffsetDb': hpOffsetDb,
      };

  @override
  Map<String, dynamic> toJson() => <String, dynamic>{
        ...toJsonWithoutSha(),
        'sha256': sha256,
      };

  factory HpCalibrationAudit.fromJson(Map<String, dynamic> json) {
    final type = json['type'] as String?;
    if (type != null && type != 'hp') {
      throw FormatException(
        'HpCalibrationAudit.fromJson: type esperado "hp", recibido "$type"',
      );
    }
    return HpCalibrationAudit(
      timestampUtc: DateTime.parse(json['timestampUtc'] as String).toUtc(),
      headphoneId: json['headphoneId'] as String,
      headphoneName: json['headphoneName'] as String,
      couplerModel: json['couplerModel'] as String,
      operatorId: json['operatorId'] as String,
      deviceModel: json['deviceModel'] as String,
      micOffsetDb: (json['micOffsetDb'] as num).toDouble(),
      targetDbspl: (json['targetDbspl'] as num).toDouble(),
      frequenciesHz: List<int>.from(
        (json['frequenciesHz'] as List).map((e) => (e as num).toInt()),
      ),
      splDbspl: List<double>.from(
        (json['splDbspl'] as List).map((e) => (e as num).toDouble()),
      ),
      hpOffsetDb: List<double>.from(
        (json['hpOffsetDb'] as List).map((e) => (e as num).toDouble()),
      ),
      sha256: json['sha256'] as String? ?? '',
    );
  }

  @override
  List<Object?> get props => <Object?>[
        timestampUtc,
        headphoneId,
        headphoneName,
        couplerModel,
        operatorId,
        deviceModel,
        micOffsetDb,
        targetDbspl,
        frequenciesHz,
        splDbspl,
        hpOffsetDb,
        sha256,
      ];
}
