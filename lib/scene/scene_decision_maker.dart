/// Smart Scene Engine — Fase 2.
///
/// Reglas de clasificación de escena a partir de un `SceneSnapshot`.
/// Aplica histéresis temporal: una vez emitida una clase con confianza C,
/// no se reemplaza por otra clase distinta antes de `holdMs` salvo que la
/// clase candidata supere `forceConfidence`.
///
/// Las reglas siguen el design.md y se basan en:
///   - VAD (`voiceActive`) para presencia de voz.
///   - Nivel de entrada (`inputDbSpl`) para silencio.
///   - SNR (`snrDb`) y mid-band SNR (`vadMidSnrDb`) para distinguir voz
///     limpia de voz en ruido.
///   - Tilt espectral (`spectralTiltDb`) para discriminar ruido grave
///     de ruido agudo.
///   - Flatness y centroide para detectar música.
///
/// Validates: Requirements 1.1, 1.2, 1.3, 1.4, 1.5, 1.6

import 'scene_snapshot.dart';

/// Resultado de una decisión, con clase, confianza y razón principal.
class SceneDecision {
  final SceneClass sceneClass;

  /// Confianza [0, 1] de la clase elegida.
  final double confidence;

  /// Etiqueta corta del criterio que disparó la decisión (debug/UI).
  final String reason;

  /// True cuando la clase fue forzada a permanecer por histéresis aunque
  /// la regla pura sugería cambiar.
  final bool heldByHysteresis;

  const SceneDecision({
    required this.sceneClass,
    required this.confidence,
    required this.reason,
    this.heldByHysteresis = false,
  });
}

/// Reglas + histéresis temporal para clasificar el ambiente.
class SceneDecisionMaker {
  /// Tiempo mínimo entre cambios de clase (ms). Una clase nueva sólo
  /// reemplaza la anterior si supera el `forceConfidenceThreshold`.
  final int holdMs;

  /// Si una nueva clase llega con confianza ≥ este valor, supera el hold.
  final double forceConfidenceThreshold;

  /// Umbral de nivel para silencio absoluto (dB SPL).
  final double silenceThresholdDbSpl;

  /// SNR (dB) por encima del cual se considera voz "limpia".
  final double cleanSpeechSnrDbThreshold;

  /// Mid-SNR (dB) por encima del cual sigue siendo voz utilizable en ruido.
  final double midSnrInNoiseThreshold;

  /// Tilt (dB/oct) por debajo del cual el ruido es "grave dominante".
  /// (-8 dB/oct: energía concentrada en bajos típica de subte / motores).
  final double lowDominantTiltMaxDbOct;

  /// Tilt por encima del cual el ruido es "agudo dominante".
  final double highDominantTiltMinDbOct;

  /// Flatness por debajo del cual una señal estable suele ser música.
  final double musicFlatnessMax;

  /// Centroide mínimo (Hz) para considerar música (espectro distribuido).
  final double musicCentroidMinHz;

  SceneDecision? _lastDecision;
  DateTime? _lastDecisionAt;

  SceneDecisionMaker({
    this.holdMs = 3000,
    this.forceConfidenceThreshold = 0.9,
    this.silenceThresholdDbSpl = 30.0,
    this.cleanSpeechSnrDbThreshold = 15.0,
    this.midSnrInNoiseThreshold = 6.0,
    this.lowDominantTiltMaxDbOct = -8.0,
    this.highDominantTiltMinDbOct = 2.0,
    this.musicFlatnessMax = 0.10,
    this.musicCentroidMinHz = 600.0,
  });

  /// Estado actual (puede ser null antes del primer `evaluate`).
  SceneDecision? get currentDecision => _lastDecision;

  /// Reinicia la histéresis.
  void reset() {
    _lastDecision = null;
    _lastDecisionAt = null;
  }

  /// Evalúa la regla pura sobre `snapshot` y aplica histéresis contra el
  /// estado anterior.
  ///
  /// `now` es opcional (sirve para tests); si no se pasa usa
  /// `DateTime.now()`.
  SceneDecision evaluate(SceneSnapshot snapshot, {DateTime? now}) {
    final fresh = _classify(snapshot);
    final t = now ?? DateTime.now();

    final last = _lastDecision;
    final lastAt = _lastDecisionAt;

    if (last == null || lastAt == null) {
      _lastDecision = fresh;
      _lastDecisionAt = t;
      return fresh;
    }

    if (fresh.sceneClass == last.sceneClass) {
      // Mismo veredicto: actualizar confidence (suavizado a favor de la
      // muestra reciente para que la UI vea cambios) pero conservar el
      // tiempo del primer cambio.
      final smoothed = (last.confidence * 0.6) + (fresh.confidence * 0.4);
      final updated = SceneDecision(
        sceneClass: fresh.sceneClass,
        confidence: smoothed.clamp(0.0, 1.0),
        reason: fresh.reason,
      );
      _lastDecision = updated;
      return updated;
    }

    // Veredicto distinto: aplicar histéresis temporal.
    final elapsed = t.difference(lastAt).inMilliseconds;
    final forceChange = fresh.confidence >= forceConfidenceThreshold;
    final holdExpired = elapsed >= holdMs;

    if (holdExpired || forceChange) {
      _lastDecision = fresh;
      _lastDecisionAt = t;
      return fresh;
    }

    // Mantener la clase anterior, marcando hysteresis.
    final held = SceneDecision(
      sceneClass: last.sceneClass,
      confidence: last.confidence,
      reason: 'hold ${last.reason}',
      heldByHysteresis: true,
    );
    _lastDecision = held;
    return held;
  }

