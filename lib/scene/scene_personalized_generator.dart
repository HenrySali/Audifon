/// Smart Scene Engine — Fase 3.
///
/// Generador personalizado: parte de las ganancias NAL-NL2 derivadas del
/// audiograma del paciente y aplica los deltas por banda definidos en el
/// `design.md` para cada `SceneClass`. Aplica también un clamp por banda
/// usando la regla de headroom:
///
///   `maxSafeGain[i] = MPO_threshold_db_spl - input_db_spl - safety_margin`
///
/// Donde `safety_margin = 3 dB` y `MPO_threshold_db_spl = 110 dB SPL` (tope
/// FDA OTC 2022). Esto garantiza que la salida nunca excede el MPO del
/// pipeline DSP aunque el EQ amplifique.
///
/// Si no hay audiograma, lanza `ArgumentError`.
///
/// Validates: Requirements 3.2, 3.3, 3.5, 3.6, 3.7

import '../domain/entities/audiogram.dart';
import '../domain/gain_prescriber.dart';
import 'scene_snapshot.dart' show SceneClass, SceneSnapshot;
import 'smart_preset.dart';

class ScenePersonalizedPresetGenerator {
  /// Tope MPO del pipeline (FDA OTC ≤ 110 dB SPL).
  final double mpoThresholdDbSpl;

  /// Margen de seguridad para crest factor.
  final double safetyMarginDb;

  /// Ganancia máxima permitida por banda (limita el techo absoluto).
  final double absoluteMaxGainDb;

  final GainPrescriber _prescriber;

  ScenePersonalizedPresetGenerator({
    GainPrescriber? prescriber,
    this.mpoThresholdDbSpl = 110.0,
    this.safetyMarginDb = 3.0,
    this.absoluteMaxGainDb = 50.0,
  }) : _prescriber = prescriber ?? GainPrescriber();

  /// Genera un `SmartPreset` partiendo del audiograma y aplicando deltas
  /// según la escena.
  SmartPreset generate({
    required Audiogram audiogram,
    required SceneClass sceneClass,
    required SceneSnapshot snapshot,
    required double confidence,
  }) {
    // 1) Base NAL-NL2 desde el audiograma. 12 valores en [0, 50] dB.
    final base = _prescriber.prescribeFromAudiogram(audiogram);

    // 2) Delta por banda según la escena.
    final delta = _deltasFor(sceneClass);

    // 3) Cap superior por banda usando headroom.
    final input = snapshot.inputDbSpl;
    final maxSafe = (mpoThresholdDbSpl - input - safetyMarginDb)
        .clamp(0.0, absoluteMaxGainDb);

    final gains = <double>[];
    for (var i = 0; i < base.length; i++) {
      var g = base[i] + delta[i];
      if (g < 0.0) g = 0.0;
      if (g > maxSafe) g = maxSafe;
      if (g > absoluteMaxGainDb) g = absoluteMaxGainDb;
      gains.add(g);
    }

    final tuning = _tuningFor(sceneClass);
    final timestamp =
        DateTime.now().millisecondsSinceEpoch.remainder(100000);

    return SmartPreset(
      name: 'SmartScenePerso_${sceneClass.name}_$timestamp',
      isPersonalized: true,
      sceneClass: sceneClass,
      gains: List<double>.unmodifiable(gains),
      compressionRatio: tuning.compressionRatio,
      compressionKnee: tuning.compressionKnee,
      expansionKnee: tuning.expansionKnee,
      nrLevel: tuning.nrLevel,
      tnrEnabled: tuning.tnrEnabled,
      volumeDeltaDb: tuning.volumeDeltaDb,
      confidence: confidence,
    );
  }

  /// Deltas por banda en dB. Las bandas siguen el orden de
  /// `EqPreset.bandFrequencies` (250, 500, 750, 1k, 1.5k, 2k, 2.5k, 3k,
  /// 3.5k, 4k, 6k, 8k Hz).
  ///
  /// Mapeo del design.md:
  /// - bandas graves (250-750 Hz)  → indices 0..2
  /// - bandas medias (1k-4 kHz)    → indices 3..9
  /// - bandas altas (6-8 kHz)      → indices 10..11
  List<double> _deltasFor(SceneClass cls) {
    final low = _lowDeltaFor(cls);
    final mid = _midDeltaFor(cls);
    final high = _highDeltaFor(cls);
    return <double>[
      low, low, low,
      mid, mid, mid, mid, mid, mid, mid,
      high, high,
    ];
  }

