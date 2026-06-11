// Feature: in-app-diagnostic-analyzer
// Module: result/recommendations_result
//
// Output of the DiagnosticHeuristics rule engine. An ordered list of
// Spanish-language `Recommendation` items.

/// Severity level driving the UI color coding on the SummaryTab.
enum RecommendationSeverity { info, warn, error }

class Recommendation {
  final RecommendationSeverity severity;
  final String message;

  const Recommendation({
    required this.severity,
    required this.message,
  });
}

class RecommendationsResult {
  /// Ordered list of recommendations following Req. 14.1–14.8 sequence.
  final List<Recommendation> items;

  const RecommendationsResult({required this.items});

  /// Empty result, used when no rule fires.
  const RecommendationsResult.empty() : items = const <Recommendation>[];
}
