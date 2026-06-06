/// Smoke validation test del pipeline de clasificación + presets (Fase 5).
///
/// Reproduce los 7 escenarios del `design.md` con snapshots sintéticos que
/// imitan los rangos esperados de cada clase (input dB SPL, SNR, tilt,
/// flatness, voiceActive). Verifica que para cada escenario:
///   1. El `SceneDecisionMaker` clasifica con la clase correcta.
///   2. La sesión completa (10+ snapshots) confirma la clase dominante.
///   3. El generador genérico produce un preset coherente con la escena.
///   4. El generador personalizado respeta el headroom MPO.
///
/// Esto NO reemplaza la validación contra DCASE TAU 2020 Mobile (Fase 5
/// del spec, que requiere bajar ~64 GB de dataset y correr el motor C++
/// nativo offline) ni el smoke test en dispositivo real, pero sí sirve
/// como guard de regresión automático para el código Dart de la app.
///
/// Validates: Requirements 1.6, 2.4, 7.4

import 'package:flutter_test/flutter_test.dart';

import 'package:hearing_aid_app/domain/audiogram_driven_presets/audiogram_driven_bundle.dart';
import 'package:hearing_aid_app/domain/audiogram_driven_presets/bundle_builder.dart';
import 'package:hearing_aid_app/domain/entities/audiogram.dart';
import 'package:hearing_aid_app/domain/entities/prescription_mode.dart';
import 'package:hearing_aid_app/scene/scene_decision_maker.dart';
import 'package:hearing_aid_app/scene/scene_personalized_generator.dart';
import 'package:hearing_aid_app/scene/scene_preset_generator.dart';
import 'package:hearing_aid_app/scene/scene_session.dart';
import 'package:hearing_aid_app/scene/scene_snapshot.dart';

import 'scene_decision_maker_test.dart' show makeSnap;

class _Scenario {
  final String label;
  final SceneClass expected;
  final SceneSnapshot Function() builder;

  const _Scenario({
    required this.label,
    required this.expected,
    required this.builder,
  });
}

