/// Tests del SceneRecorder (Fase 4).
///
/// Usa el initializer estándar de Hive en memoria (init('./')) — no
/// requiere flutter test runner especial.
///
/// Validates: Requirements 5.4, 8.2, 8.3

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';

import 'package:hearing_aid_app/domain/audiogram_driven_presets/audiogram_driven_bundle.dart';
import 'package:hearing_aid_app/domain/audiogram_driven_presets/operating_mode.dart';
import 'package:hearing_aid_app/domain/entities/loss_type.dart';
import 'package:hearing_aid_app/domain/entities/prescription_mode.dart';
import 'package:hearing_aid_app/scene/scene_engine.dart';
import 'package:hearing_aid_app/scene/scene_recorder.dart';
import 'package:hearing_aid_app/scene/scene_snapshot.dart';
import 'package:hearing_aid_app/scene/smart_preset.dart';

import 'scene_decision_maker_test.dart' show makeSnap;

AudiogramDrivenBundle _fakeBundle() {
  return AudiogramDrivenBundle(
    gainsDb: List<double>.filled(12, 5.0),
    compressionRatios: List<double>.filled(12, 1.5),
    compressionKneesDbSpl: List<double>.filled(12, 50.0),
    mpoProfileDbSpl: List<double>.filled(12, 110.0),
    nrLevel: 1,
    wdrcAttackMs: 5.0,
    wdrcReleaseMs: 100.0,
    expansionKneeDbSpl: 35.0,
    lossType: LossType.flat,
    prescriptionMode: PrescriptionMode.quiet,
    mode: OperatingMode.diagnostic,
    gainScale: 1.0,
    derivedAt: DateTime.utc(2026, 1, 1),
  );
}

SceneAnalysisResult _fakeResult(SceneClass cls) {
  return SceneAnalysisResult(
    sceneClass: cls,
    confidence: 0.7,
    lastSnapshot: makeSnap(),
    wasPersonalized: false,
    sampleCount: 12,
    distribution: <SceneClass, int>{cls: 12},
    preset: _fakePreset(cls),
    usedDefaultAudiogram: false,
    bundle: _fakeBundle(),
  );
}

SmartPreset _fakePreset(SceneClass cls) {
  return SmartPreset(
    name: 'Test_${cls.name}',
    isPersonalized: false,
    sceneClass: cls,
    gains: List<double>.filled(12, 5.0),
    compressionRatio: 2.0,
    compressionKnee: 50.0,
    expansionKnee: 35.0,
    nrLevel: 1,
    tnrEnabled: false,
    volumeDeltaDb: 0.0,
    confidence: 0.7,
  );
}

void main() {
  late Directory tempDir;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('scene_recorder_test_');
    Hive.init(tempDir.path);
  });

  tearDown(() async {
    await Hive.deleteBoxFromDisk(SceneRecorder.boxName);
    await Hive.close();
    if (tempDir.existsSync()) {
      tempDir.deleteSync(recursive: true);
    }
  });

  test('record() persiste un SceneRecord en el box', () async {
    final recorder = SceneRecorder();
    final result = _fakeResult(SceneClass.voiceOnly);

    final rec = await recorder.record(result, preset: result.preset);
    expect(rec.sceneClass, SceneClass.voiceOnly);
    expect(rec.feedback, isNull);

    final history = await recorder.getHistory();
    expect(history.length, 1);
    expect(history.first.id, rec.id);
  });

  test('updateFeedback() actualiza el feedback de la entrada', () async {
    final recorder = SceneRecorder();
    final rec = await recorder.record(_fakeResult(SceneClass.silence),
        preset: _fakePreset(SceneClass.silence));
    await recorder.updateFeedback(rec.id, true);

    final list = await recorder.getHistory();
    expect(list.first.feedback, isTrue);

    await recorder.updateFeedback(rec.id, false);
    final list2 = await recorder.getHistory();
    expect(list2.first.feedback, isFalse);
  });

  test('getHistory() devuelve más reciente primero', () async {
    final recorder = SceneRecorder();
    await recorder.record(_fakeResult(SceneClass.silence),
        preset: _fakePreset(SceneClass.silence));
    await Future<void>.delayed(const Duration(milliseconds: 5));
    await recorder.record(_fakeResult(SceneClass.voiceOnly),
        preset: _fakePreset(SceneClass.voiceOnly));

    final list = await recorder.getHistory();
    expect(list.length, 2);
    expect(list.first.sceneClass, SceneClass.voiceOnly);
    expect(list.last.sceneClass, SceneClass.silence);
  });

  test('FIFO: tope de maxRecords descarta entradas viejas', () async {
    final recorder = SceneRecorder(maxRecords: 3);
    for (var i = 0; i < 5; i++) {
      await recorder.record(_fakeResult(SceneClass.silence),
          preset: _fakePreset(SceneClass.silence));
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }

    final list = await recorder.getHistory(limit: 100);
    expect(list.length, 3);
  });

  test('clearAll() vacía el box', () async {
    final recorder = SceneRecorder();
    for (var i = 0; i < 3; i++) {
      await recorder.record(_fakeResult(SceneClass.silence),
          preset: _fakePreset(SceneClass.silence));
    }
    await recorder.clearAll();
    final list = await recorder.getHistory();
    expect(list, isEmpty);
  });

  test('getHistory(limit: N) trunca al mínimo de N o tamaño actual', () async {
    final recorder = SceneRecorder();
    for (var i = 0; i < 5; i++) {
      await recorder.record(_fakeResult(SceneClass.silence),
          preset: _fakePreset(SceneClass.silence));
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    final list = await recorder.getHistory(limit: 2);
    expect(list.length, 2);
  });
}
