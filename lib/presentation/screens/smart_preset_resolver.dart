// Helper puro de mapeo `environmentClass` → preset Smart Scene del técnico.
//
// Este archivo NO debe importar `package:flutter/*`, blocs, repositorios ni el
// `AudioBridge`. La función `resolveSmartPreset` es lógica pura y existe para
// poder testearse aisladamente (PBT con `glados`) sin instanciar la screen
// `SmartSceneScreen` ni el motor de audio.
//
// La tabla de mapeo viene del enum C++ `smart_scene::SceneClass`
// (`android/app/src/main/cpp/smart_scene/scene_types.h`), expuesto en Dart
// vía `getDspStageMetrics()['environmentClass']` y replicado bit a bit del
// helper del paciente (`PACIENTE/oir_pro_patient_app/lib/presentation/`
// `home_screen.dart`, método `_smartPresetFor`).
//
// Diferencia intencional con el paciente: el paciente, ante ausencia total
// de match exacto y de prefijo, retorna `bundle.presets.first` como último
// recurso. El técnico **no** lo hace: si no hay match exacto ni preset con
// el prefijo correspondiente, retorna `null` y el polling de `SmartSceneScreen`
// no despacha `ChangePreset` (ver Property 11 en design.md y AC 2.9).
//
// Cubre los Acceptance Criteria 2.3, 2.4, 2.5, 2.6, 2.7, 2.8, 2.9 y 2.13 del
// spec `tecnico-paciente-feature-parity`.

/// Resuelve el nombre del preset al que el polling Smart Scene debería
/// transicionar para una clase de entorno `cls` y una lista de presets
/// disponibles `availablePresets`.
///
/// Tabla de mapeo (`smart_scene::SceneClass` → preset esperado / prefijo de
/// fallback):
///
/// | `cls` | Etiqueta             | Preset esperado | Prefijo fallback |
/// |-------|----------------------|-----------------|------------------|
/// | 0     | UNKNOWN              | (no cambiar)    | —                |
/// | 1     | SILENCE              | "Suave Plano"   | "Suave"          |
/// | 2     | VOICE_ONLY           | "Medio Voz"     | "Medio"          |
/// | 3     | VOICE_IN_NOISE_LOW   | "Alto Voz"      | "Alto"           |
/// | 4     | VOICE_IN_NOISE_MID   | "Alto Voz"      | "Alto"           |
/// | 5     | NOISE_LOW_DOMINANT   | "Alto Plano"    | "Alto"           |
/// | 6     | NOISE_HIGH_DOMINANT  | "Alto Plano"    | "Alto"           |
/// | 7     | MUSIC                | (no cambiar)    | —                |
///
/// Reglas:
/// - `cls` fuera de `[0, 7]` se trata como `0` (UNKNOWN) y retorna `null`
///   (AC 2.13).
/// - `cls ∈ {0, 7}` retorna `null` (AC 2.7).
/// - Para `cls ∈ {1..6}`:
///   1. Si `availablePresets` contiene el nombre exacto, lo retorna
///      (comparación case-sensitive, sin trim).
///   2. Si no, retorna el primer elemento de `availablePresets` (en orden de
///      aparición) cuyo nombre comience con el prefijo de fallback
///      correspondiente. La comparación de prefijo es case-sensitive
///      (AC 2.8).
///   3. Si tampoco existe ningún preset con ese prefijo, retorna `null`
///      (AC 2.9, Property 11). El polling NO debe despachar `ChangePreset`
///      en ese caso.
///
/// Garantías:
/// - Función pura: sin efectos secundarios, sin lecturas externas, sin
///   throws (totalidad sobre `int × List<String>`).
/// - Idempotente: dos invocaciones con los mismos argumentos retornan
///   exactamente el mismo resultado (incluyendo identidad de string para
///   el match exacto / prefijo).
/// - No mutates `availablePresets`.
String? resolveSmartPreset(int cls, List<String> availablePresets) {
  // AC 2.13: cls fuera de [0, 7] se normaliza a 0 (UNKNOWN).
  final normalized = (cls < 0 || cls > 7) ? 0 : cls;

  String targetName;
  String prefixFallback;
  switch (normalized) {
    case 1: // SILENCE
      targetName = 'Suave Plano';
      prefixFallback = 'Suave';
      break;
    case 2: // VOICE_ONLY
      targetName = 'Medio Voz';
      prefixFallback = 'Medio';
      break;
    case 3: // VOICE_IN_NOISE_LOW
    case 4: // VOICE_IN_NOISE_MID
      targetName = 'Alto Voz';
      prefixFallback = 'Alto';
      break;
    case 5: // NOISE_LOW_DOMINANT
    case 6: // NOISE_HIGH_DOMINANT
      targetName = 'Alto Plano';
      prefixFallback = 'Alto';
      break;
    case 0: // UNKNOWN  → AC 2.7
    case 7: // MUSIC    → AC 2.7
    default:
      return null;
  }

  // (1) Match exacto, case-sensitive, sin trim.
  for (final name in availablePresets) {
    if (name == targetName) return name;
  }

  // (2) Fallback por prefijo, case-sensitive, primer match en orden.
  for (final name in availablePresets) {
    if (name.startsWith(prefixFallback)) return name;
  }

  // (3) Sin match exacto ni prefijo → no cambiar de preset (AC 2.9).
  return null;
}

/// Resuelve el perfil de entorno del TÉCNICO para la `environmentClass` REAL
/// que emite el motor C++ (`EnvironmentClassifier`, 4 clases), mapeándola a
/// los perfiles que existen en la app: **Silencioso / Conversación / Ruidoso**.
///
/// FIX del clasificador (causa raíz #3): el motor expone `EnvironmentClass`
/// (0..3) vía `getDspStageMetrics()['environmentClass']`, pero el polling lo
/// interpretaba con `resolveSmartPreset` como `smart_scene::SceneClass` (0..7)
/// con presets inexistentes ("Suave/Medio/Alto") → siempre `null` → nunca
/// cambiaba de perfil. Este helper usa el contrato correcto de 4 clases.
///
/// Tabla de mapeo (`environment_classifier.h` → perfil del técnico):
///
/// | `envClass` | EnvironmentClass | Perfil          |
/// |------------|------------------|-----------------|
/// | 0          | QUIET            | "Silencioso"    |
/// | 1          | SPEECH           | "Conversación"  |
/// | 2          | SPEECH_IN_NOISE  | "Ruidoso"       |
/// | 3          | NOISE            | "Ruidoso"       |
///
/// Reglas:
/// - `envClass` fuera de `[0, 3]` → `null` (no cambiar de perfil).
/// - Si el perfil mapeado NO está en `availableProfiles` (case-sensitive,
///   sin trim) → `null` (no despachar; comportamiento seguro). Los perfiles
///   predefinidos (Req 8.1) siempre incluyen los tres.
///
/// Garantías: función pura, sin efectos secundarios, sin throws (total sobre
/// `int × List<String>`), no muta `availableProfiles`.
String? resolveEnvironmentProfile(int envClass, List<String> availableProfiles) {
  String target;
  switch (envClass) {
    case 0: // QUIET
      target = 'Silencioso';
      break;
    case 1: // SPEECH
      target = 'Conversación';
      break;
    case 2: // SPEECH_IN_NOISE
    case 3: // NOISE
      target = 'Ruidoso';
      break;
    default:
      return null;
  }
  for (final name in availableProfiles) {
    if (name == target) return name;
  }
  return null;
}