  // ────────────────────────────────────────────────────────────────────
  // Reglas puras
  // ────────────────────────────────────────────────────────────────────

  SceneDecision _classify(SceneSnapshot s) {
    // 1) Silencio: nivel muy bajo. Tiene precedencia sobre todo lo demás.
    if (s.inputDbSpl < silenceThresholdDbSpl) {
      final conf = _confFromDistance(silenceThresholdDbSpl - s.inputDbSpl,
          fullAt: 10.0);
      return SceneDecision(
        sceneClass: SceneClass.silence,
        confidence: conf,
        reason: 'level<${silenceThresholdDbSpl.toStringAsFixed(0)}',
      );
    }

    // 2) Música: señal armónica estable, flatness baja, sin voz dominante.
    //    Requiere flatness baja Y centroide medio Y nivel alto.
    if (!s.voiceActive &&
        s.spectralFlatness < musicFlatnessMax &&
        s.spectralCentroidHz >= musicCentroidMinHz &&
        s.inputDbSpl >= 50.0) {
      final conf = (((musicFlatnessMax - s.spectralFlatness) /
                  musicFlatnessMax) *
              0.6 +
          ((s.spectralCentroidHz - musicCentroidMinHz) / 4000.0) * 0.4)
          .clamp(0.0, 1.0);
      return SceneDecision(
        sceneClass: SceneClass.music,
        confidence: conf,
        reason: 'low_flatness',
      );
    }

    // 3) Voz: VAD activo. Decidimos sub-clase por SNR y tilt.
    if (s.voiceActive) {
      if (s.snrDb >= cleanSpeechSnrDbThreshold) {
        final conf = _confFromDistance(
            s.snrDb - cleanSpeechSnrDbThreshold,
            fullAt: 10.0);
        return SceneDecision(
          sceneClass: SceneClass.voiceOnly,
          confidence: conf.clamp(0.5, 1.0),
          reason: 'voice+highSNR',
        );
      }

      // Voz en ruido: medir tilt para distinguir ruido grave vs medio.
      if (s.spectralTiltDb < lowDominantTiltMaxDbOct) {
        final conf = _confFromDistance(
            lowDominantTiltMaxDbOct - s.spectralTiltDb,
            fullAt: 6.0);
        return SceneDecision(
          sceneClass: SceneClass.voiceInNoiseLow,
          confidence: conf.clamp(0.5, 1.0),
          reason: 'voice+tilt<${lowDominantTiltMaxDbOct.toStringAsFixed(0)}',
        );
      }

      // SNR no es alto y tilt no es muy negativo → ruido medio.
      final conf = (1.0 - (s.snrDb / cleanSpeechSnrDbThreshold))
          .clamp(0.4, 1.0);
      return SceneDecision(
        sceneClass: SceneClass.voiceInNoiseMid,
        confidence: conf,
        reason: 'voice+midSNR',
      );
    }

    // 4) Sin voz, no silencio, no música → ruido. Decidir grave vs agudo.
    if (s.spectralTiltDb < lowDominantTiltMaxDbOct) {
      final conf = _confFromDistance(
          lowDominantTiltMaxDbOct - s.spectralTiltDb,
          fullAt: 8.0);
      return SceneDecision(
        sceneClass: SceneClass.noiseLowDominant,
        confidence: conf.clamp(0.4, 1.0),
        reason: 'noise+tilt<${lowDominantTiltMaxDbOct.toStringAsFixed(0)}',
      );
    }

    if (s.spectralTiltDb > highDominantTiltMinDbOct) {
      final conf = _confFromDistance(
          s.spectralTiltDb - highDominantTiltMinDbOct,
          fullAt: 8.0);
      return SceneDecision(
        sceneClass: SceneClass.noiseHighDominant,
        confidence: conf.clamp(0.4, 1.0),
        reason: 'noise+tilt>${highDominantTiltMinDbOct.toStringAsFixed(0)}',
      );
    }

    // Ruido balanceado sin voz: lo etiquetamos como noise_high_dominant
    // por convención (es el menos agresivo en términos de NR).
    return SceneDecision(
      sceneClass: SceneClass.noiseHighDominant,
      confidence: 0.4,
      reason: 'noise_balanced',
    );
  }

  /// Mapea una distancia (en unidades de la magnitud relevante) a una
  /// confianza saturada en [0, 1]. Cuando `distance == 0` da 0.5; cuando
  /// `distance == fullAt` da 1.0.
  static double _confFromDistance(double distance, {required double fullAt}) {
    if (distance < 0) return 0.5;
    if (fullAt <= 0) return 1.0;
    return (0.5 + 0.5 * (distance / fullAt)).clamp(0.5, 1.0);
  }
}
