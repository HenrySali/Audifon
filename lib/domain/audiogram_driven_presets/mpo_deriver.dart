import '../entities/patient_profile.dart';
import 'audiogram_driven_bundle.dart';

/// Función pura que deriva el perfil MPO (Maximum Power Output) por banda
/// a partir de un perfil UCL (Uncomfortable Loudness Level), aplicando un
/// margen de seguridad y un techo absoluto que dependen de la edad del
/// paciente.
///
/// El MPO es el techo de salida del audífono y protege al paciente de la
/// exposición a niveles incómodos o lesivos. La regla canónica es:
///
/// ```
/// MPO[f] = UCL[f] - safety_margin
/// ```
///
/// donde `safety_margin` es 5 dB en adultos y 10 dB en pediátricos
/// (DSL v5). Adicionalmente se aplica un techo absoluto en dB SPL:
/// 132 dB SPL en adultos (límite duro de electrónica + tolerancia
/// audiológica) y 110 dB SPL en pediátricos (recomendación AAA / DSL v5
/// para evitar TTS o NIHL en oídos pequeños). Como protección adicional
/// se hace un clamp final al rango operativo del limitador del pipeline
/// `[80, 132] dB SPL`, sustituyendo cualquier valor fuera de rango por
/// el bound más cercano.
///
/// Es una función pura: identidad de inputs → identidad de outputs, sin
/// side-effects ni lectura de reloj. La detección pediátrica se basa
/// exclusivamente en `profile.ageYears`. Si `profile` es null, o
/// `profile.ageYears` es null, o `profile.ageYears >= 18` se aplica la
/// regla adulto.
///
/// **Disclaimer clínico:** el MPO derivado de UCL estimado (vía
/// [UclEstimator] con `UCL ≈ 100 + 0.15 × HL`) es una aproximación
/// clínica. Para fitting clínico certificado, medir UCL con escala Cox
/// Contour y pasar el `measuredUcl` directo al [UclEstimator] antes de
/// invocar [MpoDeriver.derive]. La aproximación se propaga en cascada:
/// si UCL es estimado, entonces MPO también lo es.
///
/// ## Fuentes
///
/// - DSL v5 — Bagatto et al. (2005), *Clinical protocols for hearing
///   instrument fitting in the Desired Sensation Level method*, Trends
///   in Amplification 9(4): 199–226.
/// - AAA Pediatric Amplification Guidelines — Bagatto et al. (2016),
///   American Academy of Audiology.
/// - FDA OTC Hearing Aid Rule, 21 CFR § 800.30 (límite operativo
///   máximo de OSPL90 = 132 dB SPL para audífonos OTC).
/// - [Hearing Review — MPO comparativo](https://hearingreview.com/hearing-products/testing-equipment/testing-diagnostics-equipment/mpos)
///   y [PMC9325086](https://pmc.ncbi.nlm.nih.gov/articles/PMC9325086/).
/// - Documento padre del spec:
///   `docs/07-calibracion-audiograma/analisis-prescripcion-real-vs-simulador.md`
///   §6.4 "De UCL a MPO".
///
/// Requisitos: 2.3, 2.4, 2.5, 2.7
class MpoDeriver {
  /// Edad de corte (en años cumplidos) para aplicar la regla pediátrica.
  /// Estrictamente menor a este valor → pediátrico.
  static const int pediatricAgeCutoff = 18;

  /// Margen de seguridad por debajo del UCL para la regla adulto, en dB.
  static const double adultSafetyMarginDb = 5.0;

  /// Margen de seguridad por debajo del UCL para la regla pediátrica, en dB.
  /// Recomendación DSL v5 / AAA.
  static const double pediatricSafetyMarginDb = 10.0;

  /// Techo absoluto del MPO en adultos, en dB SPL (FDA OTC).
  static const double adultCeilingDbSpl = AudiogramDrivenBundle.mpoMaxDbSpl;

  /// Techo absoluto del MPO en pediátricos, en dB SPL (AAA / DSL v5).
  static const double pediatricCeilingDbSpl = 110.0;

  /// Bound inferior del clamp final del perfil MPO, en dB SPL.
  /// Sincronizado con el rango operativo del bundle.
  static const double mpoFloorDbSpl = AudiogramDrivenBundle.mpoMinDbSpl;

  /// Bound superior del clamp final del perfil MPO, en dB SPL.
  /// Sincronizado con el rango operativo del bundle.
  static const double mpoCeilingDbSpl = AudiogramDrivenBundle.mpoMaxDbSpl;

  /// Constructor privado: este módulo es puramente estático.
  const MpoDeriver._();

