import 'dart:developer' as developer;

import 'audiogram_driven_bundle.dart';

/// Aplicador de "estilos" sobre un [AudiogramDrivenBundle].
///
/// Los estilos son refinamientos relativos a la prescripción audiograma
/// derivada. Conservan los nombres visibles al usuario de los 10
/// `EqPreset.allPresets` clásicos (`Normal`, `Mild High`, `Mild Flat`,
/// `Moderate High`, `Moderate Flat`, `Moderate+`, `Voice Clarity`,
/// `Music`, `Outdoor`, `TV/Media`) pero internamente cada estilo es una
/// función pura que suma deltas a [AudiogramDrivenBundle.gainsDb] sin
/// reemplazar las ganancias prescritas.
///
/// El [StyleApplicator] respeta la separación de responsabilidades del
/// bundle:
///
/// - **Solo modifica [AudiogramDrivenBundle.gainsDb].** Los campos
///   [AudiogramDrivenBundle.compressionRatios],
///   [AudiogramDrivenBundle.compressionKneesDbSpl],
///   [AudiogramDrivenBundle.mpoProfileDbSpl],
///   [AudiogramDrivenBundle.nrLevel],
///   [AudiogramDrivenBundle.wdrcAttackMs],
///   [AudiogramDrivenBundle.wdrcReleaseMs] y
///   [AudiogramDrivenBundle.expansionKneeDbSpl] permanecen idénticos al
///   bundle de entrada (Req 5.3, Req 10.x).
/// - **No aplica clamp de headroom (MPO).** El handler atómico del bloc
///   (`_onApplyBundle`, wave 4) es el responsable del clamp final por
///   banda contra `mpoProfileDbSpl[f] - input - 3` (Req 10.3). El
///   estilo solo clampa al rango estructural del bundle
///   (`[0, 50] dB`, Req 5.3).
/// - **El estilo `Normal` retorna el bundle sin cambios.** Si se pasa un
///   [DateTime] en `derivedAt`, se actualiza ese campo; en caso
///   contrario el bundle se devuelve idéntico (Req 5.2).
/// - **Estilo desconocido = no-op observado.** Si `styleName` no
///   corresponde a uno de los 10 estilos soportados, el método registra
///   un error vía `dart:developer.log` y retorna el bundle de entrada
///   sin modificarlo (Req 5.7).
///
/// ## Tabla de deltas por banda
///
/// Los deltas están alineados con el orden de
/// [Audiogram.standardFrequencies] (12 bandas: 250, 500, 750, 1000, 1500,
/// 2000, 2500, 3000, 3500, 4000, 6000, 8000 Hz).
///
/// **Estilos orientados a forma de pérdida** (Req 5.3, deltas por banda
/// dentro de `[-3, +3] dB`):
///
/// | Estilo         | 250 | 500 | 750 | 1k | 1.5k | 2k | 2.5k | 3k | 3.5k | 4k | 6k | 8k |
/// |----------------|----:|----:|----:|---:|-----:|---:|-----:|---:|-----:|---:|---:|---:|
/// | Normal         |   0 |   0 |   0 |  0 |    0 |  0 |    0 |  0 |    0 |  0 |  0 |  0 |
/// | Mild High      |   0 |   0 |   0 |  0 |    0 |  0 |    0 |  0 |    0 | +1 | +2 | +3 |
/// | Mild Flat      |  +1 |  +1 |  +1 | +2 |   +2 | +2 |   +2 | +2 |   +2 | +2 | +1 | +1 |
/// | Moderate High  |   0 |   0 |   0 |  0 |    0 | +1 |   +1 | +2 |   +2 | +3 | +3 | +3 |
/// | Moderate Flat  |  +1 |  +1 |  +2 | +2 |   +2 | +3 |   +3 | +3 |   +3 | +3 | +2 | +2 |
/// | Moderate+      |  +1 |  +1 |  +1 | +1 |   +1 | +2 |   +2 | +3 |   +3 | +3 | +3 | +2 |
///
/// **Estilos de uso** (Req 5.4, deltas por grupo frecuencial dentro de
/// `[-4, +4] dB` — graves: 250–750, medios: 1000–4000, agudos:
/// 6000–8000):
///
/// | Estilo         | 250 | 500 | 750 | 1k | 1.5k | 2k | 2.5k | 3k | 3.5k | 4k | 6k | 8k |
/// |----------------|----:|----:|----:|---:|-----:|---:|-----:|---:|-----:|---:|---:|---:|
/// | Voice Clarity  |   0 |   0 |   0 | +4 |   +4 | +4 |   +4 | +4 |   +4 | +4 |  0 |  0 |
/// | Music          |  +1 |  +1 |  +1 |  0 |    0 |  0 |    0 |  0 |    0 |  0 | -1 | -1 |
/// | Outdoor        |  -4 |  -4 |  -4 | +3 |   +3 | +3 |   +3 | +3 |   +3 | +3 | -1 | -1 |
/// | TV/Media       |  +2 |  +2 |  +2 | +4 |   +4 | +4 |   +4 | +4 |   +4 | +4 | -1 | -1 |
///
/// > El ajuste de [AudiogramDrivenBundle.nrLevel] mencionado en Req 5.4
/// > no se aplica en este componente: queda delegado al handler atómico
/// > del bloc, que sumará el `nrDelta` apropiado del
/// > `EnvironmentProfile` activo. El [StyleApplicator] mantiene foco en
/// > [AudiogramDrivenBundle.gainsDb] para preservar la pureza de la
/// > función y la separación de responsabilidades del wave 5.
///
/// ## Bibliografía
///
/// - Keidser, G., Dillon, H., Flax, M., Ching, T., & Brewer, S. (2011).
///   "The NAL-NL2 prescription procedure". *Audiology Research*, 1(1),
///   e24. (Base de la prescripción que el estilo refina.)
/// - Moore, B. C. J. (2012). "Effects of Bandwidth, Compression Speed,
///   and Gain at High Frequencies on Preferences for Amplified Music".
///   *Trends in Amplification*, 16(3), 159–172.
///   (Justifica el shape plano del estilo `Music`.)
///
/// **Documento del proyecto:** ver
/// `docs/07-calibracion-audiograma/analisis-prescripcion-real-vs-simulador.md`
/// §7 "Estilos como deltas relativos sobre la prescripción audiograma".
///
/// Requisitos: 5.1, 5.2, 5.3, 5.4, 5.7
class StyleApplicator {
  /// Estilo neutro. Retorna el bundle sin cambios (Req 5.2).
  static const String styleNormal = 'Normal';

