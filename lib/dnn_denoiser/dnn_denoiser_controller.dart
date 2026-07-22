/// DNN Denoiser Controller — fachada Dart del wrapper C++ GTCRN.
///
/// Rol en la arquitectura (estilo LabVIEW SubVI / Front Panel):
///   - Front Panel: este controller expone `setEnabled` / `setIntensity` / `isActive`
///                  como controles e indicadores para la UI (cuando exista).
///   - Block Diagram: traduce esas operaciones a invocaciones del MethodChannel
///                    `com.psk.hearing_aid/audio` que terminan en el wrapper C++.
///   - Persistence: usa Hive (box `dnn_denoiser_settings`) para que la config
///                  sobreviva reinicios.
///
/// Defaults (deliberadamente conservadores para no cambiar el comportamiento
/// actual de la app):
///   - enabled  = false  → la app arranca con el NR Wiener clásico.
///   - intensity = 1.0   → si el usuario lo activa, va al máximo de denoising.
///
/// Errores: todas las llamadas al MethodChannel están envueltas en try/catch.
/// Si el bridge nativo no está disponible (tests sin dispositivo, sandbox web),
/// la operación se registra silenciosamente como fallida y el estado interno
/// se mantiene consistente con lo último que pidió la UI.
///
/// Tests: ver `test/dnn_denoiser/dnn_denoiser_controller_test.dart`. Los tests
/// inyectan un MethodChannel mockeado y un Hive box temporal para correr
/// 100% offline (sin dispositivo).

import 'dart:async';

import 'package:flutter/services.dart';
import 'package:hive/hive.dart';

/// Controlador del DNN denoiser (GTCRN). Vive como singleton lógico al lado
/// del resto del audio pipeline.
class DnnDenoiserController {
  /// Nombre del MethodChannel (compartido con el resto del audio bridge).
  static const String channelName = 'com.psk.hearing_aid/audio';

  /// Box de Hive donde persistimos enabled / intensity.
  static const String hiveBoxName = 'dnn_denoiser_settings';

  /// Llaves dentro del box.
  static const String _kEnabledKey = 'enabled';
  static const String _kIntensityKey = 'intensity';

  // ─── Defaults conservadores ──────────────────────────────────────────
  static const bool _defaultEnabled = false;
  static const double _defaultIntensity = 0.65;  // 0.65 evita artefactos; cap C++ a 0.75

  /// Cliente del MethodChannel (inyectable para tests).
  final MethodChannel _channel;

  /// Resolver perezoso del Box (inyectable para tests).
  final Future<Box<dynamic>> Function() _boxOpener;

  bool _enabled = _defaultEnabled;
  double _intensity = _defaultIntensity;
  bool _settingsLoaded = false;
  bool _isActiveCache = false;

  DnnDenoiserController({
    MethodChannel? channel,
    Future<Box<dynamic>> Function()? boxOpener,
  })  : _channel = channel ?? const MethodChannel(channelName),
        _boxOpener = boxOpener ?? _defaultBoxOpener;

  static Future<Box<dynamic>> _defaultBoxOpener() async {
    if (Hive.isBoxOpen(hiveBoxName)) {
      return Hive.box<dynamic>(hiveBoxName);
    }
    return Hive.openBox<dynamic>(hiveBoxName);
  }

  // ─── Estado público (snapshots in-memory) ───────────────────────────

  /// Último valor de enabled persistido / pedido por el usuario.
  bool get isEnabled => _enabled;

  /// Última intensity persistida (0..1).
  double get intensity => _intensity;

  /// Última lectura de "está procesando audio" del wrapper nativo.
  /// Se actualiza vía [refreshIsActive] o tras llamar [setEnabled].
  bool get isActive => _isActiveCache;

  /// true si ya se hizo `loadSettings()` (o el constructor de tests).
  bool get isSettingsLoaded => _settingsLoaded;

  // ─── Carga de settings ──────────────────────────────────────────────

