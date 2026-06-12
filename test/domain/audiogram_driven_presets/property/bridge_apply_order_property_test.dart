// Feature: audiogram-driven-presets, Property 11.6 — Atomic apply order
//
// Property-based test for the atomic 4-call sequence of
// `AmplificationBloc._onApplyBundle` (Req 4.1, design.md §"Atomic apply"):
//
//     setMpoThresholdDbSpl  →  updateWdrcParams  →  updateEqGains  →  updateNrLevel
//
// For ANY (audiogram, age, manual delta) triple — i.e. for any clinical
// state the system can land in — dispatching `ApplyAudiogramDrivenBundle`
// MUST produce EXACTLY four calls on the [AudioBridge] in EXACTLY that
// order. Any reorder, missing call, or extra call breaks the runtime
// contract the native DSP layer relies on (the MPO threshold has to be
// armed before WDRC compression so the limiter never lets samples
// through above the dynamic ceiling — see `mpo_limiter.cpp` runtime
// expectations).
//
// Generation strategy (seed-based, same convention as
// `bundle_invariants_property_test.dart` and the rest of the property
// tests in this directory):
//
//   - **audiogramSeed** ∈ [0, 120] → 12 thresholds in [0, 120] dB HL via
//     a pseudo-hash (`((seed * (i + 1) * 7.3) % 120).abs()`).
//   - **ageSeed** ∈ [1, 95] → integer age, drives adult vs pediatric
//     MPO derivation in `MpoDeriver` so we exercise both code paths.
//   - **deltaSeed** ∈ [0, 100] → 12-band `eqDeltaDb ∈ [-10, +10]`
//     manual overlay so the test covers the path with a non-zero
//     `ManualAdjustmentDelta` (which the bloc resolves into the gains
//     fed to `updateEqGains`).
//
// Each glados run rebuilds the bridge mock from scratch and pumps the
// event through a fresh [AmplificationBloc], so the call log is
// scoped per case and shrinking surfaces a minimal counter-example if
// the contract ever breaks.
//
// Validates: Requirements 11.7 (atomic apply order)
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart'
    hide test, group, setUp, tearDown, setUpAll, tearDownAll, expect;
import 'package:glados/glados.dart';
import 'package:hive/hive.dart';
// `mocktail` exports a top-level `any` matcher that collides with glados'
// `Any` extension namespace. We hide mocktail's `any` from the unprefixed
// import so the test body can keep using `any.doubleInRange(...)` for
// glados generators (idiomatic), while a second prefixed import provides
// `mt.any()` for stubbing/verifying mocktail matchers (`when(() =>
// bridge.foo(mt.any()))`). All other mocktail symbols (`Mock`, `Fake`,
// `when`, `verify`, `registerFallbackValue`) come unprefixed.
import 'package:mocktail/mocktail.dart' hide any;
import 'package:mocktail/mocktail.dart' as mt show any;

import 'package:hearing_aid_app/data/bridges/audio_bridge.dart';
import 'package:hearing_aid_app/domain/audiogram_driven_presets/audiogram_driven_bundle.dart';
import 'package:hearing_aid_app/domain/audiogram_driven_presets/bundle_builder.dart';
import 'package:hearing_aid_app/domain/audiogram_driven_presets/manual_adjustment_delta.dart';
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

// ─── Mocks & fakes ─────────────────────────────────────────────────────────

class _MockAudioBridge extends Mock implements AudioBridge {}

class _MockAudiogramRepository extends Mock implements AudiogramRepository {}

class _MockProfileRepository extends Mock implements ProfileRepository {}

class _MockSettingsRepository extends Mock implements SettingsRepository {}

class _FakeAudioConfig extends Fake implements AudioConfig {}

class _FakeWdrcParams extends Fake implements WdrcParams {}

class _FakeAudiogram extends Fake implements Audiogram {}

// ─── Generators (seed-based, same pattern as the rest of property/) ───────

/// Convierte un seed `double ∈ [0, 120]` a 12 umbrales HL ∈ [0, 120] dB HL
/// en las frecuencias estándar del audiograma. Mantenido determinista para
/// que glados pueda shrinkear counterexamples.
Audiogram _seedToAudiogram(double seed) {
  const freqs = Audiogram.standardFrequencies;
  final thresholds = <int, double>{};
  for (var i = 0; i < 12; i++) {
    thresholds[freqs[i]] = ((seed * (i + 1) * 7.3) % 120.0).abs();
  }
  return Audiogram(thresholds: thresholds);
}

