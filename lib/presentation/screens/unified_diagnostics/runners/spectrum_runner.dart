import '../../../../data/bridges/spectrum_bridge.dart';
import 'test_runner_base.dart';

/// Spectrum Analyzer: activa FFT, polea 10 Hz durante 5 s, reporta stats.
class SpectrumRunner extends TestRunnerBase {
  final SpectrumBridge spectrumBridge;

  SpectrumRunner({
    required super.isCancelled,
    required this.spectrumBridge,
  });

  @override
  Future<Map<String, dynamic>> run() async {
    spectrumBridge.startAnalysis();
    await Future.delayed(const Duration(milliseconds: 200));

    const int durationMs = 5000;
    const int intervalMs = 100;
    const int expectedSamples = durationMs ~/ intervalMs;

    final List<double> inputLevels = [];
    final List<double> outputLevels = [];
    int nullCount = 0;

    for (int i = 0; i < expectedSamples; i++) {
      if (isCancelled()) break;
      final snap = await spectrumBridge.getCurrentSpectrum();
      if (snap != null) {
        inputLevels.add(snap.inputLevelDb);
        outputLevels.add(snap.outputLevelDb);
      } else {
        nullCount++;
      }
      if (i < expectedSamples - 1) {
        await Future.delayed(const Duration(milliseconds: intervalMs));
      }
    }

    spectrumBridge.stopAnalysis();

    if (inputLevels.isEmpty) {
      return {'available': false, 'status': 'Sin datos de espectro'};
    }

    return {
      'available': true,
      'duración': '${durationMs ~/ 1000} s',
      'muestras': inputLevels.length,
      'inputDb (min/avg/max)':
          '${TestRunnerBase.min(inputLevels).toStringAsFixed(1)} / ${TestRunnerBase.avg(inputLevels).toStringAsFixed(1)} / ${TestRunnerBase.max(inputLevels).toStringAsFixed(1)}',
      'outputDb (min/avg/max)':
          '${TestRunnerBase.min(outputLevels).toStringAsFixed(1)} / ${TestRunnerBase.avg(outputLevels).toStringAsFixed(1)} / ${TestRunnerBase.max(outputLevels).toStringAsFixed(1)}',
      'snapshotsNulos': nullCount,
    };
  }
}
