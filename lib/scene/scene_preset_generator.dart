/// Smart Scene Engine — Fase 3.
///
/// Generador genérico: convierte una `SceneClass` en un `SmartPreset` usando
/// los presets clínicos existentes (`EqPreset.allPresets`) más la tabla de
/// deltas de NR / TNR / volumen del `design.md`.
///
/// No usa el audiograma del usuario. Sirve como fallback cuando el toggle
/// "Personalizar" está OFF o cuando no hay audiograma disponible.
///
/// Validates: Requirements 3.1

import '../domain/entities/eq_preset.dart';
import 'scene_class.dart';
import 'scene_snapshot.dart' show SceneClass;
import 'smart_preset.dart';

class SceneGenericPresetGenerator {
  /// Mapea cada clase a un preset clínico predefinido.
  static EqPreset _baseFor(SceneClass cls) {
    switch (cls) {
      case SceneClass.silence:
        return EqPreset.normal;
      case SceneClass.voiceOnly:
        return EqPreset.voiceClarity;
      case SceneClass.voiceInNoiseLow:
        return EqPreset.outdoor;
      case SceneClass.voiceInNoiseMid:
        return EqPreset.voiceClarity;
      case SceneClass.noiseLowDominant:
        return EqPreset.outdoor;
      case SceneClass.noiseHighDominant:
        return EqPreset.normal;
      case SceneClass.music:
        return EqPreset.music;
      case SceneClass.unknown:
        return EqPreset.normal;
    }
  }

  /// Tabla del design: NR / TNR / volumen / WDRC override por escena.
  static _SceneTuning _tuningFor(SceneClass cls) {
    switch (cls) {
      case SceneClass.silence:
        return const _SceneTuning(
          nrLevel: 0,
          tnrEnabled: false,
          volumeDeltaDb: 0.0,
          compressionRatioOverride: 1.5,
          compressionKneeOverride: 60.0,
        );
      case SceneClass.voiceOnly:
        return const _SceneTuning(
          nrLevel: 1,
          tnrEnabled: false,
          volumeDeltaDb: 0.0,
          compressionRatioOverride: 1.5,
          compressionKneeOverride: 55.0,
        );
      case SceneClass.voiceInNoiseMid:
        return const _SceneTuning(
          nrLevel: 2,
          tnrEnabled: false,
          volumeDeltaDb: -1.0,
          compressionRatioOverride: 2.0,
          compressionKneeOverride: 47.0,
        );
      case SceneClass.voiceInNoiseLow:
        return const _SceneTuning(
          nrLevel: 3,
          tnrEnabled: true,
          volumeDeltaDb: -2.0,
          compressionRatioOverride: 2.5,
          compressionKneeOverride: 45.0,
        );
      case SceneClass.noiseLowDominant:
        return const _SceneTuning(
          nrLevel: 3,
          tnrEnabled: true,
          volumeDeltaDb: -3.0,
          compressionRatioOverride: 2.5,
          compressionKneeOverride: 45.0,
        );
      case SceneClass.noiseHighDominant:
        return const _SceneTuning(
          nrLevel: 3,
          tnrEnabled: false,
          volumeDeltaDb: -2.0,
          compressionRatioOverride: 2.0,
          compressionKneeOverride: 50.0,
        );
      case SceneClass.music:
        return const _SceneTuning(
          nrLevel: 0,
          tnrEnabled: false,
          volumeDeltaDb: 0.0,
          compressionRatioOverride: 1.3,
          compressionKneeOverride: 60.0,
        );
      case SceneClass.unknown:
        return const _SceneTuning(
          nrLevel: 1,
          tnrEnabled: false,
          volumeDeltaDb: 0.0,
          compressionRatioOverride: 1.5,
          compressionKneeOverride: 55.0,
        );
    }
  }

  /// Genera un `SmartPreset` para la clase dada usando un base clínico
  /// y la tabla de tuning. `confidence` se propaga del análisis.
  SmartPreset generate(SceneClass cls, {required double confidence}) {
    final base = _baseFor(cls);
    final tuning = _tuningFor(cls);
    final clamped = base.gains
        .map((g) => g.clamp(0.0, 50.0).toDouble())
        .toList(growable: false);
    final timestamp = DateTime.now().millisecondsSinceEpoch.remainder(100000);
    return SmartPreset(
      name: 'SmartScene_${cls.name}_$timestamp',
      isPersonalized: false,
      sceneClass: cls,
      gains: clamped,
      compressionRatio: tuning.compressionRatioOverride,
      compressionKnee: tuning.compressionKneeOverride,
      expansionKnee: base.expansionKnee,
      nrLevel: tuning.nrLevel,
      tnrEnabled: tuning.tnrEnabled,
      volumeDeltaDb: tuning.volumeDeltaDb,
      confidence: confidence,
    );
  }
}

/// Bloque interno con los parámetros derivados del design.
class _SceneTuning {
  final int nrLevel;
  final bool tnrEnabled;
  final double volumeDeltaDb;
  final double compressionRatioOverride;
  final double compressionKneeOverride;

  const _SceneTuning({
    required this.nrLevel,
    required this.tnrEnabled,
    required this.volumeDeltaDb,
    required this.compressionRatioOverride,
    required this.compressionKneeOverride,
  });
}
