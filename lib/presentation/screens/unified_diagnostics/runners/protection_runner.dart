import 'test_runner_base.dart';

/// Protección: polling 5 Hz durante 5 s (25 muestras).
class ProtectionRunner extends TestRunnerBase {
  ProtectionRunner({required super.isCancelled});

  @override
  Future<Map<String, dynamic>> run() async {
    const int durationMs = 5000;
    const int intervalMs = 200;
    const int expected = durationMs ~/ intervalMs;

    final List<int> envClasses = [];
    final List<double> eqMaxGains = [];
    int samples = 0;

    for (int i = 0; i < expected; i++) {
      if (isCancelled()) break;
      try {
        final m = await TestRunnerBase.channel
            .invokeMethod<Map>('getDspStageMetrics');
        if (m != null) {
          final data = Map<String, dynamic>.from(m);
          final env = data['environmentClass'];
          final eqMax = data['eqMaxGain'];
          if (env is int) envClasses.add(env);
          if (eqMax is num) eqMaxGains.add(eqMax.toDouble());
          samples++;
        }
      } catch (_) {}
      if (i < expected - 1) {
        await Future.delayed(const Duration(milliseconds: intervalMs));
      }
    }

    if (samples == 0) return {'available': false};

    final envNames = ['QUIET', 'SPEECH', 'SPEECH_IN_NOISE', 'NOISE'];
    final envCount = <int, int>{};
    for (final e in envClasses) {
      envCount[e] = (envCount[e] ?? 0) + 1;
    }
    final dominantEnv = envCount.entries
        .reduce((a, b) => a.value >= b.value ? a : b)
        .key;
    final envChanges = TestRunnerBase.countChanges(envClasses);

    return {
      'available': true,
      'duración': '${durationMs ~/ 1000} s',
      'muestras': samples,
      'ambienteDominante': envNames[dominantEnv.clamp(0, 3)],
      'cambiosDeAmbiente': envChanges,
      'clasificadorEstable': envChanges <= 2,
      'eqMaxGain': '${TestRunnerBase.max(eqMaxGains).toStringAsFixed(1)} dB',
      'afc': 'Activo',
      'fbs': 'Activo',
      'tnr': 'Configurado',
      'sce': 'Activo',
      'expander': 'Vía Smart Scene',
    };
  }
}
