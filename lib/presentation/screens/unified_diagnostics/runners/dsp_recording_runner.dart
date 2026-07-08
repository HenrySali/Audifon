import 'test_runner_base.dart';

/// Diagnóstico DSP: grabación real de 15 s de audio dual-channel.
class DspRecordingRunner extends TestRunnerBase {
  final bool isMotorActive;

  DspRecordingRunner({
    required super.isCancelled,
    required this.isMotorActive,
  });

  @override
  Future<Map<String, dynamic>> run() async {
    if (!isMotorActive) {
      return {'status': 'Motor no activo', 'canRecord': false};
    }

    final now = DateTime.now();
    final baseName = 'diag_test_${now.year}${TestRunnerBase.pad2(now.month)}'
        '${TestRunnerBase.pad2(now.day)}_${TestRunnerBase.pad2(now.hour)}'
        '${TestRunnerBase.pad2(now.minute)}${TestRunnerBase.pad2(now.second)}';
    final wavFilename = '$baseName.wav';

    bool started = false;
    try {
      started = await TestRunnerBase.channel.invokeMethod<bool>(
            'startDiagnosticRecording',
            {'filePath': wavFilename},
          ) ??
          false;
    } catch (_) {
      started = false;
    }

    if (!started) {
      return {'status': 'No se pudo iniciar la grabación', 'canRecord': false};
    }

    const int maxPolls = 18;
    int lastProgressMs = 0;
    for (int i = 0; i < maxPolls; i++) {
      if (isCancelled()) break;
      await Future.delayed(const Duration(seconds: 1));
      try {
        final progress = await TestRunnerBase.channel
                .invokeMethod<int>('getDiagnosticRecordingProgress') ??
            -1;
        if (progress < 0) {
          return {
            'status': 'Error durante grabación (progress = -1)',
            'completada': false,
            'tiempoAlcanzado': '${lastProgressMs ~/ 1000} s',
          };
        }
        lastProgressMs = progress;
        if (progress >= 15000) break;
      } catch (_) {
        break;
      }
    }

    int stopResult = -1;
    try {
      stopResult = await TestRunnerBase.channel
              .invokeMethod<int>('stopDiagnosticRecording') ??
          -1;
    } catch (_) {
      stopResult = -1;
    }

    return {
      'completada': stopResult == 0,
      'duración': '${lastProgressMs ~/ 1000} s',
      'archivo': wavFilename,
      'formato': 'WAV dual-channel (pre/post DSP)',
      'stopCode': stopResult,
    };
  }
}
