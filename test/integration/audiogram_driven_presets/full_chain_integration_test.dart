// Spec: audiogram-driven-presets · Wave 9, task 12.1 — Full chain integration.
//
// Validates Requirement 11.8: the full chain "audiometry result → bundle →
// AudioBridge" produces the atomic 4-call sequence with values consistent
// with what the [BundleBuilder] derived from the audiogram.
//
// Scope: this test wires the real [AmplificationBloc] with the real
// [BundleBuilder] (via the bloc's internal instance) against a mocked
// [AudioBridge] and stub repositories. It boots the bloc with a
// pre-existing Bisgaard N3 audiogram (moderate flat loss, typical
// fitting case), then dispatches [UpdateAudiogram] with a Bisgaard N4
// audiogram (the "new audiometry result"). The test then verifies:
//
//   1. The bridge received exactly four calls in the order
//      `setMpoThresholdDbSpl` → `updateWdrcParams` → `updateEqGains` →
//      `updateNrLevel` (Req 4.1, design.md "Atomic apply order").
//
//   2. The values passed to each call match the bundle that the
//      [BundleBuilder] derives from the new audiogram (Req 11.8).
//      The expected values are recomputed in the test using the same
//      formulas the bloc uses internally (`_resolveBroadbandMpo`,
//      `_resolveBridgeCompressionRatio`, `_resolveBridgeCompressionKnee`,
//      `_resolveFinalGains`, `_resolveNrLevel`).
//
//   3. The audiogram is persisted via [AudiogramRepository.saveAudiogram]
//      before the bundle path runs (the bloc reads-then-saves on
//      `_onUpdateAudiogram`, so the new audiogram is observable in the
//      repo at the time the bundle is built).
//
// This test does NOT exercise rollback (covered by 12.4) or stale delta
// detection (covered by 12.3) — its single concern is the success
// path of the atomic 4-call sequence.

import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

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

// ─── Bisgaard fixtures ──────────────────────────────────────────────────────
//
// Bisgaard, Vlaming & Dahlquist (2010), "Standard Audiograms for the IEC
// 60118-15 Measurement Procedure", *Trends in Amplification* 14(2):113–120.
//
// N3 = moderate flat (used as the "previous" audiogram on disk).
// N4 = moderately severe flat (used as the "new audiometry result" the
//      simulated audiometry session captured).

const Map<int, double> _bisgaardN3 = {
  250: 35, 500: 35, 750: 35, 1000: 40, 1500: 45,
  2000: 50, 2500: 55, 3000: 55, 3500: 55, 4000: 60,
  6000: 60, 8000: 65,
};

const Map<int, double> _bisgaardN4 = {
  250: 55, 500: 55, 750: 55, 1000: 55, 1500: 60,
  2000: 65, 2500: 70, 3000: 70, 3500: 70, 4000: 75,
  6000: 75, 8000: 80,
};

Audiogram _audiogramFrom(Map<int, double> map) =>
    Audiogram(thresholds: Map<int, double>.from(map));

List<AudiogramPoint> _pointsFrom(Map<int, double> map) => map.entries
    .map((e) => AudiogramPoint(frequencyHz: e.key, thresholdHL: e.value))
    .toList()
  ..sort((a, b) => a.frequencyHz.compareTo(b.frequencyHz));

// ─── Helpers mirroring the bloc's private resolvers ─────────────────────────
//
// The bloc keeps `_resolveBroadbandMpo`, `_resolveBridgeCompressionRatio`,
// `_resolveBridgeCompressionKnee`, `_resolveFinalGains` and
// `_resolveNrLevel` private. To assert that the bridge receives values
// consistent with the bundle, the test mirrors the documented
// formulas (design.md §"Atomic apply" + amplification_bloc.dart).

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

double _bridgeKneeOf(AudiogramDrivenBundle b) {
  double sum = 0;
  for (final k in b.compressionKneesDbSpl) {
    sum += k;
  }
  return (sum / b.compressionKneesDbSpl.length)
      .clamp(
        AudiogramDrivenBundle.compressionKneeMinDbSpl,
        AudiogramDrivenBundle.compressionKneeMaxDbSpl,
      )
      .toDouble();
}

