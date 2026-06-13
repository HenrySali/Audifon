// Helpers puros para la pantalla "Diagnóstico DSP" del técnico.
//
// Este archivo NO debe importar `package:flutter/*`, blocs, repositorios ni el
// `AudioBridge`. Las funciones aquí son aritmética pura y existen para poder
// testearse aisladas (PBT con `glados`) sin necesidad de instanciar la screen.
//
// Replicado bit a bit del helper estático del paciente
// (`PACIENTE/oir_pro_patient_app/lib/presentation/diagnostico_dsp_screen.dart`,
// método `DiagnosticoDspScreenState.computeCountdown`) para garantizar que el
// countdown del técnico se comporta exactamente igual.

/// Calcula los segundos restantes de la grabación de Diagnóstico DSP a partir
/// del tiempo transcurrido en milisegundos.
///
/// La grabación nominal dura 15 s (15 000 ms). El countdown decrece de 15 a 0
/// con resolución de 1 s, y queda saturado en 0 una vez alcanzados o
/// sobrepasados los 15 000 ms (incluye el caso `elapsedMs == 15000`).
///
/// Fórmula equivalente al paciente (Property 7 del diagnóstico):
///
/// ```
/// elapsedMs >= 15000 ? 0 : 15 - (elapsedMs ~/ 1000)
/// ```
///
/// Garantías:
/// - Total para todo `int` no negativo en `[0, 15000)` retorna un valor en
///   `[1, 15]`.
/// - Para todo `elapsedMs >= 15000` retorna exactamente `0` (sin valores
///   negativos).
/// - `elapsedMs == 0` retorna `15`.
/// - Función pura: sin efectos secundarios y sin dependencias externas.
///
/// Cubre los Acceptance Criteria 6.1 y 6.3 del spec
/// `tecnico-paciente-feature-parity` (duración 15 s y polling de progreso a
/// 1 Hz cuyo display usa este countdown).
int computeCountdown(int elapsedMs) {
  if (elapsedMs >= 15000) return 0;
  return 15 - (elapsedMs ~/ 1000);
}
