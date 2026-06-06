/// Tests del SceneGenericPresetGenerator y ScenePersonalizedPresetGenerator
/// (Fase 3, refactor audiogram-driven-presets task 6.1/6.3).
///
/// Validates: Requirements 7.1, 7.4, 7.5, 7.6, 10.3, 10.4, 10.6

import 'package:flutter_test/flutter_test.dart';

import 'package:hearing_aid_app/domain/audiogram_driven_presets/audiogram_driven_bundle.dart';
import 'package:hearing_aid_app/domain/audiogram_driven_presets/bundle_builder.dart';
import 'package:hearing_aid_app/domain/audiogram_driven_presets/operating_mode.dart';
import 'package:hearing_aid_app/domain/entities/audiogram.dart';
import 'package:hearing_aid_app/domain/entities/loss_type.dart';
import 'package:hearing_aid_app/domain/entities/prescription_mode.dart';
import 'package:hearing_aid_app/scene/scene_personalized_generator.dart';
import 'package:hearing_aid_app/scene/scene_preset_generator.dart';
import 'package:hearing_aid_app/scene/scene_snapshot.dart';

import 'scene_decision_maker_test.dart' show makeSnap;

/// Audiograma sintético: pérdida moderada en agudos (presbiacusia típica).
Audiogram _moderateHighLossAudiogram() {
  return const Audiogram(thresholds: <int, double>{
    250: 15,
    500: 20,
    750: 25,
    1000: 30,
    1500: 35,
    2000: 40,
    2500: 45,
    3000: 50,
    3500: 50,
    4000: 50,
    6000: 45,
    8000: 40,
  });
}

/// Bundle sintético construido del audiograma anterior. Usamos
/// `BundleBuilder` para generar valores plausibles, garantizando que
/// los tests refleien el flujo real (Req 7.1, 7.4).
AudiogramDrivenBundle _bundleFromAudiogram(Audiogram a) {
  return BundleBuilder().buildFromAudiogram(
    a,
    mode: PrescriptionMode.quiet,
    derivedAt: DateTime.utc(2026, 1, 1),
  );
}

/// Bundle sintético controlado: ganancias planas y MPO uniforme. Útil
/// para tests donde queremos verificar el comportamiento del generador
/// sin depender de la prescripción real.
AudiogramDrivenBundle _flatBundle({
  double gainDb = 20.0,
  double mpoDbSpl = 110.0,
}) {
  return AudiogramDrivenBundle(
    gainsDb: List<double>.filled(12, gainDb),
    compressionRatios: List<double>.filled(12, 1.5),
    compressionKneesDbSpl: List<double>.filled(12, 50.0),
    mpoProfileDbSpl: List<double>.filled(12, mpoDbSpl),
    nrLevel: 1,
    wdrcAttackMs: 5.0,
    wdrcReleaseMs: 100.0,
    expansionKneeDbSpl: 35.0,
    lossType: LossType.flat,
    prescriptionMode: PrescriptionMode.quiet,
    mode: OperatingMode.diagnostic,
    gainScale: 1.0,
    derivedAt: DateTime.utc(2026, 1, 1),
  );
}

