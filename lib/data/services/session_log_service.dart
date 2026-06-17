// Servicio singleton del Registro de Sesión.
//
// El Registro de Sesión captura cambios del `AmplificationBloc` (preset,
// ambiente, MHL, volumen, etc.) durante un intervalo arbitrario decidido por
// el técnico. Para que la grabación no se interrumpa cuando el técnico sale
// de `SessionLogScreen` para hacer ajustes en otras pantallas, la lógica
// vive acá (singleton) — la pantalla es un mero visor que se suscribe al
// `onChange` y refleja el estado actual.
//
// El servicio mantiene una `StreamSubscription` activa al `bloc.stream` y
// la cancela cuando se llama `stop()` o `start()` la reabre. La pantalla
// SOLO arranca/detiene/copia/limpia y escucha `onChange` para refrescar.
//
// No graba audio. Solo eventos del bloc.

import 'dart:async';
import 'dart:developer' as developer;

import '../../domain/entities/audiogram.dart';
import '../../presentation/bloc/amplification_bloc.dart';
import '../../presentation/bloc/amplification_state.dart';

/// Singleton del servicio de log de sesión.
class SessionLogService {
  SessionLogService._();

  static final SessionLogService instance = SessionLogService._();

  // ─── Estado ──────────────────────────────────────────────────────────────

  bool _recording = false;
  DateTime? _startedAt;
  DateTime? _stoppedAt;

  StreamSubscription<AmplificationState>? _stateSub;
  AmplificationActive? _lastActive;

  Map<String, dynamic>? _initialSnapshot;
  Map<String, dynamic>? _finalSnapshot;
  final List<Map<String, dynamic>> _events = <Map<String, dynamic>>[];

  // Notificador de cambios para la UI.
  final StreamController<void> _changeController =
      StreamController<void>.broadcast();

  /// Stream que emite cada vez que cambia el estado interno (start, stop,
  /// nuevo evento, clear). La UI escucha esto para hacer rebuild.
  Stream<void> get onChange => _changeController.stream;

  // ─── Getters ─────────────────────────────────────────────────────────────

  bool get isRecording => _recording;
  DateTime? get startedAt => _startedAt;
  DateTime? get stoppedAt => _stoppedAt;
  List<Map<String, dynamic>> get events => List<Map<String, dynamic>>.unmodifiable(_events);
  Map<String, dynamic>? get initialSnapshot => _initialSnapshot;
  Map<String, dynamic>? get finalSnapshot => _finalSnapshot;

  /// Tiempo transcurrido desde [startedAt] hasta [stoppedAt] o hasta ahora
  /// si todavía está grabando. `Duration.zero` si nunca arrancó.
  Duration get elapsed {
    final start = _startedAt;
    if (start == null) return Duration.zero;
    final end = _stoppedAt ?? DateTime.now();
    return end.difference(start);
  }

  // ─── Acciones públicas ───────────────────────────────────────────────────

  /// Arranca el log con el [bloc] dado. Si ya estaba grabando, no hace nada.
  /// Resetea `events` y `finalSnapshot`, captura `initialSnapshot`.
  void start(AmplificationBloc bloc) {
    if (_recording) return;

    final state = bloc.state;
    final initial = state is AmplificationActive ? state : null;

    _recording = true;
    _startedAt = DateTime.now();
    _stoppedAt = null;
    _events.clear();
    _initialSnapshot = _buildSnapshot(bloc, initial, label: 'initial');
    _finalSnapshot = null;
    _lastActive = initial;

    // Suscripción al bloc.stream — vive aquí en el singleton, NO en la
    // pantalla, así sobrevive al pop de SessionLogScreen.
    _stateSub = bloc.stream.listen(_onStateChanged);

    _changeController.add(null);
  }

  /// Detiene el log. Si no estaba grabando, no hace nada.
  /// Captura `finalSnapshot` con el estado actual del [bloc].
  void stop(AmplificationBloc bloc) {
    if (!_recording) return;

    _stateSub?.cancel();
    _stateSub = null;

    _recording = false;
    _stoppedAt = DateTime.now();

    final state = bloc.state;
    final active = state is AmplificationActive ? state : null;
    _finalSnapshot = _buildSnapshot(bloc, active, label: 'final');

    _changeController.add(null);
  }

  /// Limpia eventos y snapshots. No actúa si está grabando.
  void clear() {
    if (_recording) return;
    _events.clear();
    _initialSnapshot = null;
    _finalSnapshot = null;
    _startedAt = null;
    _stoppedAt = null;
    _lastActive = null;
    _changeController.add(null);
  }

  /// JSON serializable del registro completo: snapshots + eventos.
  Map<String, dynamic> buildJson() {
    return {
      'schemaVersion': '1.0',
      'kind': 'session_log',
      'startedAt': _startedAt?.toIso8601String(),
      'stoppedAt': _stoppedAt?.toIso8601String(),
      'durationMs': _stoppedAt != null && _startedAt != null
          ? _stoppedAt!.difference(_startedAt!).inMilliseconds
          : null,
      'initialSnapshot': _initialSnapshot,
      'finalSnapshot': _finalSnapshot,
      'eventCount': _events.length,
      'events': _events,
    };
  }

