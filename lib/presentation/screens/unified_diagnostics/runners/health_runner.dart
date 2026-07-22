import 'test_runner_base.dart';

/// Salud del Sistema: polling 5 Hz durante 5 s (25 muestras).
class HealthRunner extends TestRunnerBase {
  HealthRunner({required super.isCancelled});

  @override
  Future<Map<String, dynamic>> run() async {
    const int durationMs = 5000;
    const int intervalMs = 200;
    const int expected = durationMs ~/ intervalMs;

    int? underrunsStart;
    int? underrunsEnd;
    int healthyCount = 0;
    int samples = 0;

    for (int i = 0; i < expected; i++) {
      if (isCancelled()) break;
      try {
        final m = await TestRunnerBase.channel
            .invokeMethod<Map>('getLatencyMetrics');
        if (m != null) {
          final data = Map<String, dynamic>.from(m);
          final underruns = data['callbackUnderruns'];
          final healthy = data['timestampsHealthy'];
          if (underruns is int) {
            underrunsStart ??= underruns;
            underrunsEnd = underruns;
          }
          if (healthy == true) healthyCount++;
          samples++;
        }
      } catch (_) {}
      if (i < expected - 1) {
        await Future.delayed(const Duration(milliseconds: intervalMs));
      }
    }

    if (samples == 0) return {'available': false};

    final newUnderruns = (underrunsEnd ?? 0) - (underrunsStart ?? 0);

    return {
      'available': true,
      'duración': '${durationMs ~/ 1000} s',
      'muestras': samples,
      'underrunsInicio': underrunsStart ?? 0,
      'underrunsFin': underrunsEnd ?? 0,
      'underrunsNuevos': newUnderruns,
      'creciendoActivamente': newUnderruns > 0,
      'timestampsHealthy%':
          '${(healthyCount * 100 / samples).toStringAsFixed(0)}%',
    };
  }
}
