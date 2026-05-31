/// Tests del SceneGenericPresetGenerator y ScenePersonalizedPresetGenerator
/// (Fase 3).
///
/// Validates: Requirements 3.1, 3.2, 3.3, 3.5, 3.6, 3.7

import 'package:flutter_test/flutter_test.dart';

import 'package:hearing_aid_app/domain/entities/audiogram.dart';
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

void main() {
  group('SceneGenericPresetGenerator', () {
    final gen = SceneGenericPresetGenerator();

    test('genera preset para silencio sin amplificación', () {
      final p = gen.generate(SceneClass.silence, confidence: 0.9);
      expect(p.isPersonalized, isFalse);
      expect(p.sceneClass, SceneClass.silence);
      expect(p.gains.length, 12);
      expect(p.gains.every((g) => g >= 0 && g <= 50), isTrue);
      expect(p.nrLevel, 0);
      expect(p.tnrEnabled, isFalse);
    });

    test('voiceInNoiseLow → NR alto, TNR ON, volumen reducido', () {
      final p = gen.generate(SceneClass.voiceInNoiseLow, confidence: 0.7);
      expect(p.nrLevel, 3);
      expect(p.tnrEnabled, isTrue);
      expect(p.volumeDeltaDb, lessThan(0.0));
    });

    test('música → NR off, baja CR, sin delta de volumen', () {
      final p = gen.generate(SceneClass.music, confidence: 0.8);
      expect(p.nrLevel, 0);
      expect(p.tnrEnabled, isFalse);
      expect(p.compressionRatio, lessThan(1.5));
      expect(p.volumeDeltaDb, 0.0);
    });

    test('todas las clases producen presets con 12 ganancias válidas', () {
      for (final cls in SceneClass.values) {
        final p = gen.generate(cls, confidence: 0.5);
        expect(p.gains.length, 12, reason: cls.name);
        expect(p.gains.every((g) => g >= 0 && g <= 50), isTrue,
            reason: cls.name);
      }
    });
  });

  group('ScenePersonalizedPresetGenerator', () {
    final gen = ScenePersonalizedPresetGenerator(
      mpoThresholdDbSpl: 110.0,
      safetyMarginDb: 3.0,
    );
    final audiogram = _moderateHighLossAudiogram();

    test('voiceOnly: ganancias > 0 en agudos, no exceden headroom', () {
      final snap = makeSnap(inputDbSpl: 65.0, voiceActive: true, snrDb: 18.0);
      final p = gen.generate(
        audiogram: audiogram,
        sceneClass: SceneClass.voiceOnly,
        snapshot: snap,
        confidence: 0.85,
      );
      expect(p.isPersonalized, isTrue);
      expect(p.gains.length, 12);
      // headroom para input 65 dB SPL: 110 - 65 - 3 = 42 dB.
      expect(p.gains.every((g) => g <= 42.0), isTrue);
      // Bandas medias deberían tener ganancia > 0.
      expect(p.gains[3], greaterThan(0.0));
      expect(p.gains[5], greaterThan(0.0));
    });

    test('voiceInNoiseLow: graves se atenúan respecto al base', () {
      final snap = makeSnap(inputDbSpl: 70.0, voiceActive: true);
      final pVoice = gen.generate(
        audiogram: audiogram,
        sceneClass: SceneClass.voiceOnly,
        snapshot: snap,
        confidence: 0.8,
      );
      final pVoiceLow = gen.generate(
        audiogram: audiogram,
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

    test('headroom safety: input alto reduce maxSafeGain', () {
      // input 100 dB SPL → maxSafe = 110 - 100 - 3 = 7 dB.
      final snapHigh = makeSnap(inputDbSpl: 100.0);
      final p = gen.generate(
        audiogram: audiogram,
        sceneClass: SceneClass.voiceOnly,
        snapshot: snapHigh,
        confidence: 0.8,
      );
      expect(p.gains.every((g) => g <= 7.0), isTrue,
          reason: 'todas las ganancias deberían recortarse a 7 dB');
    });

    test('todas las ganancias quedan dentro de [0, 50]', () {
      final snap = makeSnap(inputDbSpl: 60.0);
      for (final cls in SceneClass.values) {
        final p = gen.generate(
          audiogram: audiogram,
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
        audiogram: audiogram,
        sceneClass: SceneClass.voiceOnly,
        snapshot: snap,
        confidence: 0.7,
      );
      expect(p.isPersonalized, isTrue);
      expect(p.name, startsWith('SmartScenePerso_'));
    });
  });
}
