import 'test_runner_base.dart';

/// WDRC: polling 5 Hz durante 5 s (25 muestras).
class WdrcRunner extends TestRunnerBase {
  WdrcRunner({required super.isCancelled});

  @override
  Future<Map<String, dynamic>> run() async {
    const int durationMs = 5000;
    const int intervalMs = 200;
    const int expected = durationMs ~/ intervalMs;

    final List<int> regions = [];
    final List<double> gains = [];
    final List<double> postWdrcLevels = [];
    int samples = 0;

    for (int i = 0; i < expected; i++) {
      if (isCancelled()) break;
      try {
        final m = await TestRunnerBase.channel
            .invokeMethod<Map>('getDspStageMetrics');
        if (m != null) {
          final data = Map<String, dynamic>.from(m);
          final regionRaw = data['wdrcRegion'];
          final gain = data['wdrcGainFactor'];
          final postWdrc = data['postWdrcLevel'];
          // Kotlin devuelve String ("expansion"/"linear"/"compression"),
          // no int. Mapeamos para compatibilidad.
          final region = _parseRegion(regionRaw);
          if (region != null) regions.add(region);
          if (gain is num) gains.add(gain.toDouble());
          if (postWdrc is num) postWdrcLevels.add(postWdrc.toDouble());
          samples++;
        }
      } catch (_) {}
      if (i < expected - 1) {
        await Future.delayed(const Duration(milliseconds: intervalMs));
      }
    }

    if (samples == 0) return {'available': false};

    final regionNames = ['Expansión', 'Lineal', 'Compresión'];
    final regionCount = <int, int>{};
    for (final r in regions) {
      regionCount[r] = (regionCount[r] ?? 0) + 1;
    }
    final regionDist = regionCount.entries
        .map((e) =>
            '${regionNames[e.key.clamp(0, 2)]}: ${(e.value * 100 / samples).toStringAsFixed(0)}%')
        .join(', ');

    return {
      'available': true,
      'duración': '${durationMs ~/ 1000} s',
      'muestras': samples,
      'distribuciónRegiones': regionDist,
      'cambiosDeRegión': TestRunnerBase.countChanges(regions),
      'gainFactor (min/avg/max)':
          '${TestRunnerBase.min(gains).toStringAsFixed(3)} / ${TestRunnerBase.avg(gains).toStringAsFixed(3)} / ${TestRunnerBase.max(gains).toStringAsFixed(3)}',
      'postWdrc (min/avg/max)':
          '${TestRunnerBase.min(postWdrcLevels).toStringAsFixed(1)} / ${TestRunnerBase.avg(postWdrcLevels).toStringAsFixed(1)} / ${TestRunnerBase.max(postWdrcLevels).toStringAsFixed(1)} dB',
    };
  }

  /// Parsea wdrcRegion que puede venir como int O como String de Kotlin.
  static int? _parseRegion(dynamic raw) {
    if (raw is int) return raw;
    if (raw is String) {
      switch (raw) {
        case 'expansion':
          return 0;
        case 'linear':
          return 1;
        case 'compression':
          return 2;
      }
    }
    return null;
  }
}
