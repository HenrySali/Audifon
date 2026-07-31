import 'dart:developer' as developer;

import '../cin_module.dart';
import '../entities/audiogram.dart';
import '../entities/loss_type.dart';
import '../entities/nl3_prescription_result.dart';
import '../entities/patient_profile.dart';
import '../entities/prescription_mode.dart';
import '../gain_prescriber_nl3.dart';
import '../mhl_module.dart';
import 'audiogram_driven_bundle.dart';
import 'mpo_deriver.dart';
import 'operating_mode.dart';
import 'recd_provider.dart';
import 'ucl_estimator.dart';

/// Constructor del [AudiogramDrivenBundle] a partir del audiograma del
/// paciente.
///
/// Este builder es la fachada que ensambla en una sola estructura
/// inmutable los parámetros clínicos del pipeline DSP:
///
/// 1. **Ganancias EQ** y **ratios de compresión** por banda — delegados
///    al [GainPrescriberNL3] (NAL-NL3-inspired) cuando el modo no es
///    `mhl`, o al [MhlModule] cuando el modo es `mhl`. Esta separación
///    preserva la responsabilidad de la prescripción en los módulos
///    especializados (ver `nal-nl3-prescriptor` spec).
/// 2. **Knees de compresión por banda** — derivados de la severidad de
///    la pérdida con la regresión lineal documentada:
///    `knee[f] = (35 + (HL[f] / 120) × 30).clamp(35, 65)` en dB SPL.
/// 3. **UCL estimado** — vía [UclEstimator] (formula NAL-NL2 con
///    sustitución por `measuredUcl` cuando el clínico mide la escala
///    Cox Contour).
/// 4. **Perfil MPO** — vía [MpoDeriver], con regla adulto / pediátrica
///    según `profile.ageYears`.
/// 5. **Tiempos WDRC** — extraídos de [NL3PrescriptionResult.wdrcOverrides]
///    si el prescriptor los provee, o defaults clínicos
///    (`attack = 5 ms`, `release = 100 ms`).
/// 6. **Nivel de NR** — derivado del modo: `quiet → 1`,
///    `comfortInNoise → 2`, `mhl → 3`.
/// 7. **Knee de expansión** — broadband fijo en 35 dB SPL (default
///    actual de [WdrcParams.expansionKnee]).
///
/// El builder es una **función pura** sobre sus inputs: nunca usa
/// `DateTime.now()` directo dentro del cálculo; el timestamp del bundle
/// se inyecta vía [derivedAt] o, sólo en producción cuando se omite, se
/// resuelve al instante de construcción para que el bundle tenga un
/// `derivedAt` no nulo (ver Requirement 1.3).
///
/// **Aplicación del [gainScale].** En modo `OperatingMode.amplifier` el
/// builder multiplica las ganancias prescritas por el factor `gainScale`
/// (limitado al rango operativo `[0.10, 1.00]`) y vuelve a clampar al
/// rango `[0, 50] dB` del bundle. En modo `OperatingMode.diagnostic` se
/// mantiene la prescripción intacta y el bundle se construye con
/// `gainScale = 1.0` por contrato (Req 13.4): la limitación, la
/// compresión y el NR jamás se escalan, sólo las ganancias del EQ.
///
/// **Propagación de errores.** Si el módulo delegado lanza una
/// excepción (audiograma incompleto, valor fuera de rango, etc.) el
/// builder propaga la excepción al caller sin envoltura adicional, por
/// lo que el bloc puede emitir un estado de error con la causa
/// observable (Req 1.5).
///
/// **Aproximación clínica.** El bundle hereda la aproximación de UCL
/// del [UclEstimator] cuando el clínico no provee `measuredUcl`:
/// `UCL ≈ 100 + 0.15 × HL` es una regresión orientativa, **no** un
/// reemplazo de medición clínica. Para fitting clínico certificado,
/// medir UCL con escala Cox Contour y reemplazar `measuredUcl` por los
/// valores reales (ver [UclEstimator] y el README del spec
/// `audiogram-driven-presets`).
///
/// **Fuente bibliográfica:**
/// - Keidser, G., Dillon, H., Flax, M., Ching, T., & Brewer, S. (2011).
///   "The NAL-NL2 prescription procedure". *Audiology Research*, 1(1),
///   e24, §3 "Targets" y §5 "Compression".
/// - Dillon, H. (2012). *Hearing Aids* (2nd ed.), Boomerang Press,
///   Cap. 4 "Prescribing Gain" y Cap. 9 "Compression".
/// - Bagatto, M., et al. (2005). "Clinical protocols for hearing
///   instrument fitting in the Desired Sensation Level method".
///   *Trends in Amplification*, 9(4), 199–226 (regla pediátrica MPO).
///
/// **Documento del proyecto:**
/// [`docs/07-calibracion-audiograma/analisis-prescripcion-real-vs-simulador.md`](../../../../../docs/07-calibracion-audiograma/analisis-prescripcion-real-vs-simulador.md)
/// — §3 "NAL-NL2 real vs el simplificado del código", §6 "UCL y MPO
/// individualizado" y §9 "Compresión por banda".
///
/// Requisitos: 1.1, 1.3, 1.4, 1.5, 1.6, 13.4, 13.13
class BundleBuilder {
  /// Default del attack del WDRC en ms cuando el prescriptor no provee
  /// override. Valor estándar de [WdrcParams.attackMs].
  static const double _defaultWdrcAttackMs = 5.0;

