import 'test_runner_base.dart';

/// MPO Limiter: polling 5 Hz durante 5 s (25 muestras).
class MpoRunner extends TestRunnerBase {
  MpoRunner({required super.isCancelled});

  @override
  Future<Map<String, dynamic>> run() async {
    const int durationMs = 5000;
    const int intervalMs = 200;
    const int expected = durationMs ~/ intervalMs;

    int limitingCount = 0;
    int sustainedCount = 0;
    int totalClips = 0;
    final List<double> peaks = [];
    final List<double> fractions = [];
    int samples = 0;

    for (int i = 0; i < expected; i++) {
      if (isCancelled()) break;
      try {
        final m = await TestRunnerBase.channel
            .invokeMethod<Map>('getDspStageMetrics');
        if (m != null) {
          final data = Map<String, dynamic>.from(m);
          final frac = data['mpoLimitingFraction'];
          final sust = data['mpoLimitingSustained'];
          final peak = data['peakSample'];
          final clips = data['clipCount'];

          if (frac is num) {
            fractions.add(frac.toDouble());
            if (frac > 0.0) limitingCount++;
          }
          if (sust == true) sustainedCount++;
          if (peak is num) peaks.add(peak.toDouble());
          if (clips is int) totalClips += clips;
          samples++;
        }
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
      'limitando%': '${(limitingCount * 100 / samples).toStringAsFixed(0)}%',
      'sostenido%': '${(sustainedCount * 100 / samples).toStringAsFixed(0)}%',
      'fracciónPromedio': TestRunnerBase.avg(fractions).toStringAsFixed(4),
      'peakMáximo': TestRunnerBase.max(peaks).toStringAsFixed(4),
      'clipsAcumulados': totalClips,
    };
  }
}
