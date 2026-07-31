/// Tests unitarios de los modelos de calibración biológica.
///
/// Verifica:
///   - Reglas de negocio (`EligibilityQuestionnaire.isEligible`,
///     `CatchTrialStats.rate/valid`, niveles de confianza de
///     `FrequencyThreshold`, `BiologicalCalibrationResult.hlToDbFS`).
///   - Roundtrip JSON `toJson` → `fromJson` para cada modelo.
///
/// Estos tests no requieren plugins ni Flutter binding: solo
/// `flutter_test` y los modelos puros de `lib/biological_calibration/models/`.
///
/// Requisitos validados: 2, 3 (esquema de persistencia y reglas de
/// elegibilidad / catch trials / promediado del design.md §6 y §8.5).
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:hearing_aid_app/biological_calibration/models/biological_calibration_result.dart';
import 'package:hearing_aid_app/biological_calibration/models/catch_trial_stats.dart';
import 'package:hearing_aid_app/biological_calibration/models/eligibility_questionnaire.dart';
import 'package:hearing_aid_app/biological_calibration/models/frequency_threshold.dart';
import 'package:hearing_aid_app/biological_calibration/models/subject_session.dart';

void main() {
  // ---------------------------------------------------------------------------
  // EligibilityQuestionnaire
  // ---------------------------------------------------------------------------
  group('EligibilityQuestionnaire', () {
    test('isEligible es true cuando los 4 criterios son true', () {
      const q = EligibilityQuestionnaire(
        ageInRange: true,
        normalHearingSelfReported: true,
        noActiveTinnitus: true,
        noCongestion: true,
      );
      expect(q.isEligible, isTrue);
    });

    test('isEligible es false si alguno de los criterios es false', () {
      const cases = <EligibilityQuestionnaire>[
        EligibilityQuestionnaire(
          ageInRange: false,
          normalHearingSelfReported: true,
          noActiveTinnitus: true,
          noCongestion: true,
        ),
        EligibilityQuestionnaire(
          ageInRange: true,
          normalHearingSelfReported: false,
          noActiveTinnitus: true,
          noCongestion: true,
        ),
        EligibilityQuestionnaire(
          ageInRange: true,
          normalHearingSelfReported: true,
          noActiveTinnitus: false,
          noCongestion: true,
        ),
        EligibilityQuestionnaire(
          ageInRange: true,
          normalHearingSelfReported: true,
          noActiveTinnitus: true,
          noCongestion: false,
        ),
      ];
      for (final q in cases) {
        expect(q.isEligible, isFalse,
            reason: 'Cualquier criterio false debe invalidar la elegibilidad');
      }
    });

    test('roundtrip toJson → fromJson preserva los campos', () {
      const original = EligibilityQuestionnaire(
        ageInRange: true,
        normalHearingSelfReported: false,
        noActiveTinnitus: true,
        noCongestion: false,
      );

      final restored = EligibilityQuestionnaire.fromJson(
        jsonDecode(jsonEncode(original.toJson())) as Map<String, dynamic>,
      );

      expect(restored.ageInRange, original.ageInRange);
      expect(restored.normalHearingSelfReported,
          original.normalHearingSelfReported);
      expect(restored.noActiveTinnitus, original.noActiveTinnitus);
      expect(restored.noCongestion, original.noCongestion);
      expect(restored.isEligible, original.isEligible);
    });
  });

  // ---------------------------------------------------------------------------
  // CatchTrialStats
  // ---------------------------------------------------------------------------
  group('CatchTrialStats', () {
    test('rate = falsePositives / total para total > 0', () {
      const stats = CatchTrialStats(total: 10, falsePositives: 3);
      expect(stats.rate, closeTo(0.3, 1e-12));
    });

    test('rate = 0.0 cuando total = 0', () {
      const stats = CatchTrialStats(total: 0, falsePositives: 0);
      expect(stats.rate, equals(0.0));
    });

    test('valid = true cuando rate <= 0.33', () {
      // Exactamente en el límite: 1/3 ≈ 0.333... pero la regla compara con 0.33
      // así que probamos algunos casos por debajo del umbral.
      const lower = CatchTrialStats(total: 10, falsePositives: 3); // 0.30
      const equal = CatchTrialStats(total: 100, falsePositives: 33); // 0.33
      const empty = CatchTrialStats(total: 0, falsePositives: 0); // 0.0

      expect(lower.valid, isTrue);
      expect(equal.valid, isTrue);
      expect(empty.valid, isTrue);
    });

    test('valid = false cuando rate > 0.33', () {
      const above = CatchTrialStats(total: 10, falsePositives: 4); // 0.40
      const allFp = CatchTrialStats(total: 5, falsePositives: 5); // 1.0
      expect(above.valid, isFalse);
      expect(allFp.valid, isFalse);
    });

    test('roundtrip JSON preserva total y falsePositives', () {
      const original = CatchTrialStats(total: 12, falsePositives: 2);
      final restored = CatchTrialStats.fromJson(
        jsonDecode(jsonEncode(original.toJson())) as Map<String, dynamic>,
      );
      expect(restored.total, original.total);
      expect(restored.falsePositives, original.falsePositives);
      expect(restored.rate, closeTo(original.rate, 1e-12));
      expect(restored.valid, original.valid);
    });
  });

  // ---------------------------------------------------------------------------
  // FrequencyThreshold
  // ---------------------------------------------------------------------------
  group('FrequencyThreshold', () {
    test('compute() con [-50, -52, -48] → mean=-50, spread=4, confidence=high',
        () {
      final t = FrequencyThreshold.compute(
        freqHz: 1000,
        values: const [-50.0, -52.0, -48.0],
      );

      expect(t.freqHz, equals(1000));
      expect(t.meanThresholdDbFS, closeTo(-50.0, 1e-12));
      expect(t.spreadDb, closeTo(4.0, 1e-12));
      expect(t.confidence, equals(ThresholdConfidence.high));
      // std muestral de [-50,-52,-48] = sqrt(((0)^2 + (-2)^2 + (2)^2)/2) = 2.0
      expect(t.stdDb, closeTo(2.0, 1e-12));
    });

    test('compute() con spread > 5 y <= 10 → confidence=medium', () {
      // spread = -42 - (-50) = 8 dB
      final t = FrequencyThreshold.compute(
        freqHz: 2000,
        values: const [-50.0, -46.0, -42.0],
      );
      expect(t.spreadDb, closeTo(8.0, 1e-12));
      expect(t.confidence, equals(ThresholdConfidence.medium));
    });

    test('compute() con spread > 10 → confidence=low', () {
      // spread = -38 - (-50) = 12 dB
      final t = FrequencyThreshold.compute(
        freqHz: 4000,
        values: const [-50.0, -44.0, -38.0],
      );
      expect(t.spreadDb, closeTo(12.0, 1e-12));
      expect(t.confidence, equals(ThresholdConfidence.low));
    });

    test('compute() con lista vacía lanza ArgumentError', () {
      expect(
        () => FrequencyThreshold.compute(freqHz: 1000, values: const []),
        throwsArgumentError,
      );
    });

    test('maxHLAchievable = -1 - mean', () {
      final t = FrequencyThreshold.compute(
        freqHz: 1000,
        values: const [-50.0, -52.0, -48.0],
      );
      // mean = -50 → maxHL = -1 - (-50) = 49
      expect(t.maxHLAchievable, closeTo(49.0, 1e-12));
    });

    test('roundtrip JSON preserva todos los campos', () {
      final original = FrequencyThreshold.compute(
        freqHz: 2000,
        values: const [-48.0, -50.0, -52.0, -49.0],
      );

      final restored = FrequencyThreshold.fromJson(
        jsonDecode(jsonEncode(original.toJson())) as Map<String, dynamic>,
      );

      expect(restored.freqHz, original.freqHz);
      expect(restored.meanThresholdDbFS,
          closeTo(original.meanThresholdDbFS, 1e-12));
      expect(restored.stdDb, closeTo(original.stdDb, 1e-12));
      expect(restored.spreadDb, closeTo(original.spreadDb, 1e-12));
      expect(restored.maxHLAchievable,
          closeTo(original.maxHLAchievable, 1e-12));
      expect(restored.confidence, original.confidence);
      expect(restored.individualValues, equals(original.individualValues));
    });
  });

  // ---------------------------------------------------------------------------
  // SubjectSession
  // ---------------------------------------------------------------------------
  group('SubjectSession', () {
    test('roundtrip JSON con todos los campos no nulos', () {
      final original = SubjectSession(
        id: 1,
        alias: 'Sujeto A',
        testedAt: DateTime.utc(2025, 3, 15, 10, 30, 45),
        questionnaire: const EligibilityQuestionnaire(
          ageInRange: true,
          normalHearingSelfReported: true,
          noActiveTinnitus: true,
          noCongestion: true,
        ),
        thresholdsDbFS: const {
          250: -55.0,
          500: -53.0,
          1000: -52.0,
          2000: -50.0,
          4000: -48.0,
          8000: -45.0,
        },
        retest1000DbFS: -53.0,
        retestDifferenceDb: 1.0,
        catchTrials: const CatchTrialStats(total: 10, falsePositives: 1),
        valid: true,
      );

      final restored = SubjectSession.fromJson(
        jsonDecode(jsonEncode(original.toJson())) as Map<String, dynamic>,
      );

      expect(restored.id, original.id);
      expect(restored.alias, original.alias);
      expect(restored.testedAt.toUtc(), original.testedAt.toUtc());
      expect(restored.questionnaire.isEligible,
          original.questionnaire.isEligible);
      expect(restored.thresholdsDbFS, equals(original.thresholdsDbFS));
      expect(restored.retest1000DbFS, original.retest1000DbFS);
      expect(restored.retestDifferenceDb, original.retestDifferenceDb);
      expect(restored.catchTrials.total, original.catchTrials.total);
      expect(restored.catchTrials.falsePositives,
          original.catchTrials.falsePositives);
      expect(restored.valid, original.valid);
    });

    test('campos null (retest no completado) sobreviven el roundtrip', () {
      final original = SubjectSession(
        id: 2,
        alias: 'Sujeto B',
        testedAt: DateTime.utc(2025, 3, 15, 11, 0, 0),
        questionnaire: const EligibilityQuestionnaire(
          ageInRange: true,
          normalHearingSelfReported: true,
          noActiveTinnitus: true,
          noCongestion: true,
        ),
        thresholdsDbFS: const {1000: -50.0},
        retest1000DbFS: null,
        retestDifferenceDb: null,
        catchTrials: const CatchTrialStats(total: 0, falsePositives: 0),
        valid: false,
      );

      final restored = SubjectSession.fromJson(
        jsonDecode(jsonEncode(original.toJson())) as Map<String, dynamic>,
      );

      expect(restored.retest1000DbFS, isNull);
      expect(restored.retestDifferenceDb, isNull);
      expect(restored.id, original.id);
      expect(restored.alias, original.alias);
      expect(restored.thresholdsDbFS, equals(original.thresholdsDbFS));
      expect(restored.valid, original.valid);
    });
  });

  // ---------------------------------------------------------------------------
  // DeviceInfo / ProtocolInfo / QualityMetrics
  // ---------------------------------------------------------------------------
  group('DeviceInfo / ProtocolInfo / QualityMetrics', () {
    test('roundtrip JSON DeviceInfo', () {
      const original = DeviceInfo(
        phoneModel: 'Samsung SM-A546E',
        phoneOs: 'Android 14',
        bluetoothDeviceName: 'Audífono BT v2.1',
        bluetoothMac: 'AA:BB:CC:DD:EE:FF',
        bluetoothCodec: 'AAC',
        systemVolumeLevel: 12,
        systemVolumeMax: 15,
        audioStream: 'STREAM_MUSIC',
      );

      final restored = DeviceInfo.fromJson(
        jsonDecode(jsonEncode(original.toJson())) as Map<String, dynamic>,
      );

      expect(restored.phoneModel, original.phoneModel);
      expect(restored.phoneOs, original.phoneOs);
      expect(restored.bluetoothDeviceName, original.bluetoothDeviceName);
      expect(restored.bluetoothMac, original.bluetoothMac);
      expect(restored.bluetoothCodec, original.bluetoothCodec);
      expect(restored.systemVolumeLevel, original.systemVolumeLevel);
      expect(restored.systemVolumeMax, original.systemVolumeMax);
      expect(restored.audioStream, original.audioStream);
    });

    test('roundtrip JSON ProtocolInfo', () {
      const original = ProtocolInfo(
        method: 'hughson_westlake_modified',
        stepUpDb: 5.0,
        stepDownDb: 10.0,
        toneDurationMs: 1000,
        rampMs: 25,
        rampType: 'raised_cosine',
        itiMinMs: 1500,
        itiMaxMs: 3000,
        thresholdCriterion: '2_of_3_ascending',
        sampleRate: 48000,
        bitDepth: 16,
        channels: 1,
      );

      final restored = ProtocolInfo.fromJson(
        jsonDecode(jsonEncode(original.toJson())) as Map<String, dynamic>,
      );

      expect(restored.method, original.method);
      expect(restored.stepUpDb, original.stepUpDb);
      expect(restored.stepDownDb, original.stepDownDb);
      expect(restored.toneDurationMs, original.toneDurationMs);
      expect(restored.rampMs, original.rampMs);
      expect(restored.rampType, original.rampType);
      expect(restored.itiMinMs, original.itiMinMs);
      expect(restored.itiMaxMs, original.itiMaxMs);
      expect(restored.thresholdCriterion, original.thresholdCriterion);
      expect(restored.sampleRate, original.sampleRate);
      expect(restored.bitDepth, original.bitDepth);
      expect(restored.channels, original.channels);
    });

    test('roundtrip JSON QualityMetrics', () {
      const original = QualityMetrics(
        overallSpreadMeanDb: 4.5,
        overallSpreadMaxDb: 8.0,
        totalCatchTrials: 30,
        totalFalsePositives: 4,
        overallFalsePositiveRate: 4 / 30,
        allRetestsWithin5Db: true,
        calibrationValid: true,
      );

      final restored = QualityMetrics.fromJson(
        jsonDecode(jsonEncode(original.toJson())) as Map<String, dynamic>,
      );

      expect(restored.overallSpreadMeanDb,
          closeTo(original.overallSpreadMeanDb, 1e-12));
      expect(restored.overallSpreadMaxDb,
          closeTo(original.overallSpreadMaxDb, 1e-12));
      expect(restored.totalCatchTrials, original.totalCatchTrials);
      expect(restored.totalFalsePositives, original.totalFalsePositives);
      expect(restored.overallFalsePositiveRate,
          closeTo(original.overallFalsePositiveRate, 1e-12));
      expect(restored.allRetestsWithin5Db, original.allRetestsWithin5Db);
      expect(restored.calibrationValid, original.calibrationValid);
    });
  });

  // ---------------------------------------------------------------------------
  // BiologicalCalibrationResult
  // ---------------------------------------------------------------------------
  group('BiologicalCalibrationResult', () {
    BiologicalCalibrationResult buildSampleResult() {
      const device = DeviceInfo(
        phoneModel: 'Samsung SM-A546E',
        phoneOs: 'Android 14',
        bluetoothDeviceName: 'Audífono BT v2.1',
        bluetoothMac: 'AA:BB:CC:DD:EE:FF',
        bluetoothCodec: 'AAC',
        systemVolumeLevel: 12,
        systemVolumeMax: 15,
        audioStream: 'STREAM_MUSIC',
      );

      const protocol = ProtocolInfo(
        method: 'hughson_westlake_modified',
        stepUpDb: 5.0,
        stepDownDb: 10.0,
        toneDurationMs: 1000,
        rampMs: 25,
        rampType: 'raised_cosine',
        itiMinMs: 1500,
        itiMaxMs: 3000,
        thresholdCriterion: '2_of_3_ascending',
        sampleRate: 48000,
        bitDepth: 16,
        channels: 1,
      );

      final session1 = SubjectSession(
        id: 1,
        alias: 'Sujeto A',
        testedAt: DateTime.utc(2025, 3, 15, 10, 30),
        questionnaire: const EligibilityQuestionnaire(
          ageInRange: true,
          normalHearingSelfReported: true,
          noActiveTinnitus: true,
          noCongestion: true,
        ),
        thresholdsDbFS: const {1000: -50.0, 2000: -48.0},
        retest1000DbFS: -52.0,
        retestDifferenceDb: 2.0,
        catchTrials: const CatchTrialStats(total: 10, falsePositives: 1),
        valid: true,
      );

      final session2 = SubjectSession(
        id: 2,
        alias: 'Sujeto B',
        testedAt: DateTime.utc(2025, 3, 15, 11, 0),
        questionnaire: const EligibilityQuestionnaire(
          ageInRange: true,
          normalHearingSelfReported: true,
          noActiveTinnitus: true,
          noCongestion: true,
        ),
        thresholdsDbFS: const {1000: -52.0, 2000: -50.0},
        retest1000DbFS: null,
        retestDifferenceDb: null,
        catchTrials: const CatchTrialStats(total: 10, falsePositives: 2),
        valid: true,
      );

      final freq1k = FrequencyThreshold.compute(
        freqHz: 1000,
        values: const [-50.0, -52.0, -48.0],
      );
      final freq2k = FrequencyThreshold.compute(
        freqHz: 2000,
        values: const [-48.0, -50.0, -52.0],
      );

      const quality = QualityMetrics(
        overallSpreadMeanDb: 4.0,
        overallSpreadMaxDb: 4.0,
        totalCatchTrials: 20,
        totalFalsePositives: 3,
        overallFalsePositiveRate: 3 / 20,
        allRetestsWithin5Db: true,
        calibrationValid: true,
      );

      return BiologicalCalibrationResult(
        createdAt: DateTime.utc(2025, 3, 15, 10, 0),
        expiresAt: DateTime.utc(2025, 6, 13, 10, 0),
        device: device,
        protocol: protocol,
        sessions: [session1, session2],
        frequencies: {1000: freq1k, 2000: freq2k},
        quality: quality,
      );
    }

    test('roundtrip JSON completo (sessions, frequencies, quality)', () {
      final original = buildSampleResult();

      final restored = BiologicalCalibrationResult.fromJson(
        jsonDecode(jsonEncode(original.toJson())) as Map<String, dynamic>,
      );

      expect(restored.createdAt.toUtc(), original.createdAt.toUtc());
      expect(restored.expiresAt.toUtc(), original.expiresAt.toUtc());
      expect(restored.device.bluetoothMac, original.device.bluetoothMac);
      expect(restored.protocol.method, original.protocol.method);

      expect(restored.sessions.length, original.sessions.length);
      expect(restored.sessions[0].id, original.sessions[0].id);
      expect(restored.sessions[0].thresholdsDbFS,
          equals(original.sessions[0].thresholdsDbFS));
      expect(restored.sessions[1].retest1000DbFS, isNull);

      expect(restored.frequencies.keys.toSet(),
          original.frequencies.keys.toSet());
      final orig1k = original.frequencies[1000]!;
      final rest1k = restored.frequencies[1000]!;
      expect(rest1k.freqHz, orig1k.freqHz);
      expect(rest1k.meanThresholdDbFS,
          closeTo(orig1k.meanThresholdDbFS, 1e-12));
      expect(rest1k.spreadDb, closeTo(orig1k.spreadDb, 1e-12));
      expect(rest1k.confidence, orig1k.confidence);
      expect(rest1k.maxHLAchievable, closeTo(orig1k.maxHLAchievable, 1e-12));

      expect(restored.quality.calibrationValid,
          original.quality.calibrationValid);
      expect(restored.quality.overallFalsePositiveRate,
          closeTo(original.quality.overallFalsePositiveRate, 1e-12));
    });

    test('hlToDbFS retorna mean + levelHL para una frecuencia existente', () {
      final result = buildSampleResult();
      // mean en 1000 Hz = -50.0 → -50 + 30 = -20 dBFS (≤ -1.0)
      final dbfs = result.hlToDbFS(30.0, 1000);
      expect(dbfs, isNotNull);
      expect(dbfs, closeTo(-20.0, 1e-12));
    });

    test('hlToDbFS retorna null para una frecuencia no calibrada', () {
      final result = buildSampleResult();
      // No hay umbrales para 4000 Hz en este resultado.
      expect(result.hlToDbFS(20.0, 4000), isNull);
    });

    test('hlToDbFS retorna null cuando el resultado excede -1.0 dBFS', () {
      final result = buildSampleResult();
      // mean en 1000 Hz = -50.0 → -50 + 60 = 10 dBFS > -1 → null.
      expect(result.hlToDbFS(60.0, 1000), isNull);
      // Caso límite: -50 + 49.5 = -0.5 dBFS > -1 → null.
      expect(result.hlToDbFS(49.5, 1000), isNull);
      // Justo en el techo: -50 + 49 = -1.0 dBFS NO excede el techo → válido.
      final atCeiling = result.hlToDbFS(49.0, 1000);
      expect(atCeiling, isNotNull);
      expect(atCeiling, closeTo(-1.0, 1e-12));
    });
  });
}