  /// Default del release del WDRC en ms cuando el prescriptor no provee
  /// override. Valor estándar de [WdrcParams.releaseMs].
  static const double _defaultWdrcReleaseMs = 100.0;

  /// Knee de expansión broadband fijo, en dB SPL. Coincide con el
  /// default actual del compresor del pipeline DSP.
  static const double _defaultExpansionKneeDbSpl = 35.0;

  /// Bound inferior del umbral HL aceptado por el builder (dB HL).
  /// Valores por debajo se consideran inválidos (Req 1.6).
  static const double _hlMinDbHl = -10.0;

  /// Bound superior del umbral HL aceptado por el builder (dB HL).
  /// Valores por encima se consideran inválidos (Req 1.6).
  static const double _hlMaxDbHl = 120.0;

  /// Bound inferior del umbral HL para el cálculo del knee de
  /// compresión por banda. Valores por debajo se clampan a 0 antes de
  /// aplicar la fórmula (Req 1.4).
  static const double _hlClampMinForKnee = 0.0;

  /// Bound superior del umbral HL para el cálculo del knee de
  /// compresión por banda. Coincide con [_hlMaxDbHl].
  static const double _hlClampMaxForKnee = 120.0;

  /// Knee de compresión mínimo por banda, en dB SPL. Igual al rango
  /// declarado en [AudiogramDrivenBundle.compressionKneeMinDbSpl].
  static const double _kneeMinDbSpl =
      AudiogramDrivenBundle.compressionKneeMinDbSpl;

  /// Knee de compresión máximo por banda, en dB SPL. Igual al rango
  /// declarado en [AudiogramDrivenBundle.compressionKneeMaxDbSpl].
  static const double _kneeMaxDbSpl =
      AudiogramDrivenBundle.compressionKneeMaxDbSpl;

  /// Pendiente de la fórmula del knee: 30 dB sobre el rango HL.
  static const double _kneeSlopeDb = 30.0;

  /// Intercepto de la fórmula del knee: 35 dB SPL para HL = 0.
  static const double _kneeInterceptDbSpl = 35.0;

  /// Ganancia mínima del bundle, en dB.
  /// Sincronizada con [AudiogramDrivenBundle.gainMinDb].
  static const double _gainMinDb = AudiogramDrivenBundle.gainMinDb;

