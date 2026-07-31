import 'test_runner_base.dart';

/// Latencia: polling 5 Hz durante 5 s (25 muestras).
class LatencyRunner extends TestRunnerBase {
  LatencyRunner({required super.isCancelled});

  @override
  Future<Map<String, dynamic>> run() async {
    const int durationMs = 5000;
    const int intervalMs = 200;
    const int expected = durationMs ~/ intervalMs;

    final List<double> dspAvgs = [];
    final List<double> dspMaxes = [];
    final List<double> dnnInferences = [];
    int? underrunsStart;
    int? underrunsEnd;
    int samples = 0;

    for (int i = 0; i < expected; i++) {
      if (isCancelled()) break;
      try {
        final m =
            await TestRunnerBase.channel.invokeMethod<Map>('getLatencyMetrics');
        if (m != null) {
          final data = Map<String, dynamic>.from(m);
          final dspAvg = data['dspProcessingMsAvg'];
          final dspMax = data['dspProcessingMsMax'];
          final dnnInf = data['dnnInferenceMs'];
          final underruns = data['callbackUnderruns'];

          if (dspAvg is num) dspAvgs.add(dspAvg.toDouble());
          if (dspMax is num) dspMaxes.add(dspMax.toDouble());
          if (dnnInf is num && dnnInf >= 0) {
            dnnInferences.add(dnnInf.toDouble());
          }
          if (underruns is int) {
            underrunsStart ??= underruns;
            underrunsEnd = underruns;
          }
          samples++;
        }
      } catch (_) {}
      if (i < expected - 1) {
        await Future.delayed(const Duration(milliseconds: intervalMs));
      }
    }

    if (samples == 0) return {'available': false, 'status': 'Sin métricas'};

    return {
      'available': true,
      'duración': '${durationMs ~/ 1000} s',
      'muestras': samples,
      'dspProcessing (min/avg/max)':
          '${TestRunnerBase.min(dspAvgs).toStringAsFixed(2)} / ${TestRunnerBase.avg(dspAvgs).toStringAsFixed(2)} / ${TestRunnerBase.max(dspAvgs).toStringAsFixed(2)} ms',
      'dspPeakMax': '${TestRunnerBase.max(dspMaxes).toStringAsFixed(2)} ms',
      'dnnInference (min/avg/max)': dnnInferences.isEmpty
          ? 'N/A'
          : '${TestRunnerBase.min(dnnInferences).toStringAsFixed(2)} / ${TestRunnerBase.avg(dnnInferences).toStringAsFixed(2)} / ${TestRunnerBase.max(dnnInferences).toStringAsFixed(2)} ms',
      'underrunsInicio': underrunsStart ?? 0,
      'underrunsFin': underrunsEnd ?? 0,
      'underrunsNuevos': (underrunsEnd ?? 0) - (underrunsStart ?? 0),
    };
  }
}
