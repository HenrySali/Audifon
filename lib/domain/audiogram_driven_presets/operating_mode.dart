/// Modo de operación de la aplicación.
///
/// Define cómo se comporta el motor de prescripción según haya o no
/// un audiograma medido para el usuario actual.
///
/// - [diagnostic]: hay un audiograma medido y se aplica la prescripción
///   completa derivada del mismo.
/// - [amplifier]: no hay audiograma medido; se usa un audiograma por defecto
///   ([defaultAudiogram]) escalado por una ganancia global ([gainScale]).
///
/// Requisitos: 13.1, 13.12
library;

/// Modo de operación de la app.
///
/// Ref: Requirement 13.1
enum OperatingMode {
  /// Audiograma medido presente → prescripción completa.
  diagnostic,

  /// Sin audiograma → defaultAudiogram × gainScale.
  amplifier,
}