  /// Ganancia máxima del bundle, en dB.
  /// Sincronizada con [AudiogramDrivenBundle.gainMaxDb].
  static const double _gainMaxDb = AudiogramDrivenBundle.gainMaxDb;

  /// Bound inferior del [gainScale] del modo Amplificador.
  /// Sincronizado con [AudiogramDrivenBundle.gainScaleMin].
  static const double _gainScaleMin = AudiogramDrivenBundle.gainScaleMin;

  /// Bound superior del [gainScale] del modo Amplificador.
  /// Sincronizado con [AudiogramDrivenBundle.gainScaleMax].
  static const double _gainScaleMax = AudiogramDrivenBundle.gainScaleMax;

  /// Prescriptor NAL-NL3 inyectado. Por defecto se construye una
  /// instancia nueva, pero los tests pueden inyectar un mock o un
  /// prescriptor con dependencias falsas.
  final GainPrescriberNL3 _nl3Prescriber;

  /// Reloj inyectable para resolver el `derivedAt` del bundle cuando el
  /// caller no provee un timestamp explícito. Por defecto delega en
  /// `DateTime.now`. Inyectar un fake en tests preserva la pureza del
  /// builder y evita lecturas directas del reloj del sistema (Req 1.3).
  final DateTime Function() _clock;

  /// Construye un [BundleBuilder].
  ///
  /// ### Parámetros
  ///
  /// - [nl3Prescriber]: instancia opcional del prescriptor NAL-NL3 para
  ///   inyectarla en tests. Si es `null`, se construye una nueva
  ///   instancia de [GainPrescriberNL3] con todas sus dependencias por
  ///   defecto.
  /// - [clock]: función opcional que devuelve el `DateTime` actual.
  ///   Se invoca **sólo** cuando el caller de [buildFromAudiogram] no
  ///   provee [buildFromAudiogram.derivedAt], para popular el campo
  ///   `derivedAt` del bundle. Si es `null` se usa `DateTime.now` como
  ///   default. Inyectar un fake en tests permite verificar la pureza
  ///   del builder sin depender del reloj del sistema (Req 1.3).
  ///
  /// ### Retorno
  ///
  /// No aplica (constructor). Tras la construcción el builder queda
  /// listo para invocar [buildFromAudiogram] sin estado mutable
  /// adicional.
  ///
  /// ### Referencias
  ///
  /// - Documento del proyecto:
  ///   [`docs/07-calibracion-audiograma/analisis-prescripcion-real-vs-simulador.md`](../../../../../docs/07-calibracion-audiograma/analisis-prescripcion-real-vs-simulador.md)
  ///   §3.5 "NAL-NL2 — Propuesta concreta" (rol del prescriptor
  ///   inyectable).
  /// - Spec hermana `nal-nl3-prescriptor` (provee [GainPrescriberNL3]).
  ///
  /// ### Ejemplo
  ///
  /// ```dart
  /// // Producción: dependencias por defecto.
  /// final builder = BundleBuilder();
  ///
  /// // Test: inyectar un prescriptor con dependencias falsas y un
  /// // reloj fijo para verificar pureza.
  /// final fakePrescriber = GainPrescriberNL3(/* mocks */);
  /// final fixed = DateTime.utc(2026, 6, 3, 10, 0, 0);
  /// final testBuilder = BundleBuilder(
  ///   nl3Prescriber: fakePrescriber,
  ///   clock: () => fixed,
  /// );
  /// ```
  BundleBuilder({
    GainPrescriberNL3? nl3Prescriber,
    DateTime Function()? clock,
  })  : _nl3Prescriber = nl3Prescriber ?? GainPrescriberNL3(),
        _clock = clock ?? DateTime.now;

