import '../../../../data/services/session_log_service.dart';
import '../../../bloc/amplification_bloc.dart';
import 'test_runner_base.dart';

/// Registro de Sesión: captura eventos durante 10 s.
class SessionLogRunner extends TestRunnerBase {
  final AmplificationBloc? bloc;
  final SessionLogService sessionSvc;

  SessionLogRunner({
    required super.isCancelled,
    required this.bloc,
    required this.sessionSvc,
  });

  @override
  Future<Map<String, dynamic>> run() async {
    if (bloc == null) return {'status': 'Bloc no disponible'};

    if (sessionSvc.isRecording) {
      return {
        'status': 'Ya estaba grabando',
        'isRecording': true,
        'eventCount': sessionSvc.events.length,
        'elapsed': sessionSvc.elapsed.inSeconds,
      };
    }

    sessionSvc.start(bloc!);

    const int durationSec = 10;
    for (int i = 0; i < durationSec; i++) {
      if (isCancelled()) break;
      await Future.delayed(const Duration(seconds: 1));
    }

    sessionSvc.stop(bloc!);

    final events = sessionSvc.events;
    return {
      'completado': true,
      'duración': '$durationSec s',
      'eventCount': events.length,
      'hasInitialSnapshot': sessionSvc.initialSnapshot != null,
      'hasFinalSnapshot': sessionSvc.finalSnapshot != null,
      'tiposDeEvento': _countEventTypes(events),
    };
  }

  String _countEventTypes(List<Map<String, dynamic>> events) {
    final types = <String, int>{};
    for (final e in events) {
      final kind = (e['kind'] as String?) ?? 'unknown';
      types[kind] = (types[kind] ?? 0) + 1;
    }
    if (types.isEmpty) return 'ninguno';
    return types.entries.map((e) => '${e.key}: ${e.value}').join(', ');
  }
}
