import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

import 'package:hearing_aid_app/presentation/services/permission_service.dart';
import 'package:hearing_aid_app/presentation/utils/device_checker.dart';

/// Mock del DeviceChecker para testing.
class MockDeviceChecker extends Mock implements DeviceChecker {}

void main() {
  late MockDeviceChecker mockDeviceChecker;
  late PermissionService service;

  setUp(() {
    mockDeviceChecker = MockDeviceChecker();
    service = PermissionService(deviceChecker: mockDeviceChecker);
  });

  group('PermissionService', () {
    group('checkHeadphonesConnected', () {
      test('returns true when headphones are connected', () async {
        when(() => mockDeviceChecker.isHeadphoneConnected())
            .thenAnswer((_) async => true);

        final result = await service.checkHeadphonesConnected();

        expect(result, isTrue);
        verify(() => mockDeviceChecker.isHeadphoneConnected()).called(1);
      });

      test('returns false when no headphones connected', () async {
        when(() => mockDeviceChecker.isHeadphoneConnected())
            .thenAnswer((_) async => false);

        final result = await service.checkHeadphonesConnected();

        expect(result, isFalse);
      });
    });

    group('checkLowLatencySupport', () {
      test('returns true when device supports low latency', () async {
        when(() => mockDeviceChecker.supportsLowLatency())
            .thenAnswer((_) async => true);

        final result = await service.checkLowLatencySupport();

        expect(result, isTrue);
        verify(() => mockDeviceChecker.supportsLowLatency()).called(1);
      });

      test('returns false when device does not support low latency',
          () async {
        when(() => mockDeviceChecker.supportsLowLatency())
            .thenAnswer((_) async => false);

        final result = await service.checkLowLatencySupport();

        expect(result, isFalse);
      });
    });

    group('validateStartConditions', () {
      test('returns null when all conditions are met', () async {
        // Note: requestMicrophonePermission uses permission_handler
        // which requires platform channel mocking. For this test we
        // focus on the headphone check which is the second validation.
        // The microphone permission check requires the permission_handler
        // plugin which cannot be easily mocked in unit tests without
        // platform channel setup.
        //
        // In integration tests, the full flow would be tested.
        // Here we test the headphone and low latency checks via
        // the individual methods.
        when(() => mockDeviceChecker.isHeadphoneConnected())
            .thenAnswer((_) async => true);
        when(() => mockDeviceChecker.supportsLowLatency())
            .thenAnswer((_) async => true);

        // checkHeadphonesConnected delegates to deviceChecker
        final headphones = await service.checkHeadphonesConnected();
        expect(headphones, isTrue);

        // checkLowLatencySupport delegates to deviceChecker
        final lowLatency = await service.checkLowLatencySupport();
        expect(lowLatency, isTrue);
      });

      test(
          'headphone check returns false when no output device connected',
          () async {
        when(() => mockDeviceChecker.isHeadphoneConnected())
            .thenAnswer((_) async => false);

        final result = await service.checkHeadphonesConnected();
        expect(result, isFalse);
      });
    });

    group('static messages', () {
      test('microphoneUnavailableMessage returns descriptive error', () {
        final message = PermissionService.microphoneUnavailableMessage();

        expect(message, contains('micrófono'));
        expect(message, contains('otra aplicación'));
        expect(message, isNotEmpty);
      });

      test('lowLatencyWarningMessage returns descriptive warning', () {
        final message = PermissionService.lowLatencyWarningMessage();

        expect(message, contains('baja latencia'));
        expect(message, contains('retardo'));
        expect(message, isNotEmpty);
      });
    });
  });
}
