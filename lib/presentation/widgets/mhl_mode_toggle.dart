import 'package:flutter/material.dart';

/// Toggle de Modo MHL (Minimal Hearing Loss) para la UI principal.
///
/// Muestra un switch interactivo que permite al usuario activar/desactivar
/// el modo MHL de forma explícita. Cuando MHL está activo, se aplica
/// ganancia flat mínima con reducción de ruido máxima.
///
/// Indicadores visuales:
/// - Toggle activo sin warning: color verde (MHL activo, PTA ≤ 25 dB).
/// - Toggle activo con warning: color ámbar + icono de advertencia
///   (MHL activo pero PTA > 25 dB, se recomienda prescripción estándar).
/// - Toggle inactivo: color neutro (MHL desactivado).
///
/// Ejemplo de uso:
/// ```dart
/// MhlModeToggle(
///   isActive: state.mhlActive,
///   ptaWarning: state.ptaWarning,
///   onToggled: (activate) => bloc.add(ToggleMhlMode(activate: activate)),
/// )
/// ```
///
/// Requisitos: 4.3, 4.5, 4.6
class MhlModeToggle extends StatelessWidget {
  /// Si el modo MHL está actualmente activo.
  final bool isActive;

  /// Si el PTA del paciente supera 25 dB HL (advertencia visible).
  final bool ptaWarning;

  /// Callback cuando el usuario toca el toggle.
  /// Recibe `true` para activar MHL, `false` para desactivar.
  final ValueChanged<bool> onToggled;

  /// Si el toggle está habilitado para interacción.
  final bool enabled;

  const MhlModeToggle({
    super.key,
    required this.isActive,
    required this.ptaWarning,
    required this.onToggled,
    this.enabled = true,
  });

  @override
  Widget build(BuildContext context) {
    // Determinar colores según estado activo y warning.
    final Color accentColor;
    if (isActive && ptaWarning) {
      accentColor = Colors.amber;
    } else if (isActive) {
      accentColor = Colors.greenAccent;
    } else {
      accentColor = Colors.white38;
    }

    final borderColor = isActive ? accentColor : Colors.white24;
    final backgroundColor = isActive
        ? accentColor.withOpacity(0.12)
        : Colors.transparent;

    return AnimatedContainer(
      duration: const Duration(milliseconds: 200),
      curve: Curves.easeInOut,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: backgroundColor,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: borderColor.withOpacity(0.5),
          width: isActive ? 1.5 : 0.5,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          // Encabezado con icono, título y switch
          Row(
            children: [
              Icon(
                Icons.noise_aware,
                color: accentColor,
                size: 18,
              ),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  'Modo MHL',
                  style: TextStyle(
                    color: isActive ? accentColor : Colors.white70,
                    fontSize: 13,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ),
              // Switch de activación
              SizedBox(
                height: 28,
                child: Switch(
                  value: isActive,
                  onChanged: enabled ? onToggled : null,
                  activeColor: accentColor,
                  activeTrackColor: accentColor.withOpacity(0.3),
                  inactiveThumbColor: Colors.white38,
                  inactiveTrackColor: Colors.white12,
                  materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          // Subtítulo descriptivo
          Text(
            isActive
                ? 'Ganancia mínima · NR máximo · Compresión lineal'
                : 'Pérdida mínima / dificultad en ruido',
            style: TextStyle(
              color: isActive
                  ? accentColor.withOpacity(0.7)
                  : Colors.white38,
              fontSize: 10,
            ),
          ),
          // Advertencia PTA (visible solo cuando MHL activo y PTA > 25)
          if (isActive && ptaWarning) ...[
            const SizedBox(height: 8),
            _PtaWarningBanner(),
          ],
        ],
      ),
    );
  }
}

/// Banner de advertencia PTA que se muestra cuando el PTA del paciente
/// supera 25 dB HL estando en modo MHL.
///
/// Indica que el paciente podría beneficiarse de una prescripción
/// estándar (quiet o CIN) en lugar de MHL.
///
/// Requisito 4.3
class _PtaWarningBanner extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: Colors.amber.withOpacity(0.12),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(
          color: Colors.amber.withOpacity(0.4),
          width: 1,
        ),
      ),
      child: const Row(
        children: [
          Icon(
            Icons.warning_amber_rounded,
            color: Colors.amber,
            size: 16,
          ),
          SizedBox(width: 8),
          Expanded(
            child: Text(
              'PTA > 25 dB HL — Se recomienda prescripción estándar '
              'para este perfil auditivo.',
              style: TextStyle(
                color: Colors.amber,
                fontSize: 11,
                height: 1.3,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
