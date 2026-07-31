/// Modelo del reporte unificado de diagnóstico.
///
/// Contiene dos niveles de información:
/// 1. [userSummary]: resumen en lenguaje simple para el usuario/paciente.
/// 2. [technicalData]: datos completos para el técnico/desarrollador.
///
/// El reporte se genera al completar todos los tests y se envía al
/// AnalyzerInboxService para visualización en la pantalla del Analizador.

import 'dart:convert';

/// Severidad de un hallazgo individual.
enum FindingSeverity { ok, info, warning, critical }

/// Un hallazgo individual del diagnóstico.
class DiagnosticFinding {
  final String title;
  final String userMessage;
  final String technicalDetail;
  final FindingSeverity severity;
  final String? recommendation;

  const DiagnosticFinding({
    required this.title,
    required this.userMessage,
    required this.technicalDetail,
    required this.severity,
    this.recommendation,
  });

  Map<String, dynamic> toJson() => {
        'title': title,
        'userMessage': userMessage,
        'technicalDetail': technicalDetail,
        'severity': severity.name,
        'recommendation': recommendation,
      };

  factory DiagnosticFinding.fromJson(Map<String, dynamic> json) {
    return DiagnosticFinding(
      title: json['title'] as String,
      userMessage: json['userMessage'] as String,
      technicalDetail: json['technicalDetail'] as String,
      severity: FindingSeverity.values.byName(json['severity'] as String),
      recommendation: json['recommendation'] as String?,
    );
  }
}

/// Reporte completo de diagnóstico del sistema.
class DiagnosticReport {
  final DateTime timestamp;
  final List<DiagnosticFinding> findings;
  final Map<String, Map<String, dynamic>> testResults;
  final List<String> wavFiles;
  final String overallStatus; // 'ok', 'warnings', 'issues'

  const DiagnosticReport({
    required this.timestamp,
    required this.findings,
    required this.testResults,
    required this.wavFiles,
    required this.overallStatus,
  });

  // ─── Sección usuario (lenguaje simple) ──────────────────────────────────

  String get userSummary {
    final buf = StringBuffer();
    buf.writeln('═══ DIAGNÓSTICO AUDIFON ═══');
    buf.writeln('Fecha: ${_formatDate(timestamp)}');
    buf.writeln('');

    if (findings.isEmpty) {
      buf.writeln('✅ Sistema funcionando correctamente.');
      return buf.toString();
    }

    // Agrupar por severidad
    final criticals =
        findings.where((f) => f.severity == FindingSeverity.critical).toList();
    final warnings =
        findings.where((f) => f.severity == FindingSeverity.warning).toList();
    final oks =
        findings.where((f) => f.severity == FindingSeverity.ok).toList();
    final infos =
        findings.where((f) => f.severity == FindingSeverity.info).toList();

    for (final f in oks) {
      buf.writeln('✅ ${f.userMessage}');
    }
    for (final f in infos) {
      buf.writeln('ℹ️ ${f.userMessage}');
    }
    for (final f in warnings) {
      buf.writeln('⚠️ ${f.userMessage}');
    }
    for (final f in criticals) {
      buf.writeln('❌ ${f.userMessage}');
    }

    // Recomendaciones
    final recs = findings
        .where((f) => f.recommendation != null)
        .map((f) => f.recommendation!)
        .toSet();
    if (recs.isNotEmpty) {
      buf.writeln('');
      buf.writeln('── RECOMENDACIONES ──');
      for (final r in recs) {
        buf.writeln('→ $r');
      }
    }

    return buf.toString();
  }

  // ─── Sección técnica (JSON completo) ────────────────────────────────────

  String get technicalJson {
    final data = {
      'timestamp': timestamp.toIso8601String(),
      'overallStatus': overallStatus,
      'findings': findings.map((f) => f.toJson()).toList(),
      'wavFiles': wavFiles,
      'tests': testResults,
    };
    const encoder = JsonEncoder.withIndent('  ');
    return encoder.convert(data);
  }

  // ─── Serialización completa (para guardar en archivo) ───────────────────

  String toFileContent() {
    final buf = StringBuffer();
    // Parte 1: resumen usuario
    buf.writeln(userSummary);
    buf.writeln('');
    buf.writeln('══════════════════════════════════════════');
    buf.writeln('DATOS TÉCNICOS (para soporte)');
    buf.writeln('══════════════════════════════════════════');
    buf.writeln(technicalJson);
    return buf.toString();
  }

  factory DiagnosticReport.fromJson(Map<String, dynamic> json) {
    return DiagnosticReport(
      timestamp: DateTime.parse(json['timestamp'] as String),
      findings: (json['findings'] as List)
          .map((f) => DiagnosticFinding.fromJson(f as Map<String, dynamic>))
          .toList(),
      testResults: (json['tests'] as Map<String, dynamic>).map(
        (k, v) => MapEntry(k, Map<String, dynamic>.from(v as Map)),
      ),
      wavFiles: (json['wavFiles'] as List).cast<String>(),
      overallStatus: json['overallStatus'] as String,
    );
  }

  // ─── Helpers ──────────────────────────────────────────────────────────────

  static String _formatDate(DateTime dt) {
    const months = [
      '', 'enero', 'febrero', 'marzo', 'abril', 'mayo', 'junio',
      'julio', 'agosto', 'septiembre', 'octubre', 'noviembre', 'diciembre',
    ];
    return '${dt.day} ${months[dt.month]} ${dt.year}, '
        '${dt.hour.toString().padLeft(2, '0')}:'
        '${dt.minute.toString().padLeft(2, '0')}';
  }
}
