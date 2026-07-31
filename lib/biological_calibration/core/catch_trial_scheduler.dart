import 'dart:math' as math;

/// Decide aleatoriamente cuándo intercalar un *catch trial* dentro de la
/// secuencia de presentaciones del algoritmo Hughson-Westlake.
///
/// Un catch trial es una presentación donde **no** se emite tono pero se
/// registra si el sujeto presiona el botón. Sirve para detectar respondedores
/// compulsivos y estimar la tasa de falsos positivos.
///
/// Reglas de inserción (ver `investigaciones/calibracion-biologica-parametros-tecnicos.md` §8.3):
/// - Ratio configurable: por defecto 1 catch trial cada 6 presentaciones (~16%).
/// - Distribución aleatoria uniforme **dentro de cada bloque** de `ratio`
///   presentaciones (al menos un catch trial por bloque).
/// - Nunca dos catch trials consecutivos: si la posición elegida en el bloque
///   anterior fue la última, la del siguiente bloque no puede ser la primera.
/// - El sujeto no debe poder anticipar cuándo es catch trial.
///
/// La clase es determinística cuando se le pasa un [seed], lo que permite
/// reproducibilidad en tests. Llamadas repetidas a [shouldBeCatchTrial] con el
/// mismo `presentationIndex` siempre devuelven el mismo resultado dentro de
/// una misma instancia (hasta llamar a [reset]).
class CatchTrialScheduler {
  /// Cantidad de presentaciones por bloque. El catch trial cae en exactamente
  /// una de las `ratio` posiciones del bloque. Por defecto 6 → ~16,6 %.
  final int ratio;

  final math.Random _random;

  /// Cache de la posición elegida para cada bloque. Garantiza que llamadas
  /// repetidas con el mismo índice devuelvan el mismo resultado.
  final Map<int, int> _blockCatchPositions = <int, int>{};

  /// [ratio] debe ser >= 2 para que tenga sentido elegir aleatoriamente dentro
  /// del bloque. Si [seed] es `null` se usa una fuente de aleatoriedad del
  /// sistema; si se pasa un valor, la secuencia es reproducible.
  CatchTrialScheduler({this.ratio = 6, int? seed})
      : assert(ratio >= 2, 'ratio must be >= 2 to randomize within a block'),
        _random = seed != null ? math.Random(seed) : math.Random();

  /// Devuelve `true` si la presentación con índice global [presentationIndex]
  /// (0-based) debe ser un catch trial.
  ///
  /// Llamadas con el mismo índice son idempotentes. Llamadas a índices
  /// negativos devuelven `false`.
  bool shouldBeCatchTrial(int presentationIndex) {
    if (presentationIndex < 0) return false;
    final blockIndex = presentationIndex ~/ ratio;
    final positionInBlock = presentationIndex % ratio;
    final catchPosition = _getOrChooseCatchPosition(blockIndex);
    return positionInBlock == catchPosition;
  }

  /// Obtiene (o elige por primera vez) la posición del catch trial dentro del
  /// bloque [blockIndex], respetando la regla de no-consecutivos respecto al
  /// bloque anterior si éste ya fue calculado.
  int _getOrChooseCatchPosition(int blockIndex) {
    final cached = _blockCatchPositions[blockIndex];
    if (cached != null) return cached;

    // Si ya conocemos la posición del bloque anterior y cayó en la última
    // posición del bloque, debemos excluir la posición 0 del bloque actual
    // para no producir dos catch trials consecutivos.
    final previousPosition =
        blockIndex > 0 ? _blockCatchPositions[blockIndex - 1] : null;
    final mustExcludeFirst = previousPosition == ratio - 1;

    final int chosen;
    if (mustExcludeFirst) {
      // Elegir uniforme en [1, ratio - 1].
      chosen = 1 + _random.nextInt(ratio - 1);
    } else {
      // Elegir uniforme en [0, ratio - 1].
      chosen = _random.nextInt(ratio);
    }

    _blockCatchPositions[blockIndex] = chosen;
    return chosen;
  }

  /// Reinicia el estado interno: olvida las posiciones elegidas para cada
  /// bloque. Útil al cambiar de frecuencia o de sujeto.
  ///
  /// No re-siembra el [math.Random] interno, así que la secuencia que sigue
  /// continúa siendo determinística respecto al `seed` original.
  void reset() {
    _blockCatchPositions.clear();
  }
}
