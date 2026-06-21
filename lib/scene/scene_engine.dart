/// Smart Scene Engine — Fase 3 (refactor audiogram-driven-presets task 6.2).
///
/// Fachada para la UI:
///   - Carga / guarda el toggle "personalizar con audiograma" en Hive.
///   - Lanza una sesión de análisis (`analyze`) que polea el `SceneAnalyzer`
///     nativo durante ~2.5 s y resuelve la clase dominante.
///   - Construye el [AudiogramDrivenBundle] desde el audiograma medido —
///     o desde [Audiogram.defaultAudiogram] si no hay uno medido — y
///     genera el [SmartPreset] sobre esa base. Si se está usando el
///     audiograma default, expone el flag por la stream
///     [usingDefaultAudiogramStream] para que la UI muestre el hint
///     "Audiograma no medido…" (Req 7.8).
///   - `apply()` despacha el preset al `AmplificationBloc`.
///
/// Para no romper la app si Hive no está abierto (entornos de test) las
/// operaciones de persistencia son tolerantes a fallos.
///
/// Validates: Requirements 7.1, 7.2, 7.3, 7.5, 7.6, 7.8, 7.9

import 'dart:async';

import 'package:flutter/services.dart';
import 'package:hive/hive.dart';

import '../domain/audiogram_driven_presets/audiogram_driven_bundle.dart';
import '../domain/audiogram_driven_presets/bundle_builder.dart';
import '../domain/audiogram_driven_presets/environment_profile_mapper.dart';
import '../domain/entities/audiogram.dart';
import '../domain/entities/environment_profile.dart';
import '../domain/entities/prescription_mode.dart';
import '../domain/entities/wdrc_params.dart';
import '../presentation/bloc/amplification_bloc.dart';
import '../presentation/bloc/amplification_event.dart';
import '../presentation/bloc/amplification_state.dart';
import 'scene_decision_maker.dart';
import 'scene_personalized_generator.dart';
import 'scene_preset_generator.dart';
import 'scene_recorder.dart' show SceneRecord, SceneRecorder;
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

  /// `true` cuando el bundle base se construyó usando
  /// [Audiogram.defaultAudiogram] porque no había audiograma medido
  /// disponible. La UI puede usarlo para mostrar el hint
  /// "Audiograma no medido…" (Req 7.8).
  final bool usedDefaultAudiogram;

  /// Bundle audiograma-derivado usado como base del preset. Lo
  /// exponemos para que la UI o herramientas de diagnóstico puedan
  /// inspeccionar las ganancias / MPO / NR base sin tener que
  /// reconstruirlo.
  final AudiogramDrivenBundle bundle;

  const SceneAnalysisResult({
    required this.sceneClass,
    required this.confidence,
    required this.lastSnapshot,
    required this.wasPersonalized,
    required this.sampleCount,
    required this.distribution,
    required this.preset,
    required this.usedDefaultAudiogram,
    required this.bundle,
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
  final SceneRecorder _recorder;
  final BundleBuilder _bundleBuilder;

  bool _personalize = false;
  bool _settingsLoaded = false;
  bool _personalizeFromUser = false;

  /// Stream que emite `true` cuando el último `analyze()` usó el
  /// audiograma default y `false` cuando usó uno medido. La UI se
  /// suscribe para mostrar / ocultar el hint "Audiograma no medido…"
  /// (Req 7.8).
  final StreamController<bool> _usingDefaultCtrl =
      StreamController<bool>.broadcast();

  /// Último valor emitido por [usingDefaultAudiogramStream]. La UI lo
  /// consulta al montarse para no esperar al próximo `analyze()`.
  bool _lastUsingDefault = false;

  SceneEngine({
    MethodChannel? channel,
    SceneGenericPresetGenerator? genericGenerator,
    ScenePersonalizedPresetGenerator? personalizedGenerator,
    SceneRecorder? recorder,
    BundleBuilder? bundleBuilder,
    this.pollInterval = const Duration(milliseconds: 100),
    this.sessionTimeout = const Duration(seconds: 5),
    this.minSamples = 10,
    this.maxSamples = 25,
  })  : _channel = channel ?? const MethodChannel(_channelName),
        _genericGenerator =
            genericGenerator ?? SceneGenericPresetGenerator(),
        _personalizedGenerator = personalizedGenerator ??
            ScenePersonalizedPresetGenerator(),
        _recorder = recorder ?? SceneRecorder(),
        _bundleBuilder = bundleBuilder ?? BundleBuilder();

  /// Acceso al recorder para que la UI pueda leer historial / actualizar
  /// feedback.
  SceneRecorder get recorder => _recorder;

  /// Emite `true` cuando el último análisis usó el audiograma default,
  /// `false` cuando usó uno medido. Stream broadcast: la UI puede
  /// suscribirse en cualquier momento (Req 7.8).
  Stream<bool> get usingDefaultAudiogramStream => _usingDefaultCtrl.stream;

  /// Último valor emitido por [usingDefaultAudiogramStream].
  bool get isUsingDefaultAudiogram => _lastUsingDefault;

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
  /// Construye siempre un [AudiogramDrivenBundle] como base del preset
  /// (Req 7.1, 7.2, 7.3):
  /// - Si [audiogram] está presente, lo usa.
  /// - Si es `null`, cae a [Audiogram.defaultAudiogram] y emite por
  ///   [usingDefaultAudiogramStream] el flag `true` para que la UI
  ///   muestre el hint (Req 7.8).
  ///
  /// El toggle `personalize_with_audiogram` ahora controla SOLO si los
  /// deltas por escena se aplican encima del bundle (ON →
  /// [ScenePersonalizedPresetGenerator]) o si el EQ se queda en la base
  /// audiograma-derivada con sólo el tuning de escena (OFF →
  /// [SceneGenericPresetGenerator]). En ambos casos el bundle base
  /// viene del audiograma (Req 7.5, 7.6).
  ///
  /// El [profile] (opcional) determina el [PrescriptionMode] usado al
  /// construir el bundle vía [EnvironmentProfileMapper.modeFor]. Si es
  /// `null`, se usa [PrescriptionMode.quiet] como default seguro.
  ///
  /// Lanza `SceneEngineException` si no logra acumular suficientes muestras.
  Future<SceneAnalysisResult> analyze({
    Audiogram? audiogram,
    EnvironmentProfile? profile,
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

    // Construir el bundle base SIEMPRE desde un audiograma (medido o
    // default). El toggle `personalize` ya no decide si construimos el
    // bundle, sólo decide si aplicamos los deltas por escena al EQ.
    final usedDefault = audiogram == null;
    final baseAudiogram = audiogram ?? Audiogram.defaultAudiogram();
    final prescriptionMode = profile != null
        ? EnvironmentProfileMapper.modeFor(profile)
        : PrescriptionMode.quiet;

    final bundle = _bundleBuilder.buildFromAudiogram(
      baseAudiogram,
      mode: prescriptionMode,
      derivedAt: tickClock().toUtc(),
    );

    // Notificar a la UI sobre el origen del audiograma (Req 7.8).
    if (usedDefault != _lastUsingDefault || !_usingDefaultEverEmitted) {
      _lastUsingDefault = usedDefault;
      _usingDefaultEverEmitted = true;
      if (!_usingDefaultCtrl.isClosed) {
        _usingDefaultCtrl.add(usedDefault);
      }
    }

    final preset = _personalize
        ? _personalizedGenerator.generate(
            bundle: bundle,
            sceneClass: result.dominantClass,
            snapshot: result.lastSnapshot,
            confidence: result.averageConfidence,
          )
        : _genericGenerator.generate(
            bundle: bundle,
            sceneClass: result.dominantClass,
            snapshot: result.lastSnapshot,
            confidence: result.averageConfidence,
          );

    return SceneAnalysisResult(
      sceneClass: result.dominantClass,
      confidence: result.averageConfidence,
      lastSnapshot: result.lastSnapshot,
      wasPersonalized: _personalize,
      sampleCount: result.sampleCount,
      distribution: result.distribution,
      preset: preset,
      usedDefaultAudiogram: usedDefault,
      bundle: bundle,
    );
  }

  /// Aplica el preset al pipeline DSP a través del `AmplificationBloc` y
  /// persiste el "último preset" + "último NR level" vía `SettingsRepository`
  /// para que sobreviva a reinicios de la app.
  ///
  /// - Despacha `UpdateEqGains` con las 12 ganancias y el nombre del preset.
  /// - FIX Causa C (smart-scene-diagnostico-chasquido.md): despacha también
  ///   `UpdateNrLevel`, `UpdateWdrcParams` y `SetTnrEnabled` para que el
  ///   preset Smart Scene COMPLETO llegue al engine. Antes sólo EQ + Volume
  ///   se aplicaban; los demás campos (`nrLevel`, `compressionKnee/Ratio`,
  ///   `expansionKnee`, `tnrEnabled`) quedaban persistidos en Hive pero el
  ///   `EnvironmentClassifier` automático seguía pisándolos en cada cambio
  ///   de clase, produciendo el desbalance aleatorio reportado.
  /// - Si `volumeDeltaDb != 0` y el bloc está activo, despacha `ChangeVolume`
  ///   sumando el delta al volumen actual (clamp [-20, +10] dB).
  /// - Persiste el preset y el NR level en settings (silencioso a fallos).
  Future<void> apply(
    SceneAnalysisResult result, {
    required AmplificationBloc bloc,
  }) async {
    final preset = result.preset;

    // FIX Causa C/B' (smart-scene-diagnostico-chasquido.md):
    // ANTES de despachar el preset, fijamos el "pin" del preset Smart en
    // el motor nativo. Mientras el pin esté activo, el clasificador
    // automático SIGUE corriendo (publica la clase actual para la UI)
    // pero NO machaca los targets del WDRC + NR cuando cambia la escena.
    // El preset Smart manual queda firme hasta que la UI:
    //   - desactive Smart Scene (libera el pin desde
    //     AmplificationBloc._stopSmartPolling),
    //   - aplique un preset distinto que no provenga de Smart Scene
    //     (libera el pin desde _onUpdateEqGains cuando el presetName no
    //     empieza con "SmartScene").
    // Tolerante a fallos del bridge: si falla, el preset igual se aplica
    // (la UI lo verá), pero el clasificador automático puede pisarlo.
    try {
      await _channel.invokeMethod<void>(
        'setSmartPresetPinned',
        <String, dynamic>{'pinned': true},
      );
    } catch (_) {
      // Persistencia no bloquea el apply; loguea pero sigue.
    }

    bloc.add(UpdateEqGains(gains: preset.gains, presetName: preset.name));

    // FIX Causa C (smart-scene-diagnostico-chasquido.md):
    // Despachar el resto del preset al engine para que el clasificador
    // automático no quede manejando esos campos por separado.
    bloc.add(UpdateNrLevel(level: preset.nrLevel));
    bloc.add(UpdateWdrcParams(
      params: WdrcParams(
        expansionKnee: preset.expansionKnee,
        compressionKnee: preset.compressionKnee,
        compressionRatio: preset.compressionRatio,
      ),
    ));
    bloc.add(SetTnrEnabled(enabled: preset.tnrEnabled));

    // Notificar al bloc del cambio de escena para que el módulo NL3 CIN
    // (controlado por `ScenePrescriptionController`) decida activar o
    // desactivar Comfort in Noise. En modo NL2 el bloc ignora el evento.
    bloc.add(SceneClassUpdated(sceneClass: result.sceneClass));

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
        'clampedBands': preset.clampedBands,
        'savedAt': DateTime.now().toIso8601String(),
      });
      await bloc.settingsRepository.setLastNrLevel(preset.nrLevel);
    } catch (_) {
      // Persistencia no bloquea el apply.
    }

    // Registrar la aplicación en el log de Smart Scene para histórico +
    // feedback. Devuelve el SceneRecord guardado por si el caller quiere
    // su `id` (p. ej. para asociar el botón 👍/👎).
    try {
      _lastRecord = await _recorder.record(result, preset: preset);
    } catch (_) {
      _lastRecord = null;
    }
  }

  /// Último `SceneRecord` registrado (para feedback). null si todavía no
  /// se aplicó nada en esta sesión.
  SceneRecord? get lastRecord => _lastRecord;
  SceneRecord? _lastRecord;

  /// Cierra el stream broadcast. Útil en tests para evitar leaks.
  void dispose() {
    if (!_usingDefaultCtrl.isClosed) {
      _usingDefaultCtrl.close();
    }
  }

  // ────────────────────────────────────────────────────────────────────
  // Internos
  // ────────────────────────────────────────────────────────────────────

  bool _usingDefaultEverEmitted = false;

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
