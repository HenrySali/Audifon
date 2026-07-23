/// Controlador de mapeo Escena → Modo de prescripción.
///
/// Orquesta la transición entre modos de prescripción (quiet / comfortInNoise)
/// en respuesta a cambios de escena acústica del Smart Scene Engine.
///
/// Responsabilidades:
/// - Mapea [SceneClass] a [PrescriptionMode] según el [PrescriberMode] activo.
/// - Aplica histéresis asimétrica (dwell time) para evitar oscilación rápida
///   entre modos: NOISE→QUIET requiere más tiempo que QUIET→NOISE.
/// - Expone [crossfadeDurationMs] para que la UI interpole ganancias suavemente.
/// - Trackea estado: [currentMode], [pendingMode], [lastSceneChangeTimestamp].
///
/// Cuando el prescriptor activo es NL2, el controlador ignora cambios de escena
/// y mantiene siempre [PrescriptionMode.quiet] — el scene engine sigue corriendo
/// pero no dispara CIN.
///
/// Requisitos: 6.1, 6.2, 6.3, 6.4, 6.5
library;

import '../scene/scene_snapshot.dart' show SceneClass;
import 'entities/prescription_mode.dart';

/// Controlador que resuelve el modo de prescripción activo en función de
/// la escena acústica detectada, el modo de prescriptor seleccionado y
/// las reglas de histéresis del Smart Scene Engine.
///
/// Uso típico:
/// ```dart
/// final controller = ScenePrescriptionController();
///
/// // Cuando el scene engine emite una nueva clasificación:
/// controller.onSceneChanged(SceneClass.voiceInNoiseLow);
///
/// // El controller aplica dwell time; consultá el modo resuelto:
/// final mode = controller.currentMode; // quiet o comfortInNoise
/// ```
///
/// Requisitos: 6.1, 6.2, 6.3, 6.4, 6.5
class ScenePrescriptionController {
  /// Dwell time (ms) para transición de escena ruidosa → silencio/voz.
  /// Valor más alto para evitar que fluctuaciones breves desactiven CIN.
  final int dwellNoiseToQuietMs;

  /// Dwell time (ms) para transición de silencio/voz → escena ruidosa.
  /// Valor más bajo para activar CIN rápidamente cuando aparece ruido.
  final int dwellQuietToNoiseMs;

  /// Duración del crossfade (ms) para interpolar ganancias entre modos.
  /// El UI usa este valor para animar la transición de EQ. Rango: [200, 500].
  final int crossfadeDurationMs;

  /// Modo de prescriptor activo (NL2 o NL3). Cuando es NL2, las
  /// transiciones de escena no disparan cambio de modo de prescripción.
  PrescriberMode _prescriberMode;

  /// Modo de prescripción efectivo actual.
  PrescriptionMode _currentMode;

  /// Modo pendiente (candidato tras detectar un cambio de escena).
  /// Se confirma después del dwell time correspondiente.
  PrescriptionMode? _pendingMode;

  /// Timestamp de la última detección de cambio de escena que inició
  /// un dwell period. Se usa para comparar con el reloj actual y decidir
  /// si el dwell expiró.
  DateTime? _lastSceneChangeTimestamp;

  /// Última [SceneClass] procesada por el controlador.
  SceneClass _lastSceneClass;

  /// Crea un controlador con parámetros de histéresis y crossfade.
  ///
  /// [prescriberMode] Modo inicial del prescriptor (default: NL3).
  /// [dwellNoiseToQuietMs] Tiempo de espera para confirmar transición
  ///   de ruidoso a silencio (default: 2000 ms).
  /// [dwellQuietToNoiseMs] Tiempo de espera para confirmar transición
  ///   de silencio a ruidoso (default: 500 ms).
  /// [crossfadeDurationMs] Duración de la interpolación de ganancia
  ///   entre modos (default: 300 ms, rango válido: 200–500).
  ScenePrescriptionController({
    PrescriberMode prescriberMode = PrescriberMode.smartNl3,
    this.dwellNoiseToQuietMs = 2000,
    this.dwellQuietToNoiseMs = 500,
    int crossfadeDurationMs = 300,
  })  : _prescriberMode = prescriberMode,
        _currentMode = PrescriptionMode.quiet,
        _lastSceneClass = SceneClass.unknown,
        crossfadeDurationMs = crossfadeDurationMs.clamp(200, 500);

  // ──────────────────────────────────────────────────────────────────
  // Getters públicos
  // ──────────────────────────────────────────────────────────────────

  /// Modo de prescripción efectivo actual (quiet o comfortInNoise).
  PrescriptionMode get currentMode => _currentMode;

  /// Modo pendiente esperando confirmación por dwell time, o null si
  /// no hay transición en curso.
  PrescriptionMode? get pendingMode => _pendingMode;

  /// Timestamp del último cambio de escena que inició un período de dwell.
  DateTime? get lastSceneChangeTimestamp => _lastSceneChangeTimestamp;

  /// Última escena procesada.
  SceneClass get lastSceneClass => _lastSceneClass;

  /// Modo de prescriptor activo.
  PrescriberMode get prescriberMode => _prescriberMode;

  /// Indica si hay una transición de modo pendiente (dwell en curso).
  bool get isTransitionPending => _pendingMode != null;

  // ──────────────────────────────────────────────────────────────────
  // API pública
  // ──────────────────────────────────────────────────────────────────

  /// Actualiza el modo de prescriptor (NL2 / NL3).
  ///
  /// Si se cambia a NL2, cancela cualquier transición pendiente y
  /// fuerza el modo a quiet (NL2 no usa CIN por escena).
  void setPrescriberMode(PrescriberMode mode) {
    _prescriberMode = mode;
    if (mode == PrescriberMode.smartNl2) {
      // NL2 no reacciona a la escena — siempre quiet.
      _currentMode = PrescriptionMode.quiet;
      _pendingMode = null;
      _lastSceneChangeTimestamp = null;
    }
  }