  /// Deriva un [AudiogramDrivenBundle] a partir del audiograma del
  /// paciente y del modo de prescripción solicitado.
  ///
  /// ### Parámetros
  ///
  /// - [audiogram]: audiograma del paciente. Debe contener exactamente
  ///   las 12 frecuencias de [Audiogram.standardFrequencies] (250, 500,
  ///   750, 1000, 1500, 2000, 2500, 3000, 3500, 4000, 6000, 8000 Hz) y
  ///   cada umbral debe estar en `[-10, 120] dB HL`. Si la validación
  ///   falla se lanza [ArgumentError] enumerando las frecuencias
  ///   faltantes y la lista completa requerida (Req 1.6).
  /// - [profile]: perfil del paciente (opcional). Cuando se omite se
  ///   asume usuario adulto experimentado sin componente conductivo y
  ///   sin UCL medido (Req 1.1).
  /// - [mode]: modo de prescripción activo. Determina el delegado
  ///   ([GainPrescriberNL3] para `quiet` / `comfortInNoise`,
  ///   [MhlModule] para `mhl`) y el [nrLevel] del bundle.
  /// - [measuredUcl]: mapa opcional `frecuencia (Hz) → UCL medido
  ///   (dB SPL)`. Las bandas presentes en el mapa usan el valor
  ///   medido; las ausentes caen a la regresión NAL-NL2 del
  ///   [UclEstimator].
  /// - [derivedAt]: timestamp UTC inyectable. Si es `null` el builder
  ///   resuelve `DateTime.now()` *sólo* para popular el campo final
  ///   del bundle; las funciones puras aguas abajo nunca leen el reloj
  ///   directo (Req 1.3).
  /// - [operatingMode]: modo de operación de la app. Default
  ///   [OperatingMode.diagnostic]. En `amplifier` se aplica el
  ///   [gainScale] sobre las ganancias EQ.
  /// - [gainScale]: factor multiplicativo del modo Amplificador. Rango
  ///   válido `[0.10, 1.00]` (Req 13.13). Si está fuera de rango,
  ///   contiene NaN o Infinity, se clampa al bound más cercano y se
  ///   emite un warning observable vía `dart:developer.log` (level
  ///   900). En modo Diagnóstico el factor se fuerza a `1.0` por
  ///   contrato (Req 13.4).
  /// - [recdProvider]: provider opcional de RECD (Real-Ear to 2cc
  ///   Coupler Difference). Cuando es no-null y `profile.ageYears`
  ///   está presente, el builder calcula `SPL_realear[f] = HL[f] +
  ///   RETSPL[f] + RECD[f, age, coupling]` para cada banda del
  ///   audiograma y emite los valores vía `dart:developer.log` (level
  ///   800, name `BundleBuilder.realEar`) para trazabilidad clínica.
  ///   El bundle producido **no** cambia con respecto al caso sin
  ///   provider — la conversión es informativa y se usa por los tests
  ///   de Tramo 2 (HL → SPL real-ear) y por superficies UI que
  ///   muestren el SPL al oído. Default `null` → comportamiento
  ///   anterior (HL como aproximación, sin emisión de SPL real-ear).
  ///   Ver [RecdProvider] y `docs/03-investigacion/ANSI_S3.6_Reference.md`
  ///   para fuentes primarias.
  /// - [recdCoupling]: configuración de coupling pasada al
  ///   [recdProvider]. Default [RecdCoupling.earmoldHa1] (la más
  ///   común en pediatría con BTE). Se ignora cuando [recdProvider]
  ///   es null o cuando no hay edad.
  ///
  /// ### Retorno
  ///
  /// Un [AudiogramDrivenBundle] inmutable con:
  /// - `gainsDb` (12 valores en `[0, 50] dB`),
  /// - `compressionRatios` (12 valores en `[1.0, 3.0]`),
  /// - `compressionKneesDbSpl` (12 valores en `[35, 65] dB SPL`),
  /// - `mpoProfileDbSpl` (12 valores en `[80, 132] dB SPL`),
  /// - `nrLevel` (entero en `[0, 3]`),
  /// - `wdrcAttackMs` (en `[1, 50] ms`),
  /// - `wdrcReleaseMs` (en `[20, 500] ms`),
  /// - `expansionKneeDbSpl` (en `[20, 50] dB SPL`),
  /// - `lossType`, `prescriptionMode`, `mode`, `gainScale`,
  ///   `derivedAt`.
  ///
  /// ### Errores
  ///
  /// - [ArgumentError] si el audiograma no tiene las 12 frecuencias
  ///   estándar o si algún umbral está fuera del rango `[-10, 120] dB HL`.
  /// - Cualquier excepción lanzada por [GainPrescriberNL3] o
  ///   [MhlModule] se propaga al caller sin envoltura adicional (Req 1.5).
  ///
  /// ### Referencias
  ///
  /// - Documento del proyecto:
  ///   [`docs/07-calibracion-audiograma/analisis-prescripcion-real-vs-simulador.md`](../../../../../docs/07-calibracion-audiograma/analisis-prescripcion-real-vs-simulador.md)
  ///   §3 "NAL-NL2 real vs el simplificado del código" (ganancias y
  ///   ratios), §6.3 "Estimación de UCL cuando no hay medición" y §6.4
  ///   "De UCL a MPO" (regla adulto/pediátrica), §9 "Compresión por
  ///   banda" (knees).
  /// - Keidser et al. (2011), "The NAL-NL2 prescription procedure",
  ///   *Audiology Research* 1(1):e24 — base del prescriptor delegado.
  /// - Bagatto et al. (2005), DSL v5 — base del techo MPO pediátrico.
  ///
  /// ### Ejemplo
  ///
  /// ```dart
  /// import 'package:hearing_aid_app/domain/entities/audiogram.dart';
  /// import 'package:hearing_aid_app/domain/entities/patient_profile.dart';
  /// import 'package:hearing_aid_app/domain/entities/prescription_mode.dart';
  /// import 'package:hearing_aid_app/domain/audiogram_driven_presets/bundle_builder.dart';
  /// import 'package:hearing_aid_app/domain/audiogram_driven_presets/operating_mode.dart';
  ///
  /// // Audiograma plano de 30 dB HL (pérdida leve simulada).
  /// final audiogram = Audiogram(thresholds: {
  ///   for (final f in Audiogram.standardFrequencies) f: 30.0,
  /// });
  ///
  /// final builder = BundleBuilder();
  /// final bundle = builder.buildFromAudiogram(
  ///   audiogram,
  ///   profile: const PatientProfile(experienceMonths: 24, ageYears: 35),
  ///   mode: PrescriptionMode.quiet,
  ///   derivedAt: DateTime.utc(2026, 6, 3, 10, 0, 0),
  /// );
  ///
  /// assert(bundle.gainsDb.length == 12);
  /// assert(bundle.mpoProfileDbSpl.every((v) => v >= 80 && v <= 132));
  /// assert(bundle.nrLevel == 1); // quiet → 1
  /// ```
  AudiogramDrivenBundle buildFromAudiogram(
    Audiogram audiogram, {
    PatientProfile? profile,
    required PrescriptionMode mode,
    Map<int, double>? measuredUcl,
    DateTime? derivedAt,
    OperatingMode operatingMode = OperatingMode.diagnostic,
    double gainScale = 1.0,
    RecdProvider? recdProvider,
    RecdCoupling recdCoupling = RecdCoupling.earmoldHa1,
  }) {
    // 1. Validación estructural del audiograma (Req 1.6).
    _validateAudiogram(audiogram);

    // 2. Sanitizar el gainScale: NaN/Infinity → bound más cercano,
    //    fuera de rango → clamp + warning observable (Req 13.13).
    final sanitizedGainScale = _sanitizeGainScale(gainScale);

    // 3. Despachar al delegado correspondiente. Cualquier excepción se
    //    propaga al caller sin envoltura adicional (Req 1.5).
    final List<double> prescribedGains;
    final List<double> compressionRatios;
    final LossType lossType;
    final double wdrcAttackMs;
    final double wdrcReleaseMs;

    // Targets prescritos "ideales" antes de CIN y gainScale,
    // para verificación de fitting (AAA/ASHA ±5 dB).
    late final List<double> prescribedTargetsDb;

    if (mode == PrescriptionMode.mhl) {
      // MHL: delegar a MhlModule. Pacientes con audición normal o
      // pérdida mínima → ganancia flat, compresión lineal, lossType
      // tratado como flat para mantener metadata consistente.
      final mhl = MhlModule.prescribe(audiogram);
      prescribedGains = mhl.gains;
      compressionRatios = mhl.compressionRatios;
      lossType = LossType.flat;
      wdrcAttackMs = _defaultWdrcAttackMs;
      wdrcReleaseMs = _defaultWdrcReleaseMs;
      prescribedTargetsDb = List<double>.from(prescribedGains, growable: false);
    } else {
      // Quiet / CIN: delegar al prescriptor NAL-NL3-inspired. Usamos
      // `prescribedGains` (sin compensación de auricular) como base del
      // bundle: la compensación es responsabilidad del nivel superior
      // del pipeline (audio_bridge), no del bundle clínico.
      final NL3PrescriptionResult result = _nl3Prescriber.prescribeFromAudiogram(
        audiogram,
        profile: profile,
        mode: mode,
        timestamp: derivedAt,
      );
      prescribedGains = result.prescribedGains;
      compressionRatios = result.compressionRatios;
      lossType = result.lossType;
      wdrcAttackMs = result.wdrcOverrides?.attackMs ?? _defaultWdrcAttackMs;
      wdrcReleaseMs = result.wdrcOverrides?.releaseMs ?? _defaultWdrcReleaseMs;
      prescribedTargetsDb = List<double>.from(prescribedGains, growable: false);
    }

    // 3b. Aplicar CinModule cuando el modo es comfortInNoise.
    //     Esto reduce las ganancias non-speech band (250, 6000, 8000 Hz)
    //     en 3-6 dB y ajusta los ratios para confort en ruido (Req 3.1-3.7
    //     del spec nal-nl3-prescriptor).
    //     A-4: hasta esta corrección, el chip "CIN" del UI estaba activo
    //     pero el motor recibía ganancias quiet. Ahora la reducción se
    //     aplica en el camino bundle-driven (Req 4.1).
    //     Sólo aplica al branch NL3; el branch MHL no toca CIN.
    final List<double> postCinGains;
    final List<double> postCinRatios;
    if (mode == PrescriptionMode.comfortInNoise) {
      final cinResult = CinModule.apply(prescribedGains, compressionRatios);
      postCinGains = cinResult.gains;
      postCinRatios = cinResult.compressionRatios;
    } else {
      postCinGains = prescribedGains;
      postCinRatios = compressionRatios;
    }

    // 4. UCL → MPO por banda.
    final ucl = UclEstimator.estimate(audiogram, measuredUcl: measuredUcl);
    final mpoProfileDbSpl = MpoDeriver.derive(ucl, profile: profile);

    // 5. Knee de compresión por banda (regresión lineal sobre HL).
    final compressionKneesDbSpl = _computeCompressionKnees(audiogram);

    // 6. Aplicar gainScale sólo en modo Amplificador. En Diagnóstico se
    //    fuerza el factor a 1.0 por contrato (Req 13.4).
    final List<double> gainsDb;
    final double effectiveGainScale;
    if (operatingMode == OperatingMode.amplifier) {
      effectiveGainScale = sanitizedGainScale;
      gainsDb = List<double>.generate(
        AudiogramDrivenBundle.bandCount,
        (i) => (postCinGains[i] * effectiveGainScale)
            .clamp(_gainMinDb, _gainMaxDb)
            .toDouble(),
        growable: false,
      );
    } else {
      effectiveGainScale = 1.0;
      gainsDb = List<double>.from(postCinGains, growable: false);
    }

    // 7. Nivel de NR derivado del modo (quiet → 1, CIN → 2, MHL → 3).
    final nrLevel = _nrLevelFor(mode);

    // 8. (Opcional) Conversión HL → SPL real-ear para trazabilidad
    //    clínica cuando el caller provee un `recdProvider` y el
    //    perfil del paciente tiene edad. La conversión es informativa
    //    y NO modifica el bundle: las superficies que necesitan el
    //    SPL al oído (tests de Tramo 2, UI de verificación) deben
    //    invocar `HlToSplRealEarConverter.convert(...)` directamente
    //    o leer el log emitido aquí. Ver Req 15.9.
    if (recdProvider != null && profile?.ageYears != null) {
      _logRealEarConversion(
        audiogram: audiogram,
        recdProvider: recdProvider,
        ageYears: profile!.ageYears!,
        coupling: recdCoupling,
      );
    }

    // 9. Construir el bundle inmutable.
    return AudiogramDrivenBundle(
      gainsDb: gainsDb,
      compressionRatios: List<double>.from(postCinRatios, growable: false),
      compressionKneesDbSpl: compressionKneesDbSpl,
      mpoProfileDbSpl: List<double>.from(mpoProfileDbSpl, growable: false),
      prescribedTargetsDb: prescribedTargetsDb,
      nrLevel: nrLevel,
      wdrcAttackMs: wdrcAttackMs,
      wdrcReleaseMs: wdrcReleaseMs,
      expansionKneeDbSpl: _defaultExpansionKneeDbSpl,
      lossType: lossType,
      prescriptionMode: mode,
      mode: operatingMode,
      gainScale: effectiveGainScale,
      derivedAt: derivedAt ?? _clock().toUtc(),
    );
  }

