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
import 'dart:io';

import 'package:bloc_test/bloc_test.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:mocktail/mocktail.dart';

import 'package:hearing_aid_app/data/bridges/audio_bridge.dart';
import 'package:hearing_aid_app/domain/entities/audio_config.dart';
import 'package:hearing_aid_app/domain/entities/audiogram.dart';
import 'package:hearing_aid_app/domain/entities/environment_profile.dart';
import 'package:hearing_aid_app/domain/entities/prescription_mode.dart';
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

  late Directory hiveTempDir;

  setUpAll(() {
    // Inicializar Hive en un directorio temporal para que los tests del
    // bloc que invocan `Hive.openBox(...)` no fallen con
    // `HiveError: You need to initialize Hive`.
    hiveTempDir = Directory.systemTemp.createTempSync('hive_amp_test_');
    Hive.init(hiveTempDir.path);

    registerFallbackValue(FakeAudioConfig());
    registerFallbackValue(FakeWdrcParams());
    registerFallbackValue(FakeAudiogram());
    registerFallbackValue(PrescriberMode.smartNl2);
  });

  tearDownAll(() async {
    await Hive.close();
    if (hiveTempDir.existsSync()) {
      hiveTempDir.deleteSync(recursive: true);
    }
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
    when(() => mockAudioBridge.setMpoThresholdDbSpl(any()))
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
    when(() => mockSettingsRepo.getPrescriberMode())
        .thenAnswer((_) async => PrescriberMode.smartNl2);
    when(() => mockSettingsRepo.setPrescriberMode(any()))
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
      // Tras system-audit-fix, el flujo emite Starting → Active inicial
      // (sin bundle) → Active con bundle aplicado por `_onApplyBundle`.
      // Aceptamos cualquier cantidad de Actives subsiguientes con
      // `headphonesConnected: true` y `activeProfile: 'Conversación'`.
      wait: const Duration(milliseconds: 100),
      expect: () => [
        const AmplificationStarting(),
        isA<AmplificationActive>()
            .having((s) => s.activeProfile, 'activeProfile', 'Conversación')
            .having((s) => s.volumeDb, 'volumeDb', 0.0)
            .having((s) => s.headphonesConnected, 'headphonesConnected', true),
        isA<AmplificationActive>()
            .having((s) => s.activeProfile, 'activeProfile', 'Conversación')
            .having((s) => s.bundle, 'bundle', isNotNull),
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
        await Future.delayed(const Duration(milliseconds: 100));
        bloc.add(const StopAmplification());
      },
      // Tras system-audit-fix, el bloc emite el Active inicial seguido
      // por uno o más Actives reemitidos por `_onApplyBundle`. La
      // cantidad exacta depende del scheduling — aquí solo nos importa
      // que arranque con Starting, transicione por al menos un Active y
      // termine en Idle.
      expect: () => [
        const AmplificationStarting(),
        isA<AmplificationActive>(),
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
      build: () {
        // El default stub devuelve siempre `conversation`. Override
        // para que `getProfileByName('Ruidoso')` retorne el perfil
        // correcto y el bloc emita un Active con `activeProfile: 'Ruidoso'`.
        when(() => mockProfileRepo.getProfileByName('Ruidoso'))
            .thenAnswer((_) async => EnvironmentProfile.noisy);
        return buildBloc();
      },
      seed: () => const AmplificationActive(
        inputLevelDb: 50.0,
        activeProfile: 'Conversación',
        volumeDb: 0.0,
        headphonesConnected: true,
      ),
      act: (bloc) => bloc.add(const ChangeProfile(profile: 'Ruidoso')),
      // Tras system-audit-fix, `_onChangeProfile` emite el Active con el
      // nuevo `activeProfile` y dispatch'a `ApplyAudiogramDrivenBundle`,
      // que reemite Active con el bundle aplicado al bridge.
      wait: const Duration(milliseconds: 100),
      expect: () => [
        isA<AmplificationActive>()
            .having((s) => s.activeProfile, 'activeProfile', 'Ruidoso'),
        isA<AmplificationActive>()
            .having((s) => s.activeProfile, 'activeProfile', 'Ruidoso')
            .having((s) => s.bundle, 'bundle', isNotNull),
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

    blocTest<AmplificationBloc, AmplificationState>(
      'ChangeVolume emits AmplificationError when bridge fails',
      build: () {
        // Override del default stub para que el bridge falle.
        when(() => mockAudioBridge.updateVolume(any()))
            .thenThrow(Exception('engine offline'));
        return buildBloc();
      },
      seed: () => const AmplificationActive(
        inputLevelDb: 50.0,
        activeProfile: 'Conversación',
        volumeDb: 0.0,
        headphonesConnected: true,
      ),
      act: (bloc) => bloc.add(const ChangeVolume(volumeDb: 5.0)),
      expect: () => [
        isA<AmplificationError>()
            .having((s) => s.message, 'message',
                contains('No se pudo actualizar el volumen')),
      ],
      verify: (_) {
        verify(() => mockAudioBridge.updateVolume(5.0)).called(1);
        // No debe persistir si el bridge falló (state está
        // desincronizado del engine; no tiene sentido cachear).
        verifyNever(() => mockSettingsRepo.setLastVolume(any()));
      },
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

  group('SetExperienceMonths', () {
    blocTest<AmplificationBloc, AmplificationState>(
      'persists value and emits experienceMonths in active state',
      build: buildBloc,
      seed: () => const AmplificationActive(
        inputLevelDb: 50.0,
        activeProfile: 'Conversación',
        volumeDb: 0.0,
        headphonesConnected: true,
      ),
      act: (bloc) => bloc.add(const SetExperienceMonths(9)),
      expect: () => [
        isA<AmplificationActive>()
            .having((s) => s.experienceMonths, 'experienceMonths', 9),
      ],
      verify: (_) {
        verify(() => mockSettingsRepo.setExperienceMonths(9)).called(1);
      },
    );

    blocTest<AmplificationBloc, AmplificationState>(
      'clamps negative months to zero before persisting',
      build: buildBloc,
      seed: () => const AmplificationActive(
        inputLevelDb: 0.0,
        activeProfile: 'Conversación',
        volumeDb: 0.0,
        headphonesConnected: true,
      ),
      act: (bloc) => bloc.add(const SetExperienceMonths(-5)),
      expect: () => [
        isA<AmplificationActive>()
            .having((s) => s.experienceMonths, 'experienceMonths', 0),
      ],
      verify: (_) {
        verify(() => mockSettingsRepo.setExperienceMonths(0)).called(1);
      },
    );

    blocTest<AmplificationBloc, AmplificationState>(
      'is ignored persistence-only when not Active',
      build: buildBloc,
      seed: () => const AmplificationIdle(),
      act: (bloc) => bloc.add(const SetExperienceMonths(12)),
      expect: () => [],
      verify: (_) {
        // Aún cuando el estado no sea Active, el valor se persiste.
        verify(() => mockSettingsRepo.setExperienceMonths(12)).called(1);
      },
    );

    test(
      'in NL3 mode, new user (3 months) gets gains 3 dB lower than '
      'experienced (24 months)',
      () async {
        // Configurar el bloc en modo NL3 desde el arranque.
        when(() => mockSettingsRepo.getPrescriberMode())
            .thenAnswer((_) async => PrescriberMode.smartNl3);
        when(() => mockSettingsRepo.getExperienceMonths())
            .thenAnswer((_) async => null);

        // Capturar las llamadas a updateEqGains para comparar luego.
        final capturedGains = <List<double>>[];
        when(() => mockAudioBridge.updateEqGains(any())).thenAnswer((inv) async {
          final gains = inv.positionalArguments.first as List<double>;
          capturedGains.add(List<double>.from(gains));
        });

        final bloc = buildBloc();

        // Arrancar la amplificación.
        bloc.add(const StartAmplification());
        await Future.delayed(const Duration(milliseconds: 100));

        // Limpiar captures antes de los SetExperienceMonths para aislar
        // las llamadas que provoca el evento bajo test.
        capturedGains.clear();

        // Setear usuario experimentado (24 meses) — sin aclimatización.
        bloc.add(const SetExperienceMonths(24));
        await Future.delayed(const Duration(milliseconds: 100));

        // Setear usuario nuevo (3 meses) — aplica -3 dB.
        bloc.add(const SetExperienceMonths(3));
        await Future.delayed(const Duration(milliseconds: 100));

        // Esperamos al menos una llamada por cada SetExperienceMonths.
        expect(capturedGains.length, greaterThanOrEqualTo(2));

        // Las dos últimas son las que nos interesan: experienced=24 → 3.
        final experiencedGains = capturedGains[capturedGains.length - 2];
        final newUserGains = capturedGains.last;

        expect(experiencedGains.length, 12);
        expect(newUserGains.length, 12);

        // El mock de GainPrescriber retorna 10.0 dB para todas las bandas
        // del audiograma por defecto. En NL3 el clasificador detecta `flat`
        // (audiograma uniforme), por lo que no aplica correcciones de
        // forma. La única diferencia entre los dos perfiles debe ser el
        // ajuste de aclimatización para usuario nuevo (-3 dB en todas las
        // bandas), antes del clamp [0, 50].
        for (int i = 0; i < 12; i++) {
          // El mock devuelve 10.0 ≥ 3.0, así que el clamp no entra en juego.
          expect(
            experiencedGains[i] - newUserGains[i],
            closeTo(3.0, 0.001),
            reason: 'banda $i: experienced=${experiencedGains[i]} '
                'newUser=${newUserGains[i]}',
          );
        }

        await bloc.close();
      },
    );
  });
}
