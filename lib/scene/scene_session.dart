/// Smart Scene Engine — Fase 2.
///
/// Una sesión de análisis acumula snapshots durante una ventana de tiempo y
/// devuelve la clase dominante por votación, junto con la confianza
/// promedio de los votos a esa clase.
///
/// Validates: Requirements 7.4

import 'scene_decision_maker.dart';
import 'scene_snapshot.dart';

class SceneSessionResult {
  final SceneClass dominantClass;
  final double averageConfidence;
  final int sampleCount;
  final Map<SceneClass, int> distribution;
  final SceneSnapshot lastSnapshot;

  const SceneSessionResult({
    required this.dominantClass,
    required this.averageConfidence,
    required this.sampleCount,
    required this.distribution,
    required this.lastSnapshot,
  });
}

/// Acumula muestras + decisiones durante una ventana fija y resuelve la
/// clase dominante por votación.
class SceneSession {
  /// Cantidad mínima de snapshots a acumular antes de poder resolver.
  final int minSamples;

  /// Cantidad máxima a acumular (después de esto se cierra la sesión).
  final int maxSamples;

  final SceneDecisionMaker decisionMaker;

  final List<SceneDecision> _decisions = [];
  SceneSnapshot? _lastSnapshot;

  SceneSession({
    SceneDecisionMaker? decisionMaker,
    this.minSamples = 10,
    this.maxSamples = 25,
  })  : decisionMaker =
            decisionMaker ?? SceneDecisionMaker(holdMs: 0); // sin hist en sesión

  /// Suma una muestra al buffer interno y registra la decisión cruda.
  void add(SceneSnapshot snapshot, {DateTime? now}) {
    final decision = decisionMaker.evaluate(snapshot, now: now);
    _decisions.add(decision);
    _lastSnapshot = snapshot;
  }

  /// Cantidad de muestras acumuladas hasta ahora.
  int get sampleCount => _decisions.length;

  /// Si llegó al máximo de muestras la sesión está completa.
  bool get isFull => _decisions.length >= maxSamples;

  /// True cuando ya se puede resolver con los datos actuales.
  bool get canResolve => _decisions.length >= minSamples;

  /// Limpia el estado para reutilizar la instancia.
  void reset() {
    _decisions.clear();
    _lastSnapshot = null;
    decisionMaker.reset();
  }

  /// Devuelve la clase dominante por votación. Lanza StateError si no se
  /// acumularon suficientes muestras.
  SceneSessionResult resolve() {
    if (_decisions.isEmpty || _lastSnapshot == null) {
      throw StateError('SceneSession.resolve() sin muestras');
    }

    final histogram = <SceneClass, int>{};
    final confidenceSum = <SceneClass, double>{};

    for (final d in _decisions) {
      histogram.update(d.sceneClass, (v) => v + 1, ifAbsent: () => 1);
      confidenceSum.update(d.sceneClass, (v) => v + d.confidence,
          ifAbsent: () => d.confidence);
    }

    SceneClass best = SceneClass.unknown;
    int bestCount = -1;
    histogram.forEach((cls, count) {
      if (count > bestCount) {
        bestCount = count;
        best = cls;
      }
    });

    final avgConf = (confidenceSum[best] ?? 0.0) /
        (histogram[best] ?? 1).toDouble();

    return SceneSessionResult(
      dominantClass: best,
      averageConfidence: avgConf.clamp(0.0, 1.0),
      sampleCount: _decisions.length,
      distribution: Map.unmodifiable(histogram),
      lastSnapshot: _lastSnapshot!,
    );
  }
}