  /// Valida que el audiograma contenga las 12 frecuencias estándar y
  /// que cada umbral esté en `[-10, 120] dB HL` (Req 1.6).
  ///
  /// Lanza [ArgumentError] con un mensaje que incluye las frecuencias
  /// faltantes y la lista completa requerida.
  static void _validateAudiogram(Audiogram audiogram) {
    const required = Audiogram.standardFrequencies;
    final thresholds = audiogram.thresholds;

    // Detectar frecuencias faltantes.
    final missing = required.where((f) => !thresholds.containsKey(f)).toList();
    if (missing.isNotEmpty) {
      throw ArgumentError(
        'Audiograma incompleto: faltan las frecuencias '
        '${missing.join(', ')} Hz. Lista completa requerida: '
        '${required.join(', ')} Hz.',
      );
    }

    // Detectar umbrales fuera de rango o no finitos.
    final outOfRange = <String>[];
    for (final f in required) {
      final hl = thresholds[f]!;
      if (hl.isNaN || hl.isInfinite) {
        outOfRange.add('$f Hz=$hl (no finito)');
        continue;
      }
      if (hl < _hlMinDbHl || hl > _hlMaxDbHl) {
        outOfRange.add('$f Hz=$hl');
      }
    }
    if (outOfRange.isNotEmpty) {
      throw ArgumentError(
        'Audiograma con umbrales fuera de rango '
        '[$_hlMinDbHl, $_hlMaxDbHl] dB HL: ${outOfRange.join(', ')}.',
      );
    }
  }

