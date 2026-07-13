import 'dart:developer' as developer;

import '../entities/environment_profile.dart';
import '../entities/prescription_mode.dart';

/// Mapeo entre los perfiles de entorno acústico que ve el usuario
/// (`Silencioso`, `Conversación`, `Ruidoso`) y el modo de prescripción
/// clínica que alimenta al `BundleBuilder`.
///
/// Los `EnvironmentProfile` son atajos de UI que el paciente elige según la
/// situación de escucha. La cadena clínica subyacente trabaja con
/// [PrescriptionMode], así que necesitamos un mapping unidireccional y
/// determinista entre uno y otro:
///
/// - `quiet` (Silencioso) → [PrescriptionMode.quiet]
/// - `conversation` (Conversación) → [PrescriptionMode.quiet]
/// - `noisy` (Ruidoso) → [PrescriptionMode.comfortInNoise]
///
/// La conversación entra al modo `quiet` porque la prescripción base de
/// NAL-NL3 ya está pensada para ambientes silenciosos y de habla; recién
/// cuando aparece ruido sostenido (`noisy`) cambiamos al módulo `Comfort In
/// Noise` para reducir fatiga sin sacrificar la banda de habla.
///
/// Aparte del modo, este mapper expone un helper para combinar el `nrLevel`
/// derivado por el bundle con el `nrDelta` opcional que define cada
/// `EnvironmentProfile`. Eso permite que el perfil "Ruidoso" sume +1 al NR
/// sin pisar el cálculo audiograma-derivado.
///
/// Toda la API es estática y pura: no consulta estado global, no toca el
/// reloj y no muta los argumentos. Las dos llamadas con los mismos inputs
/// producen idéntico output. La única excepción es el `developer.log` que
/// se emite cuando llega un perfil con nombre desconocido — es un side-effect
/// de observabilidad pura, no afecta el valor retornado.
///
/// **Referencias del proyecto:**
/// - `.kiro/specs/audiogram-driven-presets/design.md` §3.5
///   "EnvironmentProfileMapper".
/// - `.kiro/specs/audiogram-driven-presets/requirements.md` Req 6.2, 6.4, 6.5.
/// - `docs/07-calibracion-audiograma/analisis-prescripcion-real-vs-simulador.md`
///   §7.2 "EnvironmentProfile derivado del audiograma".
///
/// Requisitos: 6.2, 6.4, 6.5
class EnvironmentProfileMapper {
  /// Nombre del perfil predefinido `Silencioso`.
  static const String _quietName = 'Silencioso';

  /// Nombre del perfil predefinido `Conversación`.
  static const String _conversationName = 'Conversación';

  /// Nombre del perfil predefinido `Ruidoso`.
  static const String _noisyName = 'Ruidoso';

  /// Nivel mínimo del NR aceptado por el motor DSP.
  static const int _nrMin = 0;

  /// Nivel máximo del NR aceptado por el motor DSP.
  static const int _nrMax = 3;

  /// Identificador del logger usado por `dart:developer.log` cuando el
  /// mapper recibe un perfil con nombre desconocido.
  static const String _logName =
      'audiogram_driven_presets.EnvironmentProfileMapper';

