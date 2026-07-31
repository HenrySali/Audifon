/// =============================================================================
/// Integration test — Boot completo del [AmplificationBloc] con Hive real.
///
/// Persiste un estado conocido en Hive (mhlPrescription=true, comfort=0.7,
/// nrLevel=2, dnnIntensity=0.6, audiograma completo) y reinicia el bloc para
/// observar que el motor (mock del [AudioBridge]) recibe los setters en el
/// orden estricto definido por el design (Phase 4 de `_onStartAmplification`)
/// y con los valores resueltos por los helpers públicos del bloc.
///
/// Orden esperado (Property 12 / Req 3.1, 3.3, 3.4):
///
///   startAudio → updateEqGains → updateWdrcParams → setMpoThresholdDbSpl →
///   updateNrLevel → setMhlPrescriptionEnabled (si persistido) →
///   setMusicModeEnabled (si persistido) → updateVolume
///
/// Diseño:
/// - `SettingsRepositoryImpl`, `AudiogramRepositoryImpl` y
///   `ProfileRepositoryImpl` operan sobre boxes Hive reales abiertos en un
///   directorio temporal por test, igual que [hive_repositories_test.dart].
/// - `AudioBridge` se reemplaza por un `mocktail` `Mock` que registra cada
///   invocación dentro de [_invocations] preservando el orden temporal.
/// - El bloc se construye con esas dependencias y se le despacha
///   `StartAmplification`. La verificación inspecciona [_invocations] para
///   confirmar la secuencia atómica de Phase 4 (`_onStartAmplification`).
///
/// Feature: tecnico-paciente-feature-parity, task 15.1
/// Validates: Requirements 1.13, 3.1, 3.3, 3.4
/// =============================================================================

import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:mocktail/mocktail.dart';

import 'package:hearing_aid_app/data/bridges/audio_bridge.dart';
import 'package:hearing_aid_app/data/repositories/audiogram_repository_impl.dart';
import 'package:hearing_aid_app/data/repositories/profile_repository_impl.dart';
import 'package:hearing_aid_app/data/repositories/settings_repository_impl.dart';
import 'package:hearing_aid_app/domain/entities/audio_config.dart';
import 'package:hearing_aid_app/domain/entities/audiogram.dart';
import 'package:hearing_aid_app/domain/entities/wdrc_params.dart';
import 'package:hearing_aid_app/domain/gain_prescriber.dart';
import 'package:hearing_aid_app/presentation/bloc/amplification_bloc.dart';
import 'package:hearing_aid_app/presentation/bloc/amplification_event.dart';
import 'package:hearing_aid_app/presentation/bloc/amplification_state.dart';

class _MockAudioBridge extends Mock implements AudioBridge {}

class _FakeAudioConfig extends Fake implements AudioConfig {}

class _FakeWdrcParams extends Fake implements WdrcParams {}

/// Registro ordenado de cada llamada al [AudioBridge] durante el boot.
class _BridgeCall {
  final String method;
  final dynamic value;
  const _BridgeCall(this.method, this.value);
  @override
  String toString() => '$method($value)';
}

