// Feature: in-app-diagnostic-analyzer
// Module: runner/analysis_message
//
// Sealed envelope types shipped between the Analysis_Isolate and the UI
// isolate via `SendPort` / `ReceivePort`. Dart's default value-copy
// machinery handles `Float64List` / `Float32List` and the result trees
// transparently.

import '../result/analysis_error.dart';
import '../result/analysis_result.dart';

sealed class AnalysisMessage {
  const AnalysisMessage();
}

/// Stage-boundary progress message.
class AnalysisProgressMessage extends AnalysisMessage {
  final double value;
  const AnalysisProgressMessage(this.value);
}

/// Final successful result.
class AnalysisDoneMessage extends AnalysisMessage {
  final AnalysisResult result;
  const AnalysisDoneMessage(this.result);
}

/// Final error.
class AnalysisErrorMessage extends AnalysisMessage {
  final AnalysisError error;
  const AnalysisErrorMessage(this.error);
}