  // ─── Internos ────────────────────────────────────────────────────────────

  void _onStateChanged(AmplificationState s) {
    if (!_recording) return;

    if (s is! AmplificationActive) {
      _pushEvent(type: 'state', data: {'kind': s.runtimeType.toString()});
      _lastActive = null;
      _changeController.add(null);
      return;
    }

    final prev = _lastActive;
    if (prev == null) {
      _pushEvent(type: 'state', data: {'kind': 'AmplificationActive'});
      _lastActive = s;
      _changeController.add(null);
      return;
    }

    bool emitted = false;
    void diff<T>(String name, T before, T after) {
      if (before != after) {
        _pushEvent(
          type: 'change',
          data: {
            'field': name,
            'from': _stringify(before),
            'to': _stringify(after),
          },
        );
        emitted = true;
      }
    }

    diff('activeProfile', prev.activeProfile, s.activeProfile);
    diff('activeEqPreset', prev.activeEqPreset, s.activeEqPreset);
    diff('mhlActive', prev.mhlActive, s.mhlActive);
    diff('musicModeActive', prev.musicModeActive, s.musicModeActive);
    diff('activeNrLevel', prev.activeNrLevel, s.activeNrLevel);
    diff('prescriberMode', prev.prescriberMode.name, s.prescriberMode.name);
    diff('prescriptionMode', prev.prescriptionMode.name, s.prescriptionMode.name);
    diff('headphonesConnected', prev.headphonesConnected, s.headphonesConnected);

    if ((prev.volumeDb - s.volumeDb).abs() >= 0.5) {
      _pushEvent(
        type: 'change',
        data: {
          'field': 'volumeDb',
          'from': prev.volumeDb.toStringAsFixed(1),
          'to': s.volumeDb.toStringAsFixed(1),
        },
      );
      emitted = true;
    }

    _lastActive = s;
    if (emitted) _changeController.add(null);
  }

  void _pushEvent({required String type, required Map<String, dynamic> data}) {
    final start = _startedAt;
    if (start == null) return;
    final ms = DateTime.now().difference(start).inMilliseconds;
    _events.add(<String, dynamic>{'tMs': ms, 'type': type, ...data});
  }

  String _stringify(Object? v) {
    if (v is double) return v.toStringAsFixed(2);
    return v?.toString() ?? 'null';
  }

  Map<String, dynamic> _buildSnapshot(
    AmplificationBloc bloc,
    AmplificationActive? active, {
    required String label,
  }) {
    try {
      final audiogram = bloc.currentAudiogram;
      final bundle = bloc.lastBundle;
      final settings = bloc.settingsRepository;

      return <String, dynamic>{
        'label': label,
        'iso': DateTime.now().toIso8601String(),
        'engineRunning': active != null,
        if (active != null) ...<String, dynamic>{
          'activeProfile': active.activeProfile,
          'activeEqPreset': active.activeEqPreset,
          'volumeDb': double.parse(active.volumeDb.toStringAsFixed(2)),
          'mhlActive': active.mhlActive,
          'musicModeActive': active.musicModeActive,
          'activeNrLevel': active.activeNrLevel,
          'prescriberMode': active.prescriberMode.name,
          'prescriptionMode': active.prescriptionMode.name,
          'headphonesConnected': active.headphonesConnected,
          'inputLevelDb': double.parse(active.inputLevelDb.toStringAsFixed(2)),
        },
        'smartEnabled': bloc.isSmartEnabled,
        'comfort': double.parse(settings.comfort.toStringAsFixed(2)),
        'nrLevel': settings.nrLevel,
        'dnnIntensity': double.parse(settings.dnnIntensity.toStringAsFixed(2)),
        if (audiogram != null) 'audiogramThresholds': _audiogramAsMap(audiogram),
        if (bundle != null) ...<String, dynamic>{
          'bundleEqGainsDb': bundle.gainsDb
              .map((v) => double.parse(v.toStringAsFixed(2)))
              .toList(),
          'bundleMpoMin': bundle.mpoProfileDbSpl.isEmpty
              ? null
              : bundle.mpoProfileDbSpl.reduce((a, b) => a < b ? a : b),
          'bundleWdrcAttackMs': bundle.wdrcAttackMs,
          'bundleWdrcReleaseMs': bundle.wdrcReleaseMs,
          'bundleExpansionKnee': bundle.expansionKneeDbSpl,
        },
      };
    } catch (e, st) {
      developer.log('SessionLog: snapshot falló: $e',
          name: 'SessionLog', error: e, stackTrace: st);
      return <String, dynamic>{
        'label': label,
        'iso': DateTime.now().toIso8601String(),
        'error': '$e',
      };
    }
  }

  Map<String, double> _audiogramAsMap(Audiogram a) {
    final map = <String, double>{};
    for (final f in Audiogram.standardFrequencies) {
      final v = a.thresholds[f];
      if (v != null) map['$f'] = v;
    }
    return map;
  }
}
