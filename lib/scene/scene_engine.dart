/// Smart Scene Engine — Fase 2.
///
/// Fachada para la UI:
///   - Carga / guarda el toggle "personalizar con audiograma" en Hive.
///   - Lanza una sesión de análisis (`analyze`) que polea el `SceneAnalyzer`
///     nativo durante ~2.5 s y resuelve la clase dominante.
///   - `apply()` queda vacío en Fase 2 — la generación + aplicación de
///     preset llega en Fase 3.
///
/// Para no romper la app si Hive no está abierto (entornos de test) las
/// operaciones de persistencia son tolerantes a fallos.
///
/// Validates: Requirements 1.6, 5.1, 5.2

import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/services.dart';
import 'package:hive/hive.dart';

import 'scene_decision_maker.dart';
import 'scene_session.dart';
import 'scene_snapshot.dart';

/// Resultado completo de un análisis: clase + confianza + último snapshot
/// + flags para que la UI sepa qué mostrar.
class SceneAnalysisResult {
  final SceneClass sceneClass;
  final double confidence;
  final SceneSnapshot lastSnapshot;
  final bool wasPersonalized;
  final int sampleCount;
  final Map<SceneClass, int> distribution;

  const SceneAnalysisResult({
    required this.sceneClass,
    required this.confidence,
    required this.lastSnapshot,
    required this.wasPersonalized,
    required this.sampleCount,
    required this.distribution,
  });
}

/// Errores normalizados que la UI puede atrapar.
class SceneEngineException implements Exception {
  final String message;
  const SceneEngineException(this.message);
  @override
  String toString() => 'SceneEngineException: $message';
}

class SceneEngine {
  static const _channelName = 'com.psk.hearing_aid/audio';
  static const _settingsBox = 'smart_scene_settings';
  static const _personalizeKey = 'personalize_with_audiogram';

  final MethodChannel _channel;
  final Duration pollInterval;
  final Duration sessionTimeout;
  final int minSamples;
  final int maxSamples;

  bool _personalize = false;
  bool _settingsLoaded = false;

  SceneEngine({
    MethodChannel? channel,
    this.pollInterval = const Duration(milliseconds: 100),
    this.sessionTimeout = const Duration(seconds: 5),
    this.minSamples = 10,
    this.maxSamples = 25,
  }) : _channel = channel ?? const MethodChannel(_channelName);

  /// Lee el toggle persistido. Idempotente y silencioso en errores.
  Future<void> loadSettings() async {
    if (_settingsLoaded) return;
    try {
      final box = await _openBox();
      _personalize = (box.get(_personalizeKey) as bool?) ?? false;
    } catch (_) {
      _personalize = false;
    } finally {
      _settingsLoaded = true;
    }
  }

  /// Cambia el toggle y lo persiste.
  Future<void> setPersonalize(bool value) async {
    _personalize = value;
    _settingsLoaded = true;
    try {
      final box = await _openBox();
      await box.put(_personalizeKey, value);
    } catch (_) {
      // Silencioso: el valor sigue en memoria; la UI puede reintentar.
    }
  }

  /// Estado actual del toggle. Si nunca se cargó devuelve `false`.
  bool get personalizeWithAudiogram => _personalize;

  /// Hace una sesión de análisis: polea snapshots durante hasta
  /// `sessionTimeout`, requiere mínimo `minSamples` válidos, y resuelve la
  /// clase dominante.
  ///
  /// Lanza `SceneEngineException` si no logra acumular suficientes muestras
  /// (por ejemplo, si el motor de audio no está activo).
  Future<SceneAnalysisResult> analyze({
    DateTime Function()? clock,
  }) async {
    final session = SceneSession(
      decisionMaker: SceneDecisionMaker(holdMs: 0),
      minSamples: minSamples,
      maxSamples: maxSamples,
    );

    final stopwatch = Stopwatch()..start();
    final tickClock = clock ?? DateTime.now;

    while (stopwatch.elapsed < sessionTimeout && !session.isFull) {
      final snapshot = await _pollSnapshot();
      if (snapshot != null) {
        session.add(snapshot, now: tickClock());
      }
      await Future<void>.delayed(pollInterval);
    }

    if (!session.canResolve) {
      throw const SceneEngineException(
        'No se pudo capturar suficiente audio. Activá el audífono e intentá de nuevo.',
      );
    }

    final result = session.resolve();
    return SceneAnalysisResult(
      sceneClass: result.dominantClass,
      confidence: result.averageConfidence,
      lastSnapshot: result.lastSnapshot,
      wasPersonalized: _personalize,
      sampleCount: result.sampleCount,
      distribution: result.distribution,
    );
  }

  /// Aplica el preset derivado del análisis al pipeline DSP.
  ///
  /// **Fase 2:** stub no-op. La generación + dispatch al `AmplificationBloc`
  /// llega en Fase 3.
  Future<void> apply(SceneAnalysisResult result, {Object? bloc}) async {
    // No-op en Fase 2.
  }

  // ────────────────────────────────────────────────────────────────────
  // Internos
  // ────────────────────────────────────────────────────────────────────

  Future<SceneSnapshot?> _pollSnapshot() async {
    try {
      final raw = await _channel.invokeMethod<Uint8List>('getSceneSnapshot');
      if (raw == null || raw.isEmpty) return null;
      return SceneSnapshot.fromBytes(raw);
    } on PlatformException {
      return null;
    } catch (_) {
      return null;
    }
  }

  Future<Box<dynamic>> _openBox() async {
    if (Hive.isBoxOpen(_settingsBox)) {
      return Hive.box(_settingsBox);
    }
    return Hive.openBox(_settingsBox);
  }
}
