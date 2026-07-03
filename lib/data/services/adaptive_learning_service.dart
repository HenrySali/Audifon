/// Servicio de Aprendizaje Adaptativo.
///
/// Orquesta la captura de observaciones del técnico + telemetría DSP,
/// las persiste en Hive, y las envía al backend de Hermes para obtener
/// sugerencias de ajuste. Cuando Hermes responde, actualiza la observación
/// y notifica a la UI.
///
/// Integraciones:
/// - `getDspStageMetrics()` vía AudioBridge → telemetría DSP en tiempo real
/// - `SessionLogService` → contexto de sesión (optional enrichment)
/// - `SceneEngine` → clase de escena actual
/// - Hive box `adaptive_learning` → persistencia local de observaciones
/// - HTTP a Hermes backend → análisis + sugerencia
library;

import 'dart:async';
import 'dart:convert';
import 'dart:developer' as developer;

import 'package:hive/hive.dart';
import 'package:http/http.dart' as http;

import '../../domain/adaptive_learning/learning_observation.dart';
import '../../presentation/bloc/amplification_bloc.dart';
import '../../presentation/bloc/amplification_event.dart';
import '../../presentation/bloc/amplification_state.dart';
import '../../scene/scene_snapshot.dart' show SceneClass;

/// Configuración del servicio de aprendizaje adaptativo.
class AdaptiveLearningConfig {
  /// URL base del backend Hermes (ej: http://192.168.1.100:8080)
  final String hermesBaseUrl;

  /// Timeout para requests al backend.
  final Duration requestTimeout;

  /// Máximo de observaciones en el historial local.
  final int maxObservations;

  const AdaptiveLearningConfig({
    this.hermesBaseUrl = 'http://149.50.137.2:8080',
    this.requestTimeout = const Duration(seconds: 15),
    this.maxObservations = 200,
  });
}

/// Servicio singleton de aprendizaje adaptativo.
class AdaptiveLearningService {
  AdaptiveLearningService._();
  static final AdaptiveLearningService instance = AdaptiveLearningService._();

  static const String _boxName = 'adaptive_learning';

  AdaptiveLearningConfig _config = const AdaptiveLearningConfig();
  final List<LearningObservation> _observations = [];
  bool _initialized = false;

  String _deviceId = '';

  /// Establece el ID de dispositivo para tracking en Hermes.
  void setDeviceId(String id) {
    _deviceId = id;
  }

  /// Si es true, Hermes aplica automáticamente las sugerencias al recibirlas.
  bool autoApply = false;

  final StreamController<void> _changeController =
      StreamController<void>.broadcast();

  /// Stream que emite cuando cambia el estado (nueva observación, sugerencia, etc.)
  Stream<void> get onChange => _changeController.stream;

  /// Observaciones ordenadas de más reciente a más antigua.
  List<LearningObservation> get observations =>
      List<LearningObservation>.unmodifiable(_observations);

  /// Cantidad de observaciones pendientes de análisis.
  int get pendingCount => _observations
      .where((o) =>
          o.status == ObservationStatus.pending ||
          o.status == ObservationStatus.analyzing)
      .length;

  /// Cantidad de sugerencias listas para aplicar.
  int get readyCount => _observations
      .where((o) => o.status == ObservationStatus.suggestionReady)
      .length;

  /// Configura el servicio. Llamar antes de usar.
  void configure(AdaptiveLearningConfig config) {
    _config = config;
  }

  /// Activa o desactiva la aplicación automática de sugerencias.
  void setAutoApply(bool value) async {
    autoApply = value;
    try {
      final box = await _openBox();
      await box.put('auto_apply', value);
    } catch (_) {}
  }

  /// Inicializa cargando el historial desde Hive.
  Future<void> init() async {
    if (_initialized) return;
    try {
      final box = await _openBox();
      autoApply = box.get('auto_apply', defaultValue: false) as bool;
      final entries = box.values.toList();
      _observations.clear();
      for (final raw in entries) {
        try {
          final map = raw is Map
              ? Map<String, dynamic>.from(raw)
              : jsonDecode(raw as String) as Map<String, dynamic>;
          _observations.add(LearningObservation.fromJson(map));
        } catch (_) {
          // Entrada corrupta — ignorar.
        }
      }
      _observations.sort((a, b) => b.id.compareTo(a.id));
      _initialized = true;
    } catch (e) {
      developer.log('AdaptiveLearning: init failed: $e',
          name: 'AdaptiveLearning');
      _initialized = true; // Seguir funcionando en memoria.
    }
  }

