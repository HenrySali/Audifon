// Feature: in-app-diagnostic-analyzer
// Module: presentation/screens/diagnostic_analyzer_screen
//
// Pantalla del Analizador de Diagnóstico. Muestra:
// 1. Reporte unificado en lenguaje de usuario (si hay uno disponible)
// 2. Lista de WAVs pendientes para análisis individual
//
// El reporte se genera automáticamente al completar "Ejecutar Todos"
// en la ventana de Diagnóstico Unificado.

import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/analyzer/ui/analyzer_screen.dart';
import '../../data/services/analyzer_inbox_service.dart';
import 'unified_diagnostics/models/diagnostic_report.dart';

// Paleta consistente con el resto de pantallas técnicas.
const Color _kBg = Color(0xFF0a0e27);
const Color _kSurface = Color(0xFF16213e);
const Color _kAccent = Color(0xFF0f3460);
const Color _kCyan = Color(0xFF4dd0e1);
const Color _kGreen = Color(0xFF43A047);
const Color _kRed = Color(0xFFE53935);
const Color _kAmber = Color(0xFFFFB300);
const Color _kText = Colors.white;
const Color _kTextDim = Color(0xFFb0bec5);

class DiagnosticAnalyzerScreen extends StatefulWidget {
  const DiagnosticAnalyzerScreen({super.key});

  @override
  State<DiagnosticAnalyzerScreen> createState() =>
      _DiagnosticAnalyzerScreenState();
}

class _DiagnosticAnalyzerScreenState extends State<DiagnosticAnalyzerScreen> {
  final _inbox = AnalyzerInboxService.instance;
  StreamSubscription<void>? _sub;
  bool _showTechnical = false;