  /// Sanitiza [gainScale]:
  /// - `NaN` / `Infinity` → clamp al bound más cercano (Req 13.13).
  /// - Fuera de `[0.10, 1.00]` → clamp al bound más cercano + warning
  ///   observable vía `dart:developer.log` (level 900).
  /// - Dentro de rango → se devuelve sin modificación.
  static double _sanitizeGainScale(double gainScale) {
    if (gainScale.isNaN) {
      developer.log(
        'BundleBuilder: gainScale=NaN clampado a $_gainScaleMin.',
        name: 'BundleBuilder',
        level: 900,
      );
      return _gainScaleMin;
    }
    if (gainScale.isInfinite) {
      final clamped =
          gainScale > 0 ? _gainScaleMax : _gainScaleMin;
      developer.log(
        'BundleBuilder: gainScale=$gainScale clampado a $clamped.',
        name: 'BundleBuilder',
        level: 900,
      );
      return clamped;
    }
    if (gainScale < _gainScaleMin) {
      developer.log(
        'BundleBuilder: gainScale=$gainScale fuera de rango '
        '[$_gainScaleMin, $_gainScaleMax]; clampado a $_gainScaleMin.',
        name: 'BundleBuilder',
        level: 900,
      );
      return _gainScaleMin;
    }
    if (gainScale > _gainScaleMax) {
      developer.log(
        'BundleBuilder: gainScale=$gainScale fuera de rango '
        '[$_gainScaleMin, $_gainScaleMax]; clampado a $_gainScaleMax.',
        name: 'BundleBuilder',
        level: 900,
      );
      return _gainScaleMax;
    }
    return gainScale;
  }