void main() {
  group('SceneGenericPresetGenerator (bundle-based)', () {
    final gen = SceneGenericPresetGenerator();
    final bundle = _flatBundle(gainDb: 15.0);

    test('genera preset para silencio sin amplificación extra', () {
      final snap = makeSnap(inputDbSpl: 30.0);
      final p = gen.generate(
        bundle: bundle,
        sceneClass: SceneClass.silence,
        snapshot: snap,
        confidence: 0.9,
      );
      expect(p.isPersonalized, isFalse);
      expect(p.sceneClass, SceneClass.silence);
      expect(p.gains.length, 12);
      expect(p.gains.every((g) => g >= 0 && g <= 50), isTrue);
      expect(p.nrLevel, 0);
      expect(p.tnrEnabled, isFalse);
    });

    test('voiceInNoiseLow → NR alto, TNR ON, volumen reducido', () {
      final snap = makeSnap(inputDbSpl: 65.0);
      final p = gen.generate(
        bundle: bundle,
        sceneClass: SceneClass.voiceInNoiseLow,
        snapshot: snap,
        confidence: 0.7,
      );
      expect(p.nrLevel, 3);
      expect(p.tnrEnabled, isTrue);
      expect(p.volumeDeltaDb, lessThan(0.0));
    });

    test('música → NR off, baja CR, sin delta de volumen', () {
      final snap = makeSnap(inputDbSpl: 65.0);
      final p = gen.generate(
        bundle: bundle,
        sceneClass: SceneClass.music,
        snapshot: snap,
        confidence: 0.8,
      );
      expect(p.nrLevel, 0);
      expect(p.tnrEnabled, isFalse);
      expect(p.compressionRatio, lessThan(1.5));
      expect(p.volumeDeltaDb, 0.0);
    });

    test('todas las clases producen presets con 12 ganancias válidas', () {
      final snap = makeSnap(inputDbSpl: 65.0);
      for (final cls in SceneClass.values) {
        final p = gen.generate(
          bundle: bundle,
          sceneClass: cls,
          snapshot: snap,
          confidence: 0.5,
        );
        expect(p.gains.length, 12, reason: cls.name);
        expect(p.gains.every((g) => g >= 0 && g <= 50), isTrue,
            reason: cls.name);
      }
    });

    test('input alto recorta las ganancias al headroom MPO por banda', () {
      // input 100 dB SPL → headroom = 110 - 100 - 3 = 7 dB.
      final snap = makeSnap(inputDbSpl: 100.0);
      final p = gen.generate(
        bundle: bundle,
        sceneClass: SceneClass.voiceOnly,
        snapshot: snap,
        confidence: 0.8,
      );
      expect(p.gains.every((g) => g <= 7.0 + 1e-6), isTrue);
      expect(p.clampedBands, isNotEmpty);
    });
  });

  group('ScenePersonalizedPresetGenerator (bundle-based)', () {
    final gen = ScenePersonalizedPresetGenerator(safetyMarginDb: 3.0);
    final audiogram = _moderateHighLossAudiogram();
    final bundle = _bundleFromAudiogram(audiogram);

    test('voiceOnly: ganancias > 0 en agudos, no exceden headroom', () {
      final snap = makeSnap(inputDbSpl: 65.0, voiceActive: true, snrDb: 18.0);
      final p = gen.generate(
        bundle: bundle,
        sceneClass: SceneClass.voiceOnly,
        snapshot: snap,
        confidence: 0.85,
      );
      expect(p.isPersonalized, isTrue);
      expect(p.gains.length, 12);
      // headroom por banda = mpoProfile[i] - 65 - 3 (con clamp a 50).
      for (var i = 0; i < 12; i++) {
        final headroom =
            (bundle.mpoProfileDbSpl[i] - 65.0 - 3.0).clamp(0.0, 50.0);
        expect(p.gains[i], lessThanOrEqualTo(headroom + 1e-6),
            reason: 'banda $i debe respetar headroom MPO');
      }
      // Bandas medias deberían tener ganancia > 0.
      expect(p.gains[3], greaterThan(0.0));
      expect(p.gains[5], greaterThan(0.0));
    });

    test('voiceInNoiseLow: graves se atenúan respecto al base', () {
      final snap = makeSnap(inputDbSpl: 70.0, voiceActive: true);
      final pVoice = gen.generate(
        bundle: bundle,
        sceneClass: SceneClass.voiceOnly,
        snapshot: snap,
        confidence: 0.8,
      );
      final pVoiceLow = gen.generate(
        bundle: bundle,
        sceneClass: SceneClass.voiceInNoiseLow,
        snapshot: snap,
        confidence: 0.8,
      );
      // Graves deberían ser menores en voiceInNoiseLow (-6 dB delta).
      for (var i = 0; i < 3; i++) {
        expect(pVoiceLow.gains[i], lessThanOrEqualTo(pVoice.gains[i]),
            reason: 'banda $i debería bajar con voiceInNoiseLow');
      }
    });

    test('headroom safety: input alto reduce maxSafeGain por banda', () {
      // input 100 dB SPL → maxSafe[i] = mpoProfile[i] - 100 - 3.
      final snapHigh = makeSnap(inputDbSpl: 100.0);
      final p = gen.generate(
        bundle: bundle,
        sceneClass: SceneClass.voiceOnly,
        snapshot: snapHigh,
        confidence: 0.8,
      );
      for (var i = 0; i < 12; i++) {
        final maxSafe =
            (bundle.mpoProfileDbSpl[i] - 100.0 - 3.0).clamp(0.0, 50.0);
        expect(p.gains[i], lessThanOrEqualTo(maxSafe + 1e-6),
            reason: 'banda $i excede headroom para input alto');
      }
    });

    test('clampedBands se popula cuando las bandas superan headroom', () {
      // Forzar bandas con target alto y MPO bajo: bundle de prueba con
      // ganancias=40 dB y MPO=90 dB SPL. Para input=65 dB SPL:
      // headroom = 90 - 65 - 3 = 22 dB ⇒ todas las bandas deberían
      // recortarse desde 40 a 22.
      final tightBundle = _flatBundle(gainDb: 40.0, mpoDbSpl: 90.0);
      final snap = makeSnap(inputDbSpl: 65.0);
      final p = gen.generate(
        bundle: tightBundle,
        sceneClass: SceneClass.voiceOnly,
        snapshot: snap,
        confidence: 0.8,
      );
      expect(p.clampedBands.length, 12);
      expect(p.gains.every((g) => g <= 22.0 + 1e-6), isTrue);
    });

    test('todas las ganancias quedan dentro de [0, 50]', () {
      final snap = makeSnap(inputDbSpl: 60.0);
      for (final cls in SceneClass.values) {
        final p = gen.generate(
          bundle: bundle,
          sceneClass: cls,
          snapshot: snap,
          confidence: 0.5,
        );
        for (final g in p.gains) {
          expect(g, greaterThanOrEqualTo(0.0), reason: cls.name);
          expect(g, lessThanOrEqualTo(50.0), reason: cls.name);
        }
      }
    });

    test('preset isPersonalized=true y nombre lleva prefijo SmartScenePerso', () {
      final snap = makeSnap(inputDbSpl: 65.0);
      final p = gen.generate(
        bundle: bundle,
        sceneClass: SceneClass.voiceOnly,
        snapshot: snap,
        confidence: 0.7,
      );
      expect(p.isPersonalized, isTrue);
      expect(p.name, startsWith('SmartScenePerso_'));
    });
  });
}
