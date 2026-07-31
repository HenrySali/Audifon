/// @file patient_response_button.dart
/// @brief Botón principal de respuesta del paciente durante la audiometría.
///
/// Versión independiente (no comparte clase con `ToneResponseButton` del módulo
/// de calibración biológica) para poder evolucionar la UX de paciente sin
/// arrastrar el flujo del operador. Conserva la misma estética: botón grande,
/// tipografía y colores diferenciados por etapa, animación de scale + ripple
/// al tocar y feedback haptic medio.
///
/// Estados ([PatientButtonStage]):
///   - waiting   → esperando próximo tono (deshabilitado).
///   - playing   → tono sonando, paciente escuchando.
///   - listening → ventana de respuesta abierta (azul vivo, "🔊 LO ESCUCHO").
///   - recorded  → respuesta tomada (verde "Registrado" o naranja "Sin respuesta").
///
/// Compatibilidad Flutter 3.19.6: usa `withOpacity` (no `withValues`).
///
/// Referencias:
///  - design.md §"Pantalla principal" / "Widgets UI"
///  - tasks.md §4 "Widgets UI"
///  - requirements.md §6 "UI clara al paciente"
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// Etapa visual del botón de respuesta del paciente.
enum PatientButtonStage {
  /// Sin presentación activa — botón deshabilitado, "Esperando".
  waiting,

  /// Reproduciendo tono — habilitado, color tenue, indica "estoy sonando".
  playing,

  /// Tono terminó, ventana de respuesta abierta — color vivo, "ahora".
  listening,

  /// Acaba de registrarse una respuesta — verde "✓ Registrado" o equivalente.
  recorded,
}

/// Botón grande de respuesta para que el paciente indique que escuchó el tono.
class PatientResponseButton extends StatefulWidget {
  const PatientResponseButton({
    super.key,
    required this.onPressed,
    this.stage = PatientButtonStage.listening,
    this.lastResponseHeard,
  });

  /// Callback al pulsar. Si es `null`, el botón aparece deshabilitado.
  final VoidCallback? onPressed;

  /// Estado externo del flujo de presentaciones.
  final PatientButtonStage stage;

  /// Si la última respuesta fue "lo escuché" (true) o no (false).
  /// Se usa con [stage] = recorded para diferenciar el feedback visual.
  final bool? lastResponseHeard;

  @override
  State<PatientResponseButton> createState() => _PatientResponseButtonState();
}

class _PatientResponseButtonState extends State<PatientResponseButton>
    with SingleTickerProviderStateMixin {
  late final AnimationController _scaleController;
  late final Animation<double> _scaleAnim;

  @override
  void initState() {
    super.initState();
    _scaleController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 90),
      reverseDuration: const Duration(milliseconds: 220),
      lowerBound: 0.92,
      upperBound: 1.0,
      value: 1.0,
    );
    _scaleAnim = CurvedAnimation(
      parent: _scaleController,
      curve: Curves.easeOut,
      reverseCurve: Curves.easeInOut,
    );
  }

  @override
  void dispose() {
    _scaleController.dispose();
    super.dispose();
  }

  void _handleTap() {
    HapticFeedback.mediumImpact();
    // Animación rápida de scale-down y vuelta al tamaño original.
    _scaleController.value = 0.92;
    _scaleController.forward(from: 0.92);
    widget.onPressed?.call();
  }

  ({Color background, Color foreground, String label, IconData icon})
      _styleForStage(BuildContext context) {
    final ColorScheme colors = Theme.of(context).colorScheme;
    switch (widget.stage) {
      case PatientButtonStage.waiting:
        return (
          background: colors.surfaceVariant,
          foreground: colors.onSurfaceVariant.withOpacity(0.6),
          label: 'Esperando próximo tono…',
          icon: Icons.hourglass_empty,
        );
      case PatientButtonStage.playing:
        return (
          background: colors.primary.withOpacity(0.55),
          foreground: colors.onPrimary,
          label: '🔊 Sonando… escuchá con atención',
          icon: Icons.graphic_eq,
        );
      case PatientButtonStage.listening:
        return (
          background: colors.primary,
          foreground: colors.onPrimary,
          label: '🔊 LO ESCUCHO',
          icon: Icons.touch_app,
        );
      case PatientButtonStage.recorded:
        final bool heard = widget.lastResponseHeard ?? false;
        return (
          background: heard ? Colors.green.shade600 : Colors.orange.shade700,
          foreground: Colors.white,
          label: heard ? '✓ Registrado' : '— Sin respuesta',
          icon: heard ? Icons.check_circle : Icons.timer_off,
        );
    }
  }

  @override
  Widget build(BuildContext context) {
    final bool enabled = widget.onPressed != null &&
        (widget.stage == PatientButtonStage.listening ||
            widget.stage == PatientButtonStage.playing);
    final style = _styleForStage(context);

    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        final double width = constraints.maxWidth * 0.88;
        return Center(
          child: ScaleTransition(
            scale: _scaleAnim,
            child: SizedBox(
              width: width,
              height: 120,
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 180),
                curve: Curves.easeOut,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(20),
                  boxShadow: enabled
                      ? <BoxShadow>[
                          BoxShadow(
                            color: style.background.withOpacity(0.45),
                            blurRadius: 16,
                            spreadRadius: 1,
                            offset: const Offset(0, 4),
                          ),
                        ]
                      : const <BoxShadow>[],
                ),
                child: Material(
                  color: style.background,
                  elevation: 0,
                  borderRadius: BorderRadius.circular(20),
                  child: InkWell(
                    borderRadius: BorderRadius.circular(20),
                    onTap: enabled ? _handleTap : null,
                    splashColor: Colors.white.withOpacity(0.3),
                    highlightColor: Colors.white.withOpacity(0.1),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 16),
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: <Widget>[
                          Icon(style.icon, color: style.foreground, size: 36),
                          const SizedBox(width: 14),
                          Flexible(
                            child: Text(
                              style.label,
                              textAlign: TextAlign.center,
                              style: TextStyle(
                                fontSize: 24,
                                fontWeight: FontWeight.w700,
                                color: style.foreground,
                                letterSpacing: 0.4,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}
