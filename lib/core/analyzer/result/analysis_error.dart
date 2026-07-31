// Feature: in-app-diagnostic-analyzer
// Module: result/analysis_error
//
// Single error funnel for the analysis pipeline. Any exception thrown
// inside the Analysis_Isolate is captured and re-emitted as an
// `AnalysisError` carrying the stage name and a Spanish message.

/// Error type produced by the analysis pipeline.
class AnalysisError implements Exception {
  /// Name of the stage where the failure occurred (e.g. "WelchPsd",
  /// "WdrcIoAnalyzer"). Used by the UI to compose the Spanish error
  /// banner.
  final String stageName;

  /// Spanish-language message describing the failure.
  final String message;

  /// Optional underlying cause (kept for debugging; not surfaced to the
  /// user).
  final Object? cause;

  /// Optional stack trace from the underlying cause.
  final StackTrace? stackTrace;

  const AnalysisError({
    required this.stageName,
    required this.message,
    this.cause,
    this.stackTrace,
  });

  @override
  String toString() => 'AnalysisError($stageName): $message';
}
