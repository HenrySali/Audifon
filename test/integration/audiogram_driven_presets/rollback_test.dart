// Spec: audiogram-driven-presets · Wave 9, task 12.4 — Rollback test.
//
// Integration test for `AmplificationBloc._onApplyBundle` atomic rollback
// behaviour (see `memoria.md` §4.4 "_onApplyBundle con secuencia atómica
// de 4 calls"). The test wires a real [BundleBuilder] (no mock) into the
// bloc together with mocked repositories and a mocked [AudioBridge] that
// is configured to throw at step 3 (`updateEqGains`). The expected
// outcome is that the rollback restores the DSP state captured before
// the apply (in reverse order: 4 → 3 → 2 → 1, but only steps 2 and 1
// here because step 3 failed and step 4 was never reached) and that the
// bloc emits an [AmplificationError] with `failedStep == 3`.
//
// This test exercises:
//   - The atomic 4-call sequence in `_onApplyBundle`.
//   - The snapshot capture/restore logic in `_captureDspSnapshot` and
//     `_rollbackToSnapshot`.
//   - The preservation of `_lastBundle` on a failed apply (the failed
//     bundle must NOT replace the previous successful one).
//   - The `failedStep` field on [AmplificationError] (Req 4.7).
//
// Validates: Requirements 4.3
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
import 'package:hearing_aid_app/domain/entities/prescription_mode.dart';
import 'package:hearing_aid_app/domain/entities/wdrc_params.dart';
import 'package:hearing_aid_app/domain/gain_prescriber.dart';
import 'package:hearing_aid_app/domain/repositories/audiogram_repository.dart';
import 'package:hearing_aid_app/domain/repositories/profile_repository.dart';
import 'package:hearing_aid_app/domain/repositories/settings_repository.dart';
import 'package:hearing_aid_app/presentation/bloc/amplification_bloc.dart';
import 'package:hearing_aid_app/presentation/bloc/amplification_event.dart';
import 'package:hearing_aid_app/presentation/bloc/amplification_state.dart';

// ─── Mocks ─────────────────────────────────────────────────────────────────

class _MockAudioBridge extends Mock implements AudioBridge {}

class _MockAudiogramRepository extends Mock implements AudiogramRepository {}

class _MockProfileRepository extends Mock implements ProfileRepository {}

class _MockSettingsRepository extends Mock implements SettingsRepository {}

// Fakes used by `registerFallbackValue` for matchers like `any()` on
// non-nullable typed parameters.
class _FakeAudioConfig extends Fake implements AudioConfig {}

class _FakeWdrcParams extends Fake implements WdrcParams {}

class _FakeAudiogram extends Fake implements Audiogram {}

// ─── Helpers mirroring private bloc logic ──────────────────────────────────
//
// The bloc keeps `_resolveBroadbandMpo`, `_resolveBridgeCompressionRatio`,
// `_resolveBridgeCompressionKnee` private. To be able to assert on the
// values the rollback restores we mirror the formulas here. They are
// the documented contract of the bridge → bundle conversion (see
// design.md §"Atomic apply" and `amplification_bloc.dart`).

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