List<double> _finalGainsOf(AudiogramDrivenBundle b) {
  final gains = List<double>.filled(
    AudiogramDrivenBundle.bandCount,
    0.0,
    growable: false,
  );
  for (var i = 0; i < AudiogramDrivenBundle.bandCount; i++) {
    var g = b.gainsDb[i]
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

  // Mutable storage that the audiogram repo "remembers". The bloc reads
  // the previous audiogram on `_onUpdateAudiogram` (to detect MAD > 5 dB)
  // before saving the new one, so the mock must read-then-save in order.
  late Audiogram? storedAudiogram;

  setUpAll(() async {
    registerFallbackValue(_FakeAudioConfig());
    registerFallbackValue(_FakeWdrcParams());
    registerFallbackValue(_FakeAudiogram());
    registerFallbackValue(PrescriberMode.smartNl2);
    registerFallbackValue(<double>[]);
    registerFallbackValue(0);

    tempHiveDir =
        await Directory.systemTemp.createTemp('full_chain_integration_test_');
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

  // Records the order of bridge method invocations. Each stub appends
  // its method name (and the captured value) to this list. The test
  // clears the list after the boot apply settles so only the calls
  // triggered by `UpdateAudiogram` are asserted on.
  late List<({String method, Object? value})> callLog;

  setUp(() {
    bridge = _MockAudioBridge();
    audiogramRepo = _MockAudiogramRepository();
    profileRepo = _MockProfileRepository();
    settingsRepo = _MockSettingsRepository();
    gainPrescriber = GainPrescriber();
    builder = BundleBuilder();

    storedAudiogram = _audiogramFrom(_bisgaardN3);
    callLog = <({String method, Object? value})>[];

    // Bridge: streams empty + every method succeeds with no side-effects.
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
    // sees the previous audiogram during the MAD comparison and the
    // new audiogram afterwards.
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
  /// `_onStartAmplification` has been applied (i.e. an Active state with
  /// `bundle != null` is observed). Returns the bloc itself.
  Future<AmplificationBloc> bootAndWaitForInitialApply() async {
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

  group(
      '12.1 Full chain — audiometry → bundle → AudioBridge atomic 4-call',
      () {
    test(
      'UpdateAudiogram(Bisgaard N4) drives setMpoThresholdDbSpl → '
      'updateWdrcParams → updateEqGains → updateNrLevel in order, '
      'with values consistent with the bundle',
      () async {
        // ── Step 1: boot the bloc with Bisgaard N3 persisted. The boot
        //          flow calls `_onApplyBundle` once (the "initial apply")
        //          — we wait for it to settle and then clear `callLog`
        //          so the assertions below only see the post-`UpdateAudiogram`
        //          apply. We also `clearInteractions(bridge)` so the
        //          per-method `verify(...).called(...)` assertions only
        //          count calls from the second apply. ──
        final bloc = await bootAndWaitForInitialApply();
        addTearDown(bloc.close);

        callLog.clear();
        clearInteractions(bridge);

        // ── Step 2: build the expected bundle the same way the bloc
        //          does — same audiogram, same profile, same mode,
        //          same operating mode. The bundle is what the
        //          `_onApplyBundle` handler must have just applied. ──
        final newAudiogram = _audiogramFrom(_bisgaardN4);
        final expectedBundle = builder.buildFromAudiogram(
          newAudiogram,
          profile: const PatientProfile(experienceMonths: 24),
          // Conversación maps to PrescriptionMode.quiet via
          // EnvironmentProfileMapper (design.md §5.2 + req 6.2).
          mode: PrescriptionMode.quiet,
          operatingMode: OperatingMode.diagnostic,
          gainScale: 1.0,
        );

        final expectedMpo = _broadbandMpoOf(expectedBundle);
        final expectedCr = _bridgeCrOf(expectedBundle);
        final expectedKnee = _bridgeKneeOf(expectedBundle);
        final expectedNr = expectedBundle.nrLevel;
        final expectedGains = _finalGainsOf(expectedBundle);

        // ── Step 3: dispatch the simulated audiometry result. The bloc
        //          will save it via `AudiogramRepository.saveAudiogram`,
        //          build a bundle and dispatch `ApplyAudiogramDrivenBundle`
        //          internally, which fires the 4-call atomic sequence. ──
        final applyCompleted = Completer<void>();
        final applySub = bloc.stream.listen((state) {
          if (state is AmplificationActive &&
              state.bundle != null &&
              !applyCompleted.isCompleted) {
            // The bundle on the active state must reflect the new
            // audiogram — the lossType/prescriptionMode/mode metadata is
            // derived inside `_onApplyBundle`. We compare on the per-band
            // arrays, which are deterministic given the audiogram.
            final actual = state.bundle!;
            if (_listsClose(actual.gainsDb, expectedBundle.gainsDb) &&
                _listsClose(
                    actual.mpoProfileDbSpl, expectedBundle.mpoProfileDbSpl) &&
                _listsClose(actual.compressionRatios,
                    expectedBundle.compressionRatios)) {
              applyCompleted.complete();
            }
          }
        });

        bloc.add(UpdateAudiogram(audiogram: _pointsFrom(_bisgaardN4)));

        await applyCompleted.future.timeout(
          const Duration(seconds: 3),
          onTimeout: () => throw TimeoutException(
            'New bundle did not reach AmplificationActive within 3 s',
          ),
        );
        await applySub.cancel();

        // ── Step 4: the new audiogram was persisted before the bundle
        //          was built (Req: bloc reads previous → saves new → builds
        //          bundle). ──
        verify(() => audiogramRepo.saveAudiogram(any(
              that: predicate<Audiogram>(
                (a) => _audiogramThresholdsEqual(a.thresholds, _bisgaardN4),
                'audiogram == Bisgaard N4',
              ),
            ))).called(1);

        // ── Step 5: the bridge received exactly the four calls of the
        //          atomic sequence in the documented order. The order is
        //          recorded by the stub side-effects in `callLog`. ──
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

        // ── Step 6: each call received the value derived from the bundle. ──

        // 6a. setMpoThresholdDbSpl(min(bundle.mpoProfileDbSpl)) clamped
        //     to the broadband MPO range [80, 132].
        final mpoCall =
            callLog.firstWhere((e) => e.method == 'setMpoThresholdDbSpl');
        expect(mpoCall.value as double, closeTo(expectedMpo, 1e-9));
        expect(mpoCall.value as double, inInclusiveRange(80.0, 132.0));
        verify(() => bridge.setMpoThresholdDbSpl(any())).called(1);

        // 6b. updateWdrcParams with bundle-derived attack/release, knee
        //     in [35, 65] dB SPL, and PTA-weighted compression ratio in
        //     [1.0, 3.0].
        final wdrcCall =
            callLog.firstWhere((e) => e.method == 'updateWdrcParams');
        final wdrc = wdrcCall.value as WdrcParams;
        expect(wdrc.attackMs, closeTo(expectedBundle.wdrcAttackMs, 1e-9));
        expect(wdrc.releaseMs, closeTo(expectedBundle.wdrcReleaseMs, 1e-9));
        expect(wdrc.compressionRatio, closeTo(expectedCr, 1e-9));
        expect(wdrc.compressionRatio, inInclusiveRange(1.0, 3.0));
        expect(wdrc.compressionKnee, closeTo(expectedKnee, 1e-9));
        expect(wdrc.compressionKnee, inInclusiveRange(35.0, 65.0));
        expect(wdrc.expansionKnee,
            closeTo(expectedBundle.expansionKneeDbSpl, 1e-9));
        verify(() => bridge.updateWdrcParams(any())).called(1);

        // 6c. updateEqGains with the 12 final gains (bundle.gainsDb after
        //     headroom clamp). Each in [0, 50] dB and matching the values
        //     re-computed by the test mirror.
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
        verify(() => bridge.updateEqGains(any())).called(1);

        // 6d. updateNrLevel(bundle.nrLevel) — Conversación → quiet → 1.
        //     No ManualAdjustmentDelta is applied here, so no nrLevelDelta.
        final nrCall =
            callLog.firstWhere((e) => e.method == 'updateNrLevel');
        expect(nrCall.value as int, expectedNr);
        expect(nrCall.value as int, inInclusiveRange(0, 3));
        verify(() => bridge.updateNrLevel(any())).called(1);

        // ── Step 7: no other bridge methods touched the DSP during this
        //          apply (no rollback, no extra calls). ──
        verifyNever(() => bridge.startAudio(any()));
        verifyNever(() => bridge.stopAudio());
      },
    );
  });
}

// ─── Local matchers ─────────────────────────────────────────────────────────

bool _listsClose(List<double> a, List<double> b, {double tol = 1e-6}) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if ((a[i] - b[i]).abs() > tol) return false;
  }
  return true;
}

bool _audiogramThresholdsEqual(Map<int, double> a, Map<int, double> b) {
  if (a.length != b.length) return false;
  for (final e in a.entries) {
    final bv = b[e.key];
    if (bv == null) return false;
    if ((bv - e.value).abs() > 1e-9) return false;
  }
  return true;
}
