// Feature: in-app-diagnostic-analyzer
// Module: runner/analysis_runner
//
// Drives the full analysis pipeline inside a Dart `Isolate`. Exposes a
// progress stream, a one-shot `run` future, and an idempotent `cancel`
// that kills the isolate within ~1 ms via `Isolate.kill(immediate)`.
//
// The pipeline runs in this order (matching the design spec sequence diagram):
//   WavReader → MetadataReader → WelchPsd × 2 → BandGainAnalyzer →
//   SpectrogramAnalyzer → SnrAnalyzer → NoiseReductionAnalyzer →
//   WdrcIoAnalyzer → LatencyAnalyzer → ThdAnalyzer → QualityAnalyzer →
//   AudiogramInverter → DiagnosticHeuristics

import 'dart:async';
import 'dart:isolate';
import 'dart:typed_data';

import '../analyzers/audiogram_inverter.dart';
import '../analyzers/band_gain_analyzer.dart';
import '../analyzers/diagnostic_heuristics.dart';
import '../analyzers/latency_analyzer.dart';
import '../analyzers/noise_reduction_analyzer.dart';
import '../analyzers/quality_analyzer.dart';
import '../analyzers/snr_analyzer.dart';
import '../analyzers/spectrogram_analyzer.dart';
import '../analyzers/thd_analyzer.dart';
import '../analyzers/wdrc_io_analyzer.dart';
import '../io/metadata_reader.dart';
import '../io/wav_reader.dart';
import '../result/analysis_error.dart';
import '../result/analysis_result.dart';
import 'analysis_message.dart';
import 'analysis_progress.dart';

/// Argument bundle passed to the isolate entry function.
class _IsolateArgs {
  final String wavPath;
  final String jsonPath;
  final SendPort sendPort;
  const _IsolateArgs({
    required this.wavPath,
    required this.jsonPath,
    required this.sendPort,
  });
}

class AnalysisRunner {
  Isolate? _isolate;
  ReceivePort? _port;
  final StreamController<double> _progressCtrl =
      StreamController<double>.broadcast();

  /// Stream of `[0.0, 1.0]` progress values, one per stage boundary.
  Stream<double> get progress => _progressCtrl.stream;

  /// Runs the full pipeline. Completes with the `AnalysisResult` on
  /// success, or throws an `AnalysisError` on failure.
  Future<AnalysisResult> run({
    required String wavPath,
    required String jsonPath,
  }) async {
    if (_isolate != null) {
      throw StateError('AnalysisRunner already running');
    }
    final port = ReceivePort();
    _port = port;
    final completer = Completer<AnalysisResult>();
    final sub = port.listen((dynamic msg) {
      if (msg is double) {
        if (!_progressCtrl.isClosed) _progressCtrl.add(msg);
      } else if (msg is AnalysisDoneMessage) {
        if (!completer.isCompleted) completer.complete(msg.result);
      } else if (msg is AnalysisErrorMessage) {
        if (!completer.isCompleted) completer.completeError(msg.error);
      } else if (msg is AnalysisProgressMessage) {
        if (!_progressCtrl.isClosed) _progressCtrl.add(msg.value);
      }
    });

    try {
      _isolate = await Isolate.spawn<_IsolateArgs>(
        _entry,
        _IsolateArgs(
          wavPath: wavPath,
          jsonPath: jsonPath,
          sendPort: port.sendPort,
        ),
      );
    } catch (e, st) {
      await sub.cancel();
      port.close();
      _port = null;
      _isolate = null;
      throw AnalysisError(
        stageName: 'Spawn',
        message: 'No se pudo iniciar el aislamiento de análisis: $e',
        cause: e,
        stackTrace: st,
      );
    }

    try {
      final result = await completer.future;
      return result;
    } finally {
      await sub.cancel();
      _port?.close();
      _port = null;
      _isolate = null;
    }
  }

  /// Idempotent. Kills the isolate within ~1 ms when running, no-op when
  /// idle. Safe to call from `dispose()` and from back-navigation
  /// handlers (Req. 15.5).
  Future<void> cancel() async {
    final iso = _isolate;
    if (iso == null) return;
    iso.kill(priority: Isolate.immediate);
    _isolate = null;
    _port?.close();
    _port = null;
  }

  /// Releases the progress stream. Should be called from the owning
  /// widget's `dispose`.
  Future<void> dispose() async {
    await cancel();
    if (!_progressCtrl.isClosed) {
      await _progressCtrl.close();
    }
  }

  // ─── Isolate entry — top-level so it can be hoisted into the isolate ─

