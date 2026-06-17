// Pantalla "Registro de sesión" — log libre de cambios DSP.
//
// A diferencia de la `DiagnosticoDspScreen` (audio 15 s + WAV/JSON), esta
// pantalla NO graba audio. Captura una línea de tiempo de eventos del
// `AmplificationBloc` mientras el técnico ajusta presets, ambientes,
// audiograma, MHL, volumen, etc. Pensada para reproducir comportamientos
// que no se manifiestan en una grabación corta y para pegar el log directo
// en chat con el orquestador.
//
// Flujo:
//   1. Tap "Iniciar"  → cronómetro creciente + suscripción al bloc.
//   2. Cada cambio en campos de interés → push event al timeline.
//   3. Tap "Detener"  → cierra suscripción y muestra resumen.
//   4. Tap "Copiar"   → JSON al portapapeles (estado inicial + eventos +
//      estado final).
//
// Los campos que se monitorean son los que el bloc emite en
// `AmplificationActive`:
//   - `activeProfile` (Silencioso / Conversación / Ruidoso)
//   - `activeEqPreset` (Normal, Moderate+, Alto Voz, ...)
//   - `volumeDb`
//   - `mhlActive`
//   - `musicModeActive`
//   - `activeNrLevel`
//   - `prescriberMode` / `prescriptionMode`
//   - `headphonesConnected`
//
// Más cambios (audiograma cargado, comfort, smart on/off) se capturan en el
// snapshot inicial/final via getters del bloc.

import 'dart:async';
import 'dart:convert';
import 'dart:developer' as developer;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../domain/entities/audiogram.dart';
import '../bloc/amplification_bloc.dart';
import '../bloc/amplification_state.dart';

// Paleta del técnico (réplica de DiagnosticoDspScreen).
const Color _kBg = Color(0xFF0a1628);
const Color _kSurface = Color(0xFF16213e);
const Color _kAccent = Color(0xFF0f3460);
const Color _kCyan = Color(0xFF4dd0e1);

class SessionLogScreen extends StatefulWidget {
  const SessionLogScreen({super.key});

  @override
  State<SessionLogScreen> createState() => _SessionLogScreenState();
}

class _SessionLogScreenState extends State<SessionLogScreen> {
  bool _recording = false;
  DateTime? _startedAt;
  DateTime? _stoppedAt;
  Timer? _tickTimer;
  Duration _elapsed = Duration.zero;

  StreamSubscription<AmplificationState>? _stateSub;
  AmplificationActive? _lastActive;

  Map<String, dynamic>? _initialSnapshot;
  Map<String, dynamic>? _finalSnapshot;

  final List<Map<String, dynamic>> _events = <Map<String, dynamic>>[];

  @override
  void dispose() {
    _stateSub?.cancel();
    _tickTimer?.cancel();
    super.dispose();
  }

  // ─── Acciones ────────────────────────────────────────────────────────────