  /// Crea una nueva observación capturando telemetría del [bloc] actual.
  ///
  /// [userText] es la descripción libre del técnico (ej: "Restaurante
  /// ruidoso, el paciente dice que escucha la voz baja").
  ///
  /// Automáticamente:
  /// 1. Captura `getDspStageMetrics()` para la telemetría.
  /// 2. Lee la escena actual del estado del bloc.
  /// 3. Persiste en Hive.
  /// 4. Si hay conexión a Hermes, envía para análisis.
  Future<LearningObservation?> addObservation({
    required String userText,
    required AmplificationBloc bloc,
  }) async {
    if (userText.trim().isEmpty) return null;

    // Capturar telemetría DSP del momento.
    final telemetry = await _captureTelemetry(bloc);
    if (telemetry == null) {
      developer.log('AdaptiveLearning: telemetry null, motor parado?',
          name: 'AdaptiveLearning');
    }

    // Leer escena actual.
    final state = bloc.state;
    final sceneClass = state is AmplificationActive
        ? _intToSceneClass(state.activeNrLevel)
        : SceneClass.unknown;

    // Leer EQ + NR + volumen actuales del estado.
    final currentGains = state is AmplificationActive
        ? List<double>.from(state.activeEqGains ?? List<double>.filled(12, 0.0))
        : List<double>.filled(12, 0.0);
    final currentNr =
        state is AmplificationActive ? state.activeNrLevel : 1;
    final currentVol =
        state is AmplificationActive ? state.volumeDb : 0.0;

    final effectiveTelemetry = telemetry ??
        DspTelemetrySnapshot(
          inputLevelDb: -80,
          outputLevelDb: -80,
          postNrLevelDb: -80,
          postEqLevelDb: -80,
          postWdrcLevelDb: -80,
          peakSample: 0,
          clipCount: 0,
          wdrcRegion: 1,
          wdrcGainFactor: 1,
          mpoLimitingFraction: 0,
          mpoLimitingSustained: false,
          environmentClass: sceneClass.index,
          nrLevel: currentNr,
          eqGains: currentGains,
          volumeDb: currentVol,
        );

    final observation = LearningObservation(
      id: DateTime.now().microsecondsSinceEpoch,
      timestamp: DateTime.now(),
      userText: userText.trim(),
      telemetry: effectiveTelemetry,
      detectedScene: sceneClass,
      status: ObservationStatus.pending,
    );

    _observations.insert(0, observation);
    await _persist(observation);
    _changeController.add(null);

    // Enviar a Hermes en background (no bloquea la UI).
    _sendToHermes(observation, bloc: bloc);

    return observation;
  }

  /// Aplica la sugerencia de una observación y marca como aplicada.
  Future<void> applySuggestion(int observationId, AmplificationBloc bloc) async {
    final idx = _observations.indexWhere((o) => o.id == observationId);
    if (idx < 0) return;

    final obs = _observations[idx];
    if (obs.suggestion == null) return;

    // Aplicar los ajustes DSP sugeridos via el bloc.
    // Usa los mismos eventos que SceneEngine.apply() para consistencia.
    final suggestion = obs.suggestion!;

    // Importar los eventos necesarios.
    bloc.add(UpdateEqGains(
      gains: suggestion.suggestedGains,
      presetName: 'Hermes: ${obs.userText.length > 20 ? '${obs.userText.substring(0, 20)}...' : obs.userText}',
    ));
    bloc.add(UpdateNrLevel(level: suggestion.suggestedNrLevel));

    if ((suggestion.suggestedVolumeDb - obs.telemetry.volumeDb).abs() > 0.5) {
      bloc.add(ChangeVolume(volumeDb: suggestion.suggestedVolumeDb));
    }

    // Actualizar estado.
    _observations[idx] = obs.copyWith(status: ObservationStatus.applied);
    await _persist(_observations[idx]);
    _changeController.add(null);
  }

  /// Descarta la sugerencia de una observación.
  Future<void> dismissSuggestion(int observationId) async {
    final idx = _observations.indexWhere((o) => o.id == observationId);
    if (idx < 0) return;

    _observations[idx] =
        _observations[idx].copyWith(status: ObservationStatus.dismissed);
    await _persist(_observations[idx]);
    _changeController.add(null);
  }

