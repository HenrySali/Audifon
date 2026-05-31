/// Smart Scene Engine — Fase 3.
///
/// Fachada para la UI:
///   - Carga / guarda el toggle "personalizar con audiograma" en Hive.
///   - Lanza una sesión de análisis (`analyze`) que polea el `SceneAnalyzer`
///     nativo durante ~2.5 s y resuelve la clase dominante.
///   - `apply()` arma el `SmartPreset` (genérico o personalizado según
///     toggle + audiograma) y lo despacha al `AmplificationBloc`.
///
/// Para no romper la app si Hive no está abierto (entornos de test) las
/// operaciones de persistencia son tolerantes a fallos.
///
/// Validates: Requirements 1.6, 4.1, 4.2, 4.3, 4.5, 5.1, 5.2

import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/services.dart';
import 'package:hive/hive.dart';

import '../domain/entities/audiogram.dart';
import '../presentation/bloc/amplification_bloc.dart';
import '../presentation/bloc/amplification_event.dart';
import '../presentation/bloc/amplification_state.dart';
import 'scene_decision_maker.dart';
import 'scene_personalized_generator.dart';
import 'scene_preset_generator.dart';
import 'scene_session.dart';
import 'scene_snapshot.dart';
import 'smart_preset.dart';

/// Resultado completo de un análisis: clase + confianza + último snapshot
/// + flags para que la UI sepa qué mostrar.
class SceneAnalysisResult {
  final SceneClass sceneClass;
  final double confidence;
  final SceneSnapshot lastSnapshot;
  final bool wasPersonalized;
  final int sampleCount;
  final Map<SceneClass, int> distribution;
  final SmartPreset preset;

  const SceneAnalysisResult({
    required this.sceneClass,
    required this.confidence,
    required this.lastSnapshot,
    required this.wasPersonalized,
    required this.sampleCount,
    required this.distribution,
    required this.preset,
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

  final SceneGenericPresetGenerator _genericGenerator;
  final ScenePersonalizedPresetGenerator _personalizedGenerator;

  bool _personalize = false;
  bool _settingsLoaded = false;
  bool _personalizeFromUser = false;

  SceneEngine({
    MethodChannel? channel,
    SceneGenericPresetGenerator? genericGenerator,
    ScenePersonalizedPresetGenerator? personalizedGenerator,
    this.pollInterval = const Duration(milliseconds: 100),
    this.sessionTimeout = const Duration(seconds: 5),
    this.minSamples = 10,
    this.maxSamples = 25,
  })  : _channel = channel ?? const MethodChannel(_channelName),
        _genericGenerator =
            genericGenerator ?? SceneGenericPresetGenerator(),
        _personalizedGenerator = personalizedGenerator ??
            ScenePersonalizedPresetGenerator();

  /// Lee el toggle persistido. Idempotente y silencioso en errores.
  /// Tras el primer `loadSettings`, `wasPersonalizeUserSet` indica si hay
  /// un valor persistido por el usuario o se está usando el default `false`.
  Future<void> loadSettings() async {
    if (_settingsLoaded) return;
    try {
      final box = await _openBox();
      final stored = box.get(_personalizeKey);
      if (stored is bool) {
        _personalize = stored;
        _personalizeFromUser = true;
      } else {
        _personalize = false;
        _personalizeFromUser = false;
      }
    } catch (_) {
      _personalize = false;
      _personalizeFromUser = false;
    } finally {
      _settingsLoaded = true;
    }
  }

  /// Cambia el toggle y lo persiste.
  Future<void> setPersonalize(bool value) async {
    _personalize = value;
    _personalizeFromUser = true;
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

  /// True cuando el toggle viene de una elección persistida del usuario.
  /// Si es false, la UI puede aplicar un default contextual (por ej. ON
  /// si hay audiograma cargado).
  bool get wasPersonalizeUserSet => _personalizeFromUser;

  /// Hace una sesión de análisis: polea snapshots durante hasta
  /// `sessionTimeout`, requiere mínimo `minSamples` válidos, y resuelve la
  /// clase dominante.
  ///
  /// Genera el `SmartPreset` apropiado:
  ///   - Si el toggle está ON y se pasa `audiogram`, usa el generador
  ///     personalizado (NAL-NL2 + deltas).
  ///   - Si el toggle está OFF o no hay audiograma, usa el generador
  ///     genérico (preset clínico predefinido + tabla de tuning).
  ///
  /// Lanza `SceneEngineException` si no logra acumular suficientes muestras.
  Future<SceneAnalysisResult> analyze({
    Audiogram? audiogram,
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
    final usePersonalized = _personalize && audiogram != null;
    final preset = usePersonalized
        ? _personalizedGenerator.generate(
            audiogram: audiogram,
            sceneClass: result.dominantClass,
            snapshot: result.lastSnapshot,
            confidence: result.averageConfidence,
          )
        : _genericGenerator.generate(
            result.dominantClass,
            confidence: result.averageConfidence,
          );

    return SceneAnalysisResult(
      sceneClass: result.dominantClass,
      confidence: result.averageConfidence,
      lastSnapshot: result.lastSnapshot,
      wasPersonalized: usePersonalized,
      sampleCount: result.sampleCount,
      distribution: result.distribution,
      preset: preset,
    );
  }

  /// Aplica el preset al pipeline DSP a través del `AmplificationBloc` y
  /// persiste el "último preset" + "último NR level" vía `SettingsRepository`
  /// para que sobreviva a reinicios de la app.
  ///
  /// - Despacha `UpdateEqGains` con las 12 ganancias y el nombre del preset.
  /// - Si `volumeDeltaDb != 0` y el bloc está activo, despacha `ChangeVolume`
  ///   sumando el delta al volumen actual (clamp [-20, +10] dB).
  /// - Persiste el preset y el NR level en settings (silencioso a fallos).
  ///
  /// El TNR (Transient Noise Reduction) y el cambio activo de NR level no
  /// se despachan al engine en esta fase: el `AmplificationBloc` aplica NR
  /// vía clasificación automática y el TNR no tiene un canal nativo
  /// dedicado (queda diferido a Fase 5+ del spec).
  Future<void> apply(
    SceneAnalysisResult result, {
    required AmplificationBloc bloc,
  }) async {
    final preset = result.preset;
    bloc.add(UpdateEqGains(gains: preset.gains, presetName: preset.name));

    if (preset.volumeDeltaDb.abs() > 1e-3) {
      final state = bloc.state;
      if (state is AmplificationActive) {
        final newVol = (state.volumeDb + preset.volumeDeltaDb)
            .clamp(-20.0, 10.0);
        bloc.add(ChangeVolume(volumeDb: newVol));
      }
    }

    // Persistencia tolerante: si Hive no está abierto o la escritura falla,
    // el preset queda aplicado en memoria y la UI lo refleja igual.
    try {
      await bloc.settingsRepository.setLastEqPreset(<String, dynamic>{
        'name': preset.name,
        'gains': preset.gains,
        'sceneClass': preset.sceneClass.index,
        'isPersonalized': preset.isPersonalized,
        'compressionRatio': preset.compressionRatio,
        'compressionKnee': preset.compressionKnee,
        'expansionKnee': preset.expansionKnee,
        'tnrEnabled': preset.tnrEnabled,
        'volumeDeltaDb': preset.volumeDeltaDb,
        'confidence': preset.confidence,
        'savedAt': DateTime.now().toIso8601String(),
      });
      await bloc.settingsRepository.setLastNrLevel(preset.nrLevel);
    } catch (_) {
      // Persistencia no bloquea el apply.
    }
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
