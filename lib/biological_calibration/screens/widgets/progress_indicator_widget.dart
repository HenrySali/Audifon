/// @file progress_indicator_widget.dart
/// @brief Indicador visual de progreso de la calibración biológica.
///
/// Muestra dos barras de progreso superpuestas:
///
///   - Sujetos completados (de [totalSubjects])
///   - Frecuencias completadas dentro del sujeto actual (de [totalFreqs])
///
/// Adicionalmente, presenta un texto descriptivo ("Sujeto X de Y, Freq Z de W")
/// y un texto de estado opcional debajo (estado del algoritmo, advertencia, etc.).
///
/// Compatibilidad Flutter 3.19.6: usa `withOpacity` (no `withValues`).

library;

import 'package:flutter/material.dart';

/// Widget de progreso visual para la calibración biológica.
class CalibrationProgressIndicatorWidget extends StatelessWidget {
  const CalibrationProgressIndicatorWidget({
    super.key,
    required this.currentSubject,
    required this.totalSubjects,
    required this.currentFreqIndex,
    required this.totalFreqs,
    this.statusText,
  });

  /// Índice 1-based del sujeto en curso.
  final int currentSubject;

  /// Total de sujetos esperados (mínimo 3).
  final int totalSubjects;

  /// Índice 0-based de la frecuencia en curso dentro del sujeto.
  final int currentFreqIndex;

  /// Total de frecuencias del protocolo (típicamente 6).
  final int totalFreqs;

  /// Texto opcional debajo del progreso (estado, advertencias, etc.).
  final String? statusText;

  @override
  Widget build(BuildContext context) {
    final ColorScheme colors = Theme.of(context).colorScheme;

    final int safeTotalSubjects = totalSubjects > 0 ? totalSubjects : 1;
    final int safeTotalFreqs = totalFreqs > 0 ? totalFreqs : 1;
    final double subjectProgress =
        (currentSubject - 1).clamp(0, safeTotalSubjects) / safeTotalSubjects;
    final double freqProgress =
        currentFreqIndex.clamp(0, safeTotalFreqs) / safeTotalFreqs;

    return Card(
      margin: const EdgeInsets.all(12),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            // Línea: "Sujeto X de Y · Freq Z de W"
            Row(
              children: <Widget>[
                Icon(Icons.person_outline,
                    size: 20, color: colors.primary),
                const SizedBox(width: 6),
                Text(
                  'Sujeto $currentSubject de $totalSubjects',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                const SizedBox(width: 12),
                Icon(Icons.graphic_eq, size: 20, color: colors.primary),
                const SizedBox(width: 6),
                Text(
                  'Freq ${currentFreqIndex + 1} de $totalFreqs',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
              ],
            ),
            const SizedBox(height: 12),

            // Barra de sujetos.
            _buildLabeledBar(
              context: context,
              label: 'Progreso de sujetos',
              value: subjectProgress.clamp(0.0, 1.0),
              color: colors.primary,
            ),
            const SizedBox(height: 8),

            // Barra de frecuencias.
            _buildLabeledBar(
              context: context,
              label: 'Progreso de frecuencias',
              value: freqProgress.clamp(0.0, 1.0),
              color: colors.tertiary,
            ),

            if (statusText != null && statusText!.isNotEmpty) ...<Widget>[
              const SizedBox(height: 12),
              Text(
                statusText!,
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: colors.onSurface.withOpacity(0.7),
                    ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildLabeledBar({
    required BuildContext context,
    required String label,
    required double value,
    required Color color,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: <Widget>[
            Text(
              label,
              style: Theme.of(context).textTheme.bodySmall,
            ),
            Text(
              '${(value * 100).round()}%',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
        ),
        const SizedBox(height: 4),
        ClipRRect(
          borderRadius: BorderRadius.circular(6),
          child: LinearProgressIndicator(
            value: value,
            minHeight: 8,
            backgroundColor: color.withOpacity(0.18),
            valueColor: AlwaysStoppedAnimation<Color>(color),
          ),
        ),
      ],
    );
  }
}
