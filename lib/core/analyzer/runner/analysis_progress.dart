// Feature: in-app-diagnostic-analyzer
// Module: runner/analysis_progress
//
// Stage progress mapping (13 stages, monotonically increasing) used by
// the AnalysisRunner to drive the UI's `LinearProgressIndicator`.

/// Pipeline stage. Used for the runner's progress mapping and to compose
/// the `AnalysisError.stageName` when a stage throws.
enum AnalysisStage {
  wavReader,
  metadataReader,
  welchPsd,
  bandGainAnalyzer,
  spectrogramAnalyzer,
  snrAnalyzer,
  noiseReductionAnalyzer,
  wdrcIoAnalyzer,
  latencyAnalyzer,
  thdAnalyzer,
  qualityAnalyzer,
  audiogramInverter,
  diagnosticHeuristics,
}

extension AnalysisStageX on AnalysisStage {
  /// Progress value (in `[0.0, 1.0]`) emitted at the end of this stage.
  double get progress {
    switch (this) {
      case AnalysisStage.wavReader:
        return 0.077;
      case AnalysisStage.metadataReader:
        return 0.154;
      case AnalysisStage.welchPsd:
        return 0.231;
      case AnalysisStage.bandGainAnalyzer:
        return 0.308;
      case AnalysisStage.spectrogramAnalyzer:
        return 0.385;
      case AnalysisStage.snrAnalyzer:
        return 0.462;
      case AnalysisStage.noiseReductionAnalyzer:
        return 0.539;
      case AnalysisStage.wdrcIoAnalyzer:
        return 0.616;
      case AnalysisStage.latencyAnalyzer:
        return 0.693;
      case AnalysisStage.thdAnalyzer:
        return 0.770;
      case AnalysisStage.qualityAnalyzer:
        return 0.847;
      case AnalysisStage.audiogramInverter:
        return 0.924;
      case AnalysisStage.diagnosticHeuristics:
        return 1.000;
    }
  }

  /// PascalCase stage name used for `AnalysisError.stageName`.
  String get pascalCase {
    switch (this) {
      case AnalysisStage.wavReader:
        return 'WavReader';
      case AnalysisStage.metadataReader:
        return 'MetadataReader';
      case AnalysisStage.welchPsd:
        return 'WelchPsd';
      case AnalysisStage.bandGainAnalyzer:
        return 'BandGainAnalyzer';
      case AnalysisStage.spectrogramAnalyzer:
        return 'SpectrogramAnalyzer';
      case AnalysisStage.snrAnalyzer:
        return 'SnrAnalyzer';
      case AnalysisStage.noiseReductionAnalyzer:
        return 'NoiseReductionAnalyzer';
      case AnalysisStage.wdrcIoAnalyzer:
        return 'WdrcIoAnalyzer';
      case AnalysisStage.latencyAnalyzer:
        return 'LatencyAnalyzer';
      case AnalysisStage.thdAnalyzer:
        return 'ThdAnalyzer';
      case AnalysisStage.qualityAnalyzer:
        return 'QualityAnalyzer';
      case AnalysisStage.audiogramInverter:
        return 'AudiogramInverter';
      case AnalysisStage.diagnosticHeuristics:
        return 'DiagnosticHeuristics';
    }
  }
}
