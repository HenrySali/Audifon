/// @file calibration_summary_widget.dart
/// @brief Resumen visual de un `BiologicalCalibrationResult` con tabla de
///        frecuencias, métricas globales y exportación a JSON.
///
/// Renderiza:
///   - Tabla de frecuencias (Hz / mean dBFS / std / spread / max HL / confianza)
///   - Métricas globales: spread mean/max, falsePositiveRate, allRetestsWithin5Db
///   - Botón "Copiar JSON al portapapeles"
///
/// Compatibilidad Flutter 3.19.6: usa `withOpacity` (no `withValues`) y
/// no depende de APIs nuevas.

library;

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../models/biological_calibration_result.dart';
import '../../models/frequency_threshold.dart';

/// Widget que muestra el resultado de una calibración biológica completada.
class CalibrationSummaryWidget extends StatelessWidget {
  const CalibrationSummaryWidget({
    super.key,
    required this.result,
  });

  /// Resultado a mostrar.
  final BiologicalCalibrationResult result;

  @override
  Widget build(BuildContext context) {
    final ColorScheme colors = Theme.of(context).colorScheme;

    return Card(
      margin: const EdgeInsets.all(12),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            // Encabezado
            Row(
              children: <Widget>[
                Icon(Icons.fact_check_outlined,
                    color: colors.primary, size: 28),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    'Resumen de calibración',
                    style: Theme.of(context).textTheme.titleLarge,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              'Generada el ${_formatDateTime(result.createdAt)} '
              '· expira el ${_formatDateTime(result.expiresAt)}',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: colors.onSurface.withOpacity(0.7),
                  ),
            ),
            const Divider(height: 24),

            _buildFrequencyTable(context),

            const SizedBox(height: 16),
            _buildQualityMetrics(context),

            const SizedBox(height: 16),
            _buildSubjectsSummary(context),

            const SizedBox(height: 20),
            FilledButton.icon(
              onPressed: () => _copyJsonToClipboard(context),
              icon: const Icon(Icons.copy_all),
              label: const Padding(
                padding: EdgeInsets.symmetric(vertical: 10),
                child: Text(
                  'Copiar JSON al portapapeles',
                  style: TextStyle(fontSize: 15),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ───────────────────────────────────────────── Tabla de frecuencias ──

  Widget _buildFrequencyTable(BuildContext context) {
    final ColorScheme colors = Theme.of(context).colorScheme;
    final TextStyle? headerStyle =
        Theme.of(context).textTheme.labelLarge?.copyWith(
              color: colors.onPrimaryContainer,
              fontWeight: FontWeight.w700,
            );

    final List<int> orderedFreqs = result.frequencies.keys.toList()..sort();

    if (orderedFreqs.isEmpty) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 12),
        child: Text(
          'No hay frecuencias calibradas todavía.',
          style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                color: colors.onSurface.withOpacity(0.7),
              ),
        ),
      );
    }

    const List<DataColumn> columns = <DataColumn>[
      DataColumn(label: Text('Hz')),
      DataColumn(label: Text('Umbral (dBFS)'), numeric: true),
      DataColumn(label: Text('σ (dB)'), numeric: true),
      DataColumn(label: Text('Spread (dB)'), numeric: true),
      DataColumn(label: Text('Máx HL'), numeric: true),
      DataColumn(label: Text('Confianza')),
    ];

    final List<DataRow> rows = orderedFreqs.map((int freq) {
      final FrequencyThreshold ft = result.frequencies[freq]!;
      return DataRow(
        cells: <DataCell>[
          DataCell(Text(freq.toString())),
          DataCell(Text(ft.meanThresholdDbFS.toStringAsFixed(1))),
          DataCell(Text(ft.stdDb.toStringAsFixed(1))),
          DataCell(Text(ft.spreadDb.toStringAsFixed(1))),
          DataCell(Text('${ft.maxHLAchievable.toStringAsFixed(0)} dB')),
          DataCell(_confidenceChip(context, ft.confidence)),
        ],
      );
    }).toList();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Text(
          'Umbrales por frecuencia',
          style: Theme.of(context).textTheme.titleMedium,
        ),
        const SizedBox(height: 8),
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: DataTable(
            headingRowColor: MaterialStateProperty.all(
              colors.primaryContainer.withOpacity(0.6),
            ),
            headingTextStyle: headerStyle,
            columnSpacing: 18,
            columns: columns,
            rows: rows,
          ),
        ),
      ],
    );
  }

  Widget _confidenceChip(BuildContext context, String confidence) {
    final ColorScheme colors = Theme.of(context).colorScheme;
    final Color bg;
    final Color fg;
    final String label;
    switch (confidence) {
      case ThresholdConfidence.high:
        bg = Colors.green.withOpacity(0.18);
        fg = Colors.green.shade700;
        label = 'Alta';
        break;
      case ThresholdConfidence.medium:
        bg = Colors.amber.withOpacity(0.22);
        fg = Colors.amber.shade800;
        label = 'Media';
        break;
      case ThresholdConfidence.low:
      default:
        bg = colors.errorContainer.withOpacity(0.5);
        fg = colors.error;
        label = 'Baja';
    }
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Text(
        label,
        style: TextStyle(color: fg, fontWeight: FontWeight.w600),
      ),
    );
  }

  // ───────────────────────────────────────────── Métricas globales ─────

  Widget _buildQualityMetrics(BuildContext context) {
    final ColorScheme colors = Theme.of(context).colorScheme;
    final QualityMetrics q = result.quality;

    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: colors.surfaceVariant.withOpacity(0.5),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: colors.outlineVariant.withOpacity(0.6),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Text(
            'Métricas globales',
            style: Theme.of(context).textTheme.titleMedium,
          ),
          const SizedBox(height: 8),
          _metricRow(
            context,
            label: 'Spread medio',
            value: '${q.overallSpreadMeanDb.toStringAsFixed(1)} dB',
            icon: Icons.show_chart,
          ),
          _metricRow(
            context,
            label: 'Spread máximo',
            value: '${q.overallSpreadMaxDb.toStringAsFixed(1)} dB',
            icon: Icons.trending_up,
          ),
          _metricRow(
            context,
            label: 'Tasa falsos positivos',
            value:
                '${(q.overallFalsePositiveRate * 100).toStringAsFixed(1)}% '
                '(${q.totalFalsePositives}/${q.totalCatchTrials})',
            icon: Icons.report_outlined,
          ),
          _metricRow(
            context,
            label: 'Retests dentro de ±5 dB',
            value: q.allRetestsWithin5Db ? 'Sí' : 'No',
            icon: Icons.repeat,
          ),
          _metricRow(
            context,
            label: 'Calibración válida',
            value: q.calibrationValid ? '✓ Sí' : '✗ No',
            icon: q.calibrationValid
                ? Icons.check_circle_outline
                : Icons.cancel_outlined,
            highlight: !q.calibrationValid,
          ),
        ],
      ),
    );
  }

  Widget _metricRow(
    BuildContext context, {
    required String label,
    required String value,
    required IconData icon,
    bool highlight = false,
  }) {
    final ColorScheme colors = Theme.of(context).colorScheme;
    final Color color = highlight ? colors.error : colors.onSurface;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: <Widget>[
          Icon(icon, size: 18, color: color.withOpacity(0.8)),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              label,
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    color: color.withOpacity(0.85),
                  ),
            ),
          ),
          Text(
            value,
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  color: color,
                  fontWeight: FontWeight.w600,
                ),
          ),
        ],
      ),
    );
  }

  // ───────────────────────────────────────────── Sujetos ───────────────

  Widget _buildSubjectsSummary(BuildContext context) {
    final ColorScheme colors = Theme.of(context).colorScheme;
    final int valid =
        result.sessions.where((s) => s.valid).length;
    final int total = result.sessions.length;
    return Row(
      children: <Widget>[
        Icon(Icons.groups_outlined, color: colors.primary),
        const SizedBox(width: 8),
        Text(
          'Sujetos: $valid válidos de $total registrados',
          style: Theme.of(context).textTheme.bodyMedium,
        ),
      ],
    );
  }

  // ───────────────────────────────────────────── Acciones ──────────────

  Future<void> _copyJsonToClipboard(BuildContext context) async {
    final String jsonStr =
        const JsonEncoder.withIndent('  ').convert(result.toJson());
    await Clipboard.setData(ClipboardData(text: jsonStr));
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('Reporte JSON copiado al portapapeles'),
        duration: Duration(seconds: 2),
      ),
    );
  }

  // ───────────────────────────────────────────── Helpers ───────────────

  String _formatDateTime(DateTime dt) {
    String two(int n) => n.toString().padLeft(2, '0');
    final DateTime local = dt.toLocal();
    return '${local.year}-${two(local.month)}-${two(local.day)} '
        '${two(local.hour)}:${two(local.minute)}';
  }
}