  double _lowDeltaFor(SceneClass cls) {
    switch (cls) {
      case SceneClass.voiceInNoiseMid:
        return -2.0;
      case SceneClass.voiceInNoiseLow:
        return -6.0;
      case SceneClass.noiseLowDominant:
        return -8.0;
      case SceneClass.music:
        return -2.0;
      case SceneClass.silence:
      case SceneClass.voiceOnly:
      case SceneClass.noiseHighDominant:
      case SceneClass.unknown:
        return 0.0;
    }
  }

  double _midDeltaFor(SceneClass cls) {
    switch (cls) {
      case SceneClass.voiceOnly:
        return 1.0;
      case SceneClass.voiceInNoiseMid:
        return 2.0;
      case SceneClass.voiceInNoiseLow:
        return 3.0;
      case SceneClass.noiseLowDominant:
        return 1.0;
      case SceneClass.noiseHighDominant:
        return -2.0;
      case SceneClass.music:
        return -2.0;
      case SceneClass.silence:
      case SceneClass.unknown:
        return 0.0;
    }
  }

  double _highDeltaFor(SceneClass cls) {
    switch (cls) {
      case SceneClass.voiceOnly:
      case SceneClass.voiceInNoiseMid:
      case SceneClass.voiceInNoiseLow:
        return 0.0;
      case SceneClass.noiseHighDominant:
        return -3.0;
      case SceneClass.noiseLowDominant:
      case SceneClass.music:
      case SceneClass.silence:
      case SceneClass.unknown:
        return 0.0;
    }
  }

  _SceneTuning _tuningFor(SceneClass cls) {
    switch (cls) {
      case SceneClass.silence:
        return const _SceneTuning(
          compressionRatio: 1.5,
          compressionKnee: 60.0,
          expansionKnee: 35.0,
          nrLevel: 0,
          tnrEnabled: false,
          volumeDeltaDb: 0.0,
        );
      case SceneClass.voiceOnly:
        return const _SceneTuning(
          compressionRatio: 1.5,
          compressionKnee: 55.0,
          expansionKnee: 35.0,
          nrLevel: 1,
          tnrEnabled: false,
          volumeDeltaDb: 0.0,
        );
      case SceneClass.voiceInNoiseMid:
        return const _SceneTuning(
          compressionRatio: 2.0,
          compressionKnee: 47.0,
          expansionKnee: 35.0,
          nrLevel: 2,
          tnrEnabled: false,
          volumeDeltaDb: -1.0,
        );
      case SceneClass.voiceInNoiseLow:
        return const _SceneTuning(
          compressionRatio: 2.5,
          compressionKnee: 45.0,
          expansionKnee: 35.0,
          nrLevel: 3,
          tnrEnabled: true,
          volumeDeltaDb: -2.0,
        );
      case SceneClass.noiseLowDominant:
        return const _SceneTuning(
          compressionRatio: 2.5,
          compressionKnee: 45.0,
          expansionKnee: 35.0,
          nrLevel: 3,
          tnrEnabled: true,
          volumeDeltaDb: -3.0,
        );
      case SceneClass.noiseHighDominant:
        return const _SceneTuning(
          compressionRatio: 2.0,
          compressionKnee: 50.0,
          expansionKnee: 35.0,
          nrLevel: 3,
          tnrEnabled: false,
          volumeDeltaDb: -2.0,
        );
      case SceneClass.music:
        return const _SceneTuning(
          compressionRatio: 1.3,
          compressionKnee: 60.0,
          expansionKnee: 35.0,
          nrLevel: 0,
          tnrEnabled: false,
          volumeDeltaDb: 0.0,
        );
      case SceneClass.unknown:
        return const _SceneTuning(
          compressionRatio: 1.5,
          compressionKnee: 55.0,
          expansionKnee: 35.0,
          nrLevel: 1,
          tnrEnabled: false,
          volumeDeltaDb: 0.0,
        );
    }
  }
}

class _SceneTuning {
  final double compressionRatio;
  final double compressionKnee;
  final double expansionKnee;
  final int nrLevel;
  final bool tnrEnabled;
  final double volumeDeltaDb;

  const _SceneTuning({
    required this.compressionRatio,
    required this.compressionKnee,
    required this.expansionKnee,
    required this.nrLevel,
    required this.tnrEnabled,
    required this.volumeDeltaDb,
  });
}