  /// Calcula los 12 knees de compresión por banda según la regresión
  /// `knee[f] = 35 + (HL[f] / 120) × 30`, con HL clampado a `[0, 120]`
  /// y resultado clampado a `[35, 65] dB SPL`.
  static List<double> _computeCompressionKnees(Audiogram audiogram) {
    return List<double>.generate(
      AudiogramDrivenBundle.bandCount,
      (i) {
        final f = Audiogram.standardFrequencies[i];
        final rawHl = audiogram.thresholds[f]!;
        final clampedHl =
            rawHl.clamp(_hlClampMinForKnee, _hlClampMaxForKnee).toDouble();
        final knee = _kneeInterceptDbSpl +
            (clampedHl / _hlClampMaxForKnee) * _kneeSlopeDb;
        return knee.clamp(_kneeMinDbSpl, _kneeMaxDbSpl).toDouble();
      },
      growable: false,
    );
  }

  /// Mapea el modo de prescripción al nivel de NR sugerido por el
  /// bundle (Req 1.2: rango `[0, 3]`).
  static int _nrLevelFor(PrescriptionMode mode) {
    switch (mode) {
      case PrescriptionMode.quiet:
        return 1;
      case PrescriptionMode.comfortInNoise:
        return 2;
      case PrescriptionMode.mhl:
        return 3;
    }
  }

  /// Emite por `dart:developer.log` los SPL real-ear por banda del
  /// paciente, calculados como `HL + RETSPL + RECD`. Se usa para
  /// trazabilidad clínica cuando el caller provee un [RecdProvider]
  /// y el perfil del paciente tiene edad (Req 15.9). La conversión
  /// no altera el bundle.
  ///
  /// La edad se convierte de años a meses con la conversión
  /// `ageMonths = ageYears × 12`, que es la granularidad esperada
  /// por [RecdProvider.getRecd].
  static void _logRealEarConversion({
    required Audiogram audiogram,
    required RecdProvider recdProvider,
    required int ageYears,
    required RecdCoupling coupling,
  }) {
    final ageMonths = ageYears * 12;
    final spl = HlToSplRealEarConverter.convert(
      audiogram: audiogram,
      recdProvider: recdProvider,
      ageMonths: ageMonths,
      coupling: coupling,
    );
    developer.log(
      'BundleBuilder: SPL_realear (age=${ageYears}y, coupling=$coupling): '
      '${spl.entries.map((e) => '${e.key}=${e.value.toStringAsFixed(2)}').join(', ')}',
      name: 'BundleBuilder.realEar',
      level: 800,
    );
  }
}
