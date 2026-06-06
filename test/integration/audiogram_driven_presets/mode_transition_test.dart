// Spec: audiogram-driven-presets · Wave 9, task 12.2 — Mode transition.
//
// Validates Requirements 13.4, 13.6, 13.8 and 13.9 with three focused
// tests:
//
//   Test 1 — Boot Amplifier mode (no audiograma medido).
//     audiogramRepository.getAudiogram() returns null and the persisted
//     amplifier_gain_scale is 0.40. The boot flow must auto-detect
//     Modo Amplificador, build the initial bundle from the
//     defaultAudiogram and dispatch the atomic 4-call sequence to the
//     bridge.
//
//   Test 2 — Apply audiometry → transition to Diagnostic.
//     Starting from Test 1 conditions, dispatch UpdateAudiogram with a
//     complete Bisgaard N3 audiogram. Verify the bloc transitions to
//     Modo Diagnóstico with gainScale forced to 1.0, that the bundle
//     is rebuilt from the measured audiogram (gainsDb differ from the
//     Amplifier-mode bundle and are NOT a pure rescale) and that the
//     bridge received another full atomic 4-call sequence.
//
//   Test 3 — gainScale ignored in Diagnostic (Req 13.4).
//     After transitioning to Diagnostic, dispatch GainScaleChanged(0.50).
//     Verify gainScale stays at 1.0, no new Active state with a
//     different gainScale is emitted and no extra atomic sequence
//     hits the bridge (verifyNever on the post-transition window).
//
// Scope: this test wires the real [AmplificationBloc] with the real
// [BundleBuilder] (via the bloc's internal instance) against a mocked
// [AudioBridge] and stub repositories.
//
// This test does NOT exercise rollback (covered by 12.4), stale delta
// detection (covered by 12.3) or the full bridge call sequence
// validation (covered by 12.1) — its concern is the Amplifier→Diagnostic
// mode transition and the gainScale isolation contract.

import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:mocktail/mocktail.dart';

import 'package:hearing_aid_app/data/bridges/audio_bridge.dart';
import 'package:hearing_aid_app/domain/audiogram_driven_presets/audiogram_driven_bundle.dart';
import 'package:hearing_aid_app/domain/audiogram_driven_presets/bundle_builder.dart';
import 'package:hearing_aid_app/domain/audiogram_driven_presets/operating_mode.dart';
import 'package:hearing_aid_app/domain/entities/audio_config.dart';
import 'package:hearing_aid_app/domain/entities/audiogram.dart';
import 'package:hearing_aid_app/domain/entities/environment_profile.dart';
import 'package:hearing_aid_app/domain/entities/patient_profile.dart';
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

class _MockAudioBridge extends Mock implements AudioBridge {}

class _MockAudiogramRepository extends Mock implements AudiogramRepository {}

class _MockProfileRepository extends Mock implements ProfileRepository {}

class _MockSettingsRepository extends Mock implements SettingsRepository {}

class _FakeAudioConfig extends Fake implements AudioConfig {}

class _FakeWdrcParams extends Fake implements WdrcParams {}

class _FakeAudiogram extends Fake implements Audiogram {}

// ─── Bisgaard N3 fixture ────────────────────────────────────────────────────
//
// Bisgaard, Vlaming & Dahlquist (2010), "Standard Audiograms for the IEC
// 60118-15 Measurement Procedure", *Trends in Amplification* 14(2):113–120.
// N3 = moderate flat; used here as the simulated audiometry result that
// transitions the bloc out of Amplifier mode.
const Map<int, double> _bisgaardN3 = {
  250: 35, 500: 35, 750: 35, 1000: 40, 1500: 45,
  2000: 50, 2500: 55, 3000: 55, 3500: 55, 4000: 60,
  6000: 60, 8000: 65,
};

const double _kBootDefaultGainScale = 0.40;

Audiogram _audiogramFrom(Map<int, double> map) =>
    Audiogram(thresholds: Map<int, double>.from(map));

List<AudiogramPoint> _pointsFrom(Map<int, double> map) => map.entries
    .map((e) => AudiogramPoint(frequencyHz: e.key, thresholdHL: e.value))
    .toList()
  ..sort((a, b) => a.frequencyHz.compareTo(b.frequencyHz));