/// Convierte un seed `double ∈ [0, 100]` a un [ManualAdjustmentDelta]
/// con `eqDeltaDb` por banda en `[-10, +10] dB` y resto de campos en cero
/// (suficiente para que la 4-call sequence cubra el path con overlay).
ManualAdjustmentDelta _seedToDelta(double seed) {
  final eq = List<double>.generate(
    AudiogramDrivenBundle.bandCount,
    (i) => (((seed * (i + 1) * 3.7) % 20.0) - 10.0),
    growable: false,
  );
  return ManualAdjustmentDelta(
    eqDeltaDb: List<double>.unmodifiable(eq),
    volumeDeltaDb: 0.0,
    nrLevelDelta: 0,
    compressionRatioDelta: 0.0,
    compressionKneeDeltaDbSpl: 0.0,
    editedAt: DateTime.utc(2026, 6, 1),
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempHiveDir;
  late BundleBuilder builder;
  late GainPrescriber gainPrescriber;

  setUpAll(() async {
    registerFallbackValue(_FakeAudioConfig());
    registerFallbackValue(_FakeWdrcParams());
    registerFallbackValue(_FakeAudiogram());
    registerFallbackValue(PrescriberMode.smartNl2);
    registerFallbackValue(<double>[]);
    registerFallbackValue(0);

    // Hive sólo se inicializa una vez para el archivo: el bloc abre
    // `settings_box` con `_openSettingsBox`, que tolera Hive cerrado,
    // pero inicializarlo evita ruido de logs en cada uno de los 100+
    // runs de glados.
    tempHiveDir = await Directory.systemTemp.createTemp('apply_order_pbt_');
    Hive.init(tempHiveDir.path);
    builder = BundleBuilder();
    gainPrescriber = GainPrescriber();
  });

  tearDownAll(() async {
    await Hive.close();
    if (tempHiveDir.existsSync()) {
      try {
        await tempHiveDir.delete(recursive: true);
      } catch (_) {
        // Algunos backends mantienen handles abiertos en Windows; no fallar.
      }
    }
  });

  // ────────────────────────────────────────────────────────────────────────
  // 11.6 Atomic apply order
  // ────────────────────────────────────────────────────────────────────────
  group('AmplificationBloc · _onApplyBundle (Req 11.7) — atomic apply order', () {
    Glados3(
      any.doubleInRange(0, 120),
      any.intInRange(1, 95),
      any.doubleInRange(0, 100),
      ExploreConfig(numRuns: 100),
    ).test(
      '11.6 atomic apply ALWAYS issues exactly 4 calls in order: '
      'setMpoThresholdDbSpl → updateWdrcParams → updateEqGains → updateNrLevel',
      (audiogramSeed, age, deltaSeed) async {
        // ── 1. Generar inputs determinísticos a partir de los seeds. ──
        final audiogram = _seedToAudiogram(audiogramSeed);
        final patient = PatientProfile(
          experienceMonths: 24,
          ageYears: age,
        );
        final delta = _seedToDelta(deltaSeed);

        // ── 2. Construir el bundle con el BundleBuilder REAL. La regla
        //       pediátrica (age < 18) se ejercita aquí vía el
        //       PatientProfile (MpoDeriver lee `ageYears`). ──
        final bundle = builder.buildFromAudiogram(
          audiogram,
          profile: patient,
          mode: PrescriptionMode.quiet,
          operatingMode: OperatingMode.diagnostic,
          gainScale: 1.0,
          derivedAt: DateTime.utc(2026, 6, 1, 12, 0, 0),
        );

        // ── 3. Wirear bridge + repos mockeados. El callLog es local al
        //       run de glados — cada caso parte de cero, evitando
        //       contaminación cruzada entre shrink steps. ──
        final bridge = _MockAudioBridge();
        final audiogramRepo = _MockAudiogramRepository();
        final profileRepo = _MockProfileRepository();
        final settingsRepo = _MockSettingsRepository();

        final callLog = <String>[];

        when(() => bridge.inputLevelStream)
            .thenAnswer((_) => const Stream<double>.empty());
        when(() => bridge.stateStream)
            .thenAnswer((_) => const Stream<AudioEngineState>.empty());
        when(() => bridge.startAudio(mt.any())).thenAnswer((_) async {});
        when(() => bridge.stopAudio()).thenAnswer((_) async {});
        when(() => bridge.setMpoThresholdDbSpl(mt.any())).thenAnswer((_) async {
          callLog.add('setMpoThresholdDbSpl');
        });
        when(() => bridge.updateWdrcParams(mt.any())).thenAnswer((_) async {
          callLog.add('updateWdrcParams');
        });
        when(() => bridge.updateEqGains(mt.any())).thenAnswer((_) async {
          callLog.add('updateEqGains');
        });
        when(() => bridge.updateNrLevel(mt.any())).thenAnswer((_) async {
          callLog.add('updateNrLevel');
        });
        when(() => bridge.updateVolume(mt.any())).thenAnswer((_) async {});

        when(() => audiogramRepo.getAudiogram())
            .thenAnswer((_) async => audiogram);
        when(() => audiogramRepo.saveAudiogram(mt.any()))
            .thenAnswer((_) async {});

        when(() => profileRepo.getProfileByName(mt.any()))
            .thenAnswer((_) async => EnvironmentProfile.conversation);
        when(() => profileRepo.markCustomPresetsAsStale(
              mt.any(),
              thresholdDb: mt.any(named: 'thresholdDb'),
            )).thenAnswer((_) async => const <String>[]);

        when(() => settingsRepo.restoreLastConfig()).thenAnswer(
          (_) async => (lastProfile: 'Conversación', lastVolume: 0.0),
        );
        when(() => settingsRepo.setLastProfile(mt.any()))
            .thenAnswer((_) async {});
        when(() => settingsRepo.setLastVolume(mt.any()))
            .thenAnswer((_) async {});
        when(() => settingsRepo.getPrescriberMode())
            .thenAnswer((_) async => PrescriberMode.smartNl2);
        when(() => settingsRepo.setPrescriberMode(mt.any()))
            .thenAnswer((_) async {});
        when(() => settingsRepo.getExperienceMonths())
            .thenAnswer((_) async => 24);
        when(() => settingsRepo.setExperienceMonths(mt.any()))
            .thenAnswer((_) async {});

        final bloc = AmplificationBloc(
          audioBridge: bridge,
          audiogramRepository: audiogramRepo,
          profileRepository: profileRepo,
          settingsRepository: settingsRepo,
          gainPrescriber: gainPrescriber,
          bootDelay: Duration.zero,
        );

        try {
          // ── 4. Esperar el outcome del handler. _onApplyBundle emite o
          //       AmplificationActive.copyWith(...) (success path) o
          //       AmplificationError (validation/bridge failure). El
          //       state inicial es AmplificationIdle, así que en success
          //       NO se emite nada (no hay AmplificationActive previo).
          //       Por eso esperamos sobre el método de despacho del
          //       evento usando un Completer + listener temporal. ──
          final done = Completer<void>();
          final sub = bloc.stream.listen((s) {
            if (s is AmplificationError && !done.isCompleted) {
              done.completeError(
                StateError(
                  '_onApplyBundle emitió AmplificationError inesperado: '
                  '${s.message} (failedStep=${s.failedStep})',
                ),
              );
            }
          });

          bloc.add(ApplyAudiogramDrivenBundle(bundle: bundle, delta: delta));

          // El handler es async pero NO emite estado en success cuando el
          // state actual es Idle. Drenamos la cola dándole una ventana
          // suficiente para que las 4 llamadas al bridge se completen.
          // Cada una es un Future.value() inmediato — 50 ms es ~3 órdenes
          // de magnitud por encima del headroom esperado.
          await Future<void>.delayed(const Duration(milliseconds: 50));
          await sub.cancel();
          if (!done.isCompleted) done.complete();
          await done.future;

          // ── 5. Aserción central: la secuencia de calls al bridge es
          //       EXACTAMENTE las 4 documentadas, EN ORDEN. ──
          expect(
            callLog,
            equals(<String>[
              'setMpoThresholdDbSpl',
              'updateWdrcParams',
              'updateEqGains',
              'updateNrLevel',
            ]),
            reason: 'audiogramSeed=$audiogramSeed, age=$age, '
                'deltaSeed=$deltaSeed: la secuencia atómica de 4 calls al '
                'AudioBridge debe ser exactamente '
                '[setMpoThresholdDbSpl, updateWdrcParams, updateEqGains, '
                'updateNrLevel] en ese orden (Req 4.1, design.md '
                '§"Atomic apply"). Observado: $callLog',
          );

          // ── 6. Sanity checks redundantes con mocktail: cada método del
          //       bridge se invocó una sola vez. Refuerza la cardinalidad
          //       (ningún reintento accidental, ningún call extra). ──
          verify(() => bridge.setMpoThresholdDbSpl(mt.any())).called(1);
          verify(() => bridge.updateWdrcParams(mt.any())).called(1);
          verify(() => bridge.updateEqGains(mt.any())).called(1);
          verify(() => bridge.updateNrLevel(mt.any())).called(1);
        } finally {
          await bloc.close();
        }
      },
    );
  });
}
