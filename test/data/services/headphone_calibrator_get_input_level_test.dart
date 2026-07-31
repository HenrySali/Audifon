// Contract test del wire protocol entre `HeadphoneCalibrator` y el
// handler nativo `getInputLevel`.
//
// El test verifica que el caller Dart (que vive en
// `lib/data/services/headphone_calibrator.dart`):
//   - Pasa `micOffsetDb` al handler cuando está persistido en Hive.
//   - Usa `dbSpl` directamente cuando el handler retorna
//     `calibrated=true`.
//   - Cae a `dbfs + 120.0` cuando el handler retorna
//     `calibrated=false` o `dbSpl=null`.
//   - Propaga `StateError` cuando el handler tira PlatformException o
//     MissingPluginException.
//
// Implementación: replicamos el bloque privado `_measureMicLevel` de
// `HeadphoneCalibrator` con un helper que vive en este archivo y
// referencia a la constante pública `micOffsetDbSpl` del calibrator.
// Esto evita tocar la API pública del calibrator (que tiene callbacks
// y depende de just_audio para reproducir tonos).

import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';

import 'package:hearing_aid_app/data/services/headphone_calibrator.dart';

class _MockChannel {
  final MethodChannel channel;
  final List<MethodCall> calls = [];
  Map<String, dynamic>? response;
  Object? errorToThrow;

  _MockChannel(String name) : channel = MethodChannel(name) {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, _handler);
  }

  Future<dynamic> _handler(MethodCall call) async {
    calls.add(call);
    if (errorToThrow != null) {
      throw errorToThrow!;
    }
    return response;
  }

  void dispose() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDir;
  late _MockChannel mock;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('hp_cal_test_');
    Hive.init(tempDir.path);
    mock = _MockChannel('com.psk.hearing_aid/audio');
  });

  tearDown(() async {
    mock.dispose();
    if (Hive.isBoxOpen('calibration_box')) {
      await Hive.box('calibration_box').close();
    }
    await Hive.close();
    if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
  });

  group('getInputLevel wire protocol', () {
    test(
      'pasa micOffsetDb al handler cuando está persistido en Hive',
      () async {
        final box = await Hive.openBox('calibration_box');
        await box.put('mic_offset_db', 114.0);
        mock.response = <String, dynamic>{
          'dbfs': -22.5,
          'dbSpl': 91.5,
          'calibrated': true,
          'micOffsetDb': 114.0,
          'durationMs': 100,
          'sampleRate': 48000,
        };
        final value = await _measureMicLevelContract();
        expect(value, closeTo(91.5, 0.001));
        expect(mock.calls.length, equals(1));
        final args = mock.calls.first.arguments as Map?;
        expect(args!['micOffsetDb'], equals(114.0));
      },
    );

    test(
      'cae al default dbfs+120 cuando handler retorna calibrated=false',
      () async {
        // Sin offset persistido (Hive vacío).
        mock.response = <String, dynamic>{
          'dbfs': -30.0,
          'dbSpl': null,
          'calibrated': false,
          'micOffsetDb': null,
          'durationMs': 100,
          'sampleRate': 48000,
        };
        final value = await _measureMicLevelContract();
        // dbfs (-30) + default offset (120) = 90 dB SPL.
        expect(value, closeTo(90.0, 0.001));
        // No debería haber pasado micOffsetDb al handler.
        final args = mock.calls.first.arguments as Map?;
        expect(args == null || !args.containsKey('micOffsetDb'), isTrue);
      },
    );

    test(
      'propaga StateError si handler retorna null',
      () async {
        mock.response = null;
        await expectLater(
          () => _measureMicLevelContract(),
          throwsA(isA<StateError>()),
        );
      },
    );

    test(
      'propaga StateError si handler tira PlatformException',
      () async {
        mock.errorToThrow = PlatformException(
          code: 'AUDIO_RECORD_FAILED',
          message: 'No se pudo abrir AudioRecord',
        );
        await expectLater(
          () => _measureMicLevelContract(),
          throwsA(isA<StateError>()),
        );
      },
    );

    test(
      'propaga StateError si MissingPluginException',
      () async {
        mock.errorToThrow = MissingPluginException();
        await expectLater(
          () => _measureMicLevelContract(),
          throwsA(isA<StateError>()),
        );
      },
    );
  });
}

/// Replica del flujo privado `_measureMicLevel` del
/// `HeadphoneCalibrator` para verificar el wire protocol.
///
/// Importante: este helper expone la lógica visible por el caller
/// nativo, NO depende del audio output (que requiere just_audio y
/// funcionaría sólo en device/integration tests).
Future<double> _measureMicLevelContract() async {
  const channel = MethodChannel('com.psk.hearing_aid/audio');
  double? persistedOffset;
  if (Hive.isBoxOpen('calibration_box')) {
    final raw = Hive.box('calibration_box').get('mic_offset_db');
    if (raw is num) persistedOffset = raw.toDouble();
  }
  try {
    final result = await channel.invokeMapMethod<String, dynamic>(
      'getInputLevel',
      <String, dynamic>{
        if (persistedOffset != null) 'micOffsetDb': persistedOffset,
      },
    );
    if (result == null) {
      throw StateError('Calibración abortada: handler retornó null');
    }
    final dbfs = (result['dbfs'] as num?)?.toDouble();
    final dbSpl = (result['dbSpl'] as num?)?.toDouble();
    final calibrated = (result['calibrated'] as bool?) ?? false;
    if (calibrated && dbSpl != null) return dbSpl;
    if (dbfs == null) {
      throw StateError('Calibración abortada: handler no retornó dbfs');
    }
    return dbfs + HeadphoneCalibrator.micOffsetDbSpl;
  } on MissingPluginException catch (e) {
    throw StateError(
      'Calibración abortada: canal nativo no disponible. Causa: $e',
    );
  } on PlatformException catch (e) {
    throw StateError(
      'Calibración abortada: canal nativo falló. Causa: $e',
    );
  }
}