/// Audiograma realista para los tests de personalización (presbiacusia
/// moderada en agudos).
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
  // Tabla de los 7 escenarios. Los valores siguen el `design.md`.
  final scenarios = <_Scenario>[
    _Scenario(
      label: 'silencio absoluto (cuarto vacío de noche)',
      expected: SceneClass.silence,
      builder: () => makeSnap(inputDbSpl: 22.0),
    ),
    _Scenario(
      label: 'voz limpia 65 dB SPL (charla en un cuarto silencioso)',
      expected: SceneClass.voiceOnly,
      builder: () => makeSnap(
        inputDbSpl: 65.0,
        snrDb: 25.0,
        voiceActive: true,
        spectralTiltDb: -5.0,
        spectralCentroidHz: 1500.0,
      ),
    ),
    _Scenario(
      label: 'voz + ruido grave (subte / motor)',
      expected: SceneClass.voiceInNoiseLow,
      builder: () => makeSnap(
        inputDbSpl: 70.0,
        snrDb: 6.0,
        voiceActive: true,
        spectralTiltDb: -12.0,
        spectralCentroidHz: 800.0,
      ),
    ),
    _Scenario(
      label: 'voz + ruido medio (oficina, bar, restaurante)',
      expected: SceneClass.voiceInNoiseMid,
      builder: () => makeSnap(
        inputDbSpl: 68.0,
        snrDb: 5.0,
        voiceActive: true,
        spectralTiltDb: -3.0,
        spectralCentroidHz: 1500.0,
      ),
    ),
    _Scenario(
      label: 'ruido grave dominante sin voz (subte estacionario)',
      expected: SceneClass.noiseLowDominant,
      builder: () => makeSnap(
        inputDbSpl: 60.0,
        voiceActive: false,
        spectralTiltDb: -14.0,
        spectralCentroidHz: 600.0,
      ),
    ),
    _Scenario(
      label: 'ruido agudo dominante sin voz (viento, lluvia)',
      expected: SceneClass.noiseHighDominant,
      builder: () => makeSnap(
        inputDbSpl: 60.0,
        voiceActive: false,
        spectralTiltDb: 6.0,
        spectralCentroidHz: 4000.0,
      ),
    ),
    _Scenario(
      label: 'música (espectro armónico estable)',
      expected: SceneClass.music,
      builder: () => makeSnap(
        inputDbSpl: 70.0,
        voiceActive: false,
        spectralFlatness: 0.04,
        spectralCentroidHz: 1500.0,
      ),
    ),
  ];

  group('Smoke validation — DecisionMaker (regla pura)', () {
    for (final s in scenarios) {
      test(s.label, () {
        final dm = SceneDecisionMaker(holdMs: 0);
        final d = dm.evaluate(s.builder());
        expect(d.sceneClass, s.expected,
            reason: 'esperado ${s.expected.name}, obtuvo ${d.sceneClass.name}');
        expect(d.confidence, greaterThanOrEqualTo(0.4));
      });
    }
  });

  group('Smoke validation — Sesión 12 muestras → clase dominante', () {
    for (final s in scenarios) {
      test(s.label, () {
        final session = SceneSession(
          decisionMaker: SceneDecisionMaker(holdMs: 0),
          minSamples: 1,
          maxSamples: 12,
        );
        for (var i = 0; i < 12; i++) {
          session.add(s.builder());
        }
        final res = session.resolve();
        expect(res.dominantClass, s.expected,
            reason: 'sesión esperaba ${s.expected.name}, '
                'obtuvo ${res.dominantClass.name}');
        expect(res.sampleCount, 12);
      });
    }
  });

  group('Smoke validation — Generador genérico', () {
    final gen = SceneGenericPresetGenerator();
    final bundle = BundleBuilder().buildFromAudiogram(
      _moderateHighLossAudiogram(),
      mode: PrescriptionMode.quiet,
      derivedAt: DateTime.utc(2026, 1, 1),
    );
    for (final s in scenarios) {
      test('${s.label} → preset válido', () {
        final preset = gen.generate(
          bundle: bundle,
          sceneClass: s.expected,
          snapshot: s.builder(),
          confidence: 0.8,
        );
        expect(preset.gains.length, 12);
        expect(preset.gains.every((g) => g >= 0 && g <= 50), isTrue);
        expect(preset.compressionRatio, greaterThan(1.0));
        expect(preset.compressionRatio, lessThanOrEqualTo(3.0));
      });
    }
  });

  group('Smoke validation — Generador personalizado respeta headroom', () {
    final gen = ScenePersonalizedPresetGenerator();
    final audiogram = _moderateHighLossAudiogram();
    final bundle = BundleBuilder().buildFromAudiogram(
      audiogram,
      mode: PrescriptionMode.quiet,
      derivedAt: DateTime.utc(2026, 1, 1),
    );
    for (final s in scenarios) {
      test('${s.label} → ganancias dentro de [0, maxSafePerBand]', () {
        final snap = s.builder();
        final preset = gen.generate(
          bundle: bundle,
          sceneClass: s.expected,
          snapshot: snap,
          confidence: 0.8,
        );
        // Headroom por banda: maxSafe[i] = mpoProfile[i] - input - 3.
        for (var i = 0; i < AudiogramDrivenBundle.bandCount; i++) {
          final maxSafe =
              (bundle.mpoProfileDbSpl[i] - snap.inputDbSpl - 3.0)
                  .clamp(0.0, 50.0);
          expect(preset.gains[i], greaterThanOrEqualTo(0.0));
          expect(preset.gains[i], lessThanOrEqualTo(maxSafe + 1e-6),
              reason: 'banda $i excede headroom para ${s.expected.name}');
        }
      });
    }
  });
}