  /// Devuelve el [PrescriptionMode] correspondiente al [EnvironmentProfile]
  /// recibido.
  ///
  /// El identificador clave del perfil es su `name`: las constantes
  /// predefinidas (`Silencioso`, `Conversación`, `Ruidoso`) y cualquier
  /// instancia reconstruida desde JSON se enrutan por ese campo.
  ///
  /// **Parámetros:**
  /// - [profile]: perfil de entorno seleccionado por el usuario. Se compara
  ///   primero por referencia con [EnvironmentProfile.quiet],
  ///   [EnvironmentProfile.conversation] y [EnvironmentProfile.noisy] como
  ///   atajo, y si no hay match se cae al nombre (`profile.name`). Esto
  ///   cubre tanto las instancias predefinidas como copias serializadas que
  ///   conservan el nombre original. Sin unidad: enum + string.
  ///
  /// **Retorna:** [PrescriptionMode] activo para construir el bundle. Sin
  /// unidad (enum). Valores posibles:
  /// - `Silencioso` o `Conversación` → [PrescriptionMode.quiet].
  /// - `Ruidoso` → [PrescriptionMode.comfortInNoise].
  /// - Cualquier otro nombre desconocido (perfil custom no contemplado) →
  ///   [PrescriptionMode.quiet] como fallback seguro y se emite un warning
  ///   via `dart:developer.log`. La prescripción base nunca degrada al
  ///   paciente y evita activar módulos como CIN o MHL por accidente.
  ///
  /// **Ejemplo de uso:**
  /// ```dart
  /// import 'package:hearing_aid_app/domain/entities/environment_profile.dart';
  /// import 'package:hearing_aid_app/domain/audiogram_driven_presets/environment_profile_mapper.dart';
  ///
  /// // Mapeo directo desde una constante predefinida.
  /// final mode = EnvironmentProfileMapper.modeFor(EnvironmentProfile.noisy);
  /// // mode == PrescriptionMode.comfortInNoise
  ///
  /// // Mapeo a partir de un perfil reconstruido desde JSON.
  /// final restored = EnvironmentProfile(
  ///   name: 'Conversación',
  ///   nrLevel: 2,
  ///   compressionRatio: 2.0,
  ///   expansionKnee: 35,
  ///   compressionKnee: 50,
  /// );
  /// final restoredMode = EnvironmentProfileMapper.modeFor(restored);
  /// // restoredMode == PrescriptionMode.quiet
  /// ```
  ///
  /// **Referencias:**
  /// - `design.md` §3.5 — tabla de mapping `EnvironmentProfile → PrescriptionMode`.
  /// - `requirements.md` Req 6.2 — propagación atómica del modo al bundle.
  static PrescriptionMode modeFor(EnvironmentProfile profile) {
    // Comparación por referencia primero — cubre el camino feliz de las
    // constantes predefinidas sin depender del string `name`.
    if (identical(profile, EnvironmentProfile.quiet) ||
        identical(profile, EnvironmentProfile.conversation)) {
      return PrescriptionMode.quiet;
    }
    if (identical(profile, EnvironmentProfile.noisy)) {
      return PrescriptionMode.comfortInNoise;
    }

    // Fallback por nombre — atrapa perfiles deserializados o construidos a
    // mano que conservan el `name` original.
    switch (profile.name) {
      case _quietName:
      case _conversationName:
        return PrescriptionMode.quiet;
      case _noisyName:
        return PrescriptionMode.comfortInNoise;
      default:
        // Nombre desconocido: degradamos al modo más seguro para no activar
        // CIN ni MHL por accidente, y dejamos un rastro observable para que
        // el equipo clínico se entere de que hay un perfil custom no
        // contemplado por el mapping oficial.
        developer.log(
          'EnvironmentProfile con nombre desconocido "${profile.name}"; '
          'fallback a PrescriptionMode.quiet.',
          name: _logName,
          level: 900, // dart:developer.Level.WARNING ≈ 900.
        );
        return PrescriptionMode.quiet;
    }
  }

  /// Combina el `nrLevel` derivado por el bundle con el `nrDelta` opcional
  /// del [EnvironmentProfile] activo y clampa el resultado al rango válido
  /// del motor DSP.
  ///
  /// **Parámetros:**
  /// - [bundleNrLevel]: nivel de reducción de ruido en `[0, 3]` (entero,
  ///   sin unidad: índice de tap del DSP) que viene del
  ///   `AudiogramDrivenBundle` recién construido.
  /// - [nrDelta]: ajuste relativo en `[-3, +3]` (entero, sin unidad) que
  ///   define el perfil de entorno seleccionado (típicamente `0` salvo
  ///   overrides explícitos como "Ruidoso" → +1).
  ///
  /// **Retorna:** entero en `[0, 3]` (sin unidad: índice de tap) listo para
  /// enviar al bridge nativo via `updateNrLevel(...)`. Cualquier suma fuera
  /// del rango se clampea al extremo más cercano sin lanzar excepción, para
  /// mantener el flujo de aplicación atómico definido en la spec.
  ///
  /// **Ejemplo de uso:**
  /// ```dart
  /// // Bundle sugiere NR=1; perfil Ruidoso suma +1 → NR final = 2.
  /// final nr = EnvironmentProfileMapper.adjustNr(1, 1);
  /// // nr == 2
  ///
  /// // Bundle sugiere NR=3; suma +2 → clamp a 3.
  /// final clamped = EnvironmentProfileMapper.adjustNr(3, 2);
  /// // clamped == 3
  ///
  /// // Bundle sugiere NR=0; resta -1 → clamp a 0.
  /// final floored = EnvironmentProfileMapper.adjustNr(0, -1);
  /// // floored == 0
  /// ```
  ///
  /// **Referencias:**
  /// - `design.md` §3.5 — combinación bundle.nrLevel + profile.nrDelta.
  /// - `requirements.md` Req 6.4, 6.5 — campo `nrDelta` y clamp `[0, 3]`.
  static int adjustNr(int bundleNrLevel, int nrDelta) {
    return (bundleNrLevel + nrDelta).clamp(_nrMin, _nrMax);
  }
}