bool _audiogramThresholdsEqual(Map<int, double> a, Map<int, double> b) {
  if (a.length != b.length) return false;
  for (final e in a.entries) {
    final bv = b[e.key];
    if (bv == null) return false;
    if ((bv - e.value).abs() > 1e-9) return false;
  }
  return true;
}

// ─── Test harness ───────────────────────────────────────────────────────────

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempHiveDir;
  late _MockAudioBridge bridge;
  late _MockAudiogramRepository audiogramRepo;
  late _MockProfileRepository profileRepo;
  late _MockSettingsRepository settingsRepo;
  late GainPrescriber gainPrescriber;
  late BundleBuilder builder;

  // Mutable storage that the audiogram repo "remembers". The bloc
  // reads previous audiogram on `_onUpdateAudiogram` (to detect MAD >
  // 5 dB) before saving the new one, so the mock must read-then-save
  // in order. Initially `null` to force Modo Amplificador at boot.
  late Audiogram? storedAudiogram;

  // Records bridge method invocations in arrival order. Tests clear
  // this between phases to assert per-phase atomic sequences without
  // bringing prior boot-time calls into scope.
  late List<({String method, Object? value})> callLog;

  setUpAll(() async {
    registerFallbackValue(_FakeAudioConfig());
    registerFallbackValue(_FakeWdrcParams());
    registerFallbackValue(_FakeAudiogram());
    registerFallbackValue(PrescriberMode.smartNl2);
    registerFallbackValue(<double>[]);
    registerFallbackValue(0);

    tempHiveDir =
        await Directory.systemTemp.createTemp('mode_transition_test_');
    Hive.init(tempHiveDir.path);
  });

  tearDownAll(() async {
    await Hive.close();
    if (tempHiveDir.existsSync()) {
      try {
        await tempHiveDir.delete(recursive: true);
      } catch (_) {
        // Some Windows runs hold open handles briefly — non-fatal.
      }
    }
  });

  setUp(() async {
    bridge = _MockAudioBridge();
    audiogramRepo = _MockAudiogramRepository();
    profileRepo = _MockProfileRepository();
    settingsRepo = _MockSettingsRepository();
    gainPrescriber = GainPrescriber();
    builder = BundleBuilder();

    // Boot in Amplificador: no audiogram persisted.
    storedAudiogram = null;
    callLog = <({String method, Object? value})>[];

    // Reset the bloc-managed `settings_box` between tests and seed it
    // with `amplifier_gain_scale = 0.40` so `_loadAmplifierGainScale`
    // returns the documented default in a deterministic way.
    final box = Hive.isBoxOpen('settings_box')
        ? Hive.box<dynamic>('settings_box')
        : await Hive.openBox<dynamic>('settings_box');
    await box.clear();
    await box.put('amplifier_gain_scale', _kBootDefaultGainScale);

    // Bridge: streams empty + every method records into callLog.
    when(() => bridge.inputLevelStream)
        .thenAnswer((_) => const Stream<double>.empty());
    when(() => bridge.stateStream)
        .thenAnswer((_) => const Stream<AudioEngineState>.empty());
    when(() => bridge.startAudio(any())).thenAnswer((_) async {});
    when(() => bridge.stopAudio()).thenAnswer((_) async {});
    when(() => bridge.setMpoThresholdDbSpl(any())).thenAnswer((inv) async {
      callLog.add((
        method: 'setMpoThresholdDbSpl',
        value: inv.positionalArguments.first,
      ));
    });
    when(() => bridge.updateWdrcParams(any())).thenAnswer((inv) async {
      callLog.add((
        method: 'updateWdrcParams',
        value: inv.positionalArguments.first,
      ));
    });
    when(() => bridge.updateEqGains(any())).thenAnswer((inv) async {
      callLog.add((
        method: 'updateEqGains',
        value: List<double>.from(inv.positionalArguments.first as List),
      ));
    });
    when(() => bridge.updateNrLevel(any())).thenAnswer((inv) async {
      callLog.add((
        method: 'updateNrLevel',
        value: inv.positionalArguments.first,
      ));
    });
    when(() => bridge.updateVolume(any())).thenAnswer((_) async {});

    // Audiogram repo: read-then-save mutates the storage so the bloc
    // sees `null` at boot (Amplifier mode) and the new measured
    // audiogram afterwards (Diagnóstico mode).
    when(() => audiogramRepo.getAudiogram())
        .thenAnswer((_) async => storedAudiogram);
    when(() => audiogramRepo.saveAudiogram(any())).thenAnswer((inv) async {
      storedAudiogram = inv.positionalArguments.first as Audiogram;
    });

    // Profile repo: predefined Conversación + neutral stale-update spy.
    when(() => profileRepo.getProfileByName(any()))
        .thenAnswer((_) async => EnvironmentProfile.conversation);
    when(() => profileRepo.markCustomPresetsAsStale(
          any(),
          thresholdDb: any(named: 'thresholdDb'),
        )).thenAnswer((_) async => const <String>[]);

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
        .thenAnswer((_) async => 24); // adult, experienced
    when(() => settingsRepo.setExperienceMonths(any()))
        .thenAnswer((_) async {});
  });

  AmplificationBloc buildBloc() => AmplificationBloc(
        audioBridge: bridge,
        audiogramRepository: audiogramRepo,
        profileRepository: profileRepo,
        settingsRepository: settingsRepo,
        gainPrescriber: gainPrescriber,
      );

  /// Drives the bloc until it has booted and the initial bundle from
  /// `_onStartAmplification` has been applied (i.e. an Active state
  /// with `bundle != null` is observed). Returns the bloc itself.
  Future<AmplificationBloc> bootAndWaitForInitialApply(
    AmplificationBloc bloc,
  ) async {
    final completer = Completer<AmplificationActive>();
    final sub = bloc.stream.listen((state) {
      if (state is AmplificationActive &&
          state.bundle != null &&
          !completer.isCompleted) {
        completer.complete(state);
      }
    });
    bloc.add(const StartAmplification());
    await completer.future.timeout(
      const Duration(seconds: 3),
      onTimeout: () => throw TimeoutException(
        'AmplificationBloc did not reach Active+bundle within 3 s',
      ),
    );
    await sub.cancel();
    return bloc;
  }

  /// Drives the bloc through the audiometry transition: dispatches
  /// `UpdateAudiogram` with [audiogramMap] and waits for an Active
  /// state where `operatingMode == diagnostic` and the bundle reflects
  /// the measured audiogram. Returns the post-transition state.
  Future<AmplificationActive> applyAudiometryAndWait(
    AmplificationBloc bloc,
    Map<int, double> audiogramMap,
  ) async {
    final completer = Completer<AmplificationActive>();
    final sub = bloc.stream.listen((state) {
      if (state is AmplificationActive &&
          state.operatingMode == OperatingMode.diagnostic &&
          state.bundle != null &&
          state.bundle!.mode == OperatingMode.diagnostic &&
          !completer.isCompleted) {
        completer.complete(state);
      }
    });
    bloc.add(UpdateAudiogram(audiogram: _pointsFrom(audiogramMap)));
    final result = await completer.future.timeout(
      const Duration(seconds: 3),
      onTimeout: () => throw TimeoutException(
        'Bloc did not transition to Diagnostic within 3 s',
      ),
    );
    await sub.cancel();
    return result;
  }

  // ────────────────────────────────────────────────────────────────────
  // Test 1 — Boot Amplifier mode (no audiograma medido)
  // ────────────────────────────────────────────────────────────────────

  test(
    '12.2 Test 1 — boots in Amplifier with persisted gainScale=0.40, '
    'builds bundle from defaultAudiogram, dispatches atomic 4-call '
    'sequence to the bridge',
    () async {
      // ── Arrange + Act ─────────────────────────────────────────────
      final bloc = await bootAndWaitForInitialApply(buildBloc());
      addTearDown(bloc.close);

      // ── Assert ────────────────────────────────────────────────────
      final state = bloc.state;
      expect(
        state,
        isA<AmplificationActive>(),
        reason: 'Boot must reach AmplificationActive',
      );
      final active = state as AmplificationActive;

      // 1a. operatingMode == amplifier (Req 13.1).
      expect(
        active.operatingMode,
        OperatingMode.amplifier,
        reason: 'No persisted audiogram ⇒ Modo Amplificador (Req 13.1)',
      );

      // 1b. gainScale == 0.40 (the persisted value, Req 13.7).
      expect(
        active.gainScale,
        closeTo(_kBootDefaultGainScale, 1e-9),
        reason:
            'Persisted amplifier_gain_scale=0.40 should be loaded at boot '
            '(Req 13.7)',
      );

      // 1c. bundle != null, derived from defaultAudiogram with the
      //     amplifier mode + gainScale applied.
      expect(active.bundle, isNotNull,
          reason: 'Initial apply must produce a bundle');
      final bundle = active.bundle!;
      expect(bundle.mode, OperatingMode.amplifier);
      expect(bundle.gainScale, closeTo(_kBootDefaultGainScale, 1e-9));
      expect(bundle.gainsDb, hasLength(AudiogramDrivenBundle.bandCount));

      // 1d. Sanity: the gains were scaled down by gainScale (compare to
      //     the unscaled prescription for the default audiogram).
      final unscaledDefault = builder.buildFromAudiogram(
        Audiogram.defaultAudiogram(),
        profile: const PatientProfile(experienceMonths: 24),
        mode: PrescriptionMode.quiet,
        operatingMode: OperatingMode.diagnostic,
        gainScale: 1.0,
      );
      var anyStrictlySmaller = false;
      for (var i = 0; i < AudiogramDrivenBundle.bandCount; i++) {
        expect(
          bundle.gainsDb[i],
          lessThanOrEqualTo(unscaledDefault.gainsDb[i] + 1e-9),
          reason: 'Amplifier gain[$i] must be ≤ unscaled default',
        );
        if (bundle.gainsDb[i] < unscaledDefault.gainsDb[i] - 1e-9) {
          anyStrictlySmaller = true;
        }
      }
      expect(
        anyStrictlySmaller,
        isTrue,
        reason: 'gainScale=0.40 must reduce at least one band of the '
            'default-audiogram prescription (Req 13.4)',
      );

      // 1e. Bridge received exactly one full atomic 4-call sequence in
      //     the documented order during boot.
      expect(
        callLog.map((e) => e.method).toList(),
        equals(<String>[
          'setMpoThresholdDbSpl',
          'updateWdrcParams',
          'updateEqGains',
          'updateNrLevel',
        ]),
        reason: 'atomic 4-call sequence in documented order '
            '(design.md §"Atomic apply", Req 4.1)',
      );
      verify(() => bridge.startAudio(any())).called(1);
      verify(() => bridge.setMpoThresholdDbSpl(any())).called(1);
      verify(() => bridge.updateWdrcParams(any())).called(1);
      verify(() => bridge.updateEqGains(any())).called(1);
      verify(() => bridge.updateNrLevel(any())).called(1);
    },
  );

  // ────────────────────────────────────────────────────────────────────
  // Test 2 — Apply audiometry → transition to Diagnostic
  // ────────────────────────────────────────────────────────────────────

  test(
    '12.2 Test 2 — UpdateAudiogram(Bisgaard N3) transitions to Diagnostic, '
    'forces gainScale=1.0, rebuilds bundle from measured audiogram and '
    'fires another atomic 4-call sequence',
    () async {
      // ── Arrange: boot in Amplifier and capture the pre-transition
      //          bundle for comparison. ─────────────────────────────
      final bloc = await bootAndWaitForInitialApply(buildBloc());
      addTearDown(bloc.close);

      final amplifierActive = bloc.state as AmplificationActive;
      final amplifierBundle = amplifierActive.bundle!;
      expect(amplifierActive.operatingMode, OperatingMode.amplifier);
      expect(amplifierActive.gainScale,
          closeTo(_kBootDefaultGainScale, 1e-9));

      // Clear the call log so we only see the post-transition apply.
      callLog.clear();
      clearInteractions(bridge);

      // ── Act: dispatch the simulated audiometry result. ────────────
      final diagnosticActive = await applyAudiometryAndWait(
        bloc,
        _bisgaardN3,
      );

      // ── Assert ────────────────────────────────────────────────────

      // 2a. operatingMode flipped to diagnostic (Req 13.9).
      expect(
        diagnosticActive.operatingMode,
        OperatingMode.diagnostic,
        reason: 'Audiograma medido aplicado ⇒ Modo Diagnóstico (Req 13.9)',
      );

      // 2b. gainScale forced to 1.0 (Req 13.4 + 13.8).
      expect(
        diagnosticActive.gainScale,
        1.0,
        reason: 'Diagnostic forces gainScale = 1.0 (Req 13.4 + 13.8)',
      );

      // 2c. Bundle was rebuilt from the measured audiogram. We compare
      //     against the deterministic builder output for that same
      //     audiogram with gainScale=1.0.
      final diagnosticBundle = diagnosticActive.bundle!;
      expect(diagnosticBundle.mode, OperatingMode.diagnostic);
      expect(diagnosticBundle.gainScale, 1.0);

      final expectedDiagnostic = builder.buildFromAudiogram(
        _audiogramFrom(_bisgaardN3),
        profile: const PatientProfile(experienceMonths: 24),
        // Conversación maps to PrescriptionMode.quiet via
        // EnvironmentProfileMapper (design.md §5.2 + Req 6.2).
        mode: PrescriptionMode.quiet,
        operatingMode: OperatingMode.diagnostic,
        gainScale: 1.0,
      );

      for (var i = 0; i < AudiogramDrivenBundle.bandCount; i++) {
        expect(
          diagnosticBundle.gainsDb[i],
          closeTo(expectedDiagnostic.gainsDb[i], 1e-9),
          reason: 'gainsDb[$i] must come from the prescriber for the '
              'measured audiogram (no gainScale applied)',
        );
      }

      // 2d. Audiogram persisted before the bundle was built.
      verify(() => audiogramRepo.saveAudiogram(any(
            that: predicate<Audiogram>(
              (a) => _audiogramThresholdsEqual(a.thresholds, _bisgaardN3),
              'audiogram == Bisgaard N3',
            ),
          ))).called(1);

      // 2e. The diagnostic gainsDb differ from the prior Amplifier
      //     gainsDb (audiogram changed AND gainScale changed) and are
      //     not a pure rescale of them either. Both proofs together
      //     show the bundle was rebuilt, not just unscaled.
      var anyGainDiffers = false;
      var anyNotPureRescale = false;
      for (var i = 0; i < AudiogramDrivenBundle.bandCount; i++) {
        if ((diagnosticBundle.gainsDb[i] - amplifierBundle.gainsDb[i])
                .abs() >
            1e-6) {
          anyGainDiffers = true;
        }
        final pureRescale =
            amplifierBundle.gainsDb[i] / _kBootDefaultGainScale;
        if ((diagnosticBundle.gainsDb[i] - pureRescale).abs() > 1e-3) {
          anyNotPureRescale = true;
        }
      }
      expect(
        anyGainDiffers,
        isTrue,
        reason: 'Diagnostic gainsDb must differ from Amplifier gainsDb '
            '(bundle rebuilt from measured audiogram, Req 13.9)',
      );
      expect(
        anyNotPureRescale,
        isTrue,
        reason: 'Diagnostic gains must NOT be a pure rescale of the '
            'Amplifier gains — the bundle was rebuilt from the '
            'measured audiogram (Req 13.8, 13.9)',
      );

      // 2f. MPO + compression ratios were re-derived from the measured
      //     audiogram (deterministic match against builder output).
      for (var i = 0; i < AudiogramDrivenBundle.bandCount; i++) {
        expect(
          diagnosticBundle.mpoProfileDbSpl[i],
          closeTo(expectedDiagnostic.mpoProfileDbSpl[i], 1e-9),
          reason: 'MPO[$i] derived from measured audiogram',
        );
        expect(
          diagnosticBundle.compressionRatios[i],
          closeTo(expectedDiagnostic.compressionRatios[i], 1e-9),
          reason: 'CR[$i] derived from measured audiogram',
        );
      }

      // 2g. The bridge received another full atomic 4-call sequence in
      //     the documented order (and only that — no extras).
      expect(
        callLog.map((e) => e.method).toList(),
        equals(<String>[
          'setMpoThresholdDbSpl',
          'updateWdrcParams',
          'updateEqGains',
          'updateNrLevel',
        ]),
        reason: 'second atomic 4-call sequence in documented order '
            '(Req 4.1)',
      );
      verify(() => bridge.setMpoThresholdDbSpl(any())).called(1);
      verify(() => bridge.updateWdrcParams(any())).called(1);
      verify(() => bridge.updateEqGains(any())).called(1);
      verify(() => bridge.updateNrLevel(any())).called(1);
      verifyNever(() => bridge.startAudio(any()));
      verifyNever(() => bridge.stopAudio());
    },
  );

  // ────────────────────────────────────────────────────────────────────
  // Test 3 — gainScale ignored in Diagnostic
  // ────────────────────────────────────────────────────────────────────

  test(
    '12.2 Test 3 — GainScaleChanged is ignored in Diagnostic: gainScale '
    'stays at 1.0, no new Active state is emitted and no atomic '
    'sequence is dispatched to the bridge',
    () async {
      // ── Arrange: boot in Amplifier and transition to Diagnostic. ──
      final bloc = await bootAndWaitForInitialApply(buildBloc());
      addTearDown(bloc.close);
      await applyAudiometryAndWait(bloc, _bisgaardN3);

      final preState = bloc.state as AmplificationActive;
      expect(preState.operatingMode, OperatingMode.diagnostic);
      expect(preState.gainScale, 1.0);

      // Clear bridge interactions so we only observe what happens
      // AFTER GainScaleChanged is dispatched in Diagnostic.
      callLog.clear();
      clearInteractions(bridge);

      // Capture every Active state emitted after the dispatch so we
      // can assert no new gainScale-distinct Active state is emitted.
      final emittedActiveStates = <AmplificationActive>[];
      final sub = bloc.stream.listen((state) {
        if (state is AmplificationActive) {
          emittedActiveStates.add(state);
        }
      });

      // ── Act: dispatch a GainScaleChanged event with a value the
      //          handler would normally accept in Amplifier mode. ───
      bloc.add(const GainScaleChanged(gainScale: 0.50));

      // Give the bloc enough time to process the event (and any
      // hypothetical follow-up `ApplyAudiogramDrivenBundle`). 250 ms
      // is several orders of magnitude above the bloc's typical event
      // turnaround in tests; if the handler had not returned early
      // we'd see an Active state with gainScale=0.50 in this window.
      await Future<void>.delayed(const Duration(milliseconds: 250));
      await sub.cancel();

      // ── Assert ────────────────────────────────────────────────────

      // 3a. State is unchanged: still Diagnostic, still gainScale=1.0.
      final postState = bloc.state as AmplificationActive;
      expect(
        postState.operatingMode,
        OperatingMode.diagnostic,
        reason: 'GainScaleChanged must not flip the operating mode',
      );
      expect(
        postState.gainScale,
        1.0,
        reason: 'gainScale must remain 1.0 in Diagnostic (Req 13.4)',
      );

      // 3b. No new Active state was emitted with a gainScale != 1.0.
      //     (Other unrelated emits — none expected here — would still
      //     have gainScale == 1.0.)
      for (final s in emittedActiveStates) {
        expect(
          s.gainScale,
          1.0,
          reason:
              'No Active state with gainScale != 1.0 must be emitted in '
              'Diagnostic (Req 13.4)',
        );
      }

      // 3c. No atomic sequence was dispatched to the bridge: the
      //     handler must warn-and-return without triggering a rebuild.
      expect(
        callLog,
        isEmpty,
        reason: 'GainScaleChanged in Diagnostic must NOT trigger any '
            'bridge call — the handler logs a warning and returns '
            '(amplification_bloc.dart::_onGainScaleChanged, Req 13.4)',
      );
      verifyNever(() => bridge.setMpoThresholdDbSpl(any()));
      verifyNever(() => bridge.updateWdrcParams(any()));
      verifyNever(() => bridge.updateEqGains(any()));
      verifyNever(() => bridge.updateNrLevel(any()));
    },
  );
}