  @override
  void initState() {
    super.initState();
    _sub = _inbox.onChange.listen((_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }

  Future<void> _openAnalyzer(String wavPath) async {
    if (!File(wavPath).existsSync()) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
                'Archivo no encontrado: ${wavPath.split('/').last}'),
          ),
        );
      }
      return;
    }
    if (mounted) {
      Navigator.of(context).push(
        MaterialPageRoute(
          builder: (_) => AnalyzerScreen(preloadedWavPath: wavPath),
        ),
      );
    }
  }

  Future<void> _copyReport() async {
    final report = _inbox.lastReport;
    if (report == null) return;
    await Clipboard.setData(ClipboardData(text: report.toFileContent()));
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Reporte copiado al portapapeles'),
          duration: Duration(seconds: 2),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final report = _inbox.lastReport;
    final wavs = _inbox.pendingWavs;

    return Scaffold(
      backgroundColor: _kBg,
      appBar: AppBar(
        title: const Text('Analizador'),
        backgroundColor: _kAccent,
        foregroundColor: _kText,
        actions: [
          if (report != null)
            IconButton(
              icon: const Icon(Icons.copy),
              tooltip: 'Copiar reporte completo',
              onPressed: _copyReport,
            ),
          if (wavs.isNotEmpty || report != null)
            IconButton(
              icon: const Icon(Icons.delete_sweep),
              tooltip: 'Limpiar todo',
              onPressed: () {
                _inbox.clear();
                setState(() {});
              },
            ),
          IconButton(
            icon: const Icon(Icons.file_open),
            tooltip: 'Abrir WAV manualmente',
            onPressed: () {
              Navigator.of(context).push(
                MaterialPageRoute(
                  builder: (_) => const AnalyzerScreen(),
                ),
              );
            },
          ),
        ],
      ),
      body: (report == null && wavs.isEmpty)
          ? _buildEmptyState()
          : _buildContent(report, wavs),
    );
  }

  // ─── Estado vacío ─────────────────────────────────────────────────────────

  Widget _buildEmptyState() {
    return const Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.analytics_outlined, color: Colors.white30, size: 64),
          SizedBox(height: 16),
          Text(
            'Sin diagnóstico disponible',
            style: TextStyle(color: Colors.white70, fontSize: 16),
          ),
          SizedBox(height: 8),
          Text(
            'Ejecuta "Ejecutar Todos" en la ventana de\n'
            'Diagnóstico para generar el reporte.',
            style: TextStyle(color: Colors.white38, fontSize: 13),
            textAlign: TextAlign.center,
          ),
        ],
      ),
    );
  }

  // ─── Contenido principal ──────────────────────────────────────────────────

  Widget _buildContent(DiagnosticReport? report, List<String> wavs) {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // ─── Reporte unificado ──────────────────────────────────────────
          if (report != null) ...[
            _buildReportHeader(report),
            const SizedBox(height: 12),
            _buildFindings(report),
            const SizedBox(height: 12),
            // Toggle sección técnica
            _buildTechnicalToggle(report),
            const SizedBox(height: 16),
          ],
          // ─── WAVs disponibles ───────────────────────────────────────────
          if (wavs.isNotEmpty) ...[
            _buildWavSection(wavs),
          ],
        ],
      ),
    );
  }

  // ─── Header del reporte ───────────────────────────────────────────────────

  Widget _buildReportHeader(DiagnosticReport report) {
    final statusColor = switch (report.overallStatus) {
      'ok' => _kGreen,
      'warnings' => _kAmber,
      'issues' => _kRed,
      _ => _kTextDim,
    };
    final statusIcon = switch (report.overallStatus) {
      'ok' => Icons.check_circle,
      'warnings' => Icons.warning_amber_rounded,
      'issues' => Icons.error,
      _ => Icons.help_outline,
    };
    final statusText = switch (report.overallStatus) {
      'ok' => 'Sistema OK',
      'warnings' => 'Advertencias detectadas',
      'issues' => 'Problemas detectados',
      _ => 'Estado desconocido',
    };

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: _kSurface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: statusColor.withOpacity(0.4)),
      ),
      child: Row(
        children: [
          Icon(statusIcon, color: statusColor, size: 36),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  statusText,
                  style: TextStyle(
                    color: statusColor,
                    fontSize: 18,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  'Diagnóstico del ${_formatDate(report.timestamp)}',
                  style: const TextStyle(color: _kTextDim, fontSize: 12),
                ),
                Text(
                  '${report.findings.length} hallazgos · '
                  '${report.wavFiles.length} grabaciones',
                  style: const TextStyle(color: _kTextDim, fontSize: 12),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  // ─── Hallazgos (findings) ─────────────────────────────────────────────────

  Widget _buildFindings(DiagnosticReport report) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Padding(
          padding: EdgeInsets.only(left: 4, bottom: 8),
          child: Text(
            'RESULTADOS',
            style: TextStyle(
              color: _kCyan,
              fontSize: 12,
              fontWeight: FontWeight.w700,
              letterSpacing: 1.2,
            ),
          ),
        ),
        ...report.findings.map(_buildFindingCard),
      ],
    );
  }

  Widget _buildFindingCard(DiagnosticFinding finding) {
    final color = switch (finding.severity) {
      FindingSeverity.ok => _kGreen,
      FindingSeverity.info => _kCyan,
      FindingSeverity.warning => _kAmber,
      FindingSeverity.critical => _kRed,
    };
    final icon = switch (finding.severity) {
      FindingSeverity.ok => Icons.check_circle_outline,
      FindingSeverity.info => Icons.info_outline,
      FindingSeverity.warning => Icons.warning_amber_rounded,
      FindingSeverity.critical => Icons.error_outline,
    };

    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: _kSurface,
        borderRadius: BorderRadius.circular(8),
        border: Border(left: BorderSide(color: color, width: 3)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon, color: color, size: 18),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  finding.userMessage,
                  style: const TextStyle(color: _kText, fontSize: 13),
                ),
              ),
            ],
          ),
          if (finding.recommendation != null) ...[
            const SizedBox(height: 6),
            Padding(
              padding: const EdgeInsets.only(left: 26),
              child: Text(
                '→ ${finding.recommendation}',
                style: TextStyle(
                  color: color.withOpacity(0.8),
                  fontSize: 12,
                  fontStyle: FontStyle.italic,
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }

  // ─── Sección técnica (toggle) ─────────────────────────────────────────────

  Widget _buildTechnicalToggle(DiagnosticReport report) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        InkWell(
          onTap: () => setState(() => _showTechnical = !_showTechnical),
          borderRadius: BorderRadius.circular(8),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            decoration: BoxDecoration(
              color: _kSurface,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: _kAccent),
            ),
            child: Row(
              children: [
                Icon(
                  _showTechnical
                      ? Icons.keyboard_arrow_down
                      : Icons.keyboard_arrow_right,
                  color: _kTextDim,
                  size: 20,
                ),
                const SizedBox(width: 8),
                const Text(
                  'Datos técnicos (para soporte)',
                  style: TextStyle(color: _kTextDim, fontSize: 13),
                ),
                const Spacer(),
                if (_showTechnical)
                  IconButton(
                    icon: const Icon(Icons.copy, size: 16),
                    color: _kTextDim,
                    padding: EdgeInsets.zero,
                    constraints:
                        const BoxConstraints(minWidth: 28, minHeight: 28),
                    onPressed: () async {
                      await Clipboard.setData(
                        ClipboardData(text: report.technicalJson),
                      );
                      if (mounted) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(
                            content: Text('JSON técnico copiado'),
                            duration: Duration(seconds: 2),
                          ),
                        );
                      }
                    },
                    tooltip: 'Copiar JSON técnico',
                  ),
              ],
            ),
          ),
        ),
        if (_showTechnical) ...[
          const SizedBox(height: 8),
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: const Color(0xFF0d1117),
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: _kAccent),
            ),
            constraints: const BoxConstraints(maxHeight: 300),
            child: SingleChildScrollView(
              child: Text(
                report.technicalJson,
                style: const TextStyle(
                  color: _kTextDim,
                  fontSize: 11,
                  fontFamily: 'monospace',
                ),
              ),
            ),
          ),
        ],
      ],
    );
  }

  // ─── Sección de WAVs ──────────────────────────────────────────────────────

  Widget _buildWavSection(List<String> wavs) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(left: 4, bottom: 8),
          child: Text(
            'GRABACIONES (${wavs.length})',
            style: const TextStyle(
              color: _kCyan,
              fontSize: 12,
              fontWeight: FontWeight.w700,
              letterSpacing: 1.2,
            ),
          ),
        ),
        ...wavs.map((wav) => _buildWavTile(wav)),
      ],
    );
  }

  Widget _buildWavTile(String wav) {
    final fileName = wav.split('/').last;
    final exists = File(wav).existsSync();

    return Container(
      margin: const EdgeInsets.only(bottom: 6),
      decoration: BoxDecoration(
        color: _kSurface,
        borderRadius: BorderRadius.circular(8),
      ),
      child: ListTile(
        dense: true,
        leading: Icon(
          Icons.audio_file,
          color: exists ? _kCyan : _kRed.withOpacity(0.5),
          size: 22,
        ),
        title: Text(
          fileName,
          style: TextStyle(
            color: exists ? _kText : _kTextDim,
            fontSize: 12,
          ),
          overflow: TextOverflow.ellipsis,
        ),
        subtitle: Text(
          exists ? 'Toca para analizar' : 'Archivo no encontrado',
          style: TextStyle(
            color: exists ? Colors.white38 : _kRed.withOpacity(0.7),
            fontSize: 10,
          ),
        ),
        trailing: IconButton(
          icon: Icon(
            Icons.play_circle,
            color: exists ? _kCyan : _kTextDim,
            size: 22,
          ),
          onPressed: exists ? () => _openAnalyzer(wav) : null,
        ),
        onTap: exists ? () => _openAnalyzer(wav) : null,
      ),
    );
  }

  // ─── Helpers ──────────────────────────────────────────────────────────────

  String _formatDate(DateTime dt) {
    const months = [
      '', 'ene', 'feb', 'mar', 'abr', 'may', 'jun',
      'jul', 'ago', 'sep', 'oct', 'nov', 'dic',
    ];
    return '${dt.day} ${months[dt.month]} ${dt.year}, '
        '${dt.hour.toString().padLeft(2, '0')}:'
        '${dt.minute.toString().padLeft(2, '0')}';
  }
}
