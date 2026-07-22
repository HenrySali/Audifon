import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../domain/audiogram_driven_presets/audiogram_driven_bundle.dart';
import '../../domain/audiogram_driven_presets/manual_adjustment_delta.dart';
import '../bloc/amplification_bloc.dart';
import '../bloc/amplification_event.dart';
import '../bloc/amplification_state.dart';

/// Overlay de EQ manual que muestra simultáneamente:
/// - La curva base del bundle derivada del audiograma (línea de referencia)
/// - La curva con delta aplicado (`gainsDb[i] + eqDeltaDb[i] + volumeDeltaDb`)
///
/// Incluye sliders verticales por banda que despachan `ManualEqAdjust`,
/// labels de delta por banda ("+2 dB", "-1 dB"), y un botón "Restablecer"
/// que despacha `ResetManualDelta()`.
///
/// Accesibilidad: cada slider tiene semántica de banda (frecuencia + dB).
///
/// Requisitos: 14.11, 14.9
class ManualEqOverlay extends StatelessWidget {
  const ManualEqOverlay({super.key});

  /// Frecuencias estándar de las 12 bandas (Hz).
  static const List<int> _bandFrequenciesHz = [
    250, 500, 750, 1000, 1500, 2000, 2500, 3000, 3500, 4000, 6000, 8000,
  ];

  /// Labels compactos para cada banda.
  static const List<String> _bandLabels = [
    '250', '500', '750', '1k', '1.5k', '2k',
    '2.5k', '3k', '3.5k', '4k', '6k', '8k',
  ];

  @override
  Widget build(BuildContext context) {
    return BlocBuilder<AmplificationBloc, AmplificationState>(
      buildWhen: (previous, current) {
        if (current is! AmplificationActive) return true;
        if (previous is! AmplificationActive) return true;
        return previous.bundle != current.bundle ||
            previous.manualDelta != current.manualDelta;
      },
      builder: (context, state) {
        if (state is! AmplificationActive) return const SizedBox.shrink();

        final bundle = state.bundle;
        if (bundle == null) {
          return const Center(
            child: Padding(
              padding: EdgeInsets.all(16),
              child: Text('Sin bundle activo para visualizar.'),
            ),
          );
        }

        final delta = state.manualDelta ?? ManualAdjustmentDelta.zero();
        final hasDelta = !delta.isZero;
        final adjustedGains = _computeAdjustedGains(bundle, delta);

        return Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
              // Header con título y botón Restablecer
              _buildHeader(context, hasDelta),
              const SizedBox(height: 8),
              // Leyenda de curvas
              _buildLegend(context, hasDelta),
              const SizedBox(height: 12),
              // Gráfico de curvas superpuestas
              SizedBox(
                height: 160,
                child: CustomPaint(
                  size: Size.infinite,
                  painter: _EqCurvePainter(
                    baseGains: bundle.gainsDb,
                    adjustedGains: hasDelta ? adjustedGains : null,
                  ),
                ),
              ),
              const SizedBox(height: 8),
              // Labels de frecuencia bajo el gráfico
              _buildFrequencyLabels(context),
              const SizedBox(height: 16),
              // Sliders por banda con delta labels
              _buildBandSliders(context, bundle, delta),
            ],
          ),
        );
      },
    );
  }

  Widget _buildHeader(BuildContext context, bool hasDelta) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Text(
          'Ecualizador manual',
          style: Theme.of(context).textTheme.titleMedium,
        ),
        if (hasDelta)
          TextButton.icon(
            onPressed: () {
              context
                  .read<AmplificationBloc>()
                  .add(const ResetManualDelta());
            },
            icon: const Icon(Icons.restart_alt, size: 18),
            label: const Text('Restablecer'),
          ),
      ],
    );
  }

  Widget _buildLegend(BuildContext context, bool hasDelta) {
    return Row(
      children: [
        _LegendDot(color: Colors.blue.shade400, label: 'Base (prescripción)'),
        const SizedBox(width: 16),
        if (hasDelta)
          _LegendDot(
            color: Colors.orange.shade400,
            label: 'Ajustada (con delta)',
          ),
      ],
    );
  }

  Widget _buildFrequencyLabels(BuildContext context) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: _bandLabels
          .map(
            (label) => Text(
              label,
              style: Theme.of(context).textTheme.labelSmall?.copyWith(
                    fontSize: 9,
                    color: Colors.grey.shade600,
                  ),
            ),
          )
          .toList(),
    );
  }

  Widget _buildBandSliders(
    BuildContext context,
    AudiogramDrivenBundle bundle,
    ManualAdjustmentDelta delta,
  ) {
    return SizedBox(
      height: 180,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: List.generate(
          AudiogramDrivenBundle.bandCount,
          (i) => Expanded(
            child: _BandSliderColumn(
              bandIndex: i,
              frequencyHz: _bandFrequenciesHz[i],
              label: _bandLabels[i],
              currentDeltaDb: delta.eqDeltaDb[i],
            ),
          ),
        ),
      ),
    );
  }

  /// Computa las ganancias ajustadas incluyendo volumeDeltaDb.
  ///
  /// Fórmula: `finalGain[i] = clamp(gainsDb[i] + eqDeltaDb[i] + volumeDeltaDb, 0, 50)`
  static List<double> _computeAdjustedGains(
    AudiogramDrivenBundle bundle,
    ManualAdjustmentDelta delta,
  ) {
    return List<double>.generate(
      AudiogramDrivenBundle.bandCount,
      (i) => (bundle.gainsDb[i] + delta.eqDeltaDb[i] + delta.volumeDeltaDb)
          .clamp(
        AudiogramDrivenBundle.gainMinDb,
        AudiogramDrivenBundle.gainMaxDb,
      ),
      growable: false,
    );
  }
}