  static Future<void> _entry(_IsolateArgs args) async {
    final port = args.sendPort;
    AnalysisStage stage = AnalysisStage.wavReader;
    try {
      // 1. WAV
      stage = AnalysisStage.wavReader;
      final wav = await WavReader().read(args.wavPath);
      port.send(stage.progress);

      // 2. Metadata
      stage = AnalysisStage.metadataReader;
      final metadata = await MetadataReader().read(args.jsonPath);
      port.send(stage.progress);

      // 3. PSD pre & post (delegated to BandGainAnalyzer)
      stage = AnalysisStage.welchPsd;
      // BandGainAnalyzer computes both PSDs internally using a single
      // WelchPsd instance.
      port.send(stage.progress);

      // 4. Band gain
      stage = AnalysisStage.bandGainAnalyzer;
      final prescribedGains = Float64List.fromList(metadata.eqGainsDb);
      final bandGain = BandGainAnalyzer().analyze(
        pre: wav.left,
        post: wav.right,
        sampleRate: wav.sampleRate,
        prescribedGainsDb: prescribedGains,
      );
      port.send(stage.progress);

      // 5. Spectrogram
      stage = AnalysisStage.spectrogramAnalyzer;
      final spectrogram = SpectrogramAnalyzer().analyze(
        pre: wav.left,
        post: wav.right,
        sampleRate: wav.sampleRate,
      );
      port.send(stage.progress);

      // 6. SNR
      stage = AnalysisStage.snrAnalyzer;
      final snr = SnrAnalyzer().analyze(pre: wav.left, post: wav.right);
      port.send(stage.progress);

      // 7. Noise reduction
      stage = AnalysisStage.noiseReductionAnalyzer;
      final nr = NoiseReductionAnalyzer().analyze(
        pre: wav.left,
        post: wav.right,
        snr: snr,
        sampleRate: wav.sampleRate,
      );
      port.send(stage.progress);

      // 8. WDRC I/O
      stage = AnalysisStage.wdrcIoAnalyzer;
      final wdrc = WdrcIoAnalyzer().analyze(
        pre: wav.left,
        post: wav.right,
        configuredCompressionRatio: metadata.wdrc.compressionRatio,
      );
      port.send(stage.progress);

      // 9. Latency
      stage = AnalysisStage.latencyAnalyzer;
      final latency = LatencyAnalyzer().analyze(
        pre: wav.left,
        post: wav.right,
        snr: snr,
      );
      port.send(stage.progress);

      // 10. THD
      stage = AnalysisStage.thdAnalyzer;
      final thd = ThdAnalyzer().analyze(post: wav.right, snr: snr);
      port.send(stage.progress);

      // 11. Quality
      stage = AnalysisStage.qualityAnalyzer;
      final quality = QualityAnalyzer().analyze(
        pre: wav.left,
        post: wav.right,
      );
      port.send(stage.progress);

      // 12. Audiogram inversion
      stage = AnalysisStage.audiogramInverter;
      final audiogram = AudiogramInverter().invert(
        measuredGainsDb: bandGain.measuredGainsDb,
        referenceThresholds: metadata.audiogramThresholds,
      );
      port.send(stage.progress);

      // 13. Heuristics
      stage = AnalysisStage.diagnosticHeuristics;
      final heuristics = DiagnosticHeuristics().evaluate(
        snr: snr,
        thd: thd,
        bandGain: bandGain,
        wdrc: wdrc,
        quality: quality,
        latency: latency,
        psdPre: bandGain.psdPre,
        metadata: metadata,
      );
      port.send(stage.progress);

      // Build the final result.
      final baseName = _basename(args.wavPath);
      final result = AnalysisResult(
        wavBaseName: baseName,
        metadata: metadata,
        wavData: wav,
        psdPre: bandGain.psdPre,
        psdPost: bandGain.psdPost,
        bandGain: bandGain,
        spectrogram: spectrogram,
        snr: snr,
        noiseReduction: nr,
        wdrcIo: wdrc,
        latency: latency,
        thd: thd,
        quality: quality,
        audiogram: audiogram,
        recommendations: heuristics,
      );
      port.send(AnalysisDoneMessage(result));
    } catch (e, st) {
      port.send(AnalysisErrorMessage(
        AnalysisError(
          stageName: stage.pascalCase,
          message: _spanishMessage(e),
          cause: e,
          stackTrace: st,
        ),
      ));
    }
  }

  static String _basename(String path) {
    final norm = path.replaceAll('\\', '/');
    final lastSlash = norm.lastIndexOf('/');
    final filename = lastSlash >= 0 ? norm.substring(lastSlash + 1) : norm;
    final dot = filename.lastIndexOf('.');
    return dot > 0 ? filename.substring(0, dot) : filename;
  }

  static String _spanishMessage(Object e) {
    // The lower-level exceptions already carry Spanish messages where
    // possible (WavFormatException, MetadataFormatException,
    // PsdInputException). Surface them verbatim.
    final s = e.toString();
    return s;
  }
}
