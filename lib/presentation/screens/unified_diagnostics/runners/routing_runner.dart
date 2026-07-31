import 'test_runner_base.dart';

/// Audio Routing: snapshot único de la configuración de audio.
class RoutingRunner extends TestRunnerBase {
  RoutingRunner({required super.isCancelled});

  @override
  Future<Map<String, dynamic>> run() async {
    final m = await TestRunnerBase.channel
        .invokeMethod<Map>('getLatencyMetrics');
    if (m == null) return {'available': false};
    final data = Map<String, dynamic>.from(m);
    final apis = ['Unspecified', 'AAudio', 'OpenSL ES'];
    final sharing = ['Exclusive', 'Shared'];
    final perf = ['None', 'PowerSaving', 'LowLatency'];
    return {
      'available': true,
      'sampleRate': data['sampleRate'],
      'inputApi': apis[(data['inputAudioApi'] as int? ?? 0).clamp(0, 2)],
      'outputApi': apis[(data['outputAudioApi'] as int? ?? 0).clamp(0, 2)],
      'inputSharing':
          sharing[(data['inputSharingMode'] as int? ?? 0).clamp(0, 1)],
      'outputSharing':
          sharing[(data['outputSharingMode'] as int? ?? 0).clamp(0, 1)],
      'outputPerformance':
          perf[(data['outputPerformanceMode'] as int? ?? 0).clamp(0, 2)],
      'inputBurst': data['inputFramesPerBurst'],
      'outputBurst': data['outputFramesPerBurst'],
      'outputBuffer': data['outputBufferSizeFrames'],
    };
  }
}
