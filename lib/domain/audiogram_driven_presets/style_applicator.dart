import 'dart:developer' as developer;

import 'audiogram_driven_bundle.dart';

/// Aplicador de "estilos" sobre un [AudiogramDrivenBundle].
///
/// El sistema expone 9 presets escalados, formados por la combinación de
/// 3 niveles de intensidad sobre la prescripción NAL-NL2 base × 3
/// perfiles espectrales:
///
/// - **Intensidades** (multiplicadores sobre `bundle.gainsDb`):
///   - `Suave`: ×0.7 (más conservador)
///   - `Medio`: ×1.0 (NAL-NL2 puro)
///   - `Alto`:  ×1.3 (más agresivo)
///
/// - **Perfiles** (deltas sumados por banda):
///   - `Plano`:  shape neutro, `[0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0]`
///   - `Voz`:    `[0, 0, 0, 3, 3, 3, 3, 3, 3, 3, 0, 0]`
///     (foco 1–4 kHz: fricativas + formantes)
///   - `Agudos`: `[0, 0, 0, 0, 0, 0, 0, 2, 2, 3, 4, 4]`
///     (realce >3 kHz)
///
/// Los nombres de los 9 presets son la concatenación
/// `<intensidad> <perfil>`:
///
/// `Suave Plano`, `Suave Voz`, `Suave Agudos`,
/// `Medio Plano`, `Medio Voz`, `Medio Agudos`,
/// `Alto Plano`,  `Alto Voz`,  `Alto Agudos`.
///
/// ## Lógica de aplicación
///
/// La ganancia final por banda es:
///
/// ```
/// gain[band] = clamp(
///   bundle.gainsDb[band] * intensity_multiplier
///       + profile_delta[band],
///   0,
///   50,
/// )
/// ```
///
/// donde `bundle.gainsDb` ya viene prescrito por NAL-NL2 desde el
/// [BundleBuilder] (Req 1.x, 2.x).
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
///   es el responsable del clamp final por banda contra
///   `mpoProfileDbSpl[f] - input - 3` (Req 10.3). El estilo solo clampa
///   al rango estructural del bundle (`[0, 50] dB`, Req 5.3).
/// - **Estilo desconocido = no-op observado.** Si `styleName` no
///   corresponde a uno de los 9 presets soportados, el método registra
///   un error vía `dart:developer.log` y retorna el bundle de entrada
///   sin modificarlo (Req 5.7).
///
/// ## Bibliografía
///
/// - Keidser, G., Dillon, H., Flax, M., Ching, T., & Brewer, S. (2011).
///   "The NAL-NL2 prescription procedure". *Audiology Research*, 1(1),
///   e24. (Base de la prescripción que el estilo escala/refina.)
/// - Moore, B. C. J. (2012). "Effects of Bandwidth, Compression Speed,
///   and Gain at High Frequencies on Preferences for Amplified Music".
///   *Trends in Amplification*, 16(3), 159–172.
///   (Justifica el shape del perfil `Plano`.)
///
/// Requisitos: 5.1, 5.2, 5.3, 5.4, 5.7
class StyleApplicator {
  // ─── Intensidades ─────────────────────────────────────────────────────

  /// Intensidad "Suave": multiplicador 0.7 sobre la prescripción base.
  static const String intensitySoft = 'Suave';

  /// Intensidad "Medio": multiplicador 1.0 (NAL-NL2 puro).
  static const String intensityMedium = 'Medio';

  /// Intensidad "Alto": multiplicador 1.3 (más agresivo).
  static const String intensityHigh = 'Alto';

  /// Multiplicadores por intensidad. La key es el prefijo del nombre de
  /// preset; el valor se aplica a `bundle.gainsDb`.
  static const Map<String, double> _intensityMultipliers = <String, double>{
    intensitySoft:   0.7,
    intensityMedium: 1.0,
    intensityHigh:   1.3,
  };

  // ─── Perfiles ─────────────────────────────────────────────────────────

  /// Perfil "Plano": delta cero en todas las bandas.
  static const String profileFlat = 'Plano';

  /// Perfil "Voz": +3 dB en 1–4 kHz (índices 3..9).
  static const String profileVoice = 'Voz';

  /// Perfil "Agudos": realce progresivo a partir de 3 kHz.
  static const String profileTreble = 'Agudos';

  /// Deltas por perfil. Cada lista tiene exactamente 12 valores
  /// alineados con [Audiogram.standardFrequencies]:
  /// `250, 500, 750, 1000, 1500, 2000, 2500, 3000, 3500, 4000, 6000, 8000 Hz`.
  static const Map<String, List<double>> _profileDeltas =
      <String, List<double>>{
    profileFlat:   <double>[0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0],
    profileVoice:  <double>[0, 0, 0, 3, 3, 3, 3, 3, 3, 3, 0, 0],
    profileTreble: <double>[0, 0, 0, 0, 0, 0, 0, 2, 2, 3, 4, 4],
  };

  // ─── Presets soportados ───────────────────────────────────────────────

  /// Preset `Suave Plano`.
  static const String styleSoftFlat   = 'Suave Plano';

  /// Preset `Suave Voz`.
  static const String styleSoftVoice  = 'Suave Voz';

  /// Preset `Suave Agudos`.
  static const String styleSoftTreble = 'Suave Agudos';

  /// Preset `Medio Plano`.
  static const String styleMediumFlat   = 'Medio Plano';

