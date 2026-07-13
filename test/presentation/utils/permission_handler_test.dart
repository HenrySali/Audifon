import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

import 'package:hearing_aid_app/presentation/utils/device_checker.dart';
import 'package:hearing_aid_app/presentation/utils/permission_handler.dart';

/// Mock del DeviceChecker para testing.
class MockDeviceChecker extends Mock implements DeviceChecker {}

void main() {
  late MockDeviceChecker mockDeviceChecker;
  late AudioPermissionHandler handler;

  setUp(() {
    mockDeviceChecker = MockDeviceChecker();
    handler = AudioPermissionHandler(deviceChecker: mockDeviceChecker);
  });

  group('AudioPermissionHandler', () {
    group('checkHeadphoneConnection', () {
      test('returns success when headphones are connected', () async {
        when(() => mockDeviceChecker.isHeadphoneConnected())
            .thenAnswer((_) async => true);

        final result = await handler.checkHeadphoneConnection();

        expect(result.canStart, isTrue);
        expect(result.errorMessage, isNull);
      });

      test('returns failure with descriptive message when no headphones',
          () async {
        when(() => mockDeviceChecker.isHeadphoneConnected())
            .thenAnswer((_) async => false);

        final result = await handler.checkHeadphoneConnection();

        expect(result.canStart, isFalse);
        expect(result.errorMessage, isNotNull);
        expect(result.errorMessage, contains('auriculares'));
        expect(result.errorMessage, contains('retroalimentación'));
      });
    });

    group('checkLowLatencySupport', () {
      test('returns success without warning when low latency is supported',
          () async {
        when(() => mockDeviceChecker.supportsLowLatency())
            .thenAnswer((_) async => true);

        final result = await handler.checkLowLatencySupport();

        expect(result.canStart, isTrue);
        expect(result.lowLatencyWarning, isFalse);
        expect(result.warningMessage, isNull);
      });

      test(
          'returns success with warning when low latency is not supported',
          () async {
        when(() => mockDeviceChecker.supportsLowLatency())
            .thenAnswer((_) async => false);

        final result = await handler.checkLowLatencySupport();

        expect(result.canStart, isTrue);
        expect(result.lowLatencyWarning, isTrue);
        expect(result.warningMessage, isNotNull);
        expect(result.warningMessage, contains('baja latencia'));
        expect(result.warningMessage, contains('retardo'));
      });
    });

    group('microphoneUnavailableError', () {
      test('returns failure with descriptive message about mic in use', () {
        final result = AudioPermissionHandler.microphoneUnavailableError();

        expect(result.canStart, isFalse);
        expect(result.errorMessage, isNotNull);
        expect(result.errorMessage, contains('micrófono'));
        expect(result.errorMessage, contains('otra aplicación'));
      });
    });

    group('StartupCheckResult', () {
      test('success constructor creates valid success result', () {
        const result = StartupCheckResult.success();

        expect(result.canStart, isTrue);
        expect(result.errorMessage, isNull);
        expect(result.lowLatencyWarning, isFalse);
        expect(result.warningMessage, isNull);
      });

      test('successWithWarning creates success with warning', () {
        const result =
            StartupCheckResult.successWithWarning('test warning');

        expect(result.canStart, isTrue);
        expect(result.errorMessage, isNull);
        expect(result.lowLatencyWarning, isTrue);
        expect(result.warningMessage, equals('test warning'));
      });

      test('failure creates failed result with error message', () {
        const result = StartupCheckResult.failure('test error');

        expect(result.canStart, isFalse);
        expect(result.errorMessage, equals('test error'));
        expect(result.lowLatencyWarning, isFalse);
        expect(result.warningMessage, isNull);
      });
    });
  });
}
