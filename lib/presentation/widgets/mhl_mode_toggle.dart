import 'package:flutter/material.dart';

import 'mode_toggles.dart';

/// Wrapper legacy del toggle "MHL Prescripción".
///
/// Este widget existió antes de la introducción de `ModeToggles` (que
/// renderiza dos toggles independientes: "MHL Prescripción" y "Modo
/// Música"). Para no romper screens viejas que lo importan (p. ej.
/// `main_screen.dart`), `MhlModeToggle` se mantiene con su API pública
/// original (`isActive`, `ptaWarning`, `onToggled`, `enabled`) y su
/// comportamiento visual anterior:
///
/// - Renderiza únicamente el toggle de "MHL Prescripción" (sin el de
///   "Modo Música") delegando en `ModeToggles` con `showMusic: false`.
/// - Conserva el banner de advertencia PTA cuando MHL está activo y
///   `ptaWarning == true`, ya que es comportamiento legacy ligado a la
///   semántica del antiguo "Modo MHL" y no al nuevo "MHL Prescripción"
///   genérico.
///
/// Indicadores visuales heredados:
/// - Toggle activo sin warning: acento cyan (color del nuevo
///   `ModeToggles` para MHL Prescripción).
/// - Toggle activo con warning: acento cyan + banner ámbar debajo.
/// - Toggle inactivo: color neutro.
///
/// Para código nuevo, preferir usar `ModeToggles` directamente y manejar
/// el chequeo PTA fuera del widget.
///
/// Ejemplo de uso (legacy):
/// ```dart
/// MhlModeToggle(
///   isActive: state.mhlActive,
///   ptaWarning: state.ptaWarning,
///   onToggled: (activate) => bloc.add(ToggleMhlMode(activate: activate)),
/// )
/// ```
///
/// Requisitos: 1.12, 4.3, 4.5, 4.6
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
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        // Delega el render del toggle MHL en `ModeToggles` con el toggle de
        // "Modo Música" oculto. Esto garantiza que el visual y el contrato
        // de callbacks sea exactamente el del nuevo widget compartido.
        ModeToggles(
          mhlPrescription: isActive,
          musicMode: false,
          onMhlChanged: onToggled,
          onMusicChanged: _noop,
          enabled: enabled,
          showMusic: false,
        ),
        // Banner PTA legacy: solo cuando MHL activo y warning presente.
        if (isActive && ptaWarning) ...[
          const SizedBox(height: 8),
          const _PtaWarningBanner(),
        ],
      ],
    );
  }

  // No-op para satisfacer el contrato `required` de `onMusicChanged` sin
  // efectos colaterales. Como `showMusic: false`, este callback nunca se
  // dispara desde la UI.
  static void _noop(bool _) {}
}

/// Banner de advertencia PTA que se muestra cuando el PTA del paciente
/// supera 25 dB HL estando en modo MHL.
///
/// Indica que el paciente podría beneficiarse de una prescripción
/// estándar (quiet o CIN) en lugar de MHL.
///
/// Requisito 4.3
class _PtaWarningBanner extends StatelessWidget {
  const _PtaWarningBanner();

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