  /// Estilo "Mild High": leve realce de agudos a partir de 4 kHz.
  static const String styleMildHigh = 'Mild High';

  /// Estilo "Mild Flat": realce uniforme suave en todas las bandas.
  static const String styleMildFlat = 'Mild Flat';

  /// Estilo "Moderate High": realce moderado a partir de 2 kHz.
  static const String styleModerateHigh = 'Moderate High';

  /// Estilo "Moderate Flat": realce moderado en todas las bandas.
  static const String styleModerateFlat = 'Moderate Flat';

  /// Estilo "Moderate+": realce moderado-fuerte a partir de 2 kHz.
  static const String styleModeratePlus = 'Moderate+';

  /// Estilo "Voice Clarity": foco fuerte en medios (1–4 kHz).
  static const String styleVoiceClarity = 'Voice Clarity';

  /// Estilo "Music": shape plano, ajustes mínimos.
  static const String styleMusic = 'Music';

  /// Estilo "Outdoor": reduce graves (viento), realza medios (voz).
  static const String styleOutdoor = 'Outdoor';

  /// Estilo "TV/Media": realza graves moderadamente y medios fuertes.
  static const String styleTvMedia = 'TV/Media';

  /// Tabla canónica de deltas por estilo. Cada entrada tiene exactamente
  /// 12 valores `double` alineados con
  /// [Audiogram.standardFrequencies].
  ///
  /// La tabla se usa como `static const` para garantizar que cada estilo
  /// es determinista, no aloca por llamada y no depende del reloj.
  static const Map<String, List<double>> _styleDeltas = {
    styleNormal:        <double>[0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0],
    styleMildHigh:      <double>[0, 0, 0, 0, 0, 0, 0, 0, 0, 1, 2, 3],
    styleMildFlat:      <double>[1, 1, 1, 2, 2, 2, 2, 2, 2, 2, 1, 1],
    styleModerateHigh:  <double>[0, 0, 0, 0, 0, 1, 1, 2, 2, 3, 3, 3],
    styleModerateFlat:  <double>[1, 1, 2, 2, 2, 3, 3, 3, 3, 3, 2, 2],
    styleModeratePlus:  <double>[1, 1, 1, 1, 1, 2, 2, 3, 3, 3, 3, 2],
    styleVoiceClarity:  <double>[0, 0, 0, 4, 4, 4, 4, 4, 4, 4, 0, 0],
    styleMusic:         <double>[1, 1, 1, 0, 0, 0, 0, 0, 0, 0, -1, -1],
    styleOutdoor:       <double>[-4, -4, -4, 3, 3, 3, 3, 3, 3, 3, -1, -1],
    styleTvMedia:       <double>[2, 2, 2, 4, 4, 4, 4, 4, 4, 4, -1, -1],
  };

