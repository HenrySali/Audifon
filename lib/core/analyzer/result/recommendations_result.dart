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

  /// Sugerencia concreta de acción (ej: "Subir EQ en 4 kHz +3 dB").
  /// Null si no hay acción directa recomendada.
  final String? suggestion;

  /// Etapa del pipeline que origina esta recomendación.
  final String? stage;

  const Recommendation({
    required this.severity,
    required this.message,
    this.suggestion,
    this.stage,
  });
}

class RecommendationsResult {
  /// Ordered list of recommendations following Req. 14.1–14.8 sequence.
  final List<Recommendation> items;

  /// Resumen general del estado del sistema en texto libre.
  final String summary;

  /// Veredicto por etapa: Map<nombreEtapa, 'OK'|'WARN'|'ERROR'>.
  final Map<String, String> stageVerdicts;

  const RecommendationsResult({
    required this.items,
    this.summary = '',
    this.stageVerdicts = const {},
  });

  /// Empty result, used when no rule fires.
  const RecommendationsResult.empty()
      : items = const <Recommendation>[],
        summary = 'Sin problemas detectados.',
        stageVerdicts = const {};
}
