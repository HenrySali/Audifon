// Tests del flujo `AudioBridgeImpl.calibrateHeadphones`.
//
// Verifica que:
//   1. Golden flat: 12 frecuencias con offset 0 dB → compensation ≈ 0.
//   2. Golden con decline en agudos: hp_offset[8000]=-10 → compensation[8000]=+10.
//   3. MIC_NOT_CALIBRATED: si no hay audit mic previo → caller propaga.
//   4. BAND_OUT_OF_RANGE del native → caller propaga PlatformException.
//   5. BAND_DISCONTINUITY del native → caller propaga.
//   6. Audit trail HP persistido con SHA-256 verificable.
//   7. Pasa `micOffsetDb` al handler nativo.

import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';

import 'package:hearing_aid_app/data/bridges/audio_bridge_impl.dart';
import 'package:hearing_aid_app/data/services/calibration_audit_repository.dart';
import 'package:hearing_aid_app/domain/entities/calibration_audit_record.dart';

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
  late AudioBridgeImpl bridge;
  late Box<dynamic> box;
  late CalibrationAuditRepository repo;

  const freqs = <int>[
    250, 500, 750, 1000, 1500, 2000,
    2500, 3000, 3500, 4000, 6000, 8000,
  ];

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('hp_cal_bridge_test_');
    Hive.init(tempDir.path);
    methodMock = _MockChannel('com.psk.hearing_aid/audio');
    bridge = AudioBridgeImpl.withChannels(
      methodChannel: methodMock.channel,
      levelEventChannel: const EventChannel('com.psk.hearing_aid/level'),
      stateEventChannel: const EventChannel('com.psk.hearing_aid/state'),
    );
    box = await Hive.openBox<dynamic>(calibrationBoxName);
    repo = CalibrationAuditRepository(box);
    bridge.auditRepository = repo;
  });

  tearDown(() async {
    methodMock.dispose();
    if (Hive.isBoxOpen(calibrationBoxName)) {
      await Hive.box<dynamic>(calibrationBoxName).close();
    }
    await Hive.close();
    if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
  });

  /// Helper que persiste un audit mic previo para que `calibrateHeadphones`
  /// pueda leer `mic_offset_db`.
  Future<void> _persistMicOffset(double offset) async {
    final ts = DateTime.utc(2026, 6, 6, 10, 0);
    final base = <String, dynamic>{
      'type': 'mic',
      'timestampUtc': ts.toIso8601String(),
      'referenceSplLevel': 94.0,
      'rmsAvgDbfs': 94.0 - offset,
      'rmsStdDbfs': 0.3,
      'micOffsetDb': offset,
      'calibratorModel': 'B&K 4231',
      'operatorId': 'op',
      'deviceModel': 'Pixel',
      'expectedFreqHz': 1000.0,
      'windowsUsed': 45,
    };
    final hash = CalibrationAuditRepository.computeSha256(base);
    final mic = MicCalibrationAudit(
      timestampUtc: ts,
      referenceSplLevel: 94.0,
      rmsAvgDbfs: 94.0 - offset,
      rmsStdDbfs: 0.3,
      micOffsetDb: offset,
      calibratorModel: 'B&K 4231',
      operatorId: 'op',
      deviceModel: 'Pixel',
      expectedFreqHz: 1000.0,
      windowsUsed: 45,
      sha256: hash,
    );
    await repo.appendMicCalibration(mic);
  }

  test(
    'golden flat: 12 bandas con offset 0 dB → compensation ≈ 0',
    () async {
      await _persistMicOffset(114.0);
      final ts = DateTime.utc(2026, 6, 6, 11, 0).millisecondsSinceEpoch;
      final spl = List<double>.filled(12, 94.0);
      final hp = List<double>.filled(12, 0.0);
      methodMock.response = <String, dynamic>{
        'frequencyResponse': {
          for (var i = 0; i < freqs.length; i++) freqs[i].toString(): spl[i],
        },
        'compensation': {
          for (var i = 0; i < freqs.length; i++) freqs[i].toString(): -hp[i],
        },
        'headphoneId': 'wired_default',
        'headphoneName': 'Wired headphones',
        'calibratedAtMs': ts,
        'isBluetooth': false,
        'couplerModel': 'HA-2',
        'operatorId': 'op',
        'deviceModel': 'Pixel',
        'micOffsetDb': 114.0,
        'targetDbspl': 94.0,
        'frequenciesHz': freqs,
        'splDbspl': spl,
        'hpOffsetDb': hp,
      };

      final result = await bridge.calibrateHeadphones(
        headphoneId: 'wired_default',
      );
      expect(result.headphoneId, equals('wired_default'));
      expect(result.compensation.length, equals(12));
      for (final f in freqs) {
        expect(result.compensation[f], closeTo(0.0, 0.01));
        expect(result.frequencyResponse[f], closeTo(94.0, 0.01));
      }

      // Verificar que pasó micOffsetDb al handler.
      expect(methodMock.calls.length, equals(1));
      final args = methodMock.calls.first.arguments as Map;
      expect(args['micOffsetDb'], equals(114.0));

      // Audit trail persistido.
      final latest = await repo.getLatestHp('wired_default');
      expect(latest, isNotNull);
      expect(latest!.headphoneId, equals('wired_default'));
      expect(await repo.verifyIntegrity(latest), isTrue);
    },
  );

  test(
    'decline en agudos: hp_offset[8000]=-10 → compensation[8000]=+10',
    () async {
      await _persistMicOffset(114.0);
      final ts = DateTime.utc(2026, 6, 6, 11, 0).millisecondsSinceEpoch;
      final spl = <double>[
        94.0, 94.0, 94.0, 94.0, 94.0, 94.0,
        94.0, 94.0, 92.0, 90.0, 88.0, 84.0,
      ];
      final hp = <double>[
        0.0, 0.0, 0.0, 0.0, 0.0, 0.0,
        0.0, 0.0, -2.0, -4.0, -6.0, -10.0,
      ];
      methodMock.response = <String, dynamic>{
        'frequencyResponse': {
          for (var i = 0; i < freqs.length; i++) freqs[i].toString(): spl[i],
        },
        'compensation': {
          for (var i = 0; i < freqs.length; i++) freqs[i].toString(): -hp[i],
        },
        'headphoneId': 'wired_default',
        'headphoneName': 'Wired',
        'calibratedAtMs': ts,
        'isBluetooth': false,
        'couplerModel': 'HA-2',
        'operatorId': 'op',
        'deviceModel': 'Pixel',
        'micOffsetDb': 114.0,
        'targetDbspl': 94.0,
        'frequenciesHz': freqs,
        'splDbspl': spl,
        'hpOffsetDb': hp,
      };
      final result = await bridge.calibrateHeadphones(
        headphoneId: 'wired_default',
      );
      expect(result.compensation[8000], closeTo(10.0, 0.01));
      expect(result.compensation[6000], closeTo(6.0, 0.01));
      expect(result.compensation[1000], closeTo(0.0, 0.01));
    },
  );

  test('MIC_NOT_CALIBRATED si no hay audit mic previo', () async {
    // Sin _persistMicOffset, el repo está vacío.
    methodMock.response = <String, dynamic>{};
    await expectLater(
      () => bridge.calibrateHeadphones(headphoneId: 'wired_default'),
      throwsA(
        isA<PlatformException>().having(
          (e) => e.code,
          'code',
          'MIC_NOT_CALIBRATED',
        ),
      ),
    );
    // No invocó al handler nativo.
    expect(methodMock.calls, isEmpty);
  });

  test('BAND_OUT_OF_RANGE del native propaga PlatformException', () async {
    await _persistMicOffset(114.0);
    methodMock.errorToThrow = PlatformException(
      code: 'BAND_OUT_OF_RANGE',
      message: 'Banda 8000 Hz fuera de rango (offset=-35 dB)',
    );
    await expectLater(
      () => bridge.calibrateHeadphones(headphoneId: 'wired_default'),
      throwsA(
        isA<PlatformException>().having(
          (e) => e.code,
          'code',
          'BAND_OUT_OF_RANGE',
        ),
      ),
    );
    // No persistió audit hp.
    final all = await repo.getAll(type: 'hp');
    expect(all, isEmpty);
  });

  test('BAND_DISCONTINUITY del native propaga PlatformException', () async {
    await _persistMicOffset(114.0);
    methodMock.errorToThrow = PlatformException(
      code: 'BAND_DISCONTINUITY',
      message: 'Discontinuidad entre 4000-6000 Hz: 18 dB > 15 dB',
    );
    await expectLater(
      () => bridge.calibrateHeadphones(headphoneId: 'wired_default'),
      throwsA(
        isA<PlatformException>().having(
          (e) => e.code,
          'code',
          'BAND_DISCONTINUITY',
        ),
      ),
    );
  });

  test('null response del native lanza PlatformException CALIBRATION_FAILED',
      () async {
    await _persistMicOffset(114.0);
    methodMock.response = null;
    await expectLater(
      () => bridge.calibrateHeadphones(headphoneId: 'wired_default'),
      throwsA(
        isA<PlatformException>().having(
          (e) => e.code,
          'code',
          'CALIBRATION_FAILED',
        ),
      ),
    );
  });
}
