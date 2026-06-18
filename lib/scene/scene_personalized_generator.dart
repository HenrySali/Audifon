/// Smart Scene Engine — Fase 3 (refactor audiogram-driven-presets task 6.1).
///
/// Generador personalizado: parte de las ganancias [AudiogramDrivenBundle]
/// — ya derivadas del audiograma del paciente vía [BundleBuilder] — y
/// aplica los deltas por banda definidos en el `design.md` para cada
/// `SceneClass`. Aplica también un clamp por banda usando el perfil MPO
/// del bundle como techo:
///
///   `maxSafeGain[i] = bundle.mpoProfileDbSpl[i] - input_db_spl - safety_margin`
///
/// Donde `safety_margin = 3 dB`. Esto garantiza que la salida nunca
/// excede el MPO del paciente — calculado individualmente a partir de
/// `UCL = 100 + 0.15 × HL` con la regla adulto/pediátrica — aunque el
/// EQ amplifique. Reemplaza el literal hardcoded `mpoThresholdDbSpl =
/// 110.0` que usaba la versión anterior (Req 7.7, 10.3, 10.4).
///
/// Las bandas cuyo target gain excede el headroom por ≥ 0.1 dB se
/// reportan en `SmartPreset.clampedBands` para que la UI pueda
/// resaltarlas (Req 10.6).
///
/// Validates: Requirements 7.1, 7.4, 7.7, 10.3, 10.4, 10.6

import '../domain/audiogram_driven_presets/audiogram_driven_bundle.dart';
import 'scene_snapshot.dart' show SceneClass, SceneSnapshot;
import 'smart_preset.dart';

class ScenePersonalizedPresetGenerator {
  /// Margen de seguridad para crest factor.
  final double safetyMarginDb;

  /// Ganancia máxima permitida por banda (limita el techo absoluto
  /// como red de seguridad después del clamp por banda; se conserva en
  /// 50 dB por Req 10.5).
  final double absoluteMaxGainDb;

  /// Tolerancia para reportar una banda como clampada en
  /// [SmartPreset.clampedBands]. Si `target_gain - clampedGain ≥`
  /// este valor, la banda se considera clampada (Req 10.6).
  final double clampReportThresholdDb;

  ScenePersonalizedPresetGenerator({
    this.safetyMarginDb = 3.0,
    this.absoluteMaxGainDb = 50.0,
    this.clampReportThresholdDb = 0.1,
  });

  /// Genera un `SmartPreset` partiendo del [bundle] audiograma-derivado
  /// y aplicando deltas según la escena.
  ///
  /// El [bundle] aporta:
  /// - `gainsDb` per-band como base de la ecualización.
  /// - `mpoProfileDbSpl[f]` per-band como techo de headroom (sustituye
  ///   el literal hardcoded de 110 dB SPL — Req 7.7).
  /// - `compressionRatios`, `compressionKneesDbSpl` se preservan (no
  ///   se modifican aquí; el bloc los pasa al bridge tal cual).
  ///
  /// El [snapshot] aporta el `inputDbSpl` para calcular el headroom.
  /// El [confidence] se propaga a [SmartPreset.confidence].
  SmartPreset generate({
    required AudiogramDrivenBundle bundle,
    required SceneClass sceneClass,
    required SceneSnapshot snapshot,
    required double confidence,
  }) {
    // 1) Base = ganancias del bundle (ya prescritas a partir del audiograma).
    final base = bundle.gainsDb;

    // 2) Delta por banda según la escena.
    final delta = _deltasFor(sceneClass);

    // 3) Headroom por banda usando el perfil MPO del bundle.
    final input = snapshot.inputDbSpl;

    final gains = List<double>.filled(
      AudiogramDrivenBundle.bandCount,
      0.0,
      growable: false,
    );
    final clamped = <int>[];

    for (var i = 0; i < AudiogramDrivenBundle.bandCount; i++) {
      final target = base[i] + delta[i];
      final maxSafePerBand = (bundle.mpoProfileDbSpl[i] - input - safetyMarginDb)
          .clamp(0.0, absoluteMaxGainDb)
          .toDouble();

      var g = target;
      if (g < 0.0) g = 0.0;
      if (g > maxSafePerBand) g = maxSafePerBand;
      if (g > absoluteMaxGainDb) g = absoluteMaxGainDb;

      gains[i] = g;

      // Reportar como clampada si el target real excedía el headroom
      // por ≥ clampReportThresholdDb (Req 10.6). Sólo reportamos cuando
      // hubo recorte efectivo (no cuando el target ya estaba dentro).
      if (target - g >= clampReportThresholdDb) {
        clamped.add(i);
      }
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
      clampedBands: List<int>.unmodifiable(clamped),
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
          compressionRatio: 1.8,
          compressionKnee: 50.0,
          expansionKnee: 35.0,
          nrLevel: 2,
          tnrEnabled: false,
          volumeDeltaDb: -1.0,
        );
      case SceneClass.voiceInNoiseLow:
        return const _SceneTuning(
          compressionRatio: 1.7,
          compressionKnee: 50.0,
          expansionKnee: 35.0,
          nrLevel: 3,
          tnrEnabled: true,
          volumeDeltaDb: -2.0,
        );
      case SceneClass.noiseLowDominant:
        return const _SceneTuning(
          compressionRatio: 1.7,
          compressionKnee: 50.0,
          expansionKnee: 35.0,
          nrLevel: 3,
          tnrEnabled: true,
          volumeDeltaDb: -3.0,
        );
      case SceneClass.noiseHighDominant:
        return const _SceneTuning(
          compressionRatio: 1.8,
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