  void _start() {
    final bloc = context.read<AmplificationBloc>();
    final state = bloc.state;
    final initial = state is AmplificationActive ? state : null;

    setState(() {
      _recording = true;
      _startedAt = DateTime.now();
      _stoppedAt = null;
      _elapsed = Duration.zero;
      _events.clear();
      _initialSnapshot = _buildSnapshot(bloc, initial, label: 'initial');
      _finalSnapshot = null;
      _lastActive = initial;
    });

    _tickTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted) return;
      setState(() {
        _elapsed = DateTime.now().difference(_startedAt!);
      });
    });

    _stateSub = bloc.stream.listen(_onStateChanged);
  }

  void _stop() {
    _tickTimer?.cancel();
    _tickTimer = null;
    _stateSub?.cancel();
    _stateSub = null;

    final bloc = context.read<AmplificationBloc>();
    final state = bloc.state;
    final active = state is AmplificationActive ? state : null;

    setState(() {
      _recording = false;
      _stoppedAt = DateTime.now();
      _finalSnapshot = _buildSnapshot(bloc, active, label: 'final');
    });
  }

  Future<void> _copy() async {
    final json = _buildJson();
    final text = const JsonEncoder.withIndent('  ').convert(json);
    try {
      await Clipboard.setData(ClipboardData(text: text));
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Registro copiado al portapapeles'),
          duration: Duration(seconds: 2),
        ),
      );
    } catch (e, st) {
      developer.log('SessionLog copy falló: $e',
          name: 'SessionLog', error: e, stackTrace: st);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Error al copiar: $e')),
      );
    }
  }

  void _clear() {
    setState(() {
      _events.clear();
      _initialSnapshot = null;
      _finalSnapshot = null;
      _startedAt = null;
      _stoppedAt = null;
      _elapsed = Duration.zero;
      _lastActive = null;
    });
  }

  // ─── Captura de eventos ──────────────────────────────────────────────────

  void _onStateChanged(AmplificationState s) {
    if (!_recording) return;
    if (s is! AmplificationActive) {
      _pushEvent(type: 'state', data: {'kind': s.runtimeType.toString()});
      _lastActive = null;
      return;
    }
    final prev = _lastActive;
    if (prev == null) {
      _pushEvent(type: 'state', data: {'kind': 'AmplificationActive'});
      _lastActive = s;
      return;
    }

    void diff<T>(String name, T before, T after) {
      if (before != after) {
        _pushEvent(
          type: 'change',
          data: {'field': name, 'from': _stringify(before), 'to': _stringify(after)},
        );
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

    // Volumen: solo loggeamos si cambia ≥ 0.5 dB para no llenar de ruido.
    if ((prev.volumeDb - s.volumeDb).abs() >= 0.5) {
      _pushEvent(
        type: 'change',
        data: {
          'field': 'volumeDb',
          'from': prev.volumeDb.toStringAsFixed(1),
          'to': s.volumeDb.toStringAsFixed(1),
        },
      );
    }

    _lastActive = s;
  }

  void _pushEvent({required String type, required Map<String, dynamic> data}) {
    final start = _startedAt;
    if (start == null) return;
    final ms = DateTime.now().difference(start).inMilliseconds;
    final entry = <String, dynamic>{'tMs': ms, 'type': type, ...data};
    setState(() {
      _events.add(entry);
    });
  }

  String _stringify(Object? v) {
    if (v is double) return v.toStringAsFixed(2);
    return v?.toString() ?? 'null';
  }

  // ─── Snapshots ───────────────────────────────────────────────────────────

  Map<String, dynamic> _buildSnapshot(
    AmplificationBloc bloc,
    AmplificationActive? active, {
    required String label,
  }) {
    final audiogram = bloc.currentAudiogram;
    final bundle = bloc.lastBundle;
    final settings = bloc.settingsRepository;

    return {
      'label': label,
      'iso': DateTime.now().toIso8601String(),
      'engineRunning': active != null,
      if (active != null) ...{
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
      if (bundle != null) ...{
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
  }

  Map<String, double> _audiogramAsMap(Audiogram a) {
    final map = <String, double>{};
    for (final f in Audiogram.standardFrequencies) {
      final v = a.thresholds[f];
      if (v != null) map['$f'] = v;
    }
    return map;
  }

  Map<String, dynamic> _buildJson() {
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

  // ─── UI ──────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: _kBg,
      appBar: AppBar(
        backgroundColor: _kAccent,
        title: const Text('Registro de sesión'),
        foregroundColor: Colors.white,
      ),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _buildHeader(),
              const SizedBox(height: 12),
              _buildButtons(),
              const SizedBox(height: 12),
              Expanded(child: _buildEventList()),
              const SizedBox(height: 8),
              _buildCopyButton(),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildHeader() {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: _kSurface,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(
            color: _recording ? Colors.redAccent : Colors.white24, width: 1),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Row(
            children: [
              Icon(
                _recording ? Icons.fiber_manual_record : Icons.timer_outlined,
                color: _recording ? Colors.redAccent : Colors.white54,
                size: 22,
              ),
              const SizedBox(width: 8),
              Text(
                _recording
                    ? 'Grabando'
                    : (_stoppedAt != null ? 'Detenido' : 'Listo'),
                style: TextStyle(
                  color: _recording ? Colors.redAccent : Colors.white,
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
          Text(
            _formatDuration(_elapsed),
            style: const TextStyle(
              color: _kCyan,
              fontSize: 18,
              fontWeight: FontWeight.w700,
              fontFeatures: [FontFeature.tabularFigures()],
            ),
          ),
          Text(
            '${_events.length} ev.',
            style: const TextStyle(color: Colors.white70, fontSize: 13),
          ),
        ],
      ),
    );
  }

  Widget _buildButtons() {
    return Row(
      children: [
        Expanded(
          child: ElevatedButton.icon(
            onPressed: _recording ? null : _start,
            icon: const Icon(Icons.play_arrow),
            label: const Text('Iniciar'),
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.green.shade700,
              foregroundColor: Colors.white,
              padding: const EdgeInsets.symmetric(vertical: 14),
            ),
          ),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: ElevatedButton.icon(
            onPressed: _recording ? _stop : null,
            icon: const Icon(Icons.stop),
            label: const Text('Detener'),
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.redAccent,
              foregroundColor: Colors.white,
              padding: const EdgeInsets.symmetric(vertical: 14),
            ),
          ),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: OutlinedButton.icon(
            onPressed: (_recording || _events.isEmpty) ? null : _clear,
            icon: const Icon(Icons.clear_all),
            label: const Text('Limpiar'),
            style: OutlinedButton.styleFrom(
              foregroundColor: Colors.orangeAccent,
              side: const BorderSide(color: Colors.orangeAccent),
              padding: const EdgeInsets.symmetric(vertical: 14),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildEventList() {
    if (_events.isEmpty) {
      return Container(
        decoration: BoxDecoration(
          color: _kSurface,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: Colors.white12),
        ),
        child: const Center(
          child: Padding(
            padding: EdgeInsets.all(20),
            child: Text(
              'Tap "Iniciar" y movete por la app: cambios de preset, ambiente, '
              'MHL, volumen, audiograma se loguean acá.',
              style: TextStyle(color: Colors.white60, fontSize: 13),
              textAlign: TextAlign.center,
            ),
          ),
        ),
      );
    }
    return Container(
      decoration: BoxDecoration(
        color: _kSurface,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: Colors.white12),
      ),
      child: ListView.separated(
        padding: const EdgeInsets.all(8),
        itemCount: _events.length,
        separatorBuilder: (_, __) =>
            const Divider(color: Colors.white10, height: 1),
        itemBuilder: (_, i) {
          final e = _events[i];
          final t = e['tMs'] as int? ?? 0;
          final tStr = _formatTms(t);
          if (e['type'] == 'change') {
            final field = e['field'];
            final from = e['from'];
            final to = e['to'];
            return Padding(
              padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 4),
              child: Row(
                children: [
                  SizedBox(
                    width: 70,
                    child: Text(tStr,
                        style: const TextStyle(
                            color: _kCyan,
                            fontSize: 12,
                            fontFeatures: [FontFeature.tabularFigures()])),
                  ),
                  Expanded(
                    child: Text(
                      '$field: $from → $to',
                      style: const TextStyle(color: Colors.white, fontSize: 13),
                    ),
                  ),
                ],
              ),
            );
          }
          return Padding(
            padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 4),
            child: Row(
              children: [
                SizedBox(
                  width: 70,
                  child: Text(tStr,
                      style: const TextStyle(
                          color: _kCyan,
                          fontSize: 12,
                          fontFeatures: [FontFeature.tabularFigures()])),
                ),
                Expanded(
                  child: Text(
                    '${e['type']} ${e['data'] ?? ''}',
                    style: const TextStyle(color: Colors.white70, fontSize: 13),
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }

  Widget _buildCopyButton() {
    final canCopy = !_recording && _initialSnapshot != null;
    return ElevatedButton.icon(
      onPressed: canCopy ? _copy : null,
      icon: const Icon(Icons.copy),
      label: const Text('Copiar registro'),
      style: ElevatedButton.styleFrom(
        backgroundColor: _kCyan,
        foregroundColor: _kBg,
        padding: const EdgeInsets.symmetric(vertical: 14),
        textStyle: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
      ),
    );
  }

  String _formatDuration(Duration d) {
    final h = d.inHours;
    final m = d.inMinutes.remainder(60);
    final s = d.inSeconds.remainder(60);
    if (h > 0) {
      return '${h.toString().padLeft(2, '0')}:'
          '${m.toString().padLeft(2, '0')}:'
          '${s.toString().padLeft(2, '0')}';
    }
    return '${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}';
  }

  String _formatTms(int ms) {
    final s = ms ~/ 1000;
    final mm = s ~/ 60;
    final ss = s % 60;
    return '${mm.toString().padLeft(2, '0')}:${ss.toString().padLeft(2, '0')}';
  }
}
