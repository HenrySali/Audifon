/// Tests del SceneDecisionMaker (Fase 2).
///
/// Verifica reglas puras + histéresis temporal con snapshots sintéticos.
///
/// Validates: Requirements 1.1, 1.2, 1.3, 1.4, 1.5, 1.6

import 'package:flutter_test/flutter_test.dart';
import 'package:hearing_aid_app/scene/scene_decision_maker.dart';
import 'package:hearing_aid_app/scene/scene_snapshot.dart';

/// Construye un snapshot con valores razonables de fondo y permite override
/// solo de los campos relevantes para el test.
SceneSnapshot makeSnap({
  double inputDbSpl = 55.0,
  double noiseFloorDbSpl = -90.0,
  double snrDb = 10.0,
  double vadScore = 0.5,
  double vadConfidence = 0.5,
  bool voiceActive = false,
  bool vadHangoverActive = false,
  double vadStationarity = 0.0,
  double vadMidSnrDb = 5.0,
  double spectralTiltDb = -3.0,
  double spectralCentroidHz = 1500.0,
  double spectralFlatness = 0.3,
  double spectralFlux = 0.1,
  double lowBandEnergyDb = -40.0,
  double midBandEnergyDb = -40.0,
  double highBandEnergyDb = -50.0,
}) {
  return SceneSnapshot(
    timestampUs: 0,
    inputDbSpl: inputDbSpl,
    noiseFloorDbSpl: noiseFloorDbSpl,
    snrDb: snrDb,
    vadScore: vadScore,
    vadConfidence: vadConfidence,
    voiceActive: voiceActive,
    vadHangoverActive: vadHangoverActive,
    vadStationarity: vadStationarity,
    vadMidSnrDb: vadMidSnrDb,
    spectralTiltDb: spectralTiltDb,
    spectralCentroidHz: spectralCentroidHz,
    spectralFlatness: spectralFlatness,
    spectralFlux: spectralFlux,
    lowBandEnergyDb: lowBandEnergyDb,
    midBandEnergyDb: midBandEnergyDb,
    highBandEnergyDb: highBandEnergyDb,
    noisePerBandDb: List<double>.filled(kSceneNumBands, -90.0),
    impulseCount: 0,
    sceneClass: SceneClass.unknown,
    sceneConfidence: 0.0,
  );
}

