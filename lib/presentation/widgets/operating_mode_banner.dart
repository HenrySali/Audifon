import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../domain/audiogram_driven_presets/operating_mode.dart';
import '../bloc/amplification_bloc.dart';
import '../bloc/amplification_state.dart';

/// Banner persistente que informa al usuario cuando la app opera en
/// Modo Amplificador (sin audiometría medida).
///
/// Se muestra automáticamente cuando `state.operatingMode == OperatingMode.amplifier`
/// y se oculta al transicionar a Modo Diagnóstico.
///
/// Estilo: contenedor ámbar/warning con ícono de advertencia y texto
/// descriptivo del disclaimer clínico.
///
/// Requisitos: 13.10, 5.6
class OperatingModeBanner extends StatelessWidget {
  const OperatingModeBanner({super.key});

  /// Texto del disclaimer clínico mostrado en Modo Amplificador.
  ///
  /// Ref: Requirement 13.10
  static const disclaimerText =
      'Modo Amplificador \u2014 sin audiometr\u00eda medida. '
      'Las ganancias se estiman con perfil gen\u00e9rico.';

  @override
  Widget build(BuildContext context) {
    return BlocBuilder<AmplificationBloc, AmplificationState>(
      buildWhen: (previous, current) {
        final prevMode = previous is AmplificationActive
            ? previous.operatingMode
            : null;
        final currMode = current is AmplificationActive
            ? current.operatingMode
            : null;
        return prevMode != currMode;
      },
      builder: (context, state) {
        if (state is! AmplificationActive) return const SizedBox.shrink();
        if (state.operatingMode != OperatingMode.amplifier) {
          return const SizedBox.shrink();
        }

        return Semantics(
          label: disclaimerText,
          container: true,
          liveRegion: true,
          child: Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            decoration: BoxDecoration(
              color: Colors.amber.shade100,
              border: Border(
                bottom: BorderSide(color: Colors.amber.shade400, width: 1),
              ),
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(
                  Icons.warning_amber_rounded,
                  color: Colors.amber.shade800,
                  size: 24,
                  semanticLabel: 'Advertencia',
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    disclaimerText,
                    style: TextStyle(
                      color: Colors.amber.shade900,
                      fontSize: 13,
                      fontWeight: FontWeight.w500,
                      height: 1.4,
                    ),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}
