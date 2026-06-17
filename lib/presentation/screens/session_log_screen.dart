// Pantalla "Registro de sesión" — visor del [SessionLogService].
//
// Toda la lógica de captura vive en `SessionLogService` (singleton). Esta
// pantalla solo es un visor: arranca/detiene/copia/limpia el servicio y
// se subscribe a `onChange` para refrescarse. Si el técnico sale de esta
// pantalla mientras está grabando, la suscripción al `AmplificationBloc`
// vive en el servicio y NO se cancela — el log sigue corriendo en
// segundo plano hasta que el técnico vuelva y toque "Detener".

import 'dart:async';
import 'dart:convert';
import 'dart:developer' as developer;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../data/services/session_log_service.dart';
import '../bloc/amplification_bloc.dart';

// Paleta del técnico.
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
  StreamSubscription<void>? _changeSub;
  Timer? _tickTimer;

  SessionLogService get _svc => SessionLogService.instance;

  @override
  void initState() {
    super.initState();
    // Refresh cuando el servicio emite cambios (start/stop/clear/nuevo evento).
    _changeSub = _svc.onChange.listen((_) {
      if (mounted) setState(() {});
    });
    // Tick 1 Hz para refrescar el cronómetro mientras está grabando.
    _tickTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted && _svc.isRecording) setState(() {});
    });
  }

  @override
  void dispose() {
    _changeSub?.cancel();
    _tickTimer?.cancel();
    // Importante: NO se llama a `_svc.stop()` acá. Si el técnico está
    // grabando y sale a hacer ajustes, el servicio sigue corriendo. La
    // pantalla solo es un visor.
    super.dispose();
  }

  // ─── Acciones ────────────────────────────────────────────────────────────

  void _onStart() {
    final bloc = context.read<AmplificationBloc>();
    _svc.start(bloc);
  }

  void _onStop() {
    final bloc = context.read<AmplificationBloc>();
    _svc.stop(bloc);
  }

  void _onClear() {
    _svc.clear();
  }

  Future<void> _onCopy() async {
    final json = _svc.buildJson();
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

  // ─── UI ──────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final recording = _svc.isRecording;
    final events = _svc.events;
    final hasContent = _svc.initialSnapshot != null;

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
              _buildHeader(recording, events.length),
              const SizedBox(height: 8),
              _buildHint(recording),
              const SizedBox(height: 12),
              _buildButtons(recording, events.length, hasContent),
              const SizedBox(height: 12),
              Expanded(child: _buildEventList(events)),
              const SizedBox(height: 8),
              _buildCopyButton(recording, hasContent),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildHeader(bool recording, int eventCount) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: _kSurface,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(
            color: recording ? Colors.redAccent : Colors.white24, width: 1),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Row(
            children: [
              Icon(
                recording ? Icons.fiber_manual_record : Icons.timer_outlined,
                color: recording ? Colors.redAccent : Colors.white54,
                size: 22,
              ),
              const SizedBox(width: 8),
              Text(
                recording
                    ? 'Grabando'
                    : (_svc.stoppedAt != null ? 'Detenido' : 'Listo'),
                style: TextStyle(
                  color: recording ? Colors.redAccent : Colors.white,
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
          Text(
            _formatDuration(_svc.elapsed),
            style: const TextStyle(
              color: _kCyan,
              fontSize: 18,
              fontWeight: FontWeight.w700,
              fontFeatures: [FontFeature.tabularFigures()],
            ),
          ),
          Text(
            '$eventCount ev.',
            style: const TextStyle(color: Colors.white70, fontSize: 13),
          ),
        ],
      ),
    );
  }

  Widget _buildHint(bool recording) {
    return Text(
      recording
          ? 'Podés salir de esta pantalla y hacer los ajustes — el log sigue grabando.'
          : 'Tap "Iniciar" y movete por la app: cambios de preset, ambiente, MHL, '
              'volumen, audiograma se loguean acá.',
      style: const TextStyle(color: Colors.white54, fontSize: 12),
      textAlign: TextAlign.center,
    );
  }

  Widget _buildButtons(bool recording, int eventCount, bool hasContent) {
    return Row(
      children: [
        Expanded(
          child: ElevatedButton.icon(
            onPressed: recording ? null : _onStart,
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
            onPressed: recording ? _onStop : null,
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
            onPressed: (recording || !hasContent) ? null : _onClear,
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

  Widget _buildEventList(List<Map<String, dynamic>> events) {
    if (events.isEmpty) {
      return Container(
        decoration: BoxDecoration(
          color: _kSurface,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: Colors.white12),
        ),
        child: Center(
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: Text(
              _svc.isRecording
                  ? 'Grabando... esperando cambios.\nPodés salir de esta pantalla.'
                  : 'Sin eventos. Tap "Iniciar" para empezar.',
              style: const TextStyle(color: Colors.white60, fontSize: 13),
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
        itemCount: events.length,
        separatorBuilder: (_, __) =>
            const Divider(color: Colors.white10, height: 1),
        itemBuilder: (_, i) {
          final e = events[i];
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
                    '${e['type']} ${e.containsKey('kind') ? e['kind'] : ''}',
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

  Widget _buildCopyButton(bool recording, bool hasContent) {
    final canCopy = !recording && hasContent;
    return ElevatedButton.icon(
      onPressed: canCopy ? _onCopy : null,
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
