// Spec: audiogram-driven-presets, Task 12.3 — Stale delta integration test.
//
// Validates Requirement 14.7: when the user has a manual ManualAdjustmentDelta
// applied in Diagnostic mode and the audiogram is replaced with one that
// differs by MAD > 5 dB on at least one band, the bloc must mark the existing
// custom presets as stale (`customPresetsStale = true` on
// [AmplificationActive]) so the UI can offer the three resolution options
// per Req 14.7 (accept / reset / edit).
//
// Scope: this test exercises the real `AmplificationBloc` against a mocked
// `AudioBridge` and stub repositories. It uses the real `BundleBuilder`,
// `GainPrescriberNL3` and `ManualAdjustmentDelta` so the bundle path is
// fully wired end-to-end. Hive is initialized against a temp directory so
// the bloc's persistence helpers (`_persistManualDeltaFor`, last_bundle JSON
// snapshot, `lastEqPreset` invalidation) execute without throwing.
//
// Reference: tasks.md Wave 9, integration tests, task 12.3.

import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:mocktail/mocktail.dart';

import 'package:hearing_aid_app/data/bridges/audio_bridge.dart';
import 'package:hearing_aid_app/domain/audiogram_driven_presets/manual_adjustment_delta.dart';
import 'package:hearing_aid_app/domain/audiogram_driven_presets/profile_repository_warning.dart';
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

// ─── Mocks ──────────────────────────────────────────────────────────────────

class MockAudioBridge extends Mock implements AudioBridge {}

class MockAudiogramRepository extends Mock implements AudiogramRepository {}

class MockProfileRepository extends Mock implements ProfileRepository {}

class MockSettingsRepository extends Mock implements SettingsRepository {}

class FakeAudioConfig extends Fake implements AudioConfig {}

class FakeWdrcParams extends Fake implements WdrcParams {}

class FakeAudiogram extends Fake implements Audiogram {}

// ─── Bisgaard fixtures (subset reused from ucl_estimator_test.dart) ─────────
// Reference: Bisgaard, Vlaming & Dahlquist (2010), Trends in Amplification
// 14(2):113–120. N3 = moderate flat loss; N6 = severe flat loss.
// MAD (Mean Absolute Deviation) per band from N3 → N6 is well above 5 dB on
// every band, which is the threshold the bloc uses to mark presets stale.
//
// Per-band MAD calculation (|N6 - N3|):
//   250 Hz : |65 - 35| = 30 dB
//   500 Hz : |65 - 35| = 30 dB
//   750 Hz : |65 - 35| = 30 dB
//  1000 Hz : |70 - 40| = 30 dB
//  1500 Hz : |70 - 45| = 25 dB
//  2000 Hz : |70 - 50| = 20 dB
//  2500 Hz : |75 - 55| = 20 dB
//  3000 Hz : |75 - 55| = 20 dB
//  3500 Hz : |80 - 55| = 25 dB
//  4000 Hz : |85 - 60| = 25 dB
//  6000 Hz : |85 - 60| = 25 dB
//  8000 Hz : |90 - 65| = 25 dB
// Min per-band deviation = 20 dB ≫ 5 dB → triggers stale on every band.

const Map<int, double> _bisgaardN3 = {
  250: 35, 500: 35, 750: 35, 1000: 40, 1500: 45,
  2000: 50, 2500: 55, 3000: 55, 3500: 55, 4000: 60, 6000: 60, 8000: 65,
};

const Map<int, double> _bisgaardN6 = {
  250: 65, 500: 65, 750: 65, 1000: 70, 1500: 70,
  2000: 70, 2500: 75, 3000: 75, 3500: 80, 4000: 85, 6000: 85, 8000: 90,
};

Audiogram _audiogramFrom(Map<int, double> map) =>
    Audiogram(thresholds: Map<int, double>.from(map));

List<AudiogramPoint> _pointsFrom(Map<int, double> map) => map.entries
    .map((e) => AudiogramPoint(frequencyHz: e.key, thresholdHL: e.value))
    .toList()
  ..sort((a, b) => a.frequencyHz.compareTo(b.frequencyHz));