  /// Notifica al controlador que la escena acústica cambió.
  ///
  /// Calcula el [PrescriptionMode] target según la escena y el prescriptor
  /// activo, y si difiere del modo actual inicia un período de dwell.
  /// Retorna `true` si el modo efectivo cambió inmediatamente (sin dwell
  /// pendiente) o `false` si inició/mantiene un dwell.
  ///
  /// [sceneClass] Clase de escena detectada por el Smart Scene Engine.
  /// [now] Timestamp actual. Opcional — si no se provee usa `DateTime.now()`.
  ///   Pasar explícitamente facilita testing determinista.
  bool onSceneChanged(SceneClass sceneClass, {DateTime? now}) {
    _lastSceneClass = sceneClass;
    final timestamp = now ?? DateTime.now();

    // En modo NL2, ignorar cambios de escena para CIN.
    if (_prescriberMode == PrescriberMode.smartNl2) {
      _currentMode = PrescriptionMode.quiet;
      _pendingMode = null;
      _lastSceneChangeTimestamp = null;
      return false;
    }

    // Mapear SceneClass → PrescriptionMode target para NL3.
    final targetMode = _mapSceneToMode(sceneClass);

    // Si el target ya es el modo actual, cancelar cualquier pending.
    if (targetMode == _currentMode) {
      _pendingMode = null;
      _lastSceneChangeTimestamp = null;
      return false;
    }

    // Determinar el dwell requerido para esta transición.
    final requiredDwell = _getDwellTimeMs(targetMode);

    // Si no hay transición pendiente o el target cambió respecto al pending,
    // iniciar un nuevo período de dwell.
    if (_pendingMode == null || _pendingMode != targetMode) {
      // Dwell 0: transición inmediata sin espera.
      if (requiredDwell <= 0) {
        _currentMode = targetMode;
        _pendingMode = null;
        _lastSceneChangeTimestamp = null;
        return true;
      }
      _pendingMode = targetMode;
      _lastSceneChangeTimestamp = timestamp;
      return false;
    }

    // Hay una transición pendiente hacia el mismo target — verificar si
    // el dwell time expiró.
    final elapsed =
        timestamp.difference(_lastSceneChangeTimestamp!).inMilliseconds;

    if (elapsed >= requiredDwell) {
      // Dwell cumplido: confirmar transición.
      _currentMode = targetMode;
      _pendingMode = null;
      _lastSceneChangeTimestamp = null;
      return true;
    }

    // Dwell aún en curso.
    return false;
  }

  /// Fuerza la evaluación del dwell sin un nuevo evento de escena.
  ///
  /// Útil cuando se usa un timer periódico para revisar si el dwell
  /// expiró entre eventos de escena. Retorna `true` si la transición
  /// se confirmó.
  ///
  /// [now] Timestamp actual. Opcional.
  bool tick({DateTime? now}) {
    if (_pendingMode == null || _lastSceneChangeTimestamp == null) {
      return false;
    }

    final timestamp = now ?? DateTime.now();
    final elapsed =
        timestamp.difference(_lastSceneChangeTimestamp!).inMilliseconds;
    final requiredDwell = _getDwellTimeMs(_pendingMode!);

    if (elapsed >= requiredDwell) {
      _currentMode = _pendingMode!;
      _pendingMode = null;
      _lastSceneChangeTimestamp = null;
      return true;
    }

    return false;
  }

  /// Reinicia el controlador al estado inicial (quiet, sin pending).
  void reset() {
    _currentMode = PrescriptionMode.quiet;
    _pendingMode = null;
    _lastSceneChangeTimestamp = null;
    _lastSceneClass = SceneClass.unknown;
  }

  // ──────────────────────────────────────────────────────────────────
  // Lógica interna
  // ──────────────────────────────────────────────────────────────────

  /// Mapea una [SceneClass] al [PrescriptionMode] correspondiente en NL3.
  ///
  /// Escenas que activan CIN: voiceInNoiseLow, voiceInNoiseMid,
  /// noiseLowDominant, noiseHighDominant.
  /// Escenas que mantienen quiet: silence, voiceOnly, music, unknown.
  PrescriptionMode _mapSceneToMode(SceneClass scene) {
    switch (scene) {
      case SceneClass.voiceInNoiseLow:
      case SceneClass.voiceInNoiseMid:
      case SceneClass.noiseLowDominant:
      case SceneClass.noiseHighDominant:
        return PrescriptionMode.comfortInNoise;
      case SceneClass.silence:
      case SceneClass.voiceOnly:
      case SceneClass.music:
      case SceneClass.unknown:
        return PrescriptionMode.quiet;
    }
  }

  /// Retorna el dwell time (ms) requerido para confirmar la transición
  /// hacia [targetMode].
  ///
  /// Si el target es quiet (desactivar CIN), se usa un dwell largo para
  /// evitar desactivaciones prematuras por fluctuaciones breves.
  /// Si el target es comfortInNoise (activar CIN), se usa un dwell corto
  /// para responder rápido al ruido.
  int _getDwellTimeMs(PrescriptionMode targetMode) {
    switch (targetMode) {
      case PrescriptionMode.quiet:
        return dwellNoiseToQuietMs;
      case PrescriptionMode.comfortInNoise:
        return dwellQuietToNoiseMs;
      case PrescriptionMode.mhl:
        // MHL se activa por acción explícita del usuario, no por escena.
        // Si por alguna razón llegara acá, usar dwell mínimo.
        return dwellQuietToNoiseMs;
    }
  }
}
