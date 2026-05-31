/// @file tone_response_button.dart
/// @brief Botón principal de respuesta del sujeto durante el test ("LO ESCUCHO").
///
/// Este botón ocupa una franja amplia (mínimo 80% del ancho disponible) y
/// usa tipografía grande para minimizar errores de pulsación durante la
/// calibración. Al tocarse, dispara `HapticFeedback.mediumImpact()` para
/// confirmar la pulsación al sujeto incluso si no escuchó nada (evita
/// dudas sobre si "registró" o no la respuesta).
///
/// Compatibilidad Flutter 3.19.6: usa `withOpacity` (no `withValues`).

library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// Botón grande de respuesta para que el sujeto indique que escuchó el tono.
///
/// El callback [onPressed] puede ser `null` para deshabilitar el botón
/// (por ejemplo, fuera de la ventana de respuesta o en pausa). En ese caso
/// el botón se muestra atenuado y no dispara haptic feedback.
class ToneResponseButton extends StatelessWidget {
  const ToneResponseButton({
    super.key,
    required this.onPressed,
    this.label = '🔊 LO ESCUCHO',
  });

  /// Callback al pulsar. Si es `null`, el botón aparece deshabilitado.
  final VoidCallback? onPressed;

  /// Texto principal del botón. Por defecto "🔊 LO ESCUCHO".
  final String label;

  @override
  Widget build(BuildContext context) {
    final ColorScheme colors = Theme.of(context).colorScheme;
    final bool enabled = onPressed != null;

    // Color azul-verde llamativo basado en el primary del tema, con un
    // overlay que lo hace inconfundible cuando está habilitado.
    final Color background =
        enabled ? colors.primary : colors.primary.withOpacity(0.35);
    final Color foreground =
        enabled ? colors.onPrimary : colors.onPrimary.withOpacity(0.7);

    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        // Ancho mínimo 80% del disponible.
        final double width = constraints.maxWidth * 0.85;
        return Center(
          child: SizedBox(
            width: width,
            height: 96,
            child: Material(
              color: background,
              elevation: enabled ? 4 : 0,
              shadowColor: colors.primary.withOpacity(0.4),
              borderRadius: BorderRadius.circular(20),
              child: InkWell(
                borderRadius: BorderRadius.circular(20),
                onTap: enabled
                    ? () {
                        HapticFeedback.mediumImpact();
                        onPressed!();
                      }
                    : null,
                child: Center(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                    child: Text(
                      label,
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        fontSize: 26,
                        fontWeight: FontWeight.w700,
                        color: foreground,
                        letterSpacing: 0.5,
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
