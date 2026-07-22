import 'package:flutter/material.dart';

import '../models/test_result.dart';
import '../theme/diagnostics_colors.dart';

/// Tarjeta visual de un test individual con estado, datos y acciones.
class DiagnosticsTestCard extends StatelessWidget {
  final TestResult result;
  final VoidCallback onRun;
  final VoidCallback onCopy;

  const DiagnosticsTestCard({
    super.key,
    required this.result,
    required this.onRun,
    required this.onCopy,
  });

  @override
  Widget build(BuildContext context) {
    final isRunning = result.status == TestStatus.running;
    final isCompleted = result.status == TestStatus.completed;
    final isError = result.status == TestStatus.error;

    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      decoration: BoxDecoration(
        color: DiagnosticsColors.surface,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(
          color: isError
              ? DiagnosticsColors.red.withOpacity(0.5)
              : isCompleted
                  ? DiagnosticsColors.green.withOpacity(0.3)
                  : DiagnosticsColors.accent,
          width: 1,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _buildHeader(isRunning, isCompleted, isError),
          if (isCompleted && result.data.isNotEmpty)
            _buildResultData(result.data),
          if (isError && result.errorMessage != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(14, 4, 14, 10),
              child: Text(
                result.errorMessage!,
                style: const TextStyle(
                  color: DiagnosticsColors.red,
                  fontSize: 12,
                ),
              ),
            ),
          if (isRunning)
            const Padding(
              padding: EdgeInsets.fromLTRB(14, 4, 14, 10),
              child: LinearProgressIndicator(
                backgroundColor: DiagnosticsColors.accent,
                color: DiagnosticsColors.cyan,
                minHeight: 3,
              ),
            ),
          if (!isRunning && !isCompleted && !isError)
            const SizedBox(height: 10),
        ],
      ),
    );
  }

  Widget _buildHeader(bool isRunning, bool isCompleted, bool isError) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 10, 8, 0),
      child: Row(
        children: [
          _statusIcon(result.status),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              result.testName,
              style: const TextStyle(
                color: DiagnosticsColors.text,
                fontSize: 14,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          if (!isRunning)
            IconButton(
              icon: const Icon(Icons.play_circle_outline, size: 22),
              color: DiagnosticsColors.cyan,
              tooltip: 'Ejecutar test',
              padding: EdgeInsets.zero,
              constraints:
                  const BoxConstraints(minWidth: 32, minHeight: 32),
              onPressed: onRun,
            ),
          if (isCompleted || isError)
            IconButton(
              icon: const Icon(Icons.copy, size: 18),
              color: DiagnosticsColors.textDim,
              tooltip: 'Copiar resultado',
              padding: EdgeInsets.zero,
              constraints:
                  const BoxConstraints(minWidth: 32, minHeight: 32),
              onPressed: onCopy,
            ),
        ],
      ),
    );
  }

  Widget _statusIcon(TestStatus status) {
    switch (status) {
      case TestStatus.idle:
        return const Icon(Icons.circle_outlined,
            color: DiagnosticsColors.textDim, size: 18);
      case TestStatus.running:
        return const SizedBox(
          width: 18,
          height: 18,
          child: CircularProgressIndicator(
            strokeWidth: 2,
            color: DiagnosticsColors.cyan,
          ),
        );
      case TestStatus.completed:
        return const Icon(Icons.check_circle,
            color: DiagnosticsColors.green, size: 18);
      case TestStatus.error:
        return const Icon(Icons.error,
            color: DiagnosticsColors.red, size: 18);
    }
  }

  Widget _buildResultData(Map<String, dynamic> data) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 6, 14, 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: data.entries.map((e) {
          final value = _formatValue(e.value);
          return Padding(
            padding: const EdgeInsets.symmetric(vertical: 2),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Flexible(
                  child: Text(
                    e.key,
                    style: const TextStyle(
                      color: DiagnosticsColors.textDim,
                      fontSize: 12,
                    ),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                const SizedBox(width: 8),
                Text(
                  value,
                  style: TextStyle(
                    color: _valueColor(e.key, e.value),
                    fontSize: 12,
                    fontWeight: FontWeight.w500,
                    fontFamily: 'monospace',
                  ),
                ),
              ],
            ),
          );
        }).toList(),
      ),
    );
  }

  String _formatValue(dynamic val) {
    if (val == null) return '—';
    if (val is double) return val.toStringAsFixed(2);
    if (val is bool) return val ? 'Sí' : 'No';
    return val.toString();
  }

  Color _valueColor(String key, dynamic val) {
    if (val is bool) {
      return val ? DiagnosticsColors.green : DiagnosticsColors.red;
    }
    if (key.contains('error') || key.contains('Error')) {
      return DiagnosticsColors.red;
    }
    if (key == 'available' && val == false) return DiagnosticsColors.red;
    if (key == 'clipCount' && val is int && val > 0) {
      return DiagnosticsColors.red;
    }
    if (key == 'callbackUnderruns' && val is int && val > 0) {
      return DiagnosticsColors.red;
    }
    if (key == 'mpoLimitingSustained' && val == true) {
      return DiagnosticsColors.red;
    }
    return DiagnosticsColors.text;
  }
}
