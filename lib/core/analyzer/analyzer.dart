// Feature: in-app-diagnostic-analyzer
// Barrel file — exports the public API of the analyzer module.
//
// Spec: .kiro/specs/in-app-diagnostic-analyzer/
//   - requirements.md
//   - design.md
//   - tasks.md
//
// Canonical implementation lives in PACIENTE/oir_pro_patient_app/lib/core/analyzer/.
// The technician copy at hearing_aid_app/lib/core/analyzer/ is produced by the
// patient→technician sync script (`tools/sync_patient_to_technician.bat`).

export 'constants.dart';

// I/O layer
export 'io/wav_reader.dart';
export 'io/metadata_reader.dart';

// DSP base layer
export 'dsp/fft.dart';
export 'dsp/window.dart';
export 'dsp/welch_psd.dart';
export 'dsp/stft.dart';
export 'dsp/retspl.dart';

// Analyzer modules
export 'analyzers/band_gain_analyzer.dart';
export 'analyzers/spectrogram_analyzer.dart';
export 'analyzers/snr_analyzer.dart';
export 'analyzers/noise_reduction_analyzer.dart';
export 'analyzers/wdrc_io_analyzer.dart';
export 'analyzers/latency_analyzer.dart';
export 'analyzers/thd_analyzer.dart';
export 'analyzers/quality_analyzer.dart';
export 'analyzers/audiogram_inverter.dart';
export 'analyzers/diagnostic_heuristics.dart';

// Pipeline orchestration
export 'runner/analysis_runner.dart';
export 'runner/analysis_progress.dart';

// Result types
export 'result/analysis_result.dart';
export 'result/analysis_error.dart';
export 'result/psd_result.dart';
export 'result/band_gain_result.dart';
export 'result/spectrogram_result.dart';
export 'result/snr_result.dart';
export 'result/noise_reduction_result.dart';
export 'result/wdrc_io_result.dart';
export 'result/latency_result.dart';
export 'result/thd_result.dart';
export 'result/quality_result.dart';
export 'result/audiogram_comparison_result.dart';
export 'result/recommendations_result.dart';

// UI
export 'ui/analyzer_screen.dart';
export 'ui/service_code_gate.dart';
