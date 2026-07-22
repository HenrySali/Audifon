/// @file audiometry_progress_widget.dart
/// @brief Indicador de progreso de la audiometría tonal del paciente.
///
/// Muestra:
///   - Frecuencia actual ("Frecuencia X Hz") y nivel HL emitido en este momento.
///   - Barra de progreso global de frecuencias (currentFreqIndex / totalFreqs).
///   - Texto de estado opcional ("retest 1000 Hz", "fuera de rango", etc.).
///
/// Estética alineada con `CalibrationProgressIndicatorWidget` (Card + barras
/// con etiqueta) pero simplificada: un solo eje de progreso (frecuencias) y
/// un panel destacado con el nivel HL en curso.
///
/// Compatibilidad Flutter 3.19.6: usa `withOpacity` (no `withValues`).
///
/// Referencias:
///  - design.md §"Pantalla principal" / "Widgets UI"
///  - tasks.md §4 "Widgets UI"
///  - requirements.md §6 "UI clara al paciente"
library;

import 'package:flutter/material.dart';

/// Widget de progreso visual para la audiometría del paciente.
class AudiometryProgressWidget extends StatelessWidget {
  const AudiometryProgressWidget({
    super.key,
    required this.currentFreqIndex,
    required this.totalFreqs,
    required this.currentFreqHz,
    required this.currentLevelHL,
    this.statusText,
  });

  /// Índice 0-based de la frecuencia actual dentro del orden ASHA.
  final int currentFreqIndex;

  /// Total de frecuencias del protocolo (típicamente 6).
  final int totalFreqs;

  /// Frecuencia activa en Hz (ej: 1000).
  final int currentFreqHz;

  /// Nivel actual de presentación en dB HL (puede ser negativo).
  final double currentLevelHL;

  /// Texto opcional debajo de la barra (estado, advertencias, retest).
  final String? statusText;

  @override
  Widget build(BuildContext context) {
    final ColorScheme colors = Theme.of(context).colorScheme;

    final int safeTotal = totalFreqs > 0 ? totalFreqs : 1;
    final double freqProgress =
        currentFreqIndex.clamp(0, safeTotal) / safeTotal;

    // 1-based para mostrar al usuario.
    final int displayIndex =
        (currentFreqIndex + 1).clamp(1, safeTotal).toInt();

    return Card(
      margin: const EdgeInsets.all(12),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            // Línea: "Frecuencia X de N · X Hz"
            Row(
              children: <Widget>[
                Icon(Icons.graphic_eq, size: 22, color: colors.primary),
                const SizedBox(width: 6),
                Text(
                  'Frecuencia $displayIndex de $safeTotal',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                const Spacer(),
                Text(
                  '$currentFreqHz Hz',
                  style: Theme.of(context).textTheme.titleLarge?.copyWith(
                        fontWeight: FontWeight.w700,
                        color: colors.primary,
                      ),
                ),
              ],
            ),
            const SizedBox(height: 12),

            // Panel destacado con nivel HL actual.
            Container(
              padding:
                  const EdgeInsets.symmetric(vertical: 12, horizontal: 16),
              decoration: BoxDecoration(
                color: colors.primaryContainer.withOpacity(0.6),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(
                  color: colors.outlineVariant.withOpacity(0.6),
                ),
              ),
              child: Row(
                children: <Widget>[
                  Icon(Icons.volume_up, color: colors.onPrimaryContainer),
                  const SizedBox(width: 10),
                  Text(
                    'Nivel actual:',
                    style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                          color: colors.onPrimaryContainer,
                        ),
                  ),
                  const Spacer(),
                  Text(
                    '${currentLevelHL.toStringAsFixed(0)} dB HL',
                    style: Theme.of(context).textTheme.titleLarge?.copyWith(
                          fontWeight: FontWeight.w700,
                          color: colors.onPrimaryContainer,
                        ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 12),

            // Barra de progreso de frecuencias.
            _buildLabeledBar(
              context: context,
              label: 'Progreso del test',
              value: freqProgress.clamp(0.0, 1.0),
              color: colors.primary,
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
