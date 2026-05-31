/// @file iso_targets.dart
/// @brief Targets de calibración según ISO 389-7 (campo libre frontal).
///
/// Valores en dB SPL para "0 dB HL" (umbral normal) en campo libre con
/// fuente frontal a 1 m, listener binaural (parlante BT enfrente del celu).
///
/// Para calibración a un nivel de prueba (ej. 70 dB HL), se suma ese
/// nivel al valor de referencia de la tabla.
///
/// Fuente: ISO 389-7:2019. Valores parafraseados de la norma para
/// cumplimiento de licencias.

class IsoTargets {
  /// Tabla de RETSPL para campo libre frontal (ISO 389-7:2019, Tabla 1).
  /// Frecuencia (Hz) → dB SPL para 0 dB HL.
  static const Map<int, double> retsplFrontalFreeField = {
    125: 22.1,
    250: 11.4,
    500: 4.4,
    750: 2.4,
    1000: 2.4,
    1500: 2.4,
    2000: -1.3,
    3000: -5.8,
    4000: -5.4,
    6000: 4.3,
    8000: 12.6,
  };

  /// Calcula el target dB SPL para una frecuencia y nivel HL deseado.
  /// Si la freq no está en la tabla, devuelve null.
  static double? targetDbSplForHL(double freqHz, double levelHL) {
    final ref = retsplFrontalFreeField[freqHz.toInt()];
    if (ref == null) return null;
    return ref + levelHL;
  }

  /// Frecuencias estándar para test biológico de calibración.
  static const List<double> standardFreqs = [
    125,
    250,
    500,
    1000,
    2000,
    4000,
    6000,
    8000,
  ];
}