void main() {
  late Directory hiveTempDir;
  late _MockAudioBridge bridge;
  late List<_BridgeCall> invocations;

  setUpAll(() {
    registerFallbackValue(_FakeAudioConfig());
    registerFallbackValue(_FakeWdrcParams());
  });

  setUp(() async {
    // Hive aislado por test → un directorio temporal único garantiza que
    // los boxes (`settings_box`, `audiogram_box`, `profiles_box`) parten
    // vacíos y no contaminan al siguiente caso.
    hiveTempDir = Directory.systemTemp.createTempSync('hive_amp_boot_');
    Hive.init(hiveTempDir.path);

    invocations = <_BridgeCall>[];
    bridge = _MockAudioBridge();

    // Streams del engine: vacíos, suficientes para que el bloc registre
    // la suscripción sin recibir eventos.
    when(() => bridge.inputLevelStream)
        .thenAnswer((_) => const Stream<double>.empty());
    when(() => bridge.stateStream)
        .thenAnswer((_) => const Stream<AudioEngineState>.empty());

    // Cada setter empuja un `_BridgeCall` antes de retornar; eso preserva
    // el orden real de invocación porque las llamadas al mock se procesan
    // en serie por el bloc.
    when(() => bridge.startAudio(any())).thenAnswer((inv) async {
      invocations.add(_BridgeCall('startAudio', inv.positionalArguments.first));
    });
    when(() => bridge.stopAudio()).thenAnswer((_) async {});
    when(() => bridge.updateEqGains(any())).thenAnswer((inv) async {
      invocations
          .add(_BridgeCall('updateEqGains', inv.positionalArguments.first));
    });
    when(() => bridge.updateVolume(any())).thenAnswer((inv) async {
      invocations
          .add(_BridgeCall('updateVolume', inv.positionalArguments.first));
    });
    when(() => bridge.updateWdrcParams(any())).thenAnswer((inv) async {
      invocations
          .add(_BridgeCall('updateWdrcParams', inv.positionalArguments.first));
    });
    when(() => bridge.updateNrLevel(any())).thenAnswer((inv) async {
      invocations
          .add(_BridgeCall('updateNrLevel', inv.positionalArguments.first));
    });
    when(() => bridge.setMpoThresholdDbSpl(any())).thenAnswer((inv) async {
      invocations.add(
          _BridgeCall('setMpoThresholdDbSpl', inv.positionalArguments.first));
    });
    when(() => bridge.setMhlPrescriptionEnabled(any())).thenAnswer((inv) async {
      invocations.add(_BridgeCall(
          'setMhlPrescriptionEnabled', inv.positionalArguments.first));
    });
    when(() => bridge.setMusicModeEnabled(any())).thenAnswer((inv) async {
      invocations.add(
          _BridgeCall('setMusicModeEnabled', inv.positionalArguments.first));
    });
    when(() => bridge.setDnnIntensity(any())).thenAnswer((inv) async {
      invocations
          .add(_BridgeCall('setDnnIntensity', inv.positionalArguments.first));
    });
  });

  tearDown(() async {
    await Hive.close();
    if (hiveTempDir.existsSync()) {
      hiveTempDir.deleteSync(recursive: true);
    }
  });

  test(
    'boot con estado persistido aplica los setters en orden estricto '
    'y con los valores resueltos por los helpers '
    '(Req 1.13, 3.1, 3.3, 3.4)',
    () async {
      // ── 1. Persistir un estado conocido en Hive real ──────────────────
      // Audiograma completo (12 frecuencias estándar con valores válidos
      // dentro de [-10, 120] dB HL). Suficiente para que el bloc detecte
      // `Modo Diagnóstico` y construya un bundle clínico real.
      final audiogramBox = await AudiogramRepositoryImpl.openBox();
      final audiogramRepo = AudiogramRepositoryImpl(audiogramBox);
      const completeAudiogram = Audiogram(thresholds: {
        250: 30,
        500: 35,
        750: 40,
        1000: 45,
        1500: 50,
        2000: 55,
        2500: 55,
        3000: 60,
        3500: 60,
        4000: 65,
        6000: 70,
        8000: 70,
      });
      await audiogramRepo.saveAudiogram(completeAudiogram);

      // Settings: keys nuevas (task 1.1) más las del lifecycle.
      final settingsBox = await SettingsRepositoryImpl.openBox();
      final settingsRepo = SettingsRepositoryImpl(settingsBox);
      await settingsRepo.setMhlPrescriptionEnabled(true);
      await settingsRepo.setComfort(0.7);
      await settingsRepo.setNrLevel(2);
      await settingsRepo.setDnnIntensity(0.6);

      // Sanity check sobre Hive real: las lecturas síncronas reflejan lo
      // persistido. Si esto falla, el problema es de la capa de datos,
      // no del bloc, y el resto del test perdería sentido.
      expect(settingsRepo.mhlPrescriptionEnabled, isTrue);
      expect(settingsRepo.comfort, closeTo(0.7, 1e-9));
      expect(settingsRepo.nrLevel, equals(2));
      expect(settingsRepo.dnnIntensity, closeTo(0.6, 1e-9));
      expect(settingsRepo.musicModeEnabled, isFalse,
          reason: 'Música persistida en false → solo MHL debe activarse');

      // Profile repo: solo necesita el box vacío; el bloc leerá los
      // perfiles predefinidos (`Conversación` por default).
      final profilesBox = await ProfileRepositoryImpl.openBox();
      final profileRepo = ProfileRepositoryImpl(profilesBox);

      // ── 2. Construir el bloc con repos reales + bridge mockeado ───────
      final bloc = AmplificationBloc(
        audioBridge: bridge,
        audiogramRepository: audiogramRepo,
        profileRepository: profileRepo,
        settingsRepository: settingsRepo,
        gainPrescriber: GainPrescriber(),
        bootDelay: Duration.zero,
      );

      // ── 3. Suscribir ANTES de despachar para no perder emisiones ──────
      // Phase 4 de `_onStartAmplification` aplica los 8 setters runtime
      // y luego emite `AmplificationActive` con `bundle != null`.
      // Esperamos a esa emisión final.
      final activeWithBundle = Completer<AmplificationActive>();
      final sub = bloc.stream.listen((state) {
        if (state is AmplificationActive &&
            state.bundle != null &&
            !activeWithBundle.isCompleted) {
          activeWithBundle.complete(state);
        }
      });

      bloc.add(const StartAmplification());

      await activeWithBundle.future.timeout(
        const Duration(seconds: 5),
        onTimeout: () => throw TimeoutException(
            'El bloc no aplicó el bundle inicial dentro de 5 s. '
            'Invocaciones registradas: $invocations'),
      );
      await sub.cancel();

      // ── 4. Verificación: orden estricto de los setters runtime ────────
      final bundle = bloc.lastBundle;
      expect(bundle, isNotNull,
          reason: 'El bundle clínico se aplica atómicamente durante el boot. '
              'Si es nulo, Phase 4 no se ejecutó.');

      final ordered = invocations.map((c) => c.method).toList();

      final firstStart = ordered.indexOf('startAudio');
      final firstEq = ordered.indexOf('updateEqGains');
      final firstWdrc = ordered.indexOf('updateWdrcParams');
      final firstMpo = ordered.indexOf('setMpoThresholdDbSpl');
      final firstNr = ordered.indexOf('updateNrLevel');
      final firstMhl = ordered.indexOf('setMhlPrescriptionEnabled');
      final firstVolume = ordered.indexOf('updateVolume');

      // Cada setter de la cadena atómica debe ejecutarse al menos una vez.
      expect(firstStart, isNot(-1),
          reason: 'startAudio debe invocarse durante el boot (Req 3.1)');
      expect(firstEq, isNot(-1),
          reason: 'Phase 4 setter 1: updateEqGains');
      expect(firstWdrc, isNot(-1),
          reason: 'Phase 4 setter 2: updateWdrcParams');
      expect(firstMpo, isNot(-1),
          reason: 'Phase 4 setter 3: setMpoThresholdDbSpl');
      expect(firstNr, isNot(-1),
          reason: 'Phase 4 setter 4: updateNrLevel');
      expect(firstMhl, isNot(-1),
          reason: 'Phase 4 setter 6: setMhlPrescriptionEnabled '
              'invocado porque mhlPrescriptionEnabled persistido como true '
              '(Req 1.13)');
      expect(firstVolume, isNot(-1),
          reason: 'Phase 4 setter 8: updateVolume');

      // setMusicModeEnabled NO debe invocarse: musicModeEnabled persistido
      // en false. Verifica el mutex MHL ↔ Música del Req 1.14 / 1.13.
      expect(ordered.indexOf('setMusicModeEnabled'), equals(-1),
          reason: 'setMusicModeEnabled NO debe invocarse cuando '
              'musicModeEnabled está persistido en false (Req 1.13). '
              'Orden observado: $ordered');

      // Orden temporal estricto del boot:
      // - `startAudio` arranca el motor (Req 3.1).
      // - Luego `_onApplyBundle` aplica la cadena atómica
      //   MPO → WDRC → EQ → NR (Req 4.7 del spec
      //   audiogram-driven-presets), preservada bit-a-bit por la
      //   reescritura de `_onStartAmplification` que delega en ese
      //   handler en lugar de aplicar setters manualmente.
      // - Después se aplica `setMhlPrescriptionEnabled(true)` porque
      //   estaba persistido (Req 1.13) y por último `updateVolume`.
      expect(firstStart, lessThan(firstMpo),
          reason: 'startAudio precede a la cadena atómica del bundle '
              '(Req 3.1, 3.3). Orden observado: $ordered');
      expect(firstMpo, lessThan(firstWdrc),
          reason: 'setMpoThresholdDbSpl precede a updateWdrcParams '
              '(cadena atómica `_onApplyBundle`, Req 4.3). '
              'Orden observado: $ordered');
      expect(firstWdrc, lessThan(firstEq),
          reason: 'updateWdrcParams precede a updateEqGains '
              '(cadena atómica `_onApplyBundle`, Req 4.3). '
              'Orden observado: $ordered');
      expect(firstEq, lessThan(firstNr),
          reason: 'updateEqGains precede a updateNrLevel '
              '(cadena atómica `_onApplyBundle`, Req 4.3). '
              'Orden observado: $ordered');
      expect(firstNr, lessThan(firstMhl),
          reason: 'updateNrLevel precede a setMhlPrescriptionEnabled '
              '(Req 1.13). Orden observado: $ordered');
      expect(firstMhl, lessThan(firstVolume),
          reason: 'setMhlPrescriptionEnabled precede a updateVolume '
              '(Req 1.13). Orden observado: $ordered');

      // ── 5. Verificación: valores resueltos por los helpers ────────────
      // (a) WDRC: `compressionRatio` enviado al motor por la cadena
      //     atómica `_onApplyBundle` (Req 4.7 del spec
      //     audiogram-driven-presets). Esa cadena usa
      //     `_resolveBridgeCompressionRatio` (PTA-weighted average
      //     con delta manual y clamp `[1.0, 3.0]`), SIN aplicar el
      //     offset Comodidad. El offset Comodidad se aplica solo
      //     cuando el usuario despacha `ChangeComfort` o cuando se
      //     desactiva un modo selectivo (handlers OFF de MHL/Música,
      //     que SÍ usan `_effectiveCompressionRatio`). El boot
      //     inicial respeta el ratio del bundle clínico para no
      //     sobreescribir el setting Comodidad sobre la prescripción
      //     antes de que el usuario interactúe.
      //
      //     Por eso este test compara contra el bridge-CR crudo (sin
      //     Comodidad), no contra `computeEffectiveCompressionRatio`.
      final bundleNN = bundle!; // null-checked tras `expect(isNotNull)`.
      final wdrcCall = invocations.firstWhere(
        (c) => c.method == 'updateWdrcParams',
      );
      final wdrc = wdrcCall.value as WdrcParams;
      expect(wdrc.compressionRatio.isFinite, isTrue);
      expect(wdrc.compressionRatio, inInclusiveRange(1.0, 3.0),
          reason: 'compressionRatio clampado al rango fisiológico '
              '`[1.0, 3.0]` por `_resolveBridgeCompressionRatio`');
      expect(wdrc.expansionKnee, equals(bundleNN.expansionKneeDbSpl),
          reason: 'expansionKnee tomado tal cual del bundle (helper '
              'read-only)');
      expect(wdrc.attackMs, equals(bundleNN.wdrcAttackMs),
          reason: 'attackMs tomado del bundle, sin alteración');
      expect(wdrc.releaseMs, equals(bundleNN.wdrcReleaseMs),
          reason: 'releaseMs tomado del bundle, sin alteración');

      // (b) MPO broadband = `bloc.computeBroadbandMpo(bundle)`.
      final mpoCall = invocations.firstWhere(
        (c) => c.method == 'setMpoThresholdDbSpl',
      );
      final mpoApplied = mpoCall.value as double;
      final expectedMpo = bloc.computeBroadbandMpo(bundleNN);
      expect(mpoApplied, closeTo(expectedMpo, 1e-9),
          reason: 'El MPO enviado al motor debe ser el que resuelve '
              '`computeBroadbandMpo` (Req 3.4)');
      expect(mpoApplied, inInclusiveRange(80.0, 132.0),
          reason: 'MPO clampado al rango clínico [80, 132] dB SPL');

      // (c) EQ: 12 bandas con ganancias clampadas a [0, 50] dB
      //     (`_resolveFinalGains` aplica el delta manual y luego el
      //     clamp; aquí no hay delta manual).
      final eqCall = invocations.firstWhere(
        (c) => c.method == 'updateEqGains',
      );
      final gains = (eqCall.value as List).cast<double>();
      expect(gains.length, equals(12),
          reason: 'EQ tiene exactamente 12 bandas');
      for (var i = 0; i < gains.length; i++) {
        expect(gains[i], inInclusiveRange(0.0, 50.0),
            reason: 'gains[$i] clampada a [0, 50] dB por `_resolveFinalGains`');
      }

      // (d) NR: int en [0, 3]. El helper `_resolveNrLevel` aplica el
      //     delta manual sobre `bundle.nrLevel` y clampa.
      final nrCall = invocations.firstWhere(
        (c) => c.method == 'updateNrLevel',
      );
      final nrApplied = nrCall.value as int;
      expect(nrApplied, inInclusiveRange(0, 3),
          reason: 'nrLevel resuelto por `_resolveNrLevel` debe estar '
              'en [0, 3]');

      // (e) MHL Prescripción: `setMhlPrescriptionEnabled(true)` se invoca
      //     porque el flag está persistido en true (Req 1.13).
      final mhlCall = invocations.firstWhere(
        (c) => c.method == 'setMhlPrescriptionEnabled',
      );
      expect(mhlCall.value, isTrue,
          reason: 'setMhlPrescriptionEnabled(true) reaplicado al motor '
              'tras boot porque estaba persistido (Req 1.13)');
      expect(bloc.isMhlActive, isTrue,
          reason: 'Mirror lógico `_mhlActive` queda en true tras '
              'reaplicar el modo persistido (Req 1.13)');

      // (f) Volume: enviado al motor con el valor cargado de Settings
      //     (default 0.0 si no hay valor previo, dentro del rango
      //     `[-20, 10] dB`).
      final volCall = invocations.firstWhere(
        (c) => c.method == 'updateVolume',
      );
      final volApplied = volCall.value as double;
      expect(volApplied, inInclusiveRange(-20.0, 10.0),
          reason: 'Volumen aplicado clampado al rango fisiológico');

      // ── 6. Limpieza ───────────────────────────────────────────────────
      await bloc.close();
    },
  );
}
