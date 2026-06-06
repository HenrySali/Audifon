// Spec: audiogram-driven-presets · Wave 9, task 12.1.
//
// Full chain integration test:
//   simulated audiometry result → BundleBuilder (real) → AmplificationBloc
//   → mocked AudioBridge.
//
// Validates Requirement 11.8: when the bloc boots with a measured
// audiogram, the atomic 4-call sequence reaches the bridge in the
// documented order with values consistent with the bundle the real
// [BundleBuilder] derives from that audiogram, and the resulting
// [AmplificationActive] state carries `bundle != null` plus the
// expected `lossType`, `prescriptionMode`, `operatingMode` and
// `gainScale`.
//
// This file complements the existing `full_chain_integration_test.dart`
// (which exercises the `UpdateAudiogram` path). Here we exercise the
// `StartAmplification` boot path that builds the initial bundle from a
// pre-existing audiogram in the repository, plus a secondary scenario
// where the apply runs with a non-zero [ManualAdjustmentDelta] overlay
// and verifies that `updateEqGains` receives `bundle.gainsDb[i] +
// delta.eqDeltaDb[i]` (with clamp).
//
// The test wires:
//   - real [BundleBuilder] (no mock — function-pure module)
//   - real [GainPrescriberNL3] (instantiated by the bloc internally
//     using the supplied real `GainPrescriber`)
//   - mocked [AudioBridge], [AudiogramRepository], [ProfileRepository],
//     [SettingsRepository] via mocktail
//
// Validates: Requirements 11.8

import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:mocktail/mocktail.dart';

import 'package:hearing_aid_app/data/bridges/audio_bridge.dart';
import 'package:hearing_aid_app/domain/audiogram_driven_presets/audiogram_driven_bundle.dart';
import 'package:hearing_aid_app/domain/audiogram_driven_presets/bundle_builder.dart';
import 'package:hearing_aid_app/domain/audiogram_driven_presets/manual_adjustment_delta.dart';
import 'package:hearing_aid_app/domain/audiogram_driven_presets/operating_mode.dart';
import 'package:hearing_aid_app/domain/entities/audio_config.dart';
import 'package:hearing_aid_app/domain/entities/audiogram.dart';
import 'package:hearing_aid_app/domain/entities/environment_profile.dart';
import 'package:hearing_aid_app/domain/entities/loss_type.dart';
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

// ─── Bisgaard fixtures ──────────────────────────────────────────────────────
//
// Bisgaard, Vlaming & Dahlquist (2010), "Standard Audiograms for the IEC
// 60118-15 Measurement Procedure", *Trends in Amplification* 14(2):113–120.
// Values match those documented in
// `test/domain/audiogram_driven_presets/ucl_estimator_test.dart`.

const Map<int, double> _bisgaardN3 = {
  250: 35, 500: 35, 750: 35, 1000: 40, 1500: 45,
  2000: 50, 2500: 55, 3000: 55, 3500: 55, 4000: 60,
  6000: 60, 8000: 65,
};

Audiogram _audiogramFromMap(Map<int, double> map) =>
    Audiogram(thresholds: Map<int, double>.from(map));

// ─── Helpers mirroring the bloc's private resolvers ─────────────────────────
//
// `_resolveBroadbandMpo`, `_resolveBridgeCompressionRatio`,
// `_resolveBridgeCompressionKnee`, `_resolveFinalGains` and
// `_resolveNrLevel` are private inside [AmplificationBloc]. To assert
// the values reaching the bridge are consistent with the bundle, we
// replicate the documented formulas from amplification_bloc.dart.

const double _kTypicalInputDbSpl = 65.0;
const double _kHeadroomSafetyMarginDb = 3.0;

double _broadbandMpoOf(AudiogramDrivenBundle b) {
  final m = b.mpoProfileDbSpl.reduce(math.min);
  return m
      .clamp(
        AudiogramDrivenBundle.mpoMinDbSpl,
        AudiogramDrivenBundle.mpoMaxDbSpl,
      )
      .toDouble();
}