/// Columna individual por banda: slider vertical + label de delta.
///
/// Usa [StatefulWidget] para feedback visual inmediato (el dispatch
/// al bloc ocurre en `onChangeEnd` para evitar rebuilds excesivos).
class _BandSliderColumn extends StatefulWidget {
  final int bandIndex;
  final int frequencyHz;
  final String label;
  final double currentDeltaDb;

  const _BandSliderColumn({
    required this.bandIndex,
    required this.frequencyHz,
    required this.label,
    required this.currentDeltaDb,
  });

  @override
  State<_BandSliderColumn> createState() => _BandSliderColumnState();
}

class _BandSliderColumnState extends State<_BandSliderColumn> {
  /// Valor local mientras el usuario arrastra (feedback sin dispatch).
  double? _localValue;

  double get _displayValue => _localValue ?? widget.currentDeltaDb;

  @override
  void didUpdateWidget(covariant _BandSliderColumn oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Si el bloc actualiza el valor y el usuario no está arrastrando,
    // sincronizamos.
    if (_localValue != null &&
        oldWidget.currentDeltaDb != widget.currentDeltaDb) {
      _localValue = null;
    }
  }

  @override
  Widget build(BuildContext context) {
    final deltaDb = _displayValue;
    final deltaLabel = _formatDelta(deltaDb);

    return Semantics(
      label: '${widget.label} Hz, delta: '
          '${deltaDb.toStringAsFixed(1)} decibeles',
      slider: true,
      value: '${deltaDb.toStringAsFixed(1)} dB',
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // Delta label
          Text(
            deltaLabel,
            style: Theme.of(context).textTheme.labelSmall?.copyWith(
                  fontSize: 9,
                  fontWeight: FontWeight.w600,
                  color: deltaDb == 0
                      ? Colors.grey
                      : (deltaDb > 0 ? Colors.orange.shade700 : Colors.blue.shade700),
                ),
          ),
          // Slider vertical rotado
          Expanded(
            child: RotatedBox(
              quarterTurns: 3,
              child: SliderTheme(
                data: SliderTheme.of(context).copyWith(
                  trackHeight: 3,
                  thumbShape: const RoundSliderThumbShape(
                    enabledThumbRadius: 6,
                  ),
                  overlayShape: const RoundSliderOverlayShape(
                    overlayRadius: 12,
                  ),
                ),
                child: Slider(
                  value: deltaDb,
                  min: ManualAdjustmentDelta.eqDeltaMinDb,
                  max: ManualAdjustmentDelta.eqDeltaMaxDb,
                  divisions: 20, // paso de 1 dB
                  semanticFormatterCallback: (value) =>
                      '${widget.frequencyHz} hertz, '
                      '${value.toStringAsFixed(0)} decibeles',
                  onChanged: (value) {
                    setState(() {
                      _localValue = value;
                    });
                  },
                  onChangeEnd: (value) {
                    final previousDelta = widget.currentDeltaDb;
                    final deltaDelta = value - previousDelta;
                    setState(() {
                      _localValue = null;
                    });
                    if (deltaDelta.abs() > 0.01) {
                      context.read<AmplificationBloc>().add(
                            ManualEqAdjust(
                              bandIndex: widget.bandIndex,
                              deltaDelta: deltaDelta,
                            ),
                          );
                    }
                  },
                ),
              ),
            ),
          ),
          // Frequency label
          Text(
            widget.label,
            style: Theme.of(context).textTheme.labelSmall?.copyWith(
                  fontSize: 9,
                  color: Colors.grey.shade700,
                ),
          ),
        ],
      ),
    );
  }

  /// Formatea el delta como "+2", "-1", "0" etc.
  String _formatDelta(double deltaDb) {
    final rounded = deltaDb.round();
    if (rounded == 0) return '0';
    if (rounded > 0) return '+$rounded';
    return '$rounded';
  }
}

