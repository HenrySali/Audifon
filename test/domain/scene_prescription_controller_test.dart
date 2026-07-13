/// Tests unitarios del ScenePrescriptionController.
///
/// Verifica:
/// - Mapeo SceneClass → PrescriptionMode para NL3.
/// - NL2 mode siempre retorna quiet independientemente de la escena.
/// - Histéresis asimétrica (dwell time) para transiciones.
/// - Crossfade duration se clampea a [200, 500] ms.
/// - Estado tracking: currentMode, pendingMode, lastSceneChangeTimestamp.
///
/// Requisitos: 6.1, 6.2, 6.3, 6.4, 6.5
import 'package:flutter_test/flutter_test.dart';

import 'package:hearing_aid_app/domain/entities/prescription_mode.dart';
import 'package:hearing_aid_app/domain/scene_prescription_controller.dart';
import 'package:hearing_aid_app/scene/scene_snapshot.dart' show SceneClass;

void main() {
  group('ScenePrescriptionController — mapeo SceneClass → PrescriptionMode', () {
    late ScenePrescriptionController controller;

    setUp(() {
      // Dwell times en 0 para testear mapeo puro sin histéresis.
      controller = ScenePrescriptionController(
        prescriberMode: PrescriberMode.smartNl3,
        dwellNoiseToQuietMs: 0,
        dwellQuietToNoiseMs: 0,
      );
    });

    test('silence → quiet', () {
      controller.onSceneChanged(SceneClass.silence);
      expect(controller.currentMode, PrescriptionMode.quiet);
    });

    test('voiceOnly → quiet', () {
      controller.onSceneChanged(SceneClass.voiceOnly);
      expect(controller.currentMode, PrescriptionMode.quiet);
    });

    test('music → quiet', () {
      controller.onSceneChanged(SceneClass.music);
      expect(controller.currentMode, PrescriptionMode.quiet);
    });

    test('unknown → quiet', () {
      controller.onSceneChanged(SceneClass.unknown);
      expect(controller.currentMode, PrescriptionMode.quiet);
    });

    test('voiceInNoiseLow → comfortInNoise', () {
      controller.onSceneChanged(SceneClass.voiceInNoiseLow);
      expect(controller.currentMode, PrescriptionMode.comfortInNoise);
    });

    test('voiceInNoiseMid → comfortInNoise', () {
      controller.onSceneChanged(SceneClass.voiceInNoiseMid);
      expect(controller.currentMode, PrescriptionMode.comfortInNoise);
    });

    test('noiseLowDominant → comfortInNoise', () {
      controller.onSceneChanged(SceneClass.noiseLowDominant);
      expect(controller.currentMode, PrescriptionMode.comfortInNoise);
    });

    test('noiseHighDominant → comfortInNoise', () {
      controller.onSceneChanged(SceneClass.noiseHighDominant);
      expect(controller.currentMode, PrescriptionMode.comfortInNoise);
    });
  });

  group('ScenePrescriptionController — NL2 mode no dispara CIN', () {
    late ScenePrescriptionController controller;

    setUp(() {
      controller = ScenePrescriptionController(
        prescriberMode: PrescriberMode.smartNl2,
        dwellNoiseToQuietMs: 0,
        dwellQuietToNoiseMs: 0,
      );
    });

    test('NL2 + noise → quiet (sin CIN)', () {
      controller.onSceneChanged(SceneClass.voiceInNoiseLow);
      expect(controller.currentMode, PrescriptionMode.quiet);
    });

    test('NL2 + noiseHighDominant → quiet', () {
      controller.onSceneChanged(SceneClass.noiseHighDominant);
      expect(controller.currentMode, PrescriptionMode.quiet);
    });

    test('NL2 + noiseLowDominant → quiet', () {
      controller.onSceneChanged(SceneClass.noiseLowDominant);
      expect(controller.currentMode, PrescriptionMode.quiet);
    });

    test('NL2 ignora todas las escenas de ruido', () {
      for (final scene in SceneClass.values) {
        controller.onSceneChanged(scene);
        expect(controller.currentMode, PrescriptionMode.quiet,
            reason: 'NL2 con SceneClass.${scene.name} debería ser quiet');
      }
    });

    test('pendingMode siempre es null en NL2', () {
      controller.onSceneChanged(SceneClass.voiceInNoiseMid);
      expect(controller.pendingMode, isNull);
      expect(controller.lastSceneChangeTimestamp, isNull);
    });
  });

  group('ScenePrescriptionController — histéresis (dwell time)', () {
    test('QUIET→NOISE requiere dwellQuietToNoiseMs para confirmar', () {
      final controller = ScenePrescriptionController(
        prescriberMode: PrescriberMode.smartNl3,
        dwellNoiseToQuietMs: 2000,
        dwellQuietToNoiseMs: 500,
      );

      final t0 = DateTime(2026, 1, 1, 0, 0, 0);

      // Primer evento de ruido: inicia dwell, no cambia modo.
      final changed = controller.onSceneChanged(
        SceneClass.voiceInNoiseLow,
        now: t0,
      );
      expect(changed, isFalse);
      expect(controller.currentMode, PrescriptionMode.quiet);
      expect(controller.pendingMode, PrescriptionMode.comfortInNoise);
      expect(controller.lastSceneChangeTimestamp, t0);

      // 200 ms después: todavía no expiró el dwell (500 ms requeridos).
      final t200 = t0.add(const Duration(milliseconds: 200));
      final changed200 = controller.onSceneChanged(
        SceneClass.voiceInNoiseLow,
        now: t200,
      );
      expect(changed200, isFalse);
      expect(controller.currentMode, PrescriptionMode.quiet);

      // 500 ms después: dwell cumplido → transición confirmada.
      final t500 = t0.add(const Duration(milliseconds: 500));
      final changed500 = controller.onSceneChanged(
        SceneClass.voiceInNoiseLow,
        now: t500,
      );
      expect(changed500, isTrue);
      expect(controller.currentMode, PrescriptionMode.comfortInNoise);
      expect(controller.pendingMode, isNull);
    });

    test('NOISE→QUIET requiere dwellNoiseToQuietMs para confirmar', () {
      final controller = ScenePrescriptionController(
        prescriberMode: PrescriberMode.smartNl3,
        dwellNoiseToQuietMs: 2000,
        dwellQuietToNoiseMs: 0,
      );

      final t0 = DateTime(2026, 1, 1, 0, 0, 0);

      // Llevar a CIN (dwell=0 para quiet→noise).
      controller.onSceneChanged(SceneClass.voiceInNoiseLow, now: t0);
      expect(controller.currentMode, PrescriptionMode.comfortInNoise);

      // Evento de silencio: inicia dwell largo (2000 ms).
      final t1 = t0.add(const Duration(milliseconds: 100));
      controller.onSceneChanged(SceneClass.silence, now: t1);
      expect(controller.currentMode, PrescriptionMode.comfortInNoise);
      expect(controller.pendingMode, PrescriptionMode.quiet);

      // 1000 ms después: aún no expiró.
      final t1000 = t1.add(const Duration(milliseconds: 1000));
      controller.onSceneChanged(SceneClass.silence, now: t1000);
      expect(controller.currentMode, PrescriptionMode.comfortInNoise);

      // 2000 ms después: dwell cumplido → vuelve a quiet.
      final t2000 = t1.add(const Duration(milliseconds: 2000));
      final changed = controller.onSceneChanged(SceneClass.silence, now: t2000);
      expect(changed, isTrue);
      expect(controller.currentMode, PrescriptionMode.quiet);
    });

    test('cambio de escena durante dwell reinicia el período si target cambia', () {
      final controller = ScenePrescriptionController(
        prescriberMode: PrescriberMode.smartNl3,
        dwellNoiseToQuietMs: 2000,
        dwellQuietToNoiseMs: 500,
      );

      final t0 = DateTime(2026, 1, 1, 0, 0, 0);

      // Inicia dwell hacia CIN.
      controller.onSceneChanged(SceneClass.noiseLowDominant, now: t0);
      expect(controller.pendingMode, PrescriptionMode.comfortInNoise);

      // A los 300 ms, vuelve a silencio → cancela el pending (target == current).
      final t300 = t0.add(const Duration(milliseconds: 300));
      controller.onSceneChanged(SceneClass.silence, now: t300);
      expect(controller.pendingMode, isNull);
      expect(controller.currentMode, PrescriptionMode.quiet);
    });
  });

  group('ScenePrescriptionController — tick()', () {
    test('tick confirma transición cuando dwell expiró', () {
      final controller = ScenePrescriptionController(
        prescriberMode: PrescriberMode.smartNl3,
        dwellQuietToNoiseMs: 500,
      );

      final t0 = DateTime(2026, 1, 1, 0, 0, 0);
      controller.onSceneChanged(SceneClass.voiceInNoiseMid, now: t0);
      expect(controller.currentMode, PrescriptionMode.quiet);

      // tick antes de dwell → no cambia.
      final t200 = t0.add(const Duration(milliseconds: 200));
      expect(controller.tick(now: t200), isFalse);
      expect(controller.currentMode, PrescriptionMode.quiet);

      // tick después de dwell → confirma.
      final t600 = t0.add(const Duration(milliseconds: 600));
      expect(controller.tick(now: t600), isTrue);
      expect(controller.currentMode, PrescriptionMode.comfortInNoise);
    });

    test('tick retorna false sin pending', () {
      final controller = ScenePrescriptionController();
      expect(controller.tick(), isFalse);
    });
  });

  group('ScenePrescriptionController — crossfadeDurationMs', () {
    test('valor dentro de rango se conserva', () {
      final controller = ScenePrescriptionController(crossfadeDurationMs: 350);
      expect(controller.crossfadeDurationMs, 350);
    });

    test('valor menor a 200 se clampea a 200', () {
      final controller = ScenePrescriptionController(crossfadeDurationMs: 50);
      expect(controller.crossfadeDurationMs, 200);
    });

    test('valor mayor a 500 se clampea a 500', () {
      final controller = ScenePrescriptionController(crossfadeDurationMs: 1000);
      expect(controller.crossfadeDurationMs, 500);
    });

    test('valor default es 300', () {
      final controller = ScenePrescriptionController();
      expect(controller.crossfadeDurationMs, 300);
    });
  });

  group('ScenePrescriptionController — setPrescriberMode', () {
    test('cambiar a NL2 cancela pending y fuerza quiet', () {
      final controller = ScenePrescriptionController(
        prescriberMode: PrescriberMode.smartNl3,
        dwellQuietToNoiseMs: 500,
      );

      final t0 = DateTime(2026, 1, 1, 0, 0, 0);
      controller.onSceneChanged(SceneClass.noiseLowDominant, now: t0);
      expect(controller.pendingMode, PrescriptionMode.comfortInNoise);

      // Cambiar a NL2 cancela todo.
      controller.setPrescriberMode(PrescriberMode.smartNl2);
      expect(controller.currentMode, PrescriptionMode.quiet);
      expect(controller.pendingMode, isNull);
      expect(controller.lastSceneChangeTimestamp, isNull);
    });

    test('cambiar de NL2 a NL3 permite reaccionar a escenas', () {
      final controller = ScenePrescriptionController(
        prescriberMode: PrescriberMode.smartNl2,
        dwellQuietToNoiseMs: 0,
      );

      controller.onSceneChanged(SceneClass.voiceInNoiseLow);
      expect(controller.currentMode, PrescriptionMode.quiet);

      // Cambiar a NL3 y enviar escena ruidosa.
      controller.setPrescriberMode(PrescriberMode.smartNl3);
      controller.onSceneChanged(SceneClass.voiceInNoiseLow);
      expect(controller.currentMode, PrescriptionMode.comfortInNoise);
    });
  });

  group('ScenePrescriptionController — reset()', () {
    test('reset vuelve al estado inicial', () {
      final controller = ScenePrescriptionController(
        prescriberMode: PrescriberMode.smartNl3,
        dwellQuietToNoiseMs: 0,
      );

      controller.onSceneChanged(SceneClass.noiseLowDominant);
      expect(controller.currentMode, PrescriptionMode.comfortInNoise);

      controller.reset();
      expect(controller.currentMode, PrescriptionMode.quiet);
      expect(controller.pendingMode, isNull);
      expect(controller.lastSceneChangeTimestamp, isNull);
      expect(controller.lastSceneClass, SceneClass.unknown);
    });
  });
}
