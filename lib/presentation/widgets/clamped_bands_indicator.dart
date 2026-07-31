import 'package:flutter/material.dart';

import '../../scene/smart_preset.dart';

/// Indicador visual de bandas que tocaron el clamp de headroom MPO.
///
/// Renderiza una fila de 12 indicadores (uno por banda del EQ) donde
/// las bandas cuyo gain objetivo excedió el techo de headroom MPO se
/// resaltan en color warning (naranja), y las bandas sin clamp se
/// muestran en gris neutro.
///
/// Usa el campo `clampedBands` del [SmartPreset] (lista de índices 0..11).
///
/// Requisitos: 10.6
class ClampedBandsIndicator extends StatelessWidget {
  /// Lista de índices de banda (0..11) que fueron clampados.
  final List<int> clampedBands;

  /// Cantidad total de bandas del EQ.
  static const int _totalBands = 12;

  /// Labels de frecuencia para tooltips.
  static const List<String> _bandLabels = [
    '250 Hz',
    '500 Hz',
    '750 Hz',
    '1 kHz',
    '1.5 kHz',
    '2 kHz',
    '2.5 kHz',
    '3 kHz',
    '3.5 kHz',
    '4 kHz',
    '6 kHz',
    '8 kHz',
  ];

  const ClampedBandsIndicator({super.key, required this.clampedBands});

  /// Construye el indicador directamente desde un [SmartPreset].
  factory ClampedBandsIndicator.fromPreset(SmartPreset preset, {Key? key}) {
    return ClampedBandsIndicator(
      key: key,
      clampedBands: preset.clampedBands,
    );
  }

  @override
  Widget build(BuildContext context) {
    if (clampedBands.isEmpty) return const SizedBox.shrink();

    final clampedSet = clampedBands.toSet();

    return Semantics(
      label:
          '${clampedBands.length} de $_totalBands bandas tienen ganancia limitada por protección MPO',
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                Icon(
                  Icons.vertical_align_top,
                  size: 16,
                  color: Colors.orange.shade700,
                ),
                const SizedBox(width: 6),
                Text(
                  'Bandas limitadas por MPO',
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: Colors.orange.shade800,
                        fontWeight: FontWeight.w500,
                      ),
                ),
              ],
            ),
            const SizedBox(height: 6),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
              children: List.generate(_totalBands, (index) {
                final isClamped = clampedSet.contains(index);
                return Tooltip(
                  message: isClamped
                      ? '${_bandLabels[index]} — Ganancia limitada por protección MPO'
                      : _bandLabels[index],
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 200),
                    width: 20,
                    height: isClamped ? 28 : 16,
                    decoration: BoxDecoration(
                      color: isClamped
                          ? Colors.orange.shade400
                          : Colors.grey.shade300,
                      borderRadius: BorderRadius.circular(4),
                      border: isClamped
                          ? Border.all(
                              color: Colors.orange.shade700, width: 1)
                          : null,
                    ),
                  ),
                );
              }),
            ),
            const SizedBox(height: 4),
            Text(
              '${clampedBands.length} de $_totalBands bandas alcanzaron el límite MPO',
              style: Theme.of(context).textTheme.labelSmall?.copyWith(
                    color: Colors.grey.shade600,
                  ),
            ),
          ],
        ),
      ),
    );
  }
}
