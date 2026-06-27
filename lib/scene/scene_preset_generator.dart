/// Smart Scene Engine — Fase 3 (refactor audiogram-driven-presets task 6.3).
///
/// Generador "genérico": usa el [AudiogramDrivenBundle] derivado del
/// audiograma como base de las ganancias (Req 7.4) y le aplica solo la
/// tabla de tuning por escena (NR / TNR / volumen / WDRC override). NO
/// suma deltas por banda al EQ — esa es la diferencia con el generador
/// personalizado: el toggle "Personalizar" controla si se aplican los
/// deltas por escena al EQ encima del bundle (ON), o si el EQ se queda
/// en la base audiograma-derivada (OFF, Req 7.6).
///
/// Esta versión refactoriza el generador anterior, que seleccionaba un
/// `EqPreset` hardcoded por escena. Ahora la base sale siempre del
/// audiograma para que la app nunca cargue una curva genérica que
/// ignore lo medido (Req 7.4).
///
/// Validates: Requirements 7.1, 7.4, 7.5, 7.6, 10.3, 10.6

import '../domain/audiogram_driven_presets/audiogram_driven_bundle.dart';
import 'noise_level_calculator.dart';
import 'scene_snapshot.dart' show SceneClass, SceneSnapshot;
import 'smart_preset.dart';

class SceneGenericPresetGenerator {
  /// Margen de seguridad para crest factor en el clamp por banda.
  final double safetyMarginDb;

  /// Ganancia máxima permitida por banda (red de seguridad).
  final double absoluteMaxGainDb;

  /// Tolerancia para reportar una banda como clampada en
  /// [SmartPreset.clampedBands].
  final double clampReportThresholdDb;

  SceneGenericPresetGenerator({
    this.safetyMarginDb = 3.0,
    this.absoluteMaxGainDb = 50.0,
    this.clampReportThresholdDb = 0.1,
  });

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
          compressionRatioOverride: 1.8,
          compressionKneeOverride: 50.0,
        );
      case SceneClass.voiceInNoiseLow:
        return const _SceneTuning(
          nrLevel: 3,
          tnrEnabled: true,
          volumeDeltaDb: -2.0,
          compressionRatioOverride: 1.7,
          compressionKneeOverride: 50.0,
        );
      case SceneClass.noiseLowDominant:
        return const _SceneTuning(
          nrLevel: 3,
          tnrEnabled: true,
          volumeDeltaDb: -3.0,
          compressionRatioOverride: 1.7,
          compressionKneeOverride: 50.0,
        );
      case SceneClass.noiseHighDominant:
        return const _SceneTuning(
          nrLevel: 3,
          tnrEnabled: false,
          volumeDeltaDb: -2.0,
          compressionRatioOverride: 1.8,
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

  /// Genera un `SmartPreset` usando las ganancias del [bundle]
  /// audiograma-derivado como base, clampándolas al headroom MPO por
  /// banda (Req 10.3) y aplicando el tuning de la escena (NR / TNR /
  /// volumen / WDRC override).
  SmartPreset generate({
    required AudiogramDrivenBundle bundle,
    required SceneClass sceneClass,
    required SceneSnapshot snapshot,
    required double confidence,
  }) {
    final tuning = _tuningFor(sceneClass);
    final input = snapshot.inputDbSpl;
    
    // Smart con NR automático: calcular nrLevel basándose en las métricas
    // de ruido del snapshot en vez de usar el valor fijo del tuning.
    // Requisito: Smart con detección automática de nivel de ruido (2026-06-27)
    final nrLevel = NoiseLevelCalculator.calculateNrLevel(snapshot);

    final gains = List<double>.filled(
      AudiogramDrivenBundle.bandCount,
      0.0,
      growable: false,
    );
    final clamped = <int>[];

    for (var i = 0; i < AudiogramDrivenBundle.bandCount; i++) {
      final target = bundle.gainsDb[i];
      final maxSafePerBand = (bundle.mpoProfileDbSpl[i] - input - safetyMarginDb)
          .clamp(0.0, absoluteMaxGainDb)
          .toDouble();

      var g = target;
      if (g < 0.0) g = 0.0;
      if (g > maxSafePerBand) g = maxSafePerBand;
      if (g > absoluteMaxGainDb) g = absoluteMaxGainDb;

      gains[i] = g;

      if (target - g >= clampReportThresholdDb) {
        clamped.add(i);
      }
    }

    final timestamp =
        DateTime.now().millisecondsSinceEpoch.remainder(100000);

    return SmartPreset(
      name: 'SmartScene_${sceneClass.name}_$timestamp',
      isPersonalized: false,
      sceneClass: sceneClass,
      gains: List<double>.unmodifiable(gains),
      compressionRatio: tuning.compressionRatioOverride,
      compressionKnee: tuning.compressionKneeOverride,
      expansionKnee: bundle.expansionKneeDbSpl,
      nrLevel: nrLevel, // Usar NR calculado automáticamente, no el del tuning
      tnrEnabled: tuning.tnrEnabled,
      volumeDeltaDb: tuning.volumeDeltaDb,
      confidence: confidence,
      clampedBands: List<int>.unmodifiable(clamped),
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
