import 'test_runner_base.dart';

/// DNN Denoiser: polling 5 Hz durante 5 s (25 muestras).
class DnnRunner extends TestRunnerBase {
  DnnRunner({required super.isCancelled});

  @override
  Future<Map<String, dynamic>> run() async {
    const int durationMs = 5000;
    const int intervalMs = 200;
    const int expected = durationMs ~/ intervalMs;

    int activeCount = 0;
    final List<double> inferences = [];
    int samples = 0;

    for (int i = 0; i < expected; i++) {
      if (isCancelled()) break;
      try {
        final active = await TestRunnerBase.channel
                .invokeMethod<bool>('getDnnIsActive') ??
            false;
        final lat = await TestRunnerBase.channel
            .invokeMethod<Map>('getLatencyMetrics');
        if (active) activeCount++;
        if (lat != null) {
          final data = Map<String, dynamic>.from(lat);
          final inf = data['dnnInferenceMs'];
          if (inf is num && inf >= 0) inferences.add(inf.toDouble());
        }
        samples++;
      } catch (_) {}
      if (i < expected - 1) {
        await Future.delayed(const Duration(milliseconds: intervalMs));
      }
    }

    if (samples == 0) return {'available': false};

    return {
      'available': true,
      'duración': '${durationMs ~/ 1000} s',
      'muestras': samples,
      'activo%': '${(activeCount * 100 / samples).toStringAsFixed(0)}%',
      'inferencia (min/avg/max)': inferences.isEmpty
          ? 'N/A (DNN inactiva)'
          : '${TestRunnerBase.min(inferences).toStringAsFixed(2)} / ${TestRunnerBase.avg(inferences).toStringAsFixed(2)} / ${TestRunnerBase.max(inferences).toStringAsFixed(2)} ms',
      'estable': inferences.isEmpty ||
          (TestRunnerBase.max(inferences) - TestRunnerBase.min(inferences)) <
              2.0,
    };
  }
}