  /// Deriva el perfil MPO por banda a partir de un perfil UCL.
  ///
  /// ### Parámetros
  ///
  /// - [ucl]: perfil UCL por banda en dB SPL. Debe ser una lista del
  ///   mismo largo que las 12 frecuencias estándar
  ///   ([AudiogramDrivenBundle.bandCount]). Se itera elemento a elemento
  ///   sin reordenar.
  /// - [profile]: perfil del paciente (opcional). Solo se lee
  ///   `profile.ageYears` para la decisión adulto/pediátrico. Si es null
  ///   o `ageYears` es null, se aplica la regla adulto.
  ///
  /// ### Retorno
  ///
  /// Una nueva [List<double>] inmutable (`growable: false`) con el
  /// mismo largo que [ucl] y cada valor en el rango `[80, 132] dB SPL`.
  /// El elemento `i` corresponde a la misma frecuencia estándar que
  /// `ucl[i]`.
  ///
  /// ### Reglas
  ///
  /// 1. **Adulto** (default, `ageYears >= 18` o `null` o `profile == null`):
  ///    `MPO[f] = min(UCL[f] - 5, 132)`.
  /// 2. **Pediátrico** (`ageYears < 18`):
  ///    `MPO[f] = min(UCL[f] - 10, 110)`.
  /// 3. **Clamp final**: cada valor resultante se acota al rango
  ///    `[80, 132]` dB SPL, sustituyendo cualquier valor fuera de rango
  ///    por el bound más cercano (Req 2.5).
  ///
  /// ### Referencias
  ///
  /// - Documento del proyecto:
  ///   [`docs/07-calibracion-audiograma/analisis-prescripcion-real-vs-simulador.md`](../../../../../docs/07-calibracion-audiograma/analisis-prescripcion-real-vs-simulador.md)
  ///   §6.4 "De UCL a MPO" (regla `UCL - safety_margin` y techo
  ///   absoluto), §6.5 "Por qué un MPO fijo de 110 dB SPL es inseguro
  ///   para algunos pacientes" (justificación pediátrica).
  /// - DSL v5 — Bagatto et al. (2005), *Trends in Amplification*
  ///   9(4):199–226.
  /// - AAA Pediatric Amplification Guidelines, Bagatto et al. (2016).
  ///
  /// ### Ejemplo
  ///
  /// ```dart
  /// import 'package:hearing_aid_app/domain/entities/patient_profile.dart';
  /// import 'package:hearing_aid_app/domain/audiogram_driven_presets/mpo_deriver.dart';
  ///
  /// // Adulto: UCL típico ~ 115 dB SPL para HL = 100 dB.
  /// final adult = const PatientProfile(experienceMonths: 24, ageYears: 35);
  /// final ucl = List<double>.filled(12, 115.0);
  /// final mpo = MpoDeriver.derive(ucl, profile: adult);
  /// // mpo[i] = min(115 - 5, 132) = 110 dB SPL para todas las bandas.
  ///
  /// // Pediátrico: el techo absoluto baja a 110 dB SPL.
  /// final child = const PatientProfile(experienceMonths: 6, ageYears: 8);
  /// final mpoChild = MpoDeriver.derive(ucl, profile: child);
  /// // mpoChild[i] = min(115 - 10, 110) = 105 dB SPL para todas las bandas.
  /// ```
  ///
  /// ### Pureza
  ///
  /// Función pura: no usa `DateTime.now()`, no muta el argumento [ucl]
  /// (el resultado es una lista nueva), y no escribe a estado global.
  static List<double> derive(
    List<double> ucl, {
    PatientProfile? profile,
  }) {
    final isPediatric = profile?.ageYears != null &&
        profile!.ageYears! < pediatricAgeCutoff;

    final safetyMargin =
        isPediatric ? pediatricSafetyMarginDb : adultSafetyMarginDb;
    final absoluteCeiling =
        isPediatric ? pediatricCeilingDbSpl : adultCeilingDbSpl;

    return List<double>.generate(
      ucl.length,
      (i) {
        final raw = ucl[i] - safetyMargin;
        final cappedByAbsolute = raw < absoluteCeiling ? raw : absoluteCeiling;
        // Clamp final al rango operativo del bundle [80, 132] dB SPL
        // (Req 2.5: sustituir valores fuera de rango por el bound más cercano).
        if (cappedByAbsolute < mpoFloorDbSpl) {
          return mpoFloorDbSpl;
        }
        if (cappedByAbsolute > mpoCeilingDbSpl) {
          return mpoCeilingDbSpl;
        }
        return cappedByAbsolute;
      },
      growable: false,
    );
  }
}
