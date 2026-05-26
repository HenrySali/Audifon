// Feature: psk-mobile-hearing-aid, Task 11.4: Unit tests for AmplificationBloc state transitions

/// Unit tests for AmplificationBloc state transitions.
///
/// Tests:
/// - Start → Active → Stop flow
/// - BT disconnect → Paused → Reconnect → Active flow
/// - Audio focus lost → Paused → Regained → Active flow
/// - Error states (no mic, no headphones, permission denied)
///
/// **Validates: Requirements 1.1, 1.3, 1.4, 3.3, 3.4, 3.5, 6.2, 6.3**
import 'package:bloc_test/bloc_test.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

import 'package:hearing_aid_app/data/bridges/audio_bridge.dart';
import 'package:hearing_aid_app/domain/entities/audio_config.dart';
import 'package:hearing_aid_app/domain/entities/audiogram.dart';
import 'package:hearing_aid_app/domain/entities/environment_profile.dart';
import 'package:hearing_aid_app/domain/entities/wdrc_params.dart';
import 'package:hearing_aid_app/domain/gain_prescriber.dart';
import 'package:hearing_aid_app/domain/repositories/audiogram_repository.dart';
import 'package:hearing_aid_app/domain/repositories/profile_repository.dart';
import 'package:hearing_aid_app/domain/repositories/settings_repository.dart';
import 'package:hearing_aid_app/presentation/bloc/amplification_bloc.dart';
import 'package:hearing_aid_app/presentation/bloc/amplification_event.dart';
import 'package:hearing_aid_app/presentation/bloc/amplification_state.dart';

// Mocks
class MockAudioBridge extends Mock implements AudioBridge {}

class MockAudiogramRepository extends Mock implements AudiogramRepository {}

class MockProfileRepository extends Mock implements ProfileRepository {}

class MockSettingsRepository extends Mock implements SettingsRepository {}

class MockGainPrescriber extends Mock implements GainPrescriber {}

// Fakes for registerFallbackValue
class FakeAudioConfig extends Fake implements AudioConfig {}

class FakeWdrcParams extends Fake implements WdrcParams {}

class FakeAudiogram extends Fake implements Audiogram {}

