import 'test_runner_base.dart';

/// Comparativa A/B: graba 5 s en cada modo (Bypass, DualDNN, MVDR).
///
/// Devuelve 'wavFullPaths' (List<String>) para que el orquestador los
/// registre en el AnalyzerInboxService.
class AbComparativeRunner extends TestRunnerBase {
  final bool isMotorActive;

  AbComparativeRunner({
    required super.isCancelled,
    required this.isMotorActive,
  });

  @override
  Future<Map<String, dynamic>> run() async {
    if (!isMotorActive) {
      return {'status': 'Motor no activo', 'canRecord': false};
    }

    final now = DateTime.now();
    final ts = '${now.year}${TestRunnerBase.pad2(now.month)}'
        '${TestRunnerBase.pad2(now.day)}_${TestRunnerBase.pad2(now.hour)}'
        '${TestRunnerBase.pad2(now.minute)}'
        '${TestRunnerBase.pad2(now.second)}';

    final modes = [
      {'name': 'Bypass', 'mode': 0, 'file': 'ab_bypass_$ts.wav'},
      {'name': 'DualDNN', 'mode': 1, 'file': 'ab_dualdnn_$ts.wav'},
      {'name': 'MVDR', 'mode': 2, 'file': 'ab_mvdr_$ts.wav'},
    ];

    final originalMode = await TestRunnerBase.channel
            .invokeMethod<int>('getEnhancementEngineMode') ??
        0;

    final results = <String, String>{};
    final wavFullPaths = <String>[];
    int successCount = 0;

    for (final m in modes) {
      if (isCancelled()) break;
      final modeName = m['name'] as String;
      final modeInt = m['mode'] as int;
      final fileName = m['file'] as String;

      try {
        await TestRunnerBase.channel
            .invokeMethod<void>('setEnhancementEngineMode', {'mode': modeInt});
      } catch (_) {
        results[modeName] = 'Error al cambiar modo';
        continue;
      }

      await Future.delayed(const Duration(milliseconds: 500));

      // Kotlin devuelve fullPath real o null.
      final fullPath = await TestRunnerBase.startRecording(fileName);
      if (fullPath == null) {
        results[modeName] = 'Error al iniciar grabación';
        continue;
      }

      for (int i = 0; i < 6; i++) {
        if (isCancelled()) break;
        await Future.delayed(const Duration(seconds: 1));
        try {
          final progress = await TestRunnerBase.channel
                  .invokeMethod<int>('getDiagnosticRecordingProgress') ??
              -1;
          if (progress < 0) break;
          if (progress >= 5000) break;
        } catch (_) {
          break;
        }
      }

      int stopResult = -1;
      try {
        // Usar stopKeep (conserva WAV parcial) en vez de stop (borra <15s).
        stopResult = await TestRunnerBase.channel
                .invokeMethod<int>('stopDiagnosticRecordingKeep') ??
            -1;
      } catch (_) {
        stopResult = -1;
      }

      if (stopResult == 0) {
        results[modeName] = fileName;
        wavFullPaths.add(fullPath);
        successCount++;
      } else {
        results[modeName] = 'Stop code: $stopResult';
      }

      await Future.delayed(const Duration(milliseconds: 300));
    }

    try {
      await TestRunnerBase.channel.invokeMethod<void>(
          'setEnhancementEngineMode', {'mode': originalMode});
    } catch (_) {}

    return {
      'completada': successCount == 3,
      'archivosGrabados': successCount,
      'duración': '5 s por modo (15 s total)',
      ...results,
      'modoRestaurado': originalMode,
      // Clave especial: el orquestador registra estos en el inbox.
      'wavFullPaths': wavFullPaths,
    };
  }
}
