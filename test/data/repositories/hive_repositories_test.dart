import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';

import 'package:hearing_aid_app/domain/entities/audiogram.dart';
import 'package:hearing_aid_app/domain/entities/environment_profile.dart';
import 'package:hearing_aid_app/domain/entities/calibration_data.dart';
import 'package:hearing_aid_app/domain/repositories/settings_repository.dart';
import 'package:hearing_aid_app/data/repositories/audiogram_repository_impl.dart';
import 'package:hearing_aid_app/data/repositories/profile_repository_impl.dart';
import 'package:hearing_aid_app/data/repositories/settings_repository_impl.dart';

void main() {
  late Box<dynamic> audiogramBox;
  late Box<dynamic> profilesBox;
  late Box<dynamic> settingsBox;
  late AudiogramRepositoryImpl audiogramRepo;
  late ProfileRepositoryImpl profileRepo;
  late SettingsRepositoryImpl settingsRepo;

  setUp(() async {
    // Initialize Hive with a temporary directory for testing
    Hive.init('./test_hive_temp');
    audiogramBox = await Hive.openBox('test_audiogram_box');
    profilesBox = await Hive.openBox('test_profiles_box');
    settingsBox = await Hive.openBox('test_settings_box');

    audiogramRepo = AudiogramRepositoryImpl(audiogramBox);
    profileRepo = ProfileRepositoryImpl(profilesBox);
    settingsRepo = SettingsRepositoryImpl(settingsBox);
  });

  tearDown(() async {
    await audiogramBox.clear();
    await profilesBox.clear();
    await settingsBox.clear();
    await Hive.close();
  });

  group('AudiogramRepositoryImpl', () {
    test('returns null when no audiogram is stored', () async {
      final result = await audiogramRepo.getAudiogram();
      expect(result, isNull);
    });

    test('hasAudiogram returns false when empty', () async {
      expect(await audiogramRepo.hasAudiogram(), isFalse);
    });

    test('saves and retrieves audiogram correctly', () async {
      const audiogram = Audiogram(thresholds: {
        250: 0,
        500: 0,
        750: 0,
        1000: 40,
        1500: 45,
        2000: 50,
        2500: 55,
        3000: 60,
        3500: 65,
        4000: 70,
        6000: 75,
        8000: 75,
      });

      await audiogramRepo.saveAudiogram(audiogram);

      final retrieved = await audiogramRepo.getAudiogram();
      expect(retrieved, isNotNull);
      expect(retrieved!.thresholds, equals(audiogram.thresholds));
    });

    test('hasAudiogram returns true after save', () async {
      const audiogram = Audiogram(thresholds: {250: 10, 500: 15});
      await audiogramRepo.saveAudiogram(audiogram);
      expect(await audiogramRepo.hasAudiogram(), isTrue);
    });

    test('deleteAudiogram removes stored audiogram', () async {
      const audiogram = Audiogram(thresholds: {250: 10});
      await audiogramRepo.saveAudiogram(audiogram);
      await audiogramRepo.deleteAudiogram();

      expect(await audiogramRepo.getAudiogram(), isNull);
      expect(await audiogramRepo.hasAudiogram(), isFalse);
    });

    test('round-trip preserves default audiogram', () async {
      final audiogram = Audiogram.defaultAudiogram();
      await audiogramRepo.saveAudiogram(audiogram);

      final retrieved = await audiogramRepo.getAudiogram();
      expect(retrieved, equals(audiogram));
    });
  });

  group('ProfileRepositoryImpl', () {
    test('getPredefinedProfiles returns 3 profiles', () {
      final profiles = profileRepo.getPredefinedProfiles();
      expect(profiles.length, 3);
      expect(profiles[0].name, 'Silencioso');
      expect(profiles[1].name, 'Conversación');
      expect(profiles[2].name, 'Ruidoso');
    });

    test('getAllProfiles returns predefined when no custom exist', () async {
      final profiles = await profileRepo.getAllProfiles();
      expect(profiles.length, 3);
    });

    test('saves and retrieves custom profile', () async {
      const custom = EnvironmentProfile(
        name: 'Mi Perfil',
        nrLevel: 2,
        compressionRatio: 2.5,
        expansionKnee: 30,
        compressionKnee: 50,
      );

      await profileRepo.saveCustomProfile(custom);

      final retrieved = await profileRepo.getProfileByName('Mi Perfil');
      expect(retrieved, isNotNull);
      expect(retrieved!.name, 'Mi Perfil');
      expect(retrieved.nrLevel, 2);
      expect(retrieved.compressionRatio, 2.5);
      expect(retrieved.expansionKnee, 30);
      expect(retrieved.compressionKnee, 50);
    });

    test('getAllProfiles includes custom profiles', () async {
      const custom = EnvironmentProfile(
        name: 'Custom',
        nrLevel: 1,
        compressionRatio: 1.8,
        expansionKnee: 32,
        compressionKnee: 52,
      );

      await profileRepo.saveCustomProfile(custom);
      final profiles = await profileRepo.getAllProfiles();
      expect(profiles.length, 4); // 3 predefined + 1 custom
    });

    test('getProfileByName returns predefined profile', () async {
      final profile = await profileRepo.getProfileByName('Silencioso');
      expect(profile, isNotNull);
      expect(profile, equals(EnvironmentProfile.quiet));
    });

    test('deleteCustomProfile removes custom profile', () async {
      const custom = EnvironmentProfile(
        name: 'ToDelete',
        nrLevel: 1,
        compressionRatio: 1.5,
        expansionKnee: 35,
        compressionKnee: 55,
      );

      await profileRepo.saveCustomProfile(custom);
      await profileRepo.deleteCustomProfile('ToDelete');

      final retrieved = await profileRepo.getProfileByName('ToDelete');
      expect(retrieved, isNull);
    });

    test('deleteCustomProfile does not delete predefined', () async {
      await profileRepo.deleteCustomProfile('Silencioso');
      final profile = await profileRepo.getProfileByName('Silencioso');
      expect(profile, isNotNull);
    });

    test('isPredefined identifies predefined profiles', () {
      expect(profileRepo.isPredefined('Silencioso'), isTrue);
      expect(profileRepo.isPredefined('Conversación'), isTrue);
      expect(profileRepo.isPredefined('Ruidoso'), isTrue);
      expect(profileRepo.isPredefined('Custom'), isFalse);
    });
  });

  group('SettingsRepositoryImpl', () {
    test('getLastProfile returns null when not set', () async {
      expect(await settingsRepo.getLastProfile(), isNull);
    });

    test('saves and retrieves lastProfile', () async {
      await settingsRepo.setLastProfile('Conversación');
      expect(await settingsRepo.getLastProfile(), 'Conversación');
    });

    test('getLastVolume returns null when not set', () async {
      expect(await settingsRepo.getLastVolume(), isNull);
    });

    test('saves and retrieves lastVolume', () async {
      await settingsRepo.setLastVolume(-5.0);
      expect(await settingsRepo.getLastVolume(), -5.0);
    });

    test('getPrescriptionMethod defaults to nalNl2', () async {
      final method = await settingsRepo.getPrescriptionMethod();
      expect(method, PrescriptionMethod.nalNl2);
    });

    test('saves and retrieves prescriptionMethod', () async {
      await settingsRepo.setPrescriptionMethod(PrescriptionMethod.halfGain);
      final method = await settingsRepo.getPrescriptionMethod();
      expect(method, PrescriptionMethod.halfGain);
    });

    test('restoreLastConfig returns both profile and volume', () async {
      await settingsRepo.setLastProfile('Ruidoso');
      await settingsRepo.setLastVolume(3.5);

      final config = await settingsRepo.restoreLastConfig();
      expect(config.lastProfile, 'Ruidoso');
      expect(config.lastVolume, 3.5);
    });

    test('restoreLastConfig returns nulls when nothing stored', () async {
      final config = await settingsRepo.restoreLastConfig();
      expect(config.lastProfile, isNull);
      expect(config.lastVolume, isNull);
    });

    test('saves and retrieves CalibrationData with mic calibration', () async {
      final calibData = CalibrationData(
        micCalibration: MicCalibrationResult(
          splOffset: 118.5,
          confidenceLevel: 0.8,
          method: 'external_ref',
          calibratedAt: DateTime(2024, 1, 15, 10, 30),
          deviceModel: 'Pixel 7',
        ),
      );

      await settingsRepo.setCalibrationData(calibData);
      final retrieved = await settingsRepo.getCalibrationData();

      expect(retrieved, isNotNull);
      expect(retrieved!.micCalibration, isNotNull);
      expect(retrieved.micCalibration!.splOffset, 118.5);
      expect(retrieved.micCalibration!.confidenceLevel, 0.8);
      expect(retrieved.micCalibration!.method, 'external_ref');
      expect(retrieved.micCalibration!.deviceModel, 'Pixel 7');
    });

    test('saves and retrieves CalibrationData with headphone calibration',
        () async {
      final calibData = CalibrationData(
        headphoneCalibrations: {
          'AA:BB:CC:DD:EE:FF': HeadphoneCalibrationResult(
            frequencyResponse: {250: -2.0, 1000: 0.0, 4000: 3.5},
            compensation: {250: 2.0, 1000: 0.0, 4000: -3.5},
            headphoneId: 'AA:BB:CC:DD:EE:FF',
            headphoneName: 'AirPods Pro',
            calibratedAt: DateTime(2024, 2, 20, 14, 0),
            isBluetooth: true,
          ),
          'wired_default': HeadphoneCalibrationResult(
            frequencyResponse: {250: -1.0, 1000: 0.0, 4000: 1.5},
            compensation: {250: 1.0, 1000: 0.0, 4000: -1.5},
            headphoneId: 'wired_default',
            headphoneName: 'Wired',
            calibratedAt: DateTime(2024, 3, 1, 9, 0),
            isBluetooth: false,
          ),
        },
      );

      await settingsRepo.setCalibrationData(calibData);
      final retrieved = await settingsRepo.getCalibrationData();

      expect(retrieved, isNotNull);
      expect(retrieved!.headphoneCalibrations.length, 2);
      expect(
        retrieved.headphoneCalibrations['AA:BB:CC:DD:EE:FF']!.headphoneName,
        'AirPods Pro',
      );
      expect(
        retrieved.headphoneCalibrations['wired_default']!.isBluetooth,
        isFalse,
      );
      expect(
        retrieved.headphoneCalibrations['AA:BB:CC:DD:EE:FF']!
            .frequencyResponse[4000],
        3.5,
      );
    });

    test('getCalibrationData returns null when not set', () async {
      expect(await settingsRepo.getCalibrationData(), isNull);
    });
  });
}
