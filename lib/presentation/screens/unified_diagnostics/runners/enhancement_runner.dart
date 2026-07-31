import 'test_runner_base.dart';

/// Motor de Realce: polling 5 Hz durante 5 s (25 muestras).
class EnhancementRunner extends TestRunnerBase {
  EnhancementRunner({required super.isCancelled});

  @override
  Future<Map<String, dynamic>> run() async {
    const int durationMs = 5000;
    const int intervalMs = 200;
    const int expected = durationMs ~/ intervalMs;

    final List<int> modes = [];
    int bfActiveCount = 0;
    int dnnActiveCount = 0;
    int samples = 0;

    for (int i = 0; i < expected; i++) {
      if (isCancelled()) break;
      try {
        final mode = await TestRunnerBase.channel
                .invokeMethod<int>('getEnhancementEngineMode') ??
            0;
        final bf = await TestRunnerBase.channel
                .invokeMethod<bool>('getBeamformingActive') ??
            false;
        final dnn = await TestRunnerBase.channel
                .invokeMethod<bool>('getDnnIsActive') ??
            false;
        modes.add(mode);
        if (bf) bfActiveCount++;
        if (dnn) dnnActiveCount++;
        samples++;
      } catch (_) {}
      if (i < expected - 1) {
        await Future.delayed(const Duration(milliseconds: intervalMs));
      }
    }

    if (samples == 0) return {'available': false};

    final modeNames = ['Bypass', 'Dual-DNN (GTCRN)', 'MVDR Beamformer'];
    final modeCount = <int, int>{};
    for (final m in modes) {
      modeCount[m] = (modeCount[m] ?? 0) + 1;
    }
    final dominantMode = modeCount.entries
        .reduce((a, b) => a.value >= b.value ? a : b)
        .key;
    final modeChanges = TestRunnerBase.countChanges(modes);

    return {
      'available': true,
      'duración': '${durationMs ~/ 1000} s',
      'muestras': samples,
      'modoDominante': modeNames[dominantMode.clamp(0, 2)],
      'cambiosDeModo': modeChanges,
      'mvdrActivo%': '${(bfActiveCount * 100 / samples).toStringAsFixed(0)}%',
      'dnnActivo%': '${(dnnActiveCount * 100 / samples).toStringAsFixed(0)}%',
      'estable': modeChanges == 0,
    };
  }
}