  /// Registra feedback (👍/👎) sobre una observación aplicada.
  Future<void> addFeedback(int observationId, {required bool positive}) async {
    final idx = _observations.indexWhere((o) => o.id == observationId);
    if (idx < 0) return;

    _observations[idx] = _observations[idx].copyWith(feedback: positive);
    await _persist(_observations[idx]);
    _changeController.add(null);

    // Enviar feedback a Hermes para que mejore.
    _sendFeedbackToHermes(_observations[idx]);
  }

  /// Limpia todo el historial.
  Future<void> clearHistory() async {
    _observations.clear();
    try {
      final box = await _openBox();
      await box.clear();
    } catch (_) {}
    _changeController.add(null);
  }

  /// Sincroniza el historial desde el servidor Hermes.
  /// Útil al reinstalar la app o al primer arranque.
  Future<void> syncFromServer() async {
    if (_deviceId.isEmpty) return;
    try {
      final uri = Uri.parse('${_config.hermesBaseUrl}/api/adaptive-learning/sync');
      final response = await http.post(
        uri,
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({'deviceId': _deviceId}),
      ).timeout(_config.requestTimeout);
      
      if (response.statusCode == 200) {
        final json = jsonDecode(response.body) as Map<String, dynamic>;
        final serverObs = json['observations'] as List? ?? [];
        final autoRec = json['autoApplyRecommended'] as bool? ?? false;
        
        // Merge server observations with local (server wins on conflict)
        for (final raw in serverObs) {
          try {
            final obs = LearningObservation.fromJson(Map<String, dynamic>.from(raw));
            final existing = _observations.indexWhere((o) => o.id == obs.id);
            if (existing < 0) {
              _observations.add(obs);
            } else {
              // Server version wins
              _observations[existing] = obs;
            }
          } catch (_) {}
        }
        _observations.sort((a, b) => b.id.compareTo(a.id));
        
        // If server recommends auto-apply and we don't have a local preference
        if (autoRec && !autoApply) {
          developer.log('AdaptiveLearning: server recommends autoApply', name: 'AdaptiveLearning');
        }
        
        _changeController.add(null);
        developer.log('AdaptiveLearning: synced ${serverObs.length} observations from server', name: 'AdaptiveLearning');
      }
    } catch (e) {
      developer.log('AdaptiveLearning: sync failed: $e', name: 'AdaptiveLearning');
    }
  }

  /// Returns only observations that were applied (with their suggestions).
  List<LearningObservation> get appliedHistory =>
      _observations.where((o) => o.status == ObservationStatus.applied && o.suggestion != null).toList();

  // ─── Internos ────────────────────────────────────────────────────────────

  Future<DspTelemetrySnapshot?> _captureTelemetry(
      AmplificationBloc bloc) async {
    try {
      final m = await bloc.audioBridge.getDspStageMetrics();
      if (m == null) return null;

      final state = bloc.state;
      final currentGains = state is AmplificationActive
          ? List<double>.from(state.activeEqGains ?? List<double>.filled(12, 0.0))
          : List<double>.filled(12, 0.0);
      final currentNr =
          state is AmplificationActive ? state.activeNrLevel : 1;
      final currentVol =
          state is AmplificationActive ? state.volumeDb : 0.0;

      return DspTelemetrySnapshot(
        inputLevelDb: _dbl(m, 'inputLevel'),
        outputLevelDb: _dbl(m, 'outputLevel'),
        postNrLevelDb: _dbl(m, 'postNrLevel'),
        postEqLevelDb: _dbl(m, 'postEqLevel'),
        postWdrcLevelDb: _dbl(m, 'postWdrcLevel'),
        peakSample: _dbl(m, 'peakSample'),
        clipCount: _int(m, 'clipCount'),
        wdrcRegion: _int(m, 'wdrcRegion'),
        wdrcGainFactor: _dbl(m, 'wdrcGainFactor'),
        mpoLimitingFraction: _dbl(m, 'mpoLimitingFraction'),
        mpoLimitingSustained: m['mpoLimitingSustained'] as bool? ?? false,
        environmentClass: _int(m, 'environmentClass'),
        nrLevel: currentNr,
        eqGains: currentGains,
        volumeDb: currentVol,
      );
    } catch (e) {
      developer.log('AdaptiveLearning: _captureTelemetry error: $e',
          name: 'AdaptiveLearning');
      return null;
    }
  }