// ─── Test harness ───────────────────────────────────────────────────────────

void main() {
  late Directory tempDir;
  late MockAudioBridge audioBridge;
  late MockAudiogramRepository audiogramRepo;
  late MockProfileRepository profileRepo;
  late MockSettingsRepository settingsRepo;
  late GainPrescriber gainPrescriber;

  // Mutable reference holding what the audiogram repository "remembers".
  // Mocks read from / write to this so the bloc's MAD detection sees the
  // previous audiogram on the second `UpdateAudiogram` dispatch.
  late Audiogram? storedAudiogram;

  // Track ProfileRepository.markCustomPresetsAsStale invocations to assert
  // the bloc invoked the repository with the new audiogram.
  late List<Audiogram> markStaleCalls;

  setUpAll(() {
    registerFallbackValue(FakeAudioConfig());
    registerFallbackValue(FakeWdrcParams());
    registerFallbackValue(FakeAudiogram());
    registerFallbackValue(<double>[]);
    registerFallbackValue(0);
    registerFallbackValue(PrescriberMode.smartNl2);
  });

  setUp(() async {
    // Hive temp dir — required by `_openSettingsBox` and persistence
    // helpers in the bloc (manual delta, gainScale, last_bundle JSON).
    tempDir = await Directory.systemTemp.createTemp('stale_delta_test_');
    Hive.init(tempDir.path);

    audioBridge = MockAudioBridge();
    audiogramRepo = MockAudiogramRepository();
    profileRepo = MockProfileRepository();
    settingsRepo = MockSettingsRepository();
    gainPrescriber = GainPrescriber();

    storedAudiogram = _audiogramFrom(_bisgaardN3);
    markStaleCalls = [];

    // Audio bridge — accept all calls without side effects.
    when(() => audioBridge.inputLevelStream)
        .thenAnswer((_) => const Stream<double>.empty());
    when(() => audioBridge.stateStream)
        .thenAnswer((_) => const Stream<AudioEngineState>.empty());
    when(() => audioBridge.startAudio(any())).thenAnswer((_) async {});
    when(() => audioBridge.stopAudio()).thenAnswer((_) async {});
    when(() => audioBridge.updateEqGains(any())).thenAnswer((_) async {});
    when(() => audioBridge.updateVolume(any())).thenAnswer((_) async {});
    when(() => audioBridge.updateWdrcParams(any())).thenAnswer((_) async {});
    when(() => audioBridge.updateNrLevel(any())).thenAnswer((_) async {});
    when(() => audioBridge.setMpoThresholdDbSpl(any()))
        .thenAnswer((_) async {});

    // Audiogram repo: read returns the current `storedAudiogram`; save
    // mutates it so the next `getAudiogram` call sees the previous value
    // before the new one is persisted (the bloc reads-then-saves).
    when(() => audiogramRepo.getAudiogram())
        .thenAnswer((_) async => storedAudiogram);
    when(() => audiogramRepo.saveAudiogram(any())).thenAnswer((inv) async {
      storedAudiogram = inv.positionalArguments.first as Audiogram;
    });

    // Profile repo: predefined Conversación profile + spy on stale call.
    when(() => profileRepo.getProfileByName(any()))
        .thenAnswer((_) async => EnvironmentProfile.conversation);
    when(() => profileRepo.warnings)
        .thenAnswer((_) => const Stream<ProfileRepositoryWarning>.empty());
    when(() => profileRepo.markCustomPresetsAsStale(
          any(),
          thresholdDb: any(named: 'thresholdDb'),
        )).thenAnswer((inv) async {
      markStaleCalls.add(inv.positionalArguments.first as Audiogram);
      return const <String>[];
    });

    // Settings repo: minimal restore + persistence-only stubs.
    when(() => settingsRepo.restoreLastConfig()).thenAnswer(
      (_) async => (lastProfile: 'Conversación', lastVolume: 0.0),
    );
    when(() => settingsRepo.setLastProfile(any())).thenAnswer((_) async {});
    when(() => settingsRepo.setLastVolume(any())).thenAnswer((_) async {});
    when(() => settingsRepo.getPrescriberMode())
        .thenAnswer((_) async => PrescriberMode.smartNl2);
    when(() => settingsRepo.setPrescriberMode(any()))
        .thenAnswer((_) async {});
    when(() => settingsRepo.getExperienceMonths())
        .thenAnswer((_) async => 24); // experienced user
    when(() => settingsRepo.setExperienceMonths(any()))
        .thenAnswer((_) async {});
  });

  tearDown(() async {
    await Hive.close();
    if (await tempDir.exists()) {
      await tempDir.delete(recursive: true);
    }
  });

  AmplificationBloc buildBloc() => AmplificationBloc(
        audioBridge: audioBridge,
        audiogramRepository: audiogramRepo,
        profileRepository: profileRepo,
        settingsRepository: settingsRepo,
        gainPrescriber: gainPrescriber,
        bootDelay: Duration.zero,
      );

  /// Drives the bloc until the first [AmplificationActive] state is reached
  /// and the initial bundle from boot has been applied. Returns the bloc
  /// and the active state observed.
  Future<(AmplificationBloc, AmplificationActive)> bootDiagnostic() async {
    final bloc = buildBloc();
    final completer = Completer<AmplificationActive>();
    final sub = bloc.stream.listen((state) {
      if (state is AmplificationActive && !completer.isCompleted) {
        // Wait for the bundle-driven path to settle: the bloc emits
        // Active twice — first from `_onStartAmplification`, then again
        // from `_onApplyBundle` enriched with bundle/lossType. We pick
        // the second emission to ensure the bundle is in state.
        if (state.bundle != null) {
          completer.complete(state);
        }
      }
    });
    bloc.add(const StartAmplification());
    final active = await completer.future.timeout(
      const Duration(seconds: 2),
      onTimeout: () => throw TimeoutException(
        'AmplificationBloc did not reach Active+bundle within 2 s',
      ),
    );
    await sub.cancel();
    return (bloc, active);
  }

  group('12.3 Stale delta — Diagnostic mode, MAD > 5 dB audiogram change', () {
    test(
      'manual delta stays in state and customPresetsStale flips to true '
      'when audiogram changes from Bisgaard N3 to N6',
      () async {
        // 1. Boot in Diagnostic mode with N3 audiogram persisted.
        final (bloc, initialActive) = await bootDiagnostic();
        addTearDown(() async {
          await bloc.close();
        });

        // Sanity: Diagnostic mode + no stale flag yet.
        expect(initialActive.customPresetsStale, isFalse);
        expect(
          initialActive.bundle,
          isNotNull,
          reason: 'bundle must be present after boot',
        );

        // 2. Dispatch a manual EQ adjust on band 5 (2000 Hz) to create a
        //    non-zero ManualAdjustmentDelta that the bloc must persist.
        const adjustedBandIndex = 5;
        const adjustedDeltaDb = 2.5;
        final deltaApplied = Completer<ManualAdjustmentDelta>();
        final deltaSub = bloc.stream.listen((state) {
          if (state is AmplificationActive &&
              state.manualDelta != null &&
              state.manualDelta!.eqDeltaDb[adjustedBandIndex] ==
                  adjustedDeltaDb &&
              !deltaApplied.isCompleted) {
            deltaApplied.complete(state.manualDelta);
          }
        });

        bloc.add(const ManualEqAdjust(
          bandIndex: adjustedBandIndex,
          deltaDelta: adjustedDeltaDb,
        ));

        final delta = await deltaApplied.future.timeout(
          const Duration(seconds: 2),
          onTimeout: () => throw TimeoutException(
            'manualDelta did not propagate to AmplificationActive within 2 s',
          ),
        );
        await deltaSub.cancel();

        // The persisted delta must reflect the adjustment exactly.
        expect(delta.eqDeltaDb[adjustedBandIndex], adjustedDeltaDb);
        expect(delta.isZero, isFalse);
        for (var i = 0; i < ManualAdjustmentDelta.bandCount; i++) {
          if (i == adjustedBandIndex) continue;
          expect(
            delta.eqDeltaDb[i],
            0.0,
            reason: 'untouched band $i must remain 0 dB',
          );
        }

        // 3. Dispatch UpdateAudiogram with Bisgaard N6 — every band differs
        //    from N3 by ≥ 25 dB, far above the 5 dB MAD threshold.
        final stalePropagated = Completer<AmplificationActive>();
        final staleSub = bloc.stream.listen((state) {
          if (state is AmplificationActive &&
              state.customPresetsStale &&
              !stalePropagated.isCompleted) {
            stalePropagated.complete(state);
          }
        });

        bloc.add(UpdateAudiogram(audiogram: _pointsFrom(_bisgaardN6)));

        final staleState = await stalePropagated.future.timeout(
          const Duration(seconds: 2),
          onTimeout: () => throw TimeoutException(
            'customPresetsStale did not flip to true within 2 s after '
            'audiogram change',
          ),
        );
        await staleSub.cancel();

        // 4a. The stale flag is set on the active state — UI signal that
        //     the three resolution options must be offered (Req 14.7).
        // TODO(audiogram-driven-presets): wire the three-option resolution
        // flow per Req 14.7 (accept / reset / edit) end-to-end and assert
        // the corresponding UI events here once the flow lands.
        expect(staleState.customPresetsStale, isTrue);

        // 4b. The repository was asked to mark presets stale with the new
        //     audiogram (per Req 9.2/9.3 and the bloc contract in
        //     `_onUpdateAudiogram`).
        expect(markStaleCalls, isNotEmpty);
        expect(
          markStaleCalls.first.thresholds,
          equals(_bisgaardN6),
          reason:
              'markCustomPresetsAsStale must receive the new audiogram',
        );

        // 4c. The manual delta must be preserved across the audiogram
        //     change. The current bloc contract keeps the delta intact and
        //     simply marks the dependent custom presets as stale; the user
        //     decides via UI (accept / reset / edit) whether to keep,
        //     drop, or modify it. The delta on the latest active state
        //     must therefore equal what we applied earlier.
        expect(staleState.manualDelta, isNotNull);
        expect(
          staleState.manualDelta!.eqDeltaDb[adjustedBandIndex],
          adjustedDeltaDb,
          reason: 'manual EQ delta must survive the audiogram update '
              '(stale presets are flagged, not auto-reset)',
        );
        expect(staleState.manualDelta!.isZero, isFalse);

        // 4d. The bridge received the atomic 4-call sequence at least
        //     twice (once on boot, once on the new audiogram). This is a
        //     light-weight cross-check that the bundle path actually
        //     executed; the per-call ordering is covered by task 11.6 /
        //     12.4 dedicated tests.
        verify(() => audioBridge.setMpoThresholdDbSpl(any()))
            .called(greaterThanOrEqualTo(2));
        verify(() => audioBridge.updateEqGains(any()))
            .called(greaterThanOrEqualTo(2));
      },
    );

    // TODO(spec-task-future): Req 14.7 specifies that on stale delta
    // detection, the bloc should expose 3 options to the user
    // (keep delta / discard delta / regenerate from current audiogram +
    // delta). The current bloc only flags `customPresetsStale = true` and
    // delegates to `ProfileRepository.markCustomPresetsAsStale`. When the
    // 3-option handler lands, extend this test to:
    //   1. Verify the bloc exposes the three options after stale detection
    //      (either via dedicated state fields, an event stream, or a UI
    //      controller).
    //   2. Dispatch each of the three resolution events and verify the
    //      resulting AmplificationActive (delta preserved / zeroed /
    //      regenerated) and the bridge calls (no-op vs reapply).
    test(
      'TODO: 3-option dispatch on stale delta (Req 14.7) — '
      'keep / discard / regenerate',
      () {
        // Intentional placeholder: the bloc currently does not emit a
        // structured "three options" surface; it only sets
        // `customPresetsStale = true`. This test will be implemented
        // alongside the corresponding bloc handler.
      },
      skip: 'Req 14.7 three-option resolution flow not yet implemented '
          'in AmplificationBloc',
    );
  });
}