  /// Preset `Medio Voz`.
  static const String styleMediumVoice  = 'Medio Voz';

  /// Preset `Medio Agudos`.
  static const String styleMediumTreble = 'Medio Agudos';

  /// Preset `Alto Plano`.
  static const String styleHighFlat   = 'Alto Plano';

  /// Preset `Alto Voz`.
  static const String styleHighVoice  = 'Alto Voz';

  /// Preset `Alto Agudos`.
  static const String styleHighTreble = 'Alto Agudos';

  /// Lista de los 9 nombres de preset soportados, en el orden canónico
  /// de UI (intensidad ascendente × perfil Plano → Voz → Agudos).
  ///
  /// Útil para la UI (renderizar el selector de preset) y para tests
  /// (iterar todas las opciones).
  static const List<String> _supportedStylesList = <String>[
    styleSoftFlat, styleSoftVoice, styleSoftTreble,
    styleMediumFlat, styleMediumVoice, styleMediumTreble,
    styleHighFlat, styleHighVoice, styleHighTreble,
  ];

  /// Vista pública de la lista de presets soportados (inmutable).
  static List<String> get supportedStyles =>
      List<String>.unmodifiable(_supportedStylesList);

  /// Resuelve un nombre de preset a `(multiplier, profileDeltas)`.
  ///
  /// Retorna `null` si `styleName` no es uno de los 9 presets
  /// soportados. La búsqueda es por coincidencia exacta del nombre
  /// completo (ej. `'Medio Voz'`); el formato esperado es
  /// `<intensidad> <perfil>` con un único espacio.
  static (double, List<double>)? _resolve(String styleName) {
    final spaceIdx = styleName.indexOf(' ');
    if (spaceIdx <= 0 || spaceIdx >= styleName.length - 1) return null;
    final intensity = styleName.substring(0, spaceIdx);
    final profile = styleName.substring(spaceIdx + 1);
    final mult = _intensityMultipliers[intensity];
    final deltas = _profileDeltas[profile];
    if (mult == null || deltas == null) return null;
    return (mult, deltas);
  }

  /// Aplica el preset [styleName] al [bundle] escalando
  /// [AudiogramDrivenBundle.gainsDb] por el multiplicador de intensidad
  /// y sumando el delta del perfil, clampando al rango estructural
  /// `[0, 50] dB`.
  ///
  /// Fórmula: `gain[band] = clamp(base[band] * mult + delta[band], 0, 50)`.
  ///
  /// **Parámetros:**
  /// - [bundle]: bundle base derivado del audiograma (NAL-NL2). Sus 12
  ///   ganancias `gainsDb` (en dB, rango `[0, 50]`) son las que se
  ///   ajustan. El resto de los campos se preservan tal cual.
  /// - [styleName]: nombre del preset a aplicar. Debe ser uno de los 9
  ///   strings expuestos en [supportedStyles]. Cualquier otro valor se
  ///   trata como preset desconocido y dispara el camino de Req 5.7.
  /// - [derivedAt]: timestamp opcional (UTC, resolución milisegundos)
  ///   para refrescar [AudiogramDrivenBundle.derivedAt] del bundle
  ///   resultante. Cuando se omite, el bundle resultante conserva el
  ///   `derivedAt` original. La inyección externa preserva la pureza
  ///   determinista del aplicador (Req 1.3).
  ///
  /// **Retorna:** un nuevo [AudiogramDrivenBundle] con `gainsDb`
  /// modificado (rango `[0, 50] dB`) y todos los demás campos idénticos
  /// al [bundle] de entrada. Para un nombre desconocido, retorna el
  /// bundle de entrada sin modificarlo (Req 5.7).
  ///
  /// **Errores observables (no excepciones):**
  /// - Cuando `styleName` no está en [supportedStyles], se registra un
  ///   error vía `dart:developer.log` con `name: 'StyleApplicator'` y
  ///   `level: 1000` (SEVERE). El bundle se devuelve sin modificar
  ///   (Req 5.7).
  ///
  /// Requisitos: 5.1, 5.2, 5.3, 5.4, 5.7
  static AudiogramDrivenBundle applyStyle(
    AudiogramDrivenBundle bundle,
    String styleName, {
    DateTime? derivedAt,
  }) {
    final resolved = _resolve(styleName);

    // Preset desconocido: log + retornar el bundle sin modificar (Req 5.7).
    // No se actualiza derivedAt para respetar "rechazar la selección sin
    // modificar el bundle activo".
    if (resolved == null) {
      developer.log(
        'StyleApplicator: preset desconocido "$styleName" — bundle sin '
        'modificar. Presets soportados: ${supportedStyles.join(", ")}.',
        name: 'StyleApplicator',
        level: 1000,
      );
      return bundle;
    }

    final mult = resolved.$1;
    final deltas = resolved.$2;

    // Escala la prescripción base por el multiplicador de intensidad,
    // suma el delta del perfil y clampa al rango estructural [0, 50]
    // (Req 5.3). El clamp por headroom MPO (Req 10.3) lo hace el handler
    // atómico del bloc, no este aplicador.
    final newGains = List<double>.generate(
      AudiogramDrivenBundle.bandCount,
      (i) => (bundle.gainsDb[i] * mult + deltas[i]).clamp(
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
      prescribedTargetsDb: bundle.prescribedTargetsDb,
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
