import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../domain/audiogram_driven_presets/operating_mode.dart';
import '../bloc/amplification_bloc.dart';
import '../bloc/amplification_event.dart';
import '../bloc/amplification_state.dart';

/// Slider para ajustar el factor de escala de ganancia (`gainScale`)
/// en Modo Amplificador.
///
/// Visible SOLO cuando `operatingMode == OperatingMode.amplifier`;
/// se oculta completamente en Modo Diagnóstico (Req 13.11).
///
/// Rango: [0.10, 1.00], step 0.05, divisions = 18.
/// Label: "Intensidad de amplificación" con display de porcentaje.
/// On change end: despacha `GainScaleChanged(gainScale: value)`.
///
/// Requisitos: 13.5, 13.6, 13.11
class GainScaleSlider extends StatefulWidget {
  const GainScaleSlider({super.key});

  /// Valor mínimo permitido del gain scale.
  static const double min = 0.10;

  /// Valor máximo permitido del gain scale.
  static const double max = 1.00;

  /// Número de divisiones discretas: (1.00 - 0.10) / 0.05 = 18.
  static const int divisions = 18;

  @override
  State<GainScaleSlider> createState() => _GainScaleSliderState();
}

class _GainScaleSliderState extends State<GainScaleSlider> {
  /// Valor local mientras el usuario arrastra el slider (feedback visual
  /// inmediato sin despachar al bloc en cada paso intermedio).
  double? _localValue;

  @override
  Widget build(BuildContext context) {
    return BlocBuilder<AmplificationBloc, AmplificationState>(
      buildWhen: (previous, current) {
        if (current is! AmplificationActive) return true;
        if (previous is! AmplificationActive) return true;
        return previous.operatingMode != current.operatingMode ||
            previous.gainScale != current.gainScale;
      },
      builder: (context, state) {
        if (state is! AmplificationActive) return const SizedBox.shrink();

        // En Modo Diagnóstico: oculto (Req 13.5, 13.11).
        if (state.operatingMode != OperatingMode.amplifier) {
          return const SizedBox.shrink();
        }

        final gainScale = _localValue ?? state.gainScale;
        final percentage = (gainScale * 100).round();

        return Semantics(
          label: 'Intensidad de amplificación: $percentage por ciento',
          slider: true,
          value: '$percentage%',
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(
                      'Intensidad de amplificación',
                      style: Theme.of(context).textTheme.titleSmall,
                    ),
                    Text(
                      '$percentage%',
                      style: Theme.of(context).textTheme.titleSmall?.copyWith(
                            fontWeight: FontWeight.bold,
                          ),
                    ),
                  ],
                ),
                Slider(
                  value: gainScale,
                  min: GainScaleSlider.min,
                  max: GainScaleSlider.max,
                  divisions: GainScaleSlider.divisions,
                  label: '$percentage%',
                  semanticFormatterCallback: (value) =>
                      '${(value * 100).round()} por ciento',
                  onChanged: (value) {
                    // Feedback visual inmediato sin despachar al bloc.
                    setState(() {
                      _localValue = value;
                    });
                  },
                  onChangeEnd: (value) {
                    // Despacha al bloc al soltar: reconstruye bundle (Req 13.6).
                    setState(() {
                      _localValue = null;
                    });
                    context
                        .read<AmplificationBloc>()
                        .add(GainScaleChanged(gainScale: value));
                  },
                ),
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(
                      '10%',
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                            color: Colors.grey,
                          ),
                    ),
                    Text(
                      '100%',
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                            color: Colors.grey,
                          ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}
