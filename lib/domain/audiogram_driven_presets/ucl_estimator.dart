import '../entities/audiogram.dart';

/// Estimador del Umbral de Disconfort (UCL, Uncomfortable Loudness Level)
/// por banda a partir del audiograma del paciente.
///
/// El UCL representa el nivel de presión sonora a partir del cual el sonido
/// se vuelve molesto para el paciente. Cuando no se mide en cabina con la
/// escala Cox Contour, se aproxima con la regresión clínica de NAL-NL2:
///
/// ```text
///     UCL[f] = 100 + 0.15 × HL[f]    (dB SPL)
/// ```
///
/// donde `HL[f]` es el umbral auditivo por banda en dB HL, previamente
/// clampado al rango clínicamente útil `[0, 120] dB HL` (los valores fuera
/// de ese rango no agregan información: por debajo de 0 ya es audición
/// normal, por encima de 120 el audífono no puede prescribir más ganancia
/// segura). El estimador es una función pura y determinista: no depende del
/// reloj ni de side-effects, así dos llamadas con los mismos argumentos
/// producen idéntico resultado.
///
/// Cuando el clínico mide UCL en cabina (escala Cox Contour, escala loudness
/// growth) puede pasar esos valores en `measuredUcl`, mapeados por
/// frecuencia en Hz. Para cada banda, el estimador prefiere el valor medido
/// sobre la fórmula. Las bandas ausentes en el mapa caen automáticamente a
/// la regresión.
///
/// **Aproximación clínica.** El MPO derivado de UCL estimado (con
/// `UCL ≈ 100 + 0.15 × HL`) es una aproximación. Para fitting clínico
/// certificado, medir UCL con escala Cox Contour y reemplazar
/// `measuredUcl` por los valores reales.
///
/// **Fuente bibliográfica:**
/// - Dillon, H. (2012). *Hearing Aids* (2nd ed.), Cap. 4.3 "Uncomfortable
///   Loudness Levels", pp. 88–91. Boomerang Press.
/// - Keidser, G., Dillon, H., Flax, M., Ching, T., & Brewer, S. (2011).
///   "The NAL-NL2 prescription procedure". *Audiology Research*, 1(1), e24.
///
/// **Documento del proyecto:** ver
/// `docs/07-calibracion-audiograma/analisis-prescripcion-real-vs-simulador.md`
/// §6.3 "Estimación de UCL y derivación de MPO por banda".
///
/// Requisitos: 2.1, 2.2, 2.6
class UclEstimator {
  /// Pendiente de la regresión NAL-NL2 entre HL y UCL (dB SPL por dB HL).
  static const double _slope = 0.15;

  /// Intercepto de la regresión NAL-NL2 (dB SPL).
  static const double _intercept = 100.0;

  /// Valor mínimo del umbral HL antes de aplicar la fórmula (dB HL).
  static const double _hlMinDbHl = 0.0;

  /// Valor máximo del umbral HL antes de aplicar la fórmula (dB HL).
  ///
  /// Por encima de 120 dB HL el audífono no puede prescribir más ganancia
  /// segura, así que clampar evita generar UCLs fuera de rango.
  static const double _hlMaxDbHl = 120.0;

  /// Estima los 12 valores de UCL en dB SPL para las bandas estándar del
  /// audiograma.
  ///
  /// **Parámetros:**
  /// - [audiogram]: audiograma del paciente. Se leen los umbrales por banda
  ///   en dB HL desde `audiogram.thresholds[f]` para cada `f` en
  ///   [Audiogram.standardFrequencies] (250–8000 Hz, 12 bandas). Las bandas
  ///   ausentes se tratan como `0 dB HL` (audición normal) ya que el
  ///   contrato espera 12 bandas validadas aguas arriba en `BundleBuilder`.
  /// - [measuredUcl]: mapa opcional de frecuencia (Hz) a UCL medido en
  ///   dB SPL. Cuando una frecuencia está presente en el mapa, su valor se
  ///   usa tal cual (sin clamping ni regresión). Las frecuencias ausentes
  ///   caen a la fórmula `UCL = 100 + 0.15 × HL`.
  ///
  /// **Retorna:** lista de 12 `double` con el UCL estimado en dB SPL por
  /// banda, en el mismo orden que [Audiogram.standardFrequencies]. Los
  /// valores producidos por la fórmula viven en `[100, 118] dB SPL` (porque
  /// HL queda clampado a `[0, 120]`); los valores tomados de `measuredUcl`
  /// pueden estar fuera de ese rango si el clínico midió valores extremos.
  ///
  /// **Referencias:**
  /// - Documento del proyecto:
  ///   [`docs/07-calibracion-audiograma/analisis-prescripcion-real-vs-simulador.md`](../../../../../docs/07-calibracion-audiograma/analisis-prescripcion-real-vs-simulador.md)
  ///   §6.3 "Estimación de UCL cuando no hay medición".
  /// - Dillon, H. (2012). *Hearing Aids* (2nd ed.), Cap. 4.3, pp. 88–91.
  /// - Keidser et al. (2011), "The NAL-NL2 prescription procedure",
  ///   *Audiology Research* 1(1):e24.
  ///
  /// **Disclaimer clínico:** la regresión `UCL ≈ 100 + 0.15 × HL` es
  /// una aproximación clínica. Para fitting clínico certificado, medir
  /// UCL con escala Cox Contour y reemplazar `measuredUcl` por los
  /// valores reales.
  ///
  /// **Ejemplo de uso:**
  /// ```dart
  /// import 'package:hearing_aid_app/domain/entities/audiogram.dart';
  /// import 'package:hearing_aid_app/domain/audiogram_driven_presets/ucl_estimator.dart';
  ///
  /// // Audiograma plano de 30 dB HL en las 12 bandas estándar.
  /// final audiogram = Audiogram(thresholds: {
  ///   for (final f in Audiogram.standardFrequencies) f: 30.0,
  /// });
  ///
  /// // Sin UCL medido → todas las bandas usan la fórmula.
  /// // UCL[f] = 100 + 0.15 × 30 = 104.5 dB SPL para cada banda.
  /// final ucl = UclEstimator.estimate(audiogram);
  /// // ucl == [104.5, 104.5, 104.5, ..., 104.5] (longitud 12).
  ///
  /// // Con UCL medido en 1000 Hz → solo esa banda toma el valor medido.
  /// final uclMixed = UclEstimator.estimate(
  ///   audiogram,
  ///   measuredUcl: {1000: 95.0},
  /// );
  /// // uclMixed[3] == 95.0 (banda 1000 Hz, valor medido)
  /// // uclMixed[otros] == 104.5 (regresión)
  /// ```
  static List<double> estimate(
    Audiogram audiogram, {
    Map<int, double>? measuredUcl,
  }) {
    final result = <double>[];
    for (final frequency in Audiogram.standardFrequencies) {
      // Preferir UCL medido si está disponible para esta banda; el valor
      // medido se usa tal cual (sin clamping) porque representa la medición
      // clínica del paciente.
      if (measuredUcl != null && measuredUcl.containsKey(frequency)) {
        result.add(measuredUcl[frequency]!);
        continue;
      }

      // Fallback: aplicar la regresión NAL-NL2 con HL clampado al rango
      // clínicamente útil `[0, 120] dB HL`.
      final rawHl = audiogram.thresholds[frequency] ?? 0.0;
      final clampedHl = rawHl.clamp(_hlMinDbHl, _hlMaxDbHl);
      result.add(_intercept + _slope * clampedHl);
    }
    return result;
  }
}