Audiogram _flatAudiogram(double thresholdDbHl) {
  final t = <int, double>{};
  for (final f in Audiogram.standardFrequencies) {
    t[f] = thresholdDbHl;
  }
  return Audiogram(thresholds: t);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late _MockAudioBridge bridge;
  late _MockAudiogramRepository audiogramRepo;
  late _MockProfileRepository profileRepo;
  late _MockSettingsRepository settingsRepo;
  late GainPrescriber gainPrescriber;
  late BundleBuilder builder;
  late Directory tempHiveDir;

  setUpAll(() async {
    registerFallbackValue(_FakeAudioConfig());
    registerFallbackValue(_FakeWdrcParams());
    registerFallbackValue(_FakeAudiogram());
    registerFallbackValue(PrescriberMode.smartNl2);
    // Inicializar Hive en un directorio temporal: la persistencia
    // de `_lastBundle`, `manual_delta_*` y `amplifier_gain_scale` es
    // best-effort y debe ser resiliente, pero inicializamos para evitar
    // ruido de logs.
    tempHiveDir = await Directory.systemTemp.createTemp('amp_rollback_test_');
    Hive.init(tempHiveDir.path);
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

  setUp(() {
    bridge = _MockAudioBridge();
    audiogramRepo = _MockAudiogramRepository();
    profileRepo = _MockProfileRepository();
    settingsRepo = _MockSettingsRepository();
    gainPrescriber = GainPrescriber();
    builder = BundleBuilder();

    // Bridge: streams vacíos + métodos de control en éxito por defecto.
    when(() => bridge.inputLevelStream)
        .thenAnswer((_) => const Stream<double>.empty());
    when(() => bridge.stateStream)
        .thenAnswer((_) => const Stream<AudioEngineState>.empty());
    when(() => bridge.startAudio(any())).thenAnswer((_) async {});
    when(() => bridge.stopAudio()).thenAnswer((_) async {});
    when(() => bridge.setMpoThresholdDbSpl(any())).thenAnswer((_) async {});
    when(() => bridge.updateWdrcParams(any())).thenAnswer((_) async {});
    when(() => bridge.updateEqGains(any())).thenAnswer((_) async {});
    when(() => bridge.updateNrLevel(any())).thenAnswer((_) async {});
    when(() => bridge.updateVolume(any())).thenAnswer((_) async {});

    // Repositorios con respuestas neutras.
    when(() => audiogramRepo.getAudiogram())
        .thenAnswer((_) async => Audiogram.defaultAudiogram());
    when(() => audiogramRepo.saveAudiogram(any())).thenAnswer((_) async {});

    when(() => profileRepo.getProfileByName(any()))
        .thenAnswer((_) async => EnvironmentProfile.conversation);
    when(() => profileRepo.markCustomPresetsAsStale(any()))
        .thenAnswer((_) async => const <String>[]);

    when(() => settingsRepo.restoreLastConfig()).thenAnswer(
      (_) async => (lastProfile: 'Conversación', lastVolume: 0.0),
    );
    when(() => settingsRepo.setLastProfile(any())).thenAnswer((_) async {});
    when(() => settingsRepo.setLastVolume(any())).thenAnswer((_) async {});
    when(() => settingsRepo.getPrescriberMode())
        .thenAnswer((_) async => PrescriberMode.smartNl2);
    when(() => settingsRepo.setPrescriberMode(any())).thenAnswer((_) async {});
    when(() => settingsRepo.getExperienceMonths())
        .thenAnswer((_) async => null);
  });

  AmplificationBloc buildBloc() => AmplificationBloc(
        audioBridge: bridge,
        audiogramRepository: audiogramRepo,
        profileRepository: profileRepo,
        settingsRepository: settingsRepo,
        gainPrescriber: gainPrescriber,
      );

  group('audiogram-driven-presets · _onApplyBundle rollback (Req 4.3)', () {
    test(
        'AudioBridge throws on step 3 (updateEqGains) → '
        'rollback restores steps 2 → 1 in reverse, '
        'step 4 never called, '
        'AmplificationError emitted with failedStep == 3, '
        '_lastBundle preserved (not replaced by failed bundle)',
        () async {
      // ── Build two distinct bundles via the real BundleBuilder so the
      // rollback assertions are unambiguous (different MPO/CR values). ──
      final fixedTime = DateTime.utc(2026, 6, 3, 12, 0, 0);
      final bundleA = builder.buildFromAudiogram(
        _flatAudiogram(30.0),
        mode: PrescriptionMode.quiet,
        operatingMode: OperatingMode.diagnostic,
        derivedAt: fixedTime,
      );
      final bundleB = builder.buildFromAudiogram(
        _flatAudiogram(60.0),
        mode: PrescriptionMode.quiet,
        operatingMode: OperatingMode.diagnostic,
        derivedAt: fixedTime,
      );

      // Sanity: bundleA y bundleB deben mapear a valores de bridge
      // distintos para que el rollback sea verificable.
      expect(
        _broadbandMpoOf(bundleA),
        isNot(equals(_broadbandMpoOf(bundleB))),
        reason: 'bundleA and bundleB must produce different broadband MPO',
      );
      expect(
        _bridgeCrOf(bundleA),
        isNot(equals(_bridgeCrOf(bundleB))),
        reason:
            'bundleA and bundleB must produce different bridge compression '
            'ratios so the rollback assertion is meaningful',
      );

      final bloc = buildBloc();
      addTearDown(bloc.close);

      // ── Step 0: aplicar bundleA con éxito para que `_lastBundle = bundleA`
      //          y por lo tanto el snapshot capturado para el segundo
      //          apply contenga los valores de bundleA. ──
      bloc.add(ApplyAudiogramDrivenBundle(bundle: bundleA));
      // El handler es async + el primer apply no emite nuevo estado
      // (state inicial es Idle, no Active). Drenar la cola de eventos.
      await Future<void>.delayed(const Duration(milliseconds: 50));

      // Confirmar que el primer apply fue completo (4/4 pasos).
      verify(() =>
              bridge.setMpoThresholdDbSpl(_broadbandMpoOf(bundleA))).called(1);
      verify(() => bridge.updateWdrcParams(any())).called(1);
      verify(() => bridge.updateEqGains(any())).called(1);
      verify(() => bridge.updateNrLevel(bundleA.nrLevel)).called(1);

      // Limpiar el historial de llamadas antes del apply fallido. Los
      // stubs se mantienen.
      clearInteractions(bridge);

      // ── Step 1: re-stub `updateEqGains` para que falle en el segundo
      //          apply (paso 3 de la secuencia atómica). ──
      when(() => bridge.updateEqGains(any()))
          .thenThrow(StateError('updateEqGains boom'));

      // Suscribir antes de despachar para evitar perder la emisión.
      final errorState = bloc.stream.firstWhere(
        (s) => s is AmplificationError,
      );

      bloc.add(ApplyAudiogramDrivenBundle(bundle: bundleB));

      final state = await errorState
          .timeout(const Duration(seconds: 2)) as AmplificationError;

      // ── Aserción 1: el estado emitido es AmplificationError(failedStep=3)
      //               con un mensaje que referencia el paso fallido. ──
      expect(state.failedStep, 3,
          reason: 'Failure occurred at step 3 (updateEqGains)');
      expect(state.message, contains('paso 3'),
          reason: 'Error message should reference the failed step');
      expect(state.validationErrors, isEmpty,
          reason: 'No validation errors — failure is from the bridge');

      // ── Aserción 2: setMpoThresholdDbSpl fue llamado dos veces:
      //               primero con bundleB (forward) y luego con bundleA
      //               (rollback paso 1). ──
      final mpoCaptured =
          verify(() => bridge.setMpoThresholdDbSpl(captureAny())).captured;
      expect(mpoCaptured, hasLength(2),
          reason:
              'setMpoThresholdDbSpl: 1 forward call + 1 rollback call');
      expect(
        mpoCaptured[0] as double,
        closeTo(_broadbandMpoOf(bundleB), 1e-9),
        reason: 'Forward call uses bundleB MPO',
      );
      expect(
        mpoCaptured[1] as double,
        closeTo(_broadbandMpoOf(bundleA), 1e-9),
        reason: 'Rollback restores bundleA MPO (snapshot)',
      );

      // ── Aserción 3: updateWdrcParams fue llamado dos veces, en orden
      //               forward(bundleB) → rollback(bundleA). ──
      final wdrcCaptured = verify(() => bridge.updateWdrcParams(captureAny()))
          .captured
          .cast<WdrcParams>();
      expect(wdrcCaptured, hasLength(2),
          reason: 'updateWdrcParams: 1 forward call + 1 rollback call');
      // Forward call (bundleB).
      expect(wdrcCaptured[0].compressionRatio,
          closeTo(_bridgeCrOf(bundleB), 1e-9));
      expect(wdrcCaptured[0].compressionKnee,
          closeTo(_bridgeKneeOf(bundleB), 1e-9));
      expect(wdrcCaptured[0].expansionKnee, equals(bundleB.expansionKneeDbSpl));
      expect(wdrcCaptured[0].attackMs, equals(bundleB.wdrcAttackMs));
      expect(wdrcCaptured[0].releaseMs, equals(bundleB.wdrcReleaseMs));
      // Rollback call (bundleA).
      expect(wdrcCaptured[1].compressionRatio,
          closeTo(_bridgeCrOf(bundleA), 1e-9));
      expect(wdrcCaptured[1].compressionKnee,
          closeTo(_bridgeKneeOf(bundleA), 1e-9));
      expect(wdrcCaptured[1].expansionKnee, equals(bundleA.expansionKneeDbSpl));
      expect(wdrcCaptured[1].attackMs, equals(bundleA.wdrcAttackMs));
      expect(wdrcCaptured[1].releaseMs, equals(bundleA.wdrcReleaseMs));

      // ── Aserción 4: updateEqGains fue llamado UNA sola vez (la llamada
      //               forward que lanzó). No hay rollback de paso 3
      //               porque `reachedStep < 3` cuando se disparó la
      //               excepción. ──
      verify(() => bridge.updateEqGains(any())).called(1);

      // ── Aserción 5: updateNrLevel NO fue llamado — el paso 4 nunca se
      //               alcanzó porque la secuencia atómica abortó en el 3. ──
      verifyNever(() => bridge.updateNrLevel(any()));

      // ── Aserción 6: `_lastBundle` no fue reemplazado por bundleB.
      //               Verificación indirecta: ResetManualDelta re-despacha
      //               ApplyAudiogramDrivenBundle con `_lastBundle ??
      //               _buildBundleForCurrentMode()`. Si la rollback
      //               preservó `_lastBundle == bundleA`, el bridge
      //               recibirá los valores de bundleA. ──
      clearInteractions(bridge);
      // Restaurar updateEqGains a éxito para el follow-up.
      when(() => bridge.updateEqGains(any())).thenAnswer((_) async {});

      bloc.add(const ResetManualDelta());
      await Future<void>.delayed(const Duration(milliseconds: 50));

      final preservedMpo =
          verify(() => bridge.setMpoThresholdDbSpl(captureAny())).captured;
      expect(preservedMpo, hasLength(1),
          reason:
              'After reset only one forward apply should reach the bridge');
      expect(
        preservedMpo.single as double,
        closeTo(_broadbandMpoOf(bundleA), 1e-9),
        reason:
            'If `_lastBundle` had been replaced by the failed bundleB, the '
            'bridge would receive bundleB MPO. Receiving bundleA confirms '
            'the rollback preserved `_lastBundle = bundleA`.',
      );

      final preservedWdrc = verify(() => bridge.updateWdrcParams(captureAny()))
          .captured
          .cast<WdrcParams>();
      expect(preservedWdrc, hasLength(1));
      expect(preservedWdrc.single.compressionRatio,
          closeTo(_bridgeCrOf(bundleA), 1e-9));
      verify(() => bridge.updateEqGains(any())).called(1);
      verify(() => bridge.updateNrLevel(bundleA.nrLevel)).called(1);
    });
  });
}
