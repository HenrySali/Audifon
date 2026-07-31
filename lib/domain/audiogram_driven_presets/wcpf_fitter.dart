/// WCPF — *Weighted Constrained Proportional Fitting* del audífono.
///
/// Algoritmo O(n) (sin iteraciones) que escala una prescripción de ganancia
/// por banda para que ninguna banda exceda el techo de hardware calibrado,
/// preservando lo más posible la **forma** de la curva (importante para
/// la inteligibilidad: la SII pondera 1–4 kHz por encima de los extremos).
///
/// La versión "simple" del clamp (recortar cada banda saturada por
/// separado) destruye la curva: la banda saturada se aplana al techo y
/// las no saturadas siguen como estaban, alterando la relación inter-banda.
/// El WCPF baja **toda** la curva por un factor `α` ponderado SII y solo
/// recurre al clamp duro como red de seguridad final.
///
/// Algoritmo:
///
/// 1. `ratio[i] = ceiling[i] / gains[i]` (cuando `gains[i] > epsilon` y la
///    banda está calibrada, es decir, `ceiling[i] < kSinRestriccionDb`).
/// 2. Bandas saturadas: aquellas con `ratio[i] < 1.0`.
/// 3. Si **ninguna** está saturada → retornar `gains` tal cual (no hace
///    falta escalar y no se pierde inteligibilidad).
/// 4. Si hay saturadas:
///    - `α = Σ w[i] · ratio[i] / Σ w[i]` para `i ∈ saturadas`
///      (con `w[i]` = pesos SII por banda, ANSI S3.5-1997).
///    - `fitted[i] = α · gains[i]` para todas las 12 bandas.
///    - Clamp final: `fitted[i] = min(fitted[i], ceiling[i])` por si el
///      promedio dejó alguna banda todavía por encima del techo (típico
///      cuando la banda más saturada tiene un peso SII bajo).
///
/// Las bandas con `gains[i] ≈ 0` o `ceiling[i] ≥ kSinRestriccionDb` se
/// excluyen del cómputo de `α` (no aportan: no hay nada que escalar
/// cuando la prescripción es 0, y "sin techo" se trata como 50 dB =
/// rango operativo completo del EQ).
///
/// **Backward compat**: si los 12 techos son `kSinRestriccionDb` (50 dB,
/// default sin calibrar), no hay bandas saturadas y la función retorna
/// `gains` intactos — la introducción del WCPF no altera el
/// comportamiento de instalaciones que aún no calibraron el techo.
library;

/// Pesos de importancia espectral para inteligibilidad de habla,
/// alineados con las 12 bandas estándar del audiograma del proyecto:
/// `250, 500, 750, 1000, 1500, 2000, 2500, 3000, 3500, 4000, 6000,
/// 8000 Hz`.
///
/// Aproximación monotónica de la *band importance function* del SII
/// (ANSI S3.5-1997, octava de 1/3 banda redistribuida a las 12 bandas
/// del proyecto). Lo que importa es el orden relativo: 1.5–4 kHz pesan
/// más que extremos (250, 8000 Hz). La suma no necesita ser exactamente
/// 1.0 porque el algoritmo normaliza por `Σ w[i]` sobre las bandas
/// saturadas.
const List<double> kSiiBandWeights12 = <double>[
  0.0083, // 250 Hz
  0.0185, // 500 Hz
  0.0289, // 750 Hz
  0.0398, // 1000 Hz
  0.0816, // 1500 Hz
  0.0980, // 2000 Hz
  0.1188, // 2500 Hz
  0.1063, // 3000 Hz
  0.0911, // 3500 Hz
  0.0676, // 4000 Hz
  0.0529, // 6000 Hz
  0.0249, // 8000 Hz
];

/// Techo "sin restricción" (default cuando el técnico no calibró la
/// banda). Cualquier banda con `ceiling[i] >= _kSinRestriccionDb`
/// se excluye del cómputo de `α`.
const double _kSinRestriccionDb = 50.0;