/// Dot + label para la leyenda de curvas.
class _LegendDot extends StatelessWidget {
  final Color color;
  final String label;

  const _LegendDot({required this.color, required this.label});

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 10,
          height: 10,
          decoration: BoxDecoration(color: color, shape: BoxShape.circle),
        ),
        const SizedBox(width: 4),
        Text(label, style: Theme.of(context).textTheme.bodySmall),
      ],
    );
  }
}

/// Painter de curvas EQ base y ajustada.
class _EqCurvePainter extends CustomPainter {
  final List<double> baseGains;
  final List<double>? adjustedGains;

  _EqCurvePainter({required this.baseGains, this.adjustedGains});

  @override
  void paint(Canvas canvas, Size size) {
    const minGain = AudiogramDrivenBundle.gainMinDb; // 0
    const maxGain = AudiogramDrivenBundle.gainMaxDb; // 50
    final bandCount = baseGains.length;
    if (bandCount == 0) return;

    final basePaint = Paint()
      ..color = Colors.blue.shade400
      ..strokeWidth = 2.5
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round;

    final adjustedPaint = Paint()
      ..color = Colors.orange.shade400
      ..strokeWidth = 2.5
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round;

    // Fondo con líneas guía horizontales (cada 10 dB)
    final gridPaint = Paint()
      ..color = Colors.grey.shade200
      ..strokeWidth = 0.5;

    for (var i = 0; i <= 5; i++) {
      final y = size.height * i / 5;
      canvas.drawLine(Offset(0, y), Offset(size.width, y), gridPaint);
    }

    // Curva base (muted/lighter)
    _drawCurve(canvas, size, baseGains, basePaint, minGain, maxGain);

    // Curva ajustada (primary/active)
    if (adjustedGains != null) {
      _drawCurve(canvas, size, adjustedGains!, adjustedPaint, minGain, maxGain);
    }
  }

  void _drawCurve(
    Canvas canvas,
    Size size,
    List<double> gains,
    Paint paint,
    double minGain,
    double maxGain,
  ) {
    final path = Path();
    final bandCount = gains.length;

    for (var i = 0; i < bandCount; i++) {
      final x = bandCount > 1 ? (i / (bandCount - 1)) * size.width : 0.0;
      // Invertir Y: ganancia alta arriba
      final normalized = (gains[i] - minGain) / (maxGain - minGain);
      final y = size.height * (1.0 - normalized);

      if (i == 0) {
        path.moveTo(x, y);
      } else {
        path.lineTo(x, y);
      }
    }

    canvas.drawPath(path, paint);

    // Puntos sobre la curva
    final dotPaint = Paint()
      ..color = paint.color
      ..style = PaintingStyle.fill;

    for (var i = 0; i < bandCount; i++) {
      final x = bandCount > 1 ? (i / (bandCount - 1)) * size.width : 0.0;
      final normalized = (gains[i] - minGain) / (maxGain - minGain);
      final y = size.height * (1.0 - normalized);
      canvas.drawCircle(Offset(x, y), 3, dotPaint);
    }
  }

  @override
  bool shouldRepaint(covariant _EqCurvePainter oldDelegate) {
    return oldDelegate.baseGains != baseGains ||
        oldDelegate.adjustedGains != adjustedGains;
  }
}