  /// Carga enabled / intensity desde Hive. Idempotente.
  /// Si Hive no está disponible (tests sin Hive.init), deja los defaults
  /// y marca _settingsLoaded para que no se reintente.
  Future<void> loadSettings() async {
    if (_settingsLoaded) return;
    try {
      final box = await _boxOpener();
      final storedEnabled = box.get(_kEnabledKey);
      final storedIntensity = box.get(_kIntensityKey);
      if (storedEnabled is bool) {
        _enabled = storedEnabled;
      }
      if (storedIntensity is num) {
        _intensity = _clampIntensity(storedIntensity.toDouble());
      }
    } catch (_) {
      // En tests / sin Hive: dejamos los defaults.
    } finally {
      _settingsLoaded = true;
    }
  }

  /// Inicializa el modelo nativo y aplica el último estado guardado.
  /// Llamar UNA VEZ al iniciar la app, después de loadSettings().
  ///
  /// Si la inicialización nativa falla (modelo no carga, OnnxRuntime
  /// missing, etc.), la app sigue funcionando con bypass — el flag
  /// _enabled se mantiene en false y los siguientes setEnabled(true) se
  /// pueden reintentar.
  Future<bool> initializeNative() async {
    bool ok;
    try {
      final res = await _channel.invokeMethod<bool>('initDnnDenoiser');
      ok = res ?? false;
    } catch (_) {
      ok = false;
    }
    // Aplicar el último estado guardado (intensity siempre, enabled solo si
    // el modelo cargó OK).
    await _pushIntensity(_intensity);
    if (ok && _enabled) {
      await _pushEnabled(true);
    }
    await refreshIsActive();
    return ok;
  }

  // ─── Setters (UI / smart-scene → controller) ─────────────────────────

  /// Enciende/apaga el DNN denoiser.
  /// Persiste en Hive y propaga al nativo. Si ambas fallan, no es un error
  /// fatal: el estado en memoria queda con el valor pedido para que la UI
  /// refleje la intención del usuario.
  Future<void> setEnabled(bool enabled) async {
    _enabled = enabled;
    await _persistEnabled(enabled);
    await _pushEnabled(enabled);
    await refreshIsActive();
  }

  /// Cambia la intensidad de mezcla dry/wet (0..1).
  /// Valores fuera de rango se clampean automáticamente.
  Future<void> setIntensity(double intensity) async {
    _intensity = _clampIntensity(intensity);
    await _persistIntensity(_intensity);
    await _pushIntensity(_intensity);
  }

  /// Polea al nativo para preguntar si está realmente procesando.
  /// Útil si la UI quiere mostrar un LED "DNN activo" diferente del switch.
  Future<bool> refreshIsActive() async {
    try {
      final res = await _channel.invokeMethod<bool>('getDnnIsActive');
      _isActiveCache = res ?? false;
    } catch (_) {
      _isActiveCache = false;
    }
    return _isActiveCache;
  }

  // ─── Helpers internos ────────────────────────────────────────────────

  static double _clampIntensity(double v) {
    if (v.isNaN) return _defaultIntensity;
    if (v < 0.0) return 0.0;
    if (v > 1.0) return 1.0;
    return v;
  }

  Future<void> _persistEnabled(bool enabled) async {
    try {
      final box = await _boxOpener();
      await box.put(_kEnabledKey, enabled);
    } catch (_) {
      // En tests / sin Hive: silencio.
    }
  }

  Future<void> _persistIntensity(double intensity) async {
    try {
      final box = await _boxOpener();
      await box.put(_kIntensityKey, intensity);
    } catch (_) {
      // Silencio.
    }
  }

  Future<void> _pushEnabled(bool enabled) async {
    try {
      await _channel.invokeMethod<void>('setDnnEnabled', {'enabled': enabled});
    } catch (_) {
      // Silencio: el bridge nativo puede no estar listo en tests.
    }
  }

  Future<void> _pushIntensity(double intensity) async {
    try {
      await _channel.invokeMethod<void>(
        'setDnnIntensity',
        {'intensity': intensity},
      );
    } catch (_) {
      // Silencio.
    }
  }
}
