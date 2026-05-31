/// @file tone_response_button.dart
/// @brief Botón principal de respuesta del sujeto durante el test ("LO ESCUCHO").
///
/// Características:
///  - Botón grande (mínimo 85% del ancho disponible) y alto, con tipografía
///    grande para minimizar errores de pulsación.
///  - Estado visible: el color y el texto cambian según [stage] (esperando,
///    sonando, escuchando, registrado), de modo que el sujeto y el operador
///    SIEMPRE saben qué está pasando.
///  - Feedback inmediato al tocar: animación de scale + ripple + haptic, así
///    se confirma que la pulsación quedó tomada aunque la respuesta sea null
///    (catch trial) o tardía.
///
/// Compatibilidad Flutter 3.19.6: usa `withOpacity` (no `withValues`).

library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// Estado externo que la UI le pasa al botón para que se pinte distinto.
///
/// Refleja `PresentationStage` del controller pero se mantiene independiente
/// para no acoplar el widget al modelo de dominio.
enum ToneResponseButtonStage {
  /// Sin presentación activa — botón deshabilitado / "Esperando".
  waiting,

  /// Reproduciendo tono — botón habilitado pero color tenue, indica
  /// "esperá a oír el tono y después tocá".
  playing,

  /// Tono terminó, ventana de respuesta abierta — botón en color vivo, "ahora".
  listening,

  /// Acaba de registrarse una respuesta — botón en verde "✓ Registrado".
  recorded,
}

/// Botón grande de respuesta para que el sujeto indique que escuchó el tono.
class ToneResponseButton extends StatefulWidget {
  const ToneResponseButton({
    super.key,
    required this.onPressed,
    this.stage = ToneResponseButtonStage.listening,
    this.lastResponseHeard,
  });

  /// Callback al pulsar. Si es `null`, el botón aparece deshabilitado.
  final VoidCallback? onPressed;

  /// Estado externo del flujo de presentaciones.
  final ToneResponseButtonStage stage;

  /// Si la última respuesta fue "lo escuché" (true) o no (false). Se usa
  /// junto con [stage] = recorded para mostrar feedback diferenciado.
  final bool? lastResponseHeard;

  @override
  State<ToneResponseButton> createState() => _ToneResponseButtonState();
}

class _ToneResponseButtonState extends State<ToneResponseButton>
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
      case ToneResponseButtonStage.waiting:
        return (
          background: colors.surfaceVariant,
          foreground: colors.onSurfaceVariant.withOpacity(0.6),
          label: 'Esperando próximo tono…',
          icon: Icons.hourglass_empty,
        );
      case ToneResponseButtonStage.playing:
        return (
          background: colors.primary.withOpacity(0.55),
          foreground: colors.onPrimary,
          label: '🔊 Sonando… escuchá',
          icon: Icons.graphic_eq,
        );
      case ToneResponseButtonStage.listening:
        return (
          background: colors.primary,
          foreground: colors.onPrimary,
          label: '🔊 LO ESCUCHO',
          icon: Icons.touch_app,
        );
      case ToneResponseButtonStage.recorded:
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
        (widget.stage == ToneResponseButtonStage.listening ||
            widget.stage == ToneResponseButtonStage.playing);
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
