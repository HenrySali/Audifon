import 'package:flutter/material.dart';

import '../theme/diagnostics_colors.dart';

/// Barra de control superior con botón "Ejecutar Todos" y contadores.
class DiagnosticsControlBar extends StatelessWidget {
  final bool allRunning;
  final int completedCount;
  final int errorCount;
  final VoidCallback onRunAll;

  const DiagnosticsControlBar({
    super.key,
    required this.allRunning,
    required this.completedCount,
    required this.errorCount,
    required this.onRunAll,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      decoration: const BoxDecoration(
        color: DiagnosticsColors.surface,
        border: Border(
          bottom: BorderSide(color: DiagnosticsColors.accent, width: 1),
        ),
      ),
      child: Row(
        children: [
          ElevatedButton.icon(
            onPressed: allRunning ? null : onRunAll,
            icon: allRunning
                ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: DiagnosticsColors.text,
                    ),
                  )
                : const Icon(Icons.play_arrow, size: 18),
            label: Text(allRunning ? 'Ejecutando...' : 'Ejecutar Todos'),
            style: ElevatedButton.styleFrom(
              backgroundColor: DiagnosticsColors.cyan,
              foregroundColor: DiagnosticsColors.bg,
              padding:
                  const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              textStyle: const TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          const SizedBox(width: 16),
          Text(
            '$completedCount/13 completados',
            style: const TextStyle(
              color: DiagnosticsColors.textDim,
              fontSize: 13,
            ),
          ),
          if (errorCount > 0) ...[
            const SizedBox(width: 8),
            Text(
              '$errorCount errores',
              style: const TextStyle(
                color: DiagnosticsColors.red,
                fontSize: 13,
              ),
            ),
          ],
        ],
      ),
    );
  }
}
