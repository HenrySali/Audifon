import 'package:flutter/material.dart';

import '../../domain/entities/prescription_mode.dart';

/// Selector de modo de prescriptor (Smart-NL2 / Smart-NL3).
///
/// Muestra dos botones lado a lado que permiten al usuario alternar
/// entre el prescriptor NAL-NL2 existente y el NAL-NL3-inspired.
/// El modo activo se destaca con un borde cyan iluminado y un badge
/// de color. Al tocar un botón inactivo se dispara [onModeChanged].
///
/// Ejemplo de uso:
/// ```dart
/// PrescriberModeSelector(
///   currentMode: PrescriberMode.smartNl2,
///   onModeChanged: (mode) => _handleModeChange(mode),
/// )
/// ```
///
/// Requisitos: 5.1, 5.2, 5.3, 5.4, 5.5
class PrescriberModeSelector extends StatelessWidget {
  /// Modo de prescriptor actualmente activo.
  final PrescriberMode currentMode;

  /// Callback invocado cuando el usuario selecciona un modo diferente.
  /// Debe recalcular ganancias y aplicarlas al EQ en ≤ 200 ms.
  final ValueChanged<PrescriberMode> onModeChanged;

  /// Si los botones están habilitados para interacción.
  final bool enabled;

  const PrescriberModeSelector({
    super.key,
    required this.currentMode,
    required this.onModeChanged,
    this.enabled = true,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: const Color(0xFF16213e),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Título de la sección
          const Row(
            children: [
              Icon(Icons.hearing, color: Colors.cyan, size: 18),
              SizedBox(width: 6),
              Text(
                'Prescriptor',
                style: TextStyle(
                  color: Colors.white70,
                  fontSize: 13,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          // Botones de selección de modo
          Row(
            children: [
              Expanded(
                child: _ModeButton(
                  label: 'Smart-NL2',
                  subtitle: 'NAL-NL2 clásico',
                  mode: PrescriberMode.smartNl2,
                  isActive: currentMode == PrescriberMode.smartNl2,
                  enabled: enabled,
                  onTap: () => _selectMode(PrescriberMode.smartNl2),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: _ModeButton(
                  label: 'Smart-NL3',
                  subtitle: 'NL3 + CIN adaptativo',
                  mode: PrescriberMode.smartNl3,
                  isActive: currentMode == PrescriberMode.smartNl3,
                  enabled: enabled,
                  onTap: () => _selectMode(PrescriberMode.smartNl3),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  void _selectMode(PrescriberMode mode) {
    if (!enabled) return;
    if (mode != currentMode) {
      onModeChanged(mode);
    }
  }
}

/// Botón individual de modo de prescriptor con indicador visual de estado activo.
///
/// Cuando [isActive] es true, muestra un borde cyan destacado y un badge
/// de color verde que confirma el modo seleccionado.
class _ModeButton extends StatelessWidget {
  final String label;
  final String subtitle;
  final PrescriberMode mode;
  final bool isActive;
  final bool enabled;
  final VoidCallback onTap;

  const _ModeButton({
    required this.label,
    required this.subtitle,
    required this.mode,
    required this.isActive,
    required this.enabled,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    // Colores según estado activo/inactivo.
    final borderColor = isActive ? Colors.cyan : Colors.white24;
    final borderWidth = isActive ? 2.0 : 1.0;
    final backgroundColor = isActive
        ? Colors.cyan.withOpacity(0.15)
        : Colors.transparent;
    final textColor = isActive ? Colors.cyan : Colors.white54;
    final subtitleColor = isActive ? Colors.cyan.withOpacity(0.7) : Colors.white38;

    return GestureDetector(
      onTap: enabled ? onTap : null,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        curve: Curves.easeInOut,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
        decoration: BoxDecoration(
          color: backgroundColor,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(
            color: borderColor,
            width: borderWidth,
          ),
          boxShadow: isActive
              ? [
                  BoxShadow(
                    color: Colors.cyan.withOpacity(0.2),
                    blurRadius: 8,
                    spreadRadius: 0,
                  ),
                ]
              : null,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // Badge de estado activo
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                if (isActive)
                  Container(
                    width: 8,
                    height: 8,
                    margin: const EdgeInsets.only(right: 6),
                    decoration: const BoxDecoration(
                      color: Colors.greenAccent,
                      shape: BoxShape.circle,
                    ),
                  ),
                Text(
                  label,
                  style: TextStyle(
                    color: textColor,
                    fontSize: 14,
                    fontWeight: isActive ? FontWeight.bold : FontWeight.w500,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              subtitle,
              style: TextStyle(
                color: subtitleColor,
                fontSize: 10,
              ),
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }
}