/// Umbral mínimo de ganancia para que una banda participe del cómputo
/// de `α`. Bandas con prescripción ≤ epsilon (ej. flat 0 dB en el
/// extremo agudo) no aportan información de saturación.
const double _kEpsilonDb = 1e-6;

/// Aplica WCPF: escala [gains] proporcionalmente para que ninguna
/// banda supere [ceiling], usando los pesos SII de [kSiiBandWeights12].
///
/// Contratos:
/// - [gains] y [ceiling] deben tener la misma longitud (típicamente 12).
/// - Si la longitud es != 12, se usa `1/n` como peso uniforme (se
///   preserva la idea de promedio aritmético — útil para tests con
///   vectores cortos).
/// - Si **todas** las bandas tienen `ceiling[i] >= kSinRestriccionDb`
///   (default sin calibrar), retorna [gains] sin modificar (cero
///   asignación adicional).
/// - El resultado es una `List<double>` no modificable.
List<double> fitPrescriptionToCeiling(
  List<double> gains,
  List<double> ceiling,
) {
  final n = gains.length;
  if (n == 0 || ceiling.length != n) {
    // Defensivo: si los vectores están desalineados, devolver gains
    // sin tocar y delegar la decisión al caller (que probablemente
    // ya tiene un fallback).
    return List<double>.unmodifiable(gains);
  }

  // Backward compat rápido: si ningún techo está calibrado, no hay
  // nada que escalar.
  bool anyCalibrated = false;
  for (var i = 0; i < n; i++) {
    if (ceiling[i] < _kSinRestriccionDb) {
      anyCalibrated = true;
      break;
    }
  }
  if (!anyCalibrated) {
    return List<double>.unmodifiable(gains);
  }

  // Pesos: si n == 12 usamos los SII canónicos; si no, peso uniforme
  // (garantiza que la función siga siendo testeable con vectores de
  // longitud arbitraria, sin asumir 12).
  final weights = (n == kSiiBandWeights12.length)
      ? kSiiBandWeights12
      : List<double>.filled(n, 1.0 / n);

  // 1. Identificar bandas saturadas y acumular promedio ponderado de
  //    `ratio[i] = ceiling[i] / gains[i]`.
  double weightedRatioSum = 0.0;
  double weightSum = 0.0;
  bool anySaturated = false;

  for (var i = 0; i < n; i++) {
    final g = gains[i];
    final c = ceiling[i];

    // Excluir bandas sin techo calibrado: el rango operativo del EQ
    // ya cubre 0..50 dB, no aportan información clínica.
    if (c >= _kSinRestriccionDb) continue;

    // Excluir bandas con prescripción ≈ 0 (no se puede saturar lo que
    // no se está amplificando).
    if (g <= _kEpsilonDb) continue;

    // Sanear gains/ceiling no finitos defensivamente (un NaN en gains
    // contagiaría todo el cómputo).
    if (!g.isFinite || !c.isFinite) continue;

    final ratio = c / g;

    if (ratio < 1.0) {
      anySaturated = true;
      final w = weights[i];
      weightedRatioSum += w * ratio;
      weightSum += w;
    }
  }

  // 2. Si nada está saturado → retornar gains tal cual.
  if (!anySaturated || weightSum <= 0.0) {
    return List<double>.unmodifiable(gains);
  }

  // 3. Calcular α (el promedio ponderado de los ratios saturados).
  final alpha = weightedRatioSum / weightSum;

  // 4. Aplicar α a TODAS las bandas (preservando la forma) y clampear
  //    al techo como red de seguridad final.
  final fitted = List<double>.filled(n, 0.0, growable: false);
  for (var i = 0; i < n; i++) {
    double v = gains[i] * alpha;
    final c = ceiling[i];

    // Clamp final solo cuando hay un techo calibrado (techo "sin
    // restricción" no debería actuar como cap real).
    if (c < _kSinRestriccionDb && v > c) {
      v = c;
    }
    // Piso 0: nunca emitimos ganancias negativas.
    if (v < 0.0) v = 0.0;
    fitted[i] = v;
  }

  return List<double>.unmodifiable(fitted);
}
