/// Enumeraciones de modo de prescripción y de prescriptor.
///
/// Define los modos operativos del sistema de prescripción:
/// - [PrescriptionMode]: modo de cálculo de ganancia (quiet, CIN, MHL).
/// - [PrescriberMode]: selección de algoritmo prescriptor (NL2 vs NL3).
///
/// Requisitos: 5.1, 5.2, 5.3, 6.1, 6.2
library;

/// Modo de prescripción activo — determina qué pipeline de cálculo
/// de ganancia se usa para generar los targets del EQ.
///
/// - [quiet]: prescripción base (core NL3 o NL2 según el prescriptor).
/// - [comfortInNoise]: módulo CIN activo, reduce ganancia en bandas
///   no-speech para confort en ambientes ruidosos.
/// - [mhl]: ganancia mínima flat para pacientes con pérdida mínima
///   que necesitan features de reducción de ruido.
enum PrescriptionMode {
  /// Prescripción base en ambiente silencioso o de habla.
  quiet,

  /// Comfort in Noise — reduce fatiga auditiva en ruido
  /// preservando la banda de habla (500–4000 Hz).
  comfortInNoise,

  /// Minimal Hearing Loss — ganancia flat mínima con NR máximo
  /// para pacientes con audiograma normal.
  mhl,
}

/// Modo de prescriptor seleccionado por el usuario en la UI.
///
/// Determina qué algoritmo de prescripción se emplea:
/// - [smartNl2]: prescriptor NAL-NL2 existente (tabla de lookup).
/// - [smartNl3]: prescriptor NAL-NL3-inspired con clasificación de
///   audiograma, correcciones por tipo de pérdida y módulo CIN.
enum PrescriberMode {
  /// Prescriptor NAL-NL2 existente — tabla de lookup con interpolación.
  smartNl2,

  /// Prescriptor NAL-NL3-inspired — correcciones por loss type + CIN.
  smartNl3,
}
