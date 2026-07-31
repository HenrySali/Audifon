/// Tests del SceneSession (Fase 2).
///
/// Verifica votación de clase dominante y manejo de muestras mínimas/máximas.
///
/// Validates: Requirements 7.4

import 'package:flutter_test/flutter_test.dart';
import 'package:hearing_aid_app/scene/scene_decision_maker.dart';
import 'package:hearing_aid_app/scene/scene_session.dart';
import 'package:hearing_aid_app/scene/scene_snapshot.dart';

import 'scene_decision_maker_test.dart' show makeSnap;

void main() {
  group('SceneSession', () {
    test('lanza StateError si se llama resolve() sin muestras', () {
      final session = SceneSession(
        decisionMaker: SceneDecisionMaker(holdMs: 0),
        minSamples: 1,
        maxSamples: 5,
      );
      expect(() => session.resolve(), throwsStateError);
    });

    test('canResolve == false antes de minSamples', () {
      final session = SceneSession(
        decisionMaker: SceneDecisionMaker(holdMs: 0),
        minSamples: 3,
        maxSamples: 10,
      );
      session.add(makeSnap(inputDbSpl: 22.0));
      expect(session.canResolve, isFalse);
      expect(session.sampleCount, 1);
    });

    test('isFull == true al llegar a maxSamples', () {
      final session = SceneSession(
        decisionMaker: SceneDecisionMaker(holdMs: 0),
        minSamples: 1,
        maxSamples: 3,
      );
      for (var i = 0; i < 3; i++) {
        session.add(makeSnap(inputDbSpl: 22.0));
      }
      expect(session.isFull, isTrue);
      expect(session.canResolve, isTrue);
    });

    test('vota la clase dominante por mayoría', () {
      final session = SceneSession(
        decisionMaker: SceneDecisionMaker(holdMs: 0),
        minSamples: 1,
        maxSamples: 10,
      );
      // 7 muestras de silencio, 3 de voz.
      for (var i = 0; i < 7; i++) {
        session.add(makeSnap(inputDbSpl: 22.0));
      }
      for (var i = 0; i < 3; i++) {
        session.add(makeSnap(
          inputDbSpl: 65.0,
          snrDb: 20.0,
          voiceActive: true,
        ));
      }
      final result = session.resolve();
      expect(result.dominantClass, SceneClass.silence);
      expect(result.sampleCount, 10);
      expect(result.distribution[SceneClass.silence], 7);
      expect(result.distribution[SceneClass.voiceOnly], 3);
      expect(result.averageConfidence, greaterThan(0.5));
    });

    test('reset() vacía el buffer y permite reutilizar la sesión', () {
      final session = SceneSession(
        decisionMaker: SceneDecisionMaker(holdMs: 0),
        minSamples: 1,
        maxSamples: 10,
      );
      session.add(makeSnap(inputDbSpl: 22.0));
      session.add(makeSnap(inputDbSpl: 22.0));
      session.reset();
      expect(session.sampleCount, 0);
      expect(session.canResolve, isFalse);

      // Reutilización: ahora todo es voz.
      for (var i = 0; i < 4; i++) {
        session.add(makeSnap(
          inputDbSpl: 65.0,
          snrDb: 18.0,
          voiceActive: true,
        ));
      }
      final r = session.resolve();
      expect(r.dominantClass, SceneClass.voiceOnly);
    });
  });
}
