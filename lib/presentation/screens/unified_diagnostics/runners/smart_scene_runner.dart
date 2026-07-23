import 'dart:typed_data';

import '../../../../scene/scene_snapshot.dart';
import 'test_runner_base.dart';

/// Smart Scene: polling 10 Hz durante 5 s (50 snapshots).
class SmartSceneRunner extends TestRunnerBase {
  SmartSceneRunner({required super.isCancelled});

  @override
  Future<Map<String, dynamic>> run() async {
    final check =
        await TestRunnerBase.channel.invokeMethod<Uint8List>('getSceneSnapshot');
    if (check == null || check.isEmpty) {
      return {'status': 'Motor no activo', 'available': false};
    }

    const int durationMs = 5000;
    const int intervalMs = 100;
    const int expectedSamples = durationMs ~/ intervalMs;

    final List<double> inputLevels = [];
    final List<double> snrValues = [];
    final List<double> vadScores = [];
    final List<double> tilts = [];
    final List<int> sceneClasses = [];
    int parseErrors = 0;

    for (int i = 0; i < expectedSamples; i++) {
      if (isCancelled()) break;
      final raw =
          await TestRunnerBase.channel.invokeMethod<Uint8List>('getSceneSnapshot');
      if (raw != null && raw.isNotEmpty) {
        final snap = SceneSnapshot.fromBytes(raw);
        if (snap != null) {
          inputLevels.add(snap.inputDbSpl);
          snrValues.add(snap.snrDb);
          vadScores.add(snap.vadScore);
          tilts.add(snap.spectralTiltDb);
          sceneClasses.add(snap.sceneClass.index);
        } else {
          parseErrors++;
        }
      }
      if (i < expectedSamples - 1) {
        await Future.delayed(const Duration(milliseconds: intervalMs));
      }
    }

    if (inputLevels.isEmpty) {
      return {'status': 'Sin datos tras $durationMs ms', 'available': false};
    }

    final classCount = <int, int>{};
    for (final c in sceneClasses) {
      classCount[c] = (classCount[c] ?? 0) + 1;
    }
    final dominantClass = classCount.entries
        .reduce((a, b) => a.value >= b.value ? a : b)
        .key;

    return {
      'available': true,
      'duración': '${durationMs ~/ 1000} s',
      'muestras': inputLevels.length,
      'inputDbSpl (min/avg/max)':
          '${TestRunnerBase.min(inputLevels).toStringAsFixed(1)} / ${TestRunnerBase.avg(inputLevels).toStringAsFixed(1)} / ${TestRunnerBase.max(inputLevels).toStringAsFixed(1)}',
      'snrDb (min/avg/max)':
          '${TestRunnerBase.min(snrValues).toStringAsFixed(1)} / ${TestRunnerBase.avg(snrValues).toStringAsFixed(1)} / ${TestRunnerBase.max(snrValues).toStringAsFixed(1)}',
      'vadScore (avg)': TestRunnerBase.avg(vadScores).toStringAsFixed(3),
      'tilt (avg)': TestRunnerBase.avg(tilts).toStringAsFixed(2),
      'claseDominante': dominantClass,
      'parseErrors': parseErrors,
    };
  }
}