  /// Lista de los 10 nombres de estilo soportados, en el orden canónico
  /// de UI (Normal primero, estilos de pérdida, estilos de uso).
  ///
  /// Útil para la UI (renderizar el selector de estilo) y para tests
  /// (iterar todas las opciones).
  static List<String> get supportedStyles => List<String>.unmodifiable(
        _styleDeltas.keys,
      );

  /// Aplica el estilo [styleName] al [bundle] sumando deltas a
  /// [AudiogramDrivenBundle.gainsDb] y clampando al rango estructural
  /// `[0, 50] dB`.
  ///
  /// **Parámetros:**
  /// - [bundle]: bundle base derivado del audiograma. Sus 12
  ///   ganancias `gainsDb` (en dB, rango `[0, 50]`) son las que se
  ///   ajustan. El resto de los campos se preservan tal cual.
  /// - [styleName]: nombre del estilo a aplicar. Debe ser uno de los 10
  ///   strings expuestos en [supportedStyles]. Cualquier otro valor se
  ///   trata como estilo desconocido y dispara el camino de Req 5.7.
  /// - [derivedAt]: timestamp opcional (UTC, resolución milisegundos)
  ///   para refrescar [AudiogramDrivenBundle.derivedAt] del bundle
  ///   resultante. Cuando se omite, el bundle resultante conserva el
  ///   `derivedAt` original. La inyección externa preserva la pureza
  ///   determinista del aplicador (Req 1.3).
  ///
  /// **Retorna:** un nuevo [AudiogramDrivenBundle] con `gainsDb`
  /// modificado por los deltas del estilo (rango `[0, 50] dB`) y todos
  /// los demás campos idénticos al [bundle] de entrada. Para
  /// `styleName == 'Normal'` o un nombre desconocido, retorna un bundle
  /// estructuralmente equivalente al de entrada (con `derivedAt`
  /// actualizado solo si se pasó y la entrada NO es desconocida).
  ///
  /// **Errores observables (no excepciones):**
  /// - Cuando `styleName` no está en [supportedStyles], se registra un
  ///   error vía `dart:developer.log` con `name: 'StyleApplicator'` y
  ///   `level: 1000` (SEVERE). El bundle se devuelve sin modificar
  ///   (Req 5.7).
  ///
  /// **Ejemplo de uso:**
  /// ```dart
  /// import 'package:hearing_aid_app/domain/audiogram_driven_presets/audiogram_driven_bundle.dart';
  /// import 'package:hearing_aid_app/domain/audiogram_driven_presets/style_applicator.dart';
  ///
  /// // Bundle base hipotético derivado de un audiograma plano de 30 dB
  /// // HL (mock simplificado para el ejemplo).
  /// final base = AudiogramDrivenBundle(
  ///   gainsDb: const [10, 12, 14, 15, 16, 17, 18, 18, 18, 17, 15, 12],
  ///   compressionRatios:    const [1.5, 1.5, 1.5, 1.5, 1.5, 1.5, 1.5, 1.5, 1.5, 1.5, 1.5, 1.5],
  ///   compressionKneesDbSpl:const [42.5, 42.5, 42.5, 42.5, 42.5, 42.5, 42.5, 42.5, 42.5, 42.5, 42.5, 42.5],
  ///   mpoProfileDbSpl:      const [104, 104, 104, 104, 104, 104, 104, 104, 104, 104, 104, 104],
  ///   nrLevel: 1,
  ///   wdrcAttackMs: 5.0,
  ///   wdrcReleaseMs: 100.0,
  ///   expansionKneeDbSpl: 35.0,
  ///   lossType: LossType.flat,
  ///   prescriptionMode: PrescriptionMode.quiet,
  ///   mode: OperatingMode.diagnostic,
  ///   gainScale: 1.0,
  ///   derivedAt: DateTime.utc(2026, 6, 3, 12, 0, 0),
  /// );
  ///
  /// // Aplicar estilo "Voice Clarity": +4 dB en mids (1k–4k).
  /// final clarity = StyleApplicator.applyStyle(base, 'Voice Clarity');
  /// // clarity.gainsDb[3]  == 19  (15 + 4)  banda 1 kHz
  /// // clarity.gainsDb[9]  == 21  (17 + 4)  banda 4 kHz
  /// // clarity.gainsDb[0]  == 10  (10 + 0)  banda 250 Hz (sin cambio)
  ///
  /// // Estilo desconocido: log + bundle sin cambios.
  /// final fallback = StyleApplicator.applyStyle(base, 'Unknown');
  /// assert(identical(fallback, base));
  /// ```
  ///
  /// Requisitos: 5.1, 5.2, 5.3, 5.4, 5.7
  static AudiogramDrivenBundle applyStyle(
    AudiogramDrivenBundle bundle,
    String styleName, {
    DateTime? derivedAt,
  }) {
    final deltas = _styleDeltas[styleName];

    // Estilo desconocido: log + retornar el bundle sin modificar (Req 5.7).
    // No se actualiza derivedAt para respetar "rechazar la selección sin
    // modificar el bundle activo".
    if (deltas == null) {
      developer.log(
        'StyleApplicator: estilo desconocido "$styleName" — bundle sin '
        'modificar. Estilos soportados: ${supportedStyles.join(", ")}.',
        name: 'StyleApplicator',
        level: 1000,
      );
      return bundle;
    }

    // Estilo "Normal": bundle estructuralmente idéntico al de entrada
    // (Req 5.2). Solo se materializa una copia si se pidió refrescar el
    // derivedAt.
    if (styleName == styleNormal) {
      if (derivedAt == null || derivedAt == bundle.derivedAt) {
        return bundle;
      }
      return _withGainsAndDerivedAt(bundle, bundle.gainsDb, derivedAt);
    }

    // Estilo conocido: sumar deltas y clampar al rango estructural de
    // `gainsDb` (Req 5.3). El clamp por headroom MPO (Req 10.3) lo hace
    // el handler atómico del bloc, no este aplicador.
    final newGains = List<double>.generate(
      AudiogramDrivenBundle.bandCount,
      (i) => (bundle.gainsDb[i] + deltas[i]).clamp(
        AudiogramDrivenBundle.gainMinDb,
        AudiogramDrivenBundle.gainMaxDb,
      ),
      growable: false,
    );

    return _withGainsAndDerivedAt(
      bundle,
      newGains,
      derivedAt ?? bundle.derivedAt,
    );
  }

  /// Retorna un bundle nuevo con `gainsDb` y `derivedAt` reemplazados,
  /// preservando todos los demás campos del [bundle] base. Helper
  /// privado porque [AudiogramDrivenBundle] no expone `copyWith`.
  static AudiogramDrivenBundle _withGainsAndDerivedAt(
    AudiogramDrivenBundle bundle,
    List<double> newGains,
    DateTime newDerivedAt,
  ) {
    return AudiogramDrivenBundle(
      gainsDb: newGains,
      compressionRatios: bundle.compressionRatios,
      compressionKneesDbSpl: bundle.compressionKneesDbSpl,
      mpoProfileDbSpl: bundle.mpoProfileDbSpl,
      nrLevel: bundle.nrLevel,
      wdrcAttackMs: bundle.wdrcAttackMs,
      wdrcReleaseMs: bundle.wdrcReleaseMs,
      expansionKneeDbSpl: bundle.expansionKneeDbSpl,
      lossType: bundle.lossType,
      prescriptionMode: bundle.prescriptionMode,
      mode: bundle.mode,
      gainScale: bundle.gainScale,
      derivedAt: newDerivedAt,
    );
  }
}
