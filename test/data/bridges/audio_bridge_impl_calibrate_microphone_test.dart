// Tests del flujo `AudioBridgeImpl.calibrateMicrophone`.
//
// Verifica que:
//   1. Golden: native retorna rmsAvg=-20, rmsStd=0.3 → splOffset=114, conf=1.0.
//   2. Golden: native retorna rmsStd=0.7 → confidenceLevel=0.7.
//   3. Native error UNSTABLE_SIGNAL → caller propaga PlatformException.
//   4. Native error LEVEL_OUT_OF_RANGE → caller propaga.
//   5. Tras éxito, `appendMicCalibration` se llama con el audit correcto
//      y SHA-256 verificable.

import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';

import 'package:hearing_aid_app/data/bridges/audio_bridge_impl.dart';
import 'package:hearing_aid_app/data/services/calibration_audit_repository.dart';

class _MockChannel {
  final MethodChannel channel;
  final List<MethodCall> calls = [];
  Map<String, dynamic>? response;
  Object? errorToThrow;
  _MockChannel(String name) : channel = MethodChannel(name) {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      if (errorToThrow != null) throw errorToThrow!;
      return response;
    });
  }
  void dispose() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDir;
  late _MockChannel methodMock;
  late _MockChannel levelMock;
  late _MockChannel stateMock;
  late AudioBridgeImpl bridge;
  late Box<dynamic> box;
  late CalibrationAuditRepository repo;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('mic_cal_test_');
    Hive.init(tempDir.path);
    methodMock = _MockChannel('com.psk.hearing_aid/audio');
    levelMock = _MockChannel('com.psk.hearing_aid/level');
    stateMock = _MockChannel('com.psk.hearing_aid/state');
    bridge = AudioBridgeImpl.withChannels(
      methodChannel: methodMock.channel,
      levelEventChannel: EventChannel(levelMock.channel.name),
      stateEventChannel: EventChannel(stateMock.channel.name),
    );
    box = await Hive.openBox<dynamic>(calibrationBoxName);
    repo = CalibrationAuditRepository(box);
    bridge.auditRepository = repo;
  });

  tearDown(() async {
    methodMock.dispose();
    levelMock.dispose();
    stateMock.dispose();
    if (Hive.isBoxOpen(calibrationBoxName)) {
      await Hive.box<dynamic>(calibrationBoxName).close();
    }
    await Hive.close();
    if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
  });

  test('golden: rmsAvg=-20, rmsStd=0.3 → splOffset=114, confidence=1.0',
      () async {
    final ts = DateTime.utc(2026, 6, 6, 12, 0).millisecondsSinceEpoch;
    methodMock.response = <String, dynamic>{
      'splOffset': 114.0,
      'confidenceLevel': 1.0,
      'method': 'external_ref',
      'calibratedAtMs': ts,
      'deviceModel': 'Pixel 7',
      'rmsAvgDbfs': -20.0,
      'rmsStdDbfs': 0.3,
      'referenceSplLevel': 94.0,
      'calibratorModel': 'B&K 4231',
      'operatorId': 'op_test',
      'expectedFreqHz': 1000.0,
      'windowsUsed': 45,
    };
    final result = await bridge.calibrateMicrophone(referenceSplLevel: 94.0);
    expect(result.splOffset, equals(114.0));
    expect(result.confidenceLevel, equals(1.0));
    expect(result.method, equals('external_ref'));
    expect(result.deviceModel, equals('Pixel 7'));

    // Audit trail persistido.
    final latest = await repo.getLatestMic();
    expect(latest, isNotNull);
    expect(latest!.micOffsetDb, equals(114.0));
    expect(latest.rmsAvgDbfs, equals(-20.0));
    expect(latest.rmsStdDbfs, equals(0.3));
    final ok = await repo.verifyIntegrity(latest);
    expect(ok, isTrue);
  });

  test('confidenceLevel=0.7 cuando rmsStd ∈ [0.5, 1.0]', () async {
    final ts = DateTime.utc(2026, 6, 6, 12, 0).millisecondsSinceEpoch;
    methodMock.response = <String, dynamic>{
      'splOffset': 114.0,
      'confidenceLevel': 0.7,
      'method': 'external_ref',
      'calibratedAtMs': ts,
      'deviceModel': 'Pixel 7',
      'rmsAvgDbfs': -20.0,
      'rmsStdDbfs': 0.7,
      'referenceSplLevel': 94.0,
      'calibratorModel': 'B&K 4231',
      'operatorId': 'op_test',
      'expectedFreqHz': 1000.0,
      'windowsUsed': 45,
    };
    final result = await bridge.calibrateMicrophone(referenceSplLevel: 94.0);
    expect(result.confidenceLevel, equals(0.7));
  });

  test('UNSTABLE_SIGNAL del native propaga PlatformException', () async {
    methodMock.errorToThrow = PlatformException(
      code: 'UNSTABLE_SIGNAL',
      message: 'rmsStd=1.5 > 1.0',
    );
    await expectLater(
      () => bridge.calibrateMicrophone(referenceSplLevel: 94.0),
      throwsA(
        isA<PlatformException>().having(
          (e) => e.code,
          'code',
          'UNSTABLE_SIGNAL',
        ),
      ),
    );
    // No persistió ningún audit.
    final all = await repo.getAll();
    expect(all, isEmpty);
  });

  test('LEVEL_OUT_OF_RANGE del native propaga PlatformException', () async {
    methodMock.errorToThrow = PlatformException(
      code: 'LEVEL_OUT_OF_RANGE',
      message: 'rmsAvg=-50 ∉ [-40, -10]',
    );
    await expectLater(
      () => bridge.calibrateMicrophone(referenceSplLevel: 94.0),
      throwsA(
        isA<PlatformException>().having(
          (e) => e.code,
          'code',
          'LEVEL_OUT_OF_RANGE',
        ),
      ),
    );
    final all = await repo.getAll();
    expect(all, isEmpty);
  });

  test('null response del native lanza PlatformException CALIBRATION_FAILED',
      () async {
    methodMock.response = null;
    await expectLater(
      () => bridge.calibrateMicrophone(referenceSplLevel: 94.0),
      throwsA(
        isA<PlatformException>().having(
          (e) => e.code,
          'code',
          'CALIBRATION_FAILED',
        ),
      ),
    );
  });

  test('SHA-256 del audit es verificable y único por record', () async {
    final ts1 = DateTime.utc(2026, 6, 6, 12, 0).millisecondsSinceEpoch;
    final ts2 = DateTime.utc(2026, 6, 6, 13, 0).millisecondsSinceEpoch;
    methodMock.response = <String, dynamic>{
      'splOffset': 114.0,
      'confidenceLevel': 1.0,
      'method': 'external_ref',
      'calibratedAtMs': ts1,
      'deviceModel': 'Pixel 7',
      'rmsAvgDbfs': -20.0,
      'rmsStdDbfs': 0.3,
      'referenceSplLevel': 94.0,
      'calibratorModel': 'B&K 4231',
      'operatorId': 'op_test',
      'expectedFreqHz': 1000.0,
      'windowsUsed': 45,
    };
    await bridge.calibrateMicrophone(referenceSplLevel: 94.0);

    // Segunda calibración con timestamp y offset distinto.
    methodMock.response = <String, dynamic>{
      'splOffset': 115.0,
      'confidenceLevel': 1.0,
      'method': 'external_ref',
      'calibratedAtMs': ts2,
      'deviceModel': 'Pixel 7',
      'rmsAvgDbfs': -21.0,
      'rmsStdDbfs': 0.3,
      'referenceSplLevel': 94.0,
      'calibratorModel': 'B&K 4231',
      'operatorId': 'op_test',
      'expectedFreqHz': 1000.0,
      'windowsUsed': 45,
    };
    await bridge.calibrateMicrophone(referenceSplLevel: 94.0);

    final all = await repo.getAll(type: 'mic');
    expect(all.length, equals(2));
    final hashes = all.map((r) => r.sha256).toSet();
    expect(hashes.length, equals(2)); // hashes únicos
    for (final r in all) {
      expect(await repo.verifyIntegrity(r), isTrue);
    }
  });
}