void main() {
  group('SceneDecisionMaker — reglas puras', () {
    late SceneDecisionMaker dm;

    setUp(() {
      // Hold = 0 para aislar las reglas puras de la histéresis.
      dm = SceneDecisionMaker(holdMs: 0);
    });

    test('silencio cuando inputDbSpl < threshold', () {
      final s = makeSnap(inputDbSpl: 22.0);
      final d = dm.evaluate(s);
      expect(d.sceneClass, SceneClass.silence);
      expect(d.confidence, greaterThan(0.5));
    });

    test('voz limpia cuando voiceActive y SNR alto', () {
      final s = makeSnap(
        inputDbSpl: 60.0,
        snrDb: 20.0,
        voiceActive: true,
        spectralTiltDb: -5.0,
      );
      final d = dm.evaluate(s);
      expect(d.sceneClass, SceneClass.voiceOnly);
    });

    test('voz + ruido grave cuando voiceActive y tilt muy negativo', () {
      final s = makeSnap(
        inputDbSpl: 65.0,
        snrDb: 8.0,
        voiceActive: true,
        spectralTiltDb: -12.0,
      );
      final d = dm.evaluate(s);
      expect(d.sceneClass, SceneClass.voiceInNoiseLow);
    });

    test('voz + ruido medio cuando voiceActive y SNR moderado', () {
      final s = makeSnap(
        inputDbSpl: 65.0,
        snrDb: 6.0,
        voiceActive: true,
        spectralTiltDb: -3.0,
      );
      final d = dm.evaluate(s);
      expect(d.sceneClass, SceneClass.voiceInNoiseMid);
    });

    test('ruido grave dominante: sin voz + tilt muy negativo', () {
      final s = makeSnap(
        inputDbSpl: 60.0,
        voiceActive: false,
        spectralTiltDb: -14.0,
      );
      final d = dm.evaluate(s);
      expect(d.sceneClass, SceneClass.noiseLowDominant);
    });

    test('ruido agudo dominante: sin voz + tilt positivo grande', () {
      final s = makeSnap(
        inputDbSpl: 60.0,
        voiceActive: false,
        spectralTiltDb: 6.0,
      );
      final d = dm.evaluate(s);
      expect(d.sceneClass, SceneClass.noiseHighDominant);
    });

    test('música: sin voz + flatness baja + centroide medio + nivel alto', () {
      final s = makeSnap(
        inputDbSpl: 70.0,
        voiceActive: false,
        spectralFlatness: 0.04,
        spectralCentroidHz: 1500.0,
      );
      final d = dm.evaluate(s);
      expect(d.sceneClass, SceneClass.music);
    });

    test('determinismo: misma entrada → misma clase (sin histéresis)', () {
      final s = makeSnap(
        inputDbSpl: 65.0,
        snrDb: 18.0,
        voiceActive: true,
      );
      final d1 = dm.evaluate(s);
      dm.reset();
      final d2 = dm.evaluate(s);
      expect(d1.sceneClass, d2.sceneClass);
    });
  });

  group('SceneDecisionMaker — histéresis temporal', () {
    test('clase no cambia antes de holdMs si confianza < forceThreshold', () {
      final dm = SceneDecisionMaker(holdMs: 3000, forceConfidenceThreshold: 0.9);
      final t0 = DateTime(2026, 1, 1, 12);

      // Frame 1: voz limpia, alta confianza.
      final voice = makeSnap(
        inputDbSpl: 65.0,
        snrDb: 25.0, // muy por encima del threshold para confianza alta
        voiceActive: true,
      );
      final d1 = dm.evaluate(voice, now: t0);
      expect(d1.sceneClass, SceneClass.voiceOnly);

      // Frame 2 a +1 s: silencio en frontera (input 28 dB SPL → distancia
      // 2 al threshold 30, fullAt=10 → conf ≈ 0.6, < forceThreshold 0.9).
      // Hold debería retener voz.
      final silenceWeak = makeSnap(inputDbSpl: 28.0);
      final d2 = dm.evaluate(silenceWeak,
          now: t0.add(const Duration(seconds: 1)));
      expect(d2.sceneClass, SceneClass.voiceOnly);
      expect(d2.heldByHysteresis, isTrue);

      // Frame 3 a +5 s: silencio. Hold expirado, ahora sí cambia.
      final d3 = dm.evaluate(silenceWeak,
          now: t0.add(const Duration(seconds: 5)));
      expect(d3.sceneClass, SceneClass.silence);
    });

    test('clase cambia inmediato si nueva clase tiene confianza ≥ force', () {
      final dm = SceneDecisionMaker(holdMs: 3000, forceConfidenceThreshold: 0.9);
      final t0 = DateTime(2026, 1, 1, 12);

      // Frame 1: voz limpia.
      final voice = makeSnap(
        inputDbSpl: 65.0,
        snrDb: 18.0,
        voiceActive: true,
      );
      dm.evaluate(voice, now: t0);

      // Frame 2 a +1 s: silencio absoluto muy por debajo del threshold,
      // genera confianza alta (distancia 28 dB > fullAt=10).
      final silence = makeSnap(inputDbSpl: 2.0);
      final d2 = dm.evaluate(silence, now: t0.add(const Duration(seconds: 1)));
      expect(d2.sceneClass, SceneClass.silence,
          reason: 'force-change debería superar el hold');
    });

    test('reset() limpia el estado del hold', () {
      final dm = SceneDecisionMaker(holdMs: 5000);
      final t0 = DateTime(2026, 1, 1, 12);
      dm.evaluate(makeSnap(inputDbSpl: 22.0), now: t0);
      expect(dm.currentDecision?.sceneClass, SceneClass.silence);
      dm.reset();
      expect(dm.currentDecision, isNull);
    });
  });
}