double _bridgeCrOf(AudiogramDrivenBundle b) {
  const ptaIndices = <int>{1, 3, 5, 9};
  double sum = 0;
  double weight = 0;
  for (var i = 0; i < b.compressionRatios.length; i++) {
    final w = ptaIndices.contains(i) ? 2.0 : 1.0;
    sum += b.compressionRatios[i] * w;
    weight += w;
  }
  return (sum / weight)
      .clamp(
        AudiogramDrivenBundle.compressionRatioMin,
        AudiogramDrivenBundle.compressionRatioMax,
      )
      .toDouble();
}

double _bridgeKneeOf(AudiogramDrivenBundle b, {double kneeDelta = 0.0}) {
  double sum = 0;
  for (final k in b.compressionKneesDbSpl) {
    sum += k;
  }
  final avg = sum / b.compressionKneesDbSpl.length + kneeDelta;
  return avg
      .clamp(
        AudiogramDrivenBundle.compressionKneeMinDbSpl,
        AudiogramDrivenBundle.compressionKneeMaxDbSpl,
      )
      .toDouble();
}

List<double> _finalGainsOf(
  AudiogramDrivenBundle b, {
  ManualAdjustmentDelta? delta,
}) {
  final gains = List<double>.filled(
    AudiogramDrivenBundle.bandCount,
    0.0,
    growable: false,
  );
  for (var i = 0; i < AudiogramDrivenBundle.bandCount; i++) {
    var g = b.gainsDb[i];
    if (delta != null) {
      g += delta.eqDeltaDb[i] + delta.volumeDeltaDb;
    }
    g = g
        .clamp(
          AudiogramDrivenBundle.gainMinDb,
          AudiogramDrivenBundle.gainMaxDb,
        )
        .toDouble();
    final headroom =
        b.mpoProfileDbSpl[i] - _kTypicalInputDbSpl - _kHeadroomSafetyMarginDb;
    if (headroom < g) {
      g = math.max(headroom, AudiogramDrivenBundle.gainMinDb);
    }
    gains[i] = g;
  }
  return List<double>.unmodifiable(gains);
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

  // Mutable storage so the audiogram repo "remembers" what was saved.
  late Audiogram? storedAudiogram;

  // Records the order of bridge method invocations triggered by the
  // atomic 4-call sequence in `_onApplyBundle`.
  late List<({String method, Object? value})> callLog;

  setUpAll(() async {
    registerFallbackValue(_FakeAudioConfig());
    registerFallbackValue(_FakeWdrcParams());
    registerFallbackValue(_FakeAudiogram());
    registerFallbackValue(PrescriberMode.smartNl2);
    registerFallbackValue(<double>[]);
    registerFallbackValue(0);

    tempHiveDir =
        await Directory.systemTemp.createTemp('full_chain_test_');
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

  setUp(() {
    bridge = _MockAudioBridge();
    audiogramRepo = _MockAudiogramRepository();
    profileRepo = _MockProfileRepository();
    settingsRepo = _MockSettingsRepository();
    gainPrescriber = GainPrescriber();
    builder = BundleBuilder();

    storedAudiogram = _audiogramFromMap(_bisgaardN3);
    callLog = <({String method, Object? value})>[];

    // Bridge stubs: each method appends to the callLog so the test can
    // assert ordering AND captured values.
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

    // Audiogram repo: read returns whatever is stored; save mutates it.
    when(() => audiogramRepo.getAudiogram())
        .thenAnswer((_) async => storedAudiogram);
    when(() => audiogramRepo.saveAudiogram(any())).thenAnswer((inv) async {
      storedAudiogram = inv.positionalArguments.first as Audiogram;
    });

    // Profile repo: default profile = Conversación (maps to quiet).
    when(() => profileRepo.getProfileByName(any()))
        .thenAnswer((_) async => EnvironmentProfile.conversation);
    when(() => profileRepo.markCustomPresetsAsStale(
          any(),
          thresholdDb: any(named: 'thresholdDb'),
        )).thenAnswer((_) async => const <String>[]);

    // Settings repo: minimal restore + neutral persistence stubs.
    when(() => settingsRepo.restoreLastConfig()).thenAnswer(
      (_) async => (lastProfile: 'Conversación', lastVolume: 0.0),
    );
    when(() => settingsRepo.setLastProfile(any())).thenAnswer((_) async {});
    when(() => settingsRepo.setLastVolume(any())).thenAnswer((_) async {});
    when(() => settingsRepo.getPrescriberMode())
        .thenAnswer((_) async => PrescriberMode.smartNl2);
    when(() => settingsRepo.setPrescriberMode(any()))
        .thenAnswer((_) async {});
    // Adult, experienced patient (no acclimatization correction) so the
    // bundle gains are deterministic and equal to the bundle the test
    // re-builds locally with the same profile.
    when(() => settingsRepo.getExperienceMonths())
        .thenAnswer((_) async => 24);
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

  /// Drives the bloc until [AmplificationActive] with `bundle != null`
  /// is observed (i.e. the boot apply has settled).
  Future<AmplificationBloc> bootAndWaitForBundle() async {
    final bloc = buildBloc();
    final completer = Completer<void>();
    final sub = bloc.stream.listen((state) {
      if (state is AmplificationActive &&
          state.bundle != null &&
          !completer.isCompleted) {
        completer.complete();
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

  group('12.1 Full chain — boot path with measured audiogram', () {
    test(
      'StartAmplification + Bisgaard N3 audiogram drives the atomic '
      '4-call sequence in order, with bundle-consistent values, and '
      'final state == AmplificationActive(bundle, diagnostic, gainScale=1.0)',
      () async {
        // ── Step 1: boot the bloc. The repository already has Bisgaard N3
        //          stored (set up in setUp), so `_onStartAmplification`
        //          builds the initial bundle from N3 and dispatches the
        //          `ApplyAudiogramDrivenBundle` event that triggers the
        //          atomic 4-call sequence on the mocked bridge. ──
        final bloc = await bootAndWaitForBundle();
        addTearDown(bloc.close);

        // ── Step 2: re-build the expected bundle the same way the bloc
        //          does (real BundleBuilder, same profile, same mode,
        //          same operatingMode, same gainScale). ──
        final n3 = _audiogramFromMap(_bisgaardN3);
        final expectedBundle = builder.buildFromAudiogram(
          n3,
          profile: const PatientProfile(experienceMonths: 24),
          // EnvironmentProfileMapper.modeFor(Conversación) → quiet.
          mode: PrescriptionMode.quiet,
          operatingMode: OperatingMode.diagnostic,
          gainScale: 1.0,
        );

        final expectedMpo = _broadbandMpoOf(expectedBundle);
        final expectedCr = _bridgeCrOf(expectedBundle);
        final expectedKnee = _bridgeKneeOf(expectedBundle);
        final expectedNr = expectedBundle.nrLevel;
        final expectedGains = _finalGainsOf(expectedBundle);
        final expectedLossType = AudiogramClassifier.classify(n3);

        // ── Step 3: the bridge received exactly 4 calls in the documented
        //          order (Req 4.1, design.md §"Atomic apply"). The boot
        //          flow itself does not call any other DSP method between
        //          the apply steps because `startAudio` happened earlier
        //          in `_onStartAmplification` (its capture, if any, lives
        //          in the bridge but not in `callLog`). ──
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

        // ── Step 4: each captured value matches the bundle-derived one
        //          and lies within the documented range. ──

        // 4a. setMpoThresholdDbSpl(min(bundle.mpoProfileDbSpl)) clamped
        //     to [80, 132] dB SPL.
        final mpoCall =
            callLog.firstWhere((e) => e.method == 'setMpoThresholdDbSpl');
        expect(mpoCall.value as double, closeTo(expectedMpo, 1e-9));
        expect(mpoCall.value as double, inInclusiveRange(80.0, 132.0));

        // 4b. updateWdrcParams: PTA-weighted CR ∈ [1.0, 4.0] (the spec
        //     allows up to 4.0; the bundle clamps to 3.0 by contract),
        //     knee ∈ [35, 65].
        final wdrcCall =
            callLog.firstWhere((e) => e.method == 'updateWdrcParams');
        final wdrc = wdrcCall.value as WdrcParams;
        expect(wdrc.compressionRatio, closeTo(expectedCr, 1e-9));
        expect(wdrc.compressionRatio, inInclusiveRange(1.0, 4.0));
        expect(wdrc.compressionKnee, closeTo(expectedKnee, 1e-9));
        expect(wdrc.compressionKnee, inInclusiveRange(35.0, 65.0));
        expect(wdrc.expansionKnee,
            closeTo(expectedBundle.expansionKneeDbSpl, 1e-9));
        expect(wdrc.attackMs, closeTo(expectedBundle.wdrcAttackMs, 1e-9));
        expect(wdrc.releaseMs, closeTo(expectedBundle.wdrcReleaseMs, 1e-9));

        // 4c. updateEqGains: 12 values ∈ [0, 50] dB and matching the
        //     bundle-derived list (post headroom clamp).
        final gainsCall =
            callLog.firstWhere((e) => e.method == 'updateEqGains');
        final gains = (gainsCall.value as List).cast<double>();
        expect(gains, hasLength(12));
        for (var i = 0; i < gains.length; i++) {
          expect(gains[i], inInclusiveRange(0.0, 50.0),
              reason: 'gain[$i] must be within [0, 50] dB');
          expect(gains[i], closeTo(expectedGains[i], 1e-9),
              reason: 'gain[$i] must match the bundle-derived value');
        }

        // 4d. updateNrLevel: int ∈ [0, 3], equal to bundle.nrLevel
        //     (no ManualAdjustmentDelta applied here).
        final nrCall =
            callLog.firstWhere((e) => e.method == 'updateNrLevel');
        expect(nrCall.value as int, expectedNr);
        expect(nrCall.value as int, inInclusiveRange(0, 3));

        // ── Step 5: the final state is AmplificationActive with the
        //          expected clinical metadata. ──
        final state = bloc.state;
        expect(state, isA<AmplificationActive>());
        final active = state as AmplificationActive;

        expect(active.bundle, isNotNull,
            reason: 'bundle must be set after the boot apply');
        expect(active.bundle!.lossType, expectedLossType,
            reason: 'bundle.lossType must equal '
                'LossType.classify(audiogram) for Bisgaard N3');
        expect(active.bundle!.prescriptionMode, PrescriptionMode.quiet,
            reason: 'profile default Conversación maps to quiet');
        expect(active.operatingMode, OperatingMode.diagnostic,
            reason:
                'measured audiogram present → OperatingMode.diagnostic');
        expect(active.gainScale, 1.0,
            reason: 'diagnostic mode forces gainScale = 1.0 (Req 13.4)');

        // The bundle metadata mirrored in the state must match the
        // bundle stored in the state.
        expect(active.lossType, expectedLossType);
        expect(active.prescriptionMode, PrescriptionMode.quiet);
        expect(active.activeNrLevel, expectedNr);

        // No rollback: only the forward atomic sequence reached the
        // bridge during the boot apply.
        verify(() => bridge.setMpoThresholdDbSpl(any())).called(1);
        verify(() => bridge.updateWdrcParams(any())).called(1);
        verify(() => bridge.updateEqGains(any())).called(1);
        verify(() => bridge.updateNrLevel(any())).called(1);
      },
    );
  });

  group('12.1 Full chain — apply with non-zero ManualAdjustmentDelta', () {
    test(
      'ManualEqAdjust(band=5, +3 dB) re-applies the bundle and '
      'updateEqGains receives bundle.gainsDb[5] + 3 (with clamp)',
      () async {
        // ── Step 1: boot with Bisgaard N3 + wait for the initial apply
        //          to settle, then clear the call log so only the
        //          re-apply triggered by ManualEqAdjust is observed. ──
        final bloc = await bootAndWaitForBundle();
        addTearDown(bloc.close);

        final initialActive = bloc.state as AmplificationActive;
        final baseBundle = initialActive.bundle!;
        callLog.clear();
        clearInteractions(bridge);

        // Re-stub the bridge after `clearInteractions` (mocktail keeps
        // the stub but resets the recorded interactions).
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

        // ── Step 2: dispatch ManualEqAdjust(band=5, +3 dB). The handler
        //          builds a new ManualAdjustmentDelta with eqDeltaDb[5]
        //          = +3 and re-dispatches ApplyAudiogramDrivenBundle. ──
        final reapplyDone = Completer<void>();
        final sub = bloc.stream.listen((state) {
          if (state is AmplificationActive &&
              state.manualDelta != null &&
              state.manualDelta!.eqDeltaDb[5] == 3.0 &&
              !reapplyDone.isCompleted) {
            reapplyDone.complete();
          }
        });
        bloc.add(const ManualEqAdjust(bandIndex: 5, deltaDelta: 3.0));

        await reapplyDone.future.timeout(
          const Duration(seconds: 3),
          onTimeout: () => throw TimeoutException(
            'ManualAdjustmentDelta(eqDeltaDb[5]=+3) did not reach the '
            'state within 3 s',
          ),
        );
        await sub.cancel();

        // ── Step 3: the re-apply executed the atomic 4-call sequence
        //          again. ──
        expect(
          callLog.map((e) => e.method).toList(),
          equals(<String>[
            'setMpoThresholdDbSpl',
            'updateWdrcParams',
            'updateEqGains',
            'updateNrLevel',
          ]),
        );

        // ── Step 4: the gains sent to updateEqGains reflect the +3 dB
        //          delta on band 5 (with the same headroom clamp the
        //          bloc applies). All other bands match the bundle's
        //          base gains. ──
        final delta = ManualAdjustmentDelta.zero();
        // We know eqDeltaDb is unmodifiable; build a new delta with +3
        // on band 5 to mirror the bloc's intent for the resolver.
        final eqDelta = List<double>.filled(
          ManualAdjustmentDelta.bandCount,
          0.0,
        );
        eqDelta[5] = 3.0;
        final overlay = ManualAdjustmentDelta(
          eqDeltaDb: List<double>.unmodifiable(eqDelta),
          volumeDeltaDb: delta.volumeDeltaDb,
          nrLevelDelta: delta.nrLevelDelta,
          compressionRatioDelta: delta.compressionRatioDelta,
          compressionKneeDeltaDbSpl: delta.compressionKneeDeltaDbSpl,
          editedAt: delta.editedAt,
        );
        final expectedGainsWithDelta =
            _finalGainsOf(baseBundle, delta: overlay);

        final gainsCall =
            callLog.firstWhere((e) => e.method == 'updateEqGains');
        final gains = (gainsCall.value as List).cast<double>();
        expect(gains, hasLength(12));

        // Band 5 gain must equal the (clamped) base + 3.
        final base5 = baseBundle.gainsDb[5];
        var expected5 =
            (base5 + 3.0).clamp(0.0, 50.0).toDouble();
        final headroom5 = baseBundle.mpoProfileDbSpl[5] -
            _kTypicalInputDbSpl -
            _kHeadroomSafetyMarginDb;
        if (headroom5 < expected5) {
          expected5 = math.max(headroom5, 0.0);
        }
        expect(gains[5], closeTo(expected5, 1e-9),
            reason:
                'band 5 must equal clamp(bundle.gainsDb[5] + 3, [0,50]) '
                'after headroom clamp');

        // All bands must match the resolver mirror (sanity check on the
        // full vector — guards against the +3 leaking into other bands).
        for (var i = 0; i < gains.length; i++) {
          expect(gains[i], closeTo(expectedGainsWithDelta[i], 1e-9),
              reason: 'band $i must equal the mirrored resolver output');
          expect(gains[i], inInclusiveRange(0.0, 50.0));
        }

        // The other 3 bridge calls must be unchanged because EQ delta
        // does not modify MPO/CR/knee/NR.
        final mpoCall =
            callLog.firstWhere((e) => e.method == 'setMpoThresholdDbSpl');
        expect(mpoCall.value as double,
            closeTo(_broadbandMpoOf(baseBundle), 1e-9));

        final wdrcCall =
            callLog.firstWhere((e) => e.method == 'updateWdrcParams');
        final wdrc = wdrcCall.value as WdrcParams;
        expect(wdrc.compressionRatio,
            closeTo(_bridgeCrOf(baseBundle), 1e-9));
        expect(wdrc.compressionKnee,
            closeTo(_bridgeKneeOf(baseBundle), 1e-9));

        final nrCall =
            callLog.firstWhere((e) => e.method == 'updateNrLevel');
        expect(nrCall.value as int, baseBundle.nrLevel);

        // ── Step 5: the state carries the new manualDelta with the
        //          expected eqDeltaDb[5] = +3. ──
        final finalState = bloc.state as AmplificationActive;
        expect(finalState.manualDelta, isNotNull);
        expect(finalState.manualDelta!.eqDeltaDb[5], 3.0);
        for (var i = 0; i < 12; i++) {
          if (i == 5) continue;
          expect(finalState.manualDelta!.eqDeltaDb[i], 0.0,
              reason: 'unrelated bands must remain at 0.0');
        }
      },
    );
  });
}