void main() {
  late MockAudioBridge mockAudioBridge;
  late MockAudiogramRepository mockAudiogramRepo;
  late MockProfileRepository mockProfileRepo;
  late MockSettingsRepository mockSettingsRepo;
  late MockGainPrescriber mockGainPrescriber;

  setUpAll(() {
    registerFallbackValue(FakeAudioConfig());
    registerFallbackValue(FakeWdrcParams());
    registerFallbackValue(FakeAudiogram());
  });

  setUp(() {
    mockAudioBridge = MockAudioBridge();
    mockAudiogramRepo = MockAudiogramRepository();
    mockProfileRepo = MockProfileRepository();
    mockSettingsRepo = MockSettingsRepository();
    mockGainPrescriber = MockGainPrescriber();

    // Default stubs
    when(() => mockAudioBridge.inputLevelStream)
        .thenAnswer((_) => const Stream<double>.empty());
    when(() => mockAudioBridge.stateStream)
        .thenAnswer((_) => const Stream<AudioEngineState>.empty());
    when(() => mockAudioBridge.startAudio(any()))
        .thenAnswer((_) async {});
    when(() => mockAudioBridge.stopAudio())
        .thenAnswer((_) async {});
    when(() => mockAudioBridge.updateEqGains(any()))
        .thenAnswer((_) async {});
    when(() => mockAudioBridge.updateVolume(any()))
        .thenAnswer((_) async {});
    when(() => mockAudioBridge.updateWdrcParams(any()))
        .thenAnswer((_) async {});
    when(() => mockAudioBridge.updateNrLevel(any()))
        .thenAnswer((_) async {});

    when(() => mockAudiogramRepo.getAudiogram())
        .thenAnswer((_) async => Audiogram.defaultAudiogram());
    when(() => mockAudiogramRepo.saveAudiogram(any()))
        .thenAnswer((_) async {});

    when(() => mockProfileRepo.getProfileByName(any()))
        .thenAnswer((_) async => EnvironmentProfile.conversation);

    when(() => mockSettingsRepo.restoreLastConfig())
        .thenAnswer((_) async => (lastProfile: 'Conversación', lastVolume: 0.0));
    when(() => mockSettingsRepo.setLastProfile(any()))
        .thenAnswer((_) async {});
    when(() => mockSettingsRepo.setLastVolume(any()))
        .thenAnswer((_) async {});

    when(() => mockGainPrescriber.prescribeFromAudiogram(any()))
        .thenReturn(List.filled(12, 10.0));
  });

  AmplificationBloc buildBloc() => AmplificationBloc(
        audioBridge: mockAudioBridge,
        audiogramRepository: mockAudiogramRepo,
        profileRepository: mockProfileRepo,
        settingsRepository: mockSettingsRepo,
        gainPrescriber: mockGainPrescriber,
      );

  group('Start → Active → Stop flow', () {
    blocTest<AmplificationBloc, AmplificationState>(
      'emits [Starting, Active] when StartAmplification succeeds',
      build: buildBloc,
      act: (bloc) => bloc.add(const StartAmplification()),
      expect: () => [
        const AmplificationStarting(),
        isA<AmplificationActive>()
            .having((s) => s.activeProfile, 'activeProfile', 'Conversación')
            .having((s) => s.volumeDb, 'volumeDb', 0.0)
            .having((s) => s.headphonesConnected, 'headphonesConnected', true),
      ],
      verify: (_) {
        verify(() => mockAudioBridge.startAudio(any())).called(1);
      },
    );

    blocTest<AmplificationBloc, AmplificationState>(
      'emits [Idle] when StopAmplification is called from Active',
      build: buildBloc,
      seed: () => const AmplificationActive(
        inputLevelDb: 50.0,
        activeProfile: 'Conversación',
        volumeDb: 0.0,
        headphonesConnected: true,
      ),
      act: (bloc) => bloc.add(const StopAmplification()),
      expect: () => [const AmplificationIdle()],
      verify: (_) {
        verify(() => mockAudioBridge.stopAudio()).called(1);
      },
    );

    blocTest<AmplificationBloc, AmplificationState>(
      'full cycle: Start → Active → Stop → Idle',
      build: buildBloc,
      act: (bloc) async {
        bloc.add(const StartAmplification());
        await Future.delayed(const Duration(milliseconds: 50));
        bloc.add(const StopAmplification());
      },
      expect: () => [
        const AmplificationStarting(),
        isA<AmplificationActive>(),
        const AmplificationIdle(),
      ],
    );
  });

  group('BT disconnect → Paused → Reconnect → Active flow', () {
    blocTest<AmplificationBloc, AmplificationState>(
      'emits Paused(btDisconnected) when headphones disconnect during Active',
      build: buildBloc,
      seed: () => const AmplificationActive(
        inputLevelDb: 50.0,
        activeProfile: 'Conversación',
        volumeDb: 0.0,
        headphonesConnected: true,
      ),
      act: (bloc) =>
          bloc.add(const HeadphonesStateChanged(connected: false)),
      expect: () => [
        const AmplificationPaused(
          reason: PauseReason.btDisconnected,
          lastActiveProfile: 'Conversación',
          lastVolumeDb: 0.0,
        ),
      ],
      verify: (_) {
        verify(() => mockAudioBridge.stopAudio()).called(1);
      },
    );

    blocTest<AmplificationBloc, AmplificationState>(
      'ResumeAmplification from Paused(btDisconnected) → Starting → Active',
      build: buildBloc,
      seed: () => const AmplificationPaused(
        reason: PauseReason.btDisconnected,
        lastActiveProfile: 'Conversación',
        lastVolumeDb: -5.0,
      ),
      act: (bloc) => bloc.add(const ResumeAmplification()),
      expect: () => [
        const AmplificationStarting(),
        isA<AmplificationActive>()
            .having((s) => s.activeProfile, 'activeProfile', 'Conversación')
            .having((s) => s.volumeDb, 'volumeDb', -5.0),
      ],
    );
  });

  group('Audio focus lost → Paused → Regained → Active flow', () {
    blocTest<AmplificationBloc, AmplificationState>(
      'emits Paused(audioFocusLost) when focus is lost during Active',
      build: buildBloc,
      seed: () => const AmplificationActive(
        inputLevelDb: 60.0,
        activeProfile: 'Ruidoso',
        volumeDb: 5.0,
        headphonesConnected: true,
      ),
      act: (bloc) => bloc.add(const AudioFocusChanged(hasFocus: false)),
      expect: () => [
        const AmplificationPaused(
          reason: PauseReason.audioFocusLost,
          lastActiveProfile: 'Ruidoso',
          lastVolumeDb: 5.0,
        ),
      ],
      verify: (_) {
        verify(() => mockAudioBridge.stopAudio()).called(1);
      },
    );

    blocTest<AmplificationBloc, AmplificationState>(
      'ResumeAmplification from Paused(audioFocusLost) → Starting → Active',
      build: buildBloc,
      seed: () => const AmplificationPaused(
        reason: PauseReason.audioFocusLost,
        lastActiveProfile: 'Silencioso',
        lastVolumeDb: -10.0,
      ),
      act: (bloc) => bloc.add(const ResumeAmplification()),
      expect: () => [
        const AmplificationStarting(),
        isA<AmplificationActive>()
            .having((s) => s.activeProfile, 'activeProfile', 'Silencioso')
            .having((s) => s.volumeDb, 'volumeDb', -10.0),
      ],
    );
  });

  group('Error states', () {
    blocTest<AmplificationBloc, AmplificationState>(
      'emits Error when startAudio throws (mic unavailable)',
      build: () {
        when(() => mockAudioBridge.startAudio(any()))
            .thenThrow(Exception('Micrófono no disponible'));
        return buildBloc();
      },
      act: (bloc) => bloc.add(const StartAmplification()),
      expect: () => [
        const AmplificationStarting(),
        isA<AmplificationError>().having(
          (s) => s.message,
          'message',
          contains('Micrófono no disponible'),
        ),
      ],
    );

    blocTest<AmplificationBloc, AmplificationState>(
      'emits Error when startAudio throws (no headphones)',
      build: () {
        when(() => mockAudioBridge.startAudio(any()))
            .thenThrow(Exception('No hay auriculares conectados'));
        return buildBloc();
      },
      act: (bloc) => bloc.add(const StartAmplification()),
      expect: () => [
        const AmplificationStarting(),
        isA<AmplificationError>().having(
          (s) => s.message,
          'message',
          contains('auriculares'),
        ),
      ],
    );

    blocTest<AmplificationBloc, AmplificationState>(
      'emits Error when startAudio throws (permission denied)',
      build: () {
        when(() => mockAudioBridge.startAudio(any()))
            .thenThrow(Exception('Permiso RECORD_AUDIO denegado'));
        return buildBloc();
      },
      act: (bloc) => bloc.add(const StartAmplification()),
      expect: () => [
        const AmplificationStarting(),
        isA<AmplificationError>().having(
          (s) => s.message,
          'message',
          contains('Permiso'),
        ),
      ],
    );

    blocTest<AmplificationBloc, AmplificationState>(
      'StopAmplification from Error returns to Idle',
      build: buildBloc,
      seed: () => const AmplificationError(message: 'Some error'),
      act: (bloc) => bloc.add(const StopAmplification()),
      expect: () => [const AmplificationIdle()],
    );
  });

  group('Volume and profile changes during Active', () {
    blocTest<AmplificationBloc, AmplificationState>(
      'ChangeVolume updates state and persists',
      build: buildBloc,
      seed: () => const AmplificationActive(
        inputLevelDb: 50.0,
        activeProfile: 'Conversación',
        volumeDb: 0.0,
        headphonesConnected: true,
      ),
      act: (bloc) => bloc.add(const ChangeVolume(volumeDb: 5.0)),
      expect: () => [
        isA<AmplificationActive>()
            .having((s) => s.volumeDb, 'volumeDb', 5.0),
      ],
      verify: (_) {
        verify(() => mockAudioBridge.updateVolume(5.0)).called(1);
        verify(() => mockSettingsRepo.setLastVolume(5.0)).called(1);
      },
    );

    blocTest<AmplificationBloc, AmplificationState>(
      'ChangeProfile updates state and persists',
      build: buildBloc,
      seed: () => const AmplificationActive(
        inputLevelDb: 50.0,
        activeProfile: 'Conversación',
        volumeDb: 0.0,
        headphonesConnected: true,
      ),
      act: (bloc) => bloc.add(const ChangeProfile(profile: 'Ruidoso')),
      expect: () => [
        isA<AmplificationActive>()
            .having((s) => s.activeProfile, 'activeProfile', 'Conversación'),
      ],
      verify: (_) {
        verify(() => mockProfileRepo.getProfileByName('Ruidoso')).called(1);
        verify(() => mockAudioBridge.updateWdrcParams(any())).called(1);
        verify(() => mockAudioBridge.updateNrLevel(any())).called(1);
      },
    );

    blocTest<AmplificationBloc, AmplificationState>(
      'ChangeVolume is ignored when not Active',
      build: buildBloc,
      seed: () => const AmplificationIdle(),
      act: (bloc) => bloc.add(const ChangeVolume(volumeDb: 5.0)),
      expect: () => [],
    );
  });

  group('InputLevelUpdated', () {
    blocTest<AmplificationBloc, AmplificationState>(
      'updates inputLevelDb in Active state',
      build: buildBloc,
      seed: () => const AmplificationActive(
        inputLevelDb: 0.0,
        activeProfile: 'Conversación',
        volumeDb: 0.0,
        headphonesConnected: true,
      ),
      act: (bloc) => bloc.add(const InputLevelUpdated(levelDb: 65.0)),
      expect: () => [
        isA<AmplificationActive>()
            .having((s) => s.inputLevelDb, 'inputLevelDb', 65.0),
      ],
    );

    blocTest<AmplificationBloc, AmplificationState>(
      'InputLevelUpdated is ignored when not Active',
      build: buildBloc,
      seed: () => const AmplificationIdle(),
      act: (bloc) => bloc.add(const InputLevelUpdated(levelDb: 65.0)),
      expect: () => [],
    );
  });

  group('Edge cases', () {
    blocTest<AmplificationBloc, AmplificationState>(
      'StartAmplification is ignored when already Active',
      build: buildBloc,
      seed: () => const AmplificationActive(
        inputLevelDb: 50.0,
        activeProfile: 'Conversación',
        volumeDb: 0.0,
        headphonesConnected: true,
      ),
      act: (bloc) => bloc.add(const StartAmplification()),
      expect: () => [],
    );

    blocTest<AmplificationBloc, AmplificationState>(
      'HeadphonesStateChanged(connected: false) is ignored when Idle',
      build: buildBloc,
      seed: () => const AmplificationIdle(),
      act: (bloc) =>
          bloc.add(const HeadphonesStateChanged(connected: false)),
      expect: () => [],
    );

    blocTest<AmplificationBloc, AmplificationState>(
      'ResumeAmplification is ignored when not Paused',
      build: buildBloc,
      seed: () => const AmplificationIdle(),
      act: (bloc) => bloc.add(const ResumeAmplification()),
      expect: () => [],
    );
  });
}