  /// Envía la observación a Hermes para análisis. No bloquea.
  Future<void> _sendToHermes(LearningObservation obs, {required AmplificationBloc bloc}) async {
    final idx = _observations.indexWhere((o) => o.id == obs.id);
    if (idx < 0) return;

    _observations[idx] = obs.copyWith(status: ObservationStatus.analyzing);
    _changeController.add(null);

    try {
      final uri = Uri.parse('${_config.hermesBaseUrl}/api/adaptive-learning/analyze');
      final body = jsonEncode({
        'observationId': obs.id,
        'userText': obs.userText,
        'telemetry': obs.telemetry.toJson(),
        'detectedScene': obs.detectedScene.index,
        'sceneName': obs.detectedScene.name,
        'timestamp': obs.timestamp.toIso8601String(),
        'deviceId': _deviceId,
      });

      final response = await http
          .post(uri,
              headers: {'Content-Type': 'application/json'}, body: body)
          .timeout(_config.requestTimeout);

      if (response.statusCode == 200) {
        final json = jsonDecode(response.body) as Map<String, dynamic>;
        final suggestion = DspAdjustmentSuggestion.fromJson(json);

        final newIdx = _observations.indexWhere((o) => o.id == obs.id);
        if (newIdx >= 0) {
          _observations[newIdx] = _observations[newIdx].copyWith(
            status: ObservationStatus.suggestionReady,
            suggestion: suggestion,
          );
          await _persist(_observations[newIdx]);
          _changeController.add(null);

          // Auto-apply si está activado.
          if (autoApply) {
            await applySuggestion(obs.id, bloc);
          }
        }
      } else {
        developer.log(
            'AdaptiveLearning: Hermes returned ${response.statusCode}',
            name: 'AdaptiveLearning');
        // Dejar como pending para retry manual.
        final newIdx = _observations.indexWhere((o) => o.id == obs.id);
        if (newIdx >= 0) {
          _observations[newIdx] =
              _observations[newIdx].copyWith(status: ObservationStatus.pending);
          _changeController.add(null);
        }
      }
    } catch (e) {
      developer.log('AdaptiveLearning: Hermes unreachable: $e',
          name: 'AdaptiveLearning');
      // Sin conexión — queda como pending offline.
      final newIdx = _observations.indexWhere((o) => o.id == obs.id);
      if (newIdx >= 0) {
        _observations[newIdx] =
            _observations[newIdx].copyWith(status: ObservationStatus.pending);
        _changeController.add(null);
      }
    }
  }

  /// Envía feedback a Hermes para que refine su modelo.
  Future<void> _sendFeedbackToHermes(LearningObservation obs) async {
    try {
      final uri =
          Uri.parse('${_config.hermesBaseUrl}/api/adaptive-learning/feedback');
      await http
          .post(uri,
              headers: {'Content-Type': 'application/json'},
              body: jsonEncode({
                'observationId': obs.id,
                'feedback': obs.feedback,
                'suggestion': obs.suggestion?.toJson(),
                'telemetry': obs.telemetry.toJson(),
                'sceneName': obs.detectedScene.name,
                'deviceId': _deviceId,
              }))
          .timeout(_config.requestTimeout);
    } catch (_) {
      // Feedback no es crítico — se pierde sin problema.
    }
  }

  Future<void> _persist(LearningObservation obs) async {
    try {
      final box = await _openBox();
      await box.put(obs.id.toString(), obs.toJson());
      await _trim(box);
    } catch (_) {}
  }

  Future<void> _trim(Box<dynamic> box) async {
    if (box.length <= _config.maxObservations) return;
    final keys = box.keys.toList();
    keys.sort();
    final excess = box.length - _config.maxObservations;
    for (var i = 0; i < excess; i++) {
      await box.delete(keys[i]);
    }
  }

  Future<Box<dynamic>> _openBox() async {
    if (Hive.isBoxOpen(_boxName)) return Hive.box(_boxName);
    return Hive.openBox(_boxName);
  }

  SceneClass _intToSceneClass(int raw) {
    if (raw < 0 || raw >= SceneClass.values.length) return SceneClass.unknown;
    return SceneClass.values[raw];
  }

  double _dbl(Map<String, dynamic> m, String k) {
    final v = m[k];
    if (v is num && v.isFinite) return v.toDouble();
    return 0.0;
  }

  int _int(Map<String, dynamic> m, String k) {
    final v = m[k];
    if (v is int) return v;
    if (v is num) return v.toInt();
    return 0;
  }
}
