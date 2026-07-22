import 'package:flutter/material.dart';

import '../../domain/entities/loss_type.dart';

/// Widget de comparación de ganancias NL2 vs NL3 en gráfico de 12 bandas.
///
/// Muestra las curvas de ganancia prescrita por NAL-NL2 y NAL-NL3
/// superpuestas en un mismo chart de frecuencia (250–8000 Hz).
/// Opcionalmente agrega un tercer trazo con las ganancias modificadas
/// por el módulo CIN cuando éste está activo.
///
/// Debajo del gráfico muestra el tipo de pérdida detectado (LossType)
/// como etiqueta de texto en español.
///
/// Ejemplo de uso:
/// ```dart
/// GainComparisonWidget(
///   nl2Gains: [10, 15, 18, 20, 22, 24, 23, 21, 19, 17, 14, 11],
///   nl3Gains: [9, 14, 17, 20, 23, 25, 24, 22, 20, 18, 13, 10],
///   cinGains: null,
///   lossType: LossType.sloping,
/// )
/// ```
///
/// Requisitos: 12.1, 12.2, 12.3, 12.4
class GainComparisonWidget extends StatelessWidget {
  /// Ganancias prescritas por NAL-NL2 (12 valores, dB).
  final List<double> nl2Gains;

  /// Ganancias prescritas por NAL-NL3 (12 valores, dB).
  final List<double> nl3Gains;

  /// Ganancias CIN-modificadas (12 valores, dB). Null si CIN no está activo.
  final List<double>? cinGains;

  /// Tipo de pérdida detectado por el clasificador de audiograma.
  final LossType lossType;

  /// Callback opcional invocado al tocar el widget (para mostrar detalle).
  final VoidCallback? onTap;

  const GainComparisonWidget({
    super.key,
    required this.nl2Gains,
    required this.nl3Gains,
    this.cinGains,
    required this.lossType,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: const Color(0xFF16213e),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            // Gráfico de comparación
            SizedBox(
              height: 200,
              width: double.infinity,
              child: CustomPaint(
                painter: _GainComparisonPainter(
                  nl2Gains: nl2Gains,
                  nl3Gains: nl3Gains,
                  cinGains: cinGains,
                ),
              ),
            ),
            const SizedBox(height: 8),
            // Leyenda
            _buildLegend(),
            const SizedBox(height: 8),
            // Tipo de pérdida
            Text(
              'Tipo de pérdida: ${_lossTypeLabel(lossType)}',
              style: const TextStyle(
                color: Colors.white70,
                fontSize: 12,
                fontWeight: FontWeight.w500,
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// Construye la leyenda con los colores de cada trazo.
  Widget _buildLegend() {
    return Wrap(
      spacing: 16,
      runSpacing: 4,
      children: [
        _legendItem(color: _GainComparisonPainter.nl2Color, label: 'NL2'),
        _legendItem(color: _GainComparisonPainter.nl3Color, label: 'NL3'),
        if (cinGains != null)
          _legendItem(
            color: _GainComparisonPainter.cinColor,
            label: 'CIN',
            isDashed: true,
          ),
      ],
    );
  }

  /// Elemento individual de la leyenda.
  Widget _legendItem({
    required Color color,
    required String label,
    bool isDashed = false,
  }) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        SizedBox(
          width: 18,
          height: 12,
          child: CustomPaint(
            painter: _LegendLinePainter(color: color, isDashed: isDashed),
          ),
        ),
        const SizedBox(width: 4),
        Text(
          label,
          style: TextStyle(color: color, fontSize: 10),
        ),
      ],
    );
  }

  /// Convierte el enum [LossType] a una etiqueta en español (rioplatense).
  static String _lossTypeLabel(LossType type) {
    switch (type) {
      case LossType.flat:
        return 'Plana';
      case LossType.sloping:
        return 'Descendente';
      case LossType.reverseSlope:
        return 'Pendiente inversa';
      case LossType.cookieBite:
        return 'Cookie bite (medios)';
      case LossType.notch:
        return 'Muesca';
      case LossType.mixed:
        return 'Mixta (conductiva)';
    }
  }
}

/// Painter del gráfico de comparación de ganancias.
///
/// Dibuja hasta 3 líneas superpuestas sobre un grid de 12 bandas EQ:
/// - NL2 en azul (sólida)
/// - NL3 en cyan/teal (sólida)
/// - CIN en naranja/amber (punteada) — solo si se provee
///
/// Eje X: frecuencias [250, 500, 750, 1k, 1.5k, 2k, 2.5k, 3k, 3.5k, 4k, 6k, 8k] Hz
/// Eje Y: ganancia [0, 50] dB
class _GainComparisonPainter extends CustomPainter {
  final List<double> nl2Gains;
  final List<double> nl3Gains;
  final List<double>? cinGains;

  /// Color para la línea NL2.
  static const Color nl2Color = Colors.blue;

  /// Color para la línea NL3.
  static const Color nl3Color = Colors.cyan;

  /// Color para la línea CIN.
  static const Color cinColor = Colors.amber;

  static const double _yMin = 0.0;
  static const double _yMax = 50.0;
  static const double _leftPadding = 36.0;
  static const double _rightPadding = 12.0;
  static const double _topPadding = 16.0;
  static const double _bottomPadding = 28.0;

  /// Etiquetas de frecuencia para las 12 bandas EQ.
  static const List<String> _bandLabels = [
    '250', '500', '750', '1k', '1.5k', '2k',
    '2.5k', '3k', '3.5k', '4k', '6k', '8k',
  ];

  _GainComparisonPainter({
    required this.nl2Gains,
    required this.nl3Gains,
    this.cinGains,
  });

  @override
  void paint(Canvas canvas, Size size) {
    const chartLeft = _leftPadding;
    final chartRight = size.width - _rightPadding;
    const chartTop = _topPadding;
    final chartBottom = size.height - _bottomPadding;
    final chartWidth = chartRight - chartLeft;
    final chartHeight = chartBottom - chartTop;

    // Fondo del chart
    final bgPaint = Paint()..color = const Color(0xFF1a1a2e);
    canvas.drawRect(
      Rect.fromLTRB(chartLeft, chartTop, chartRight, chartBottom),
      bgPaint,
    );

    // Grid y ejes
    _drawGrid(canvas, chartLeft, chartRight, chartTop, chartBottom, chartHeight);

    // Dibujar trazos de ganancia
    _drawGainLine(
      canvas,
      nl2Gains,
      nl2Color,
      chartLeft,
      chartTop,
      chartWidth,
      chartHeight,
      isDashed: false,
    );
    _drawGainLine(
      canvas,
      nl3Gains,
      nl3Color,
      chartLeft,
      chartTop,
      chartWidth,
      chartHeight,
      isDashed: false,
    );
    if (cinGains != null) {
      _drawGainLine(
        canvas,
        cinGains!,
        cinColor,
        chartLeft,
        chartTop,
        chartWidth,
        chartHeight,
        isDashed: true,
      );
    }

    // Etiquetas del eje X
    _drawXLabels(canvas, chartLeft, chartBottom, chartWidth);

    // Título del eje Y
    final yTitle = TextPainter(
      text: const TextSpan(
        text: 'dB Gain',
        style: TextStyle(color: Colors.white38, fontSize: 8),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    yTitle.paint(canvas, const Offset(0, chartTop - 12));

    // Título del gráfico
    final title = TextPainter(
      text: const TextSpan(
        text: 'Comparación de ganancias',
        style: TextStyle(color: Colors.white70, fontSize: 11),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    title.paint(canvas, const Offset(chartLeft, 0));
  }

  /// Dibuja el grid horizontal (cada 10 dB) y las etiquetas del eje Y.
  void _drawGrid(
    Canvas canvas,
    double left,
    double right,
    double top,
    double bottom,
    double chartHeight,
  ) {
    final gridPaint = Paint()
      ..color = Colors.white12
      ..strokeWidth = 0.5;

    const labelStyle = TextStyle(color: Colors.white54, fontSize: 9);

    // Líneas horizontales cada 10 dB (0, 10, 20, 30, 40, 50)
    for (double db = _yMin; db <= _yMax; db += 10) {
      final y = bottom - (db - _yMin) / (_yMax - _yMin) * chartHeight;
      canvas.drawLine(Offset(left, y), Offset(right, y), gridPaint);

      final tp = TextPainter(
        text: TextSpan(text: '${db.toInt()}', style: labelStyle),
        textDirection: TextDirection.ltr,
      )..layout();
      tp.paint(canvas, Offset(left - tp.width - 4, y - tp.height / 2));
    }
  }

  /// Dibuja una línea de ganancia (sólida o punteada) sobre el chart.
  void _drawGainLine(
    Canvas canvas,
    List<double> gains,
    Color color,
    double chartLeft,
    double chartTop,
    double chartWidth,
    double chartHeight, {
    required bool isDashed,
  }) {
    if (gains.length != 12) return;

    final paint = Paint()
      ..color = color
      ..strokeWidth = 2.0
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round;

    final path = Path();
    final points = <Offset>[];

    for (int i = 0; i < 12; i++) {
      final x = chartLeft + (i / 11) * chartWidth;
      final gain = gains[i].clamp(_yMin, _yMax);
      final y = chartTop + chartHeight - (gain / _yMax) * chartHeight;
      points.add(Offset(x, y));

      if (i == 0) {
        path.moveTo(x, y);
      } else {
        path.lineTo(x, y);
      }
    }

    if (isDashed) {
      _drawDashedPath(canvas, path, paint);
    } else {
      canvas.drawPath(path, paint);
    }

    // Dibujar puntos en cada banda
    final dotPaint = Paint()
      ..color = color
      ..style = PaintingStyle.fill;
    for (final point in points) {
      canvas.drawCircle(point, 3, dotPaint);
    }
  }

  /// Dibuja un path con trazo punteado (segmentos de 6px, gaps de 4px).
  void _drawDashedPath(Canvas canvas, Path path, Paint paint) {
    final metrics = path.computeMetrics();
    for (final metric in metrics) {
      double distance = 0.0;
      const dashLength = 6.0;
      const gapLength = 4.0;
      bool draw = true;

      while (distance < metric.length) {
        final segmentLength = draw ? dashLength : gapLength;
        final end = (distance + segmentLength).clamp(0.0, metric.length);

        if (draw) {
          final segment = metric.extractPath(distance, end);
          canvas.drawPath(segment, paint);
        }

        distance = end;
        draw = !draw;
      }
    }
  }

  /// Dibuja las etiquetas de frecuencia en el eje X.
  void _drawXLabels(
    Canvas canvas,
    double chartLeft,
    double chartBottom,
    double chartWidth,
  ) {
    const labelStyle = TextStyle(color: Colors.white54, fontSize: 8);

    // Mostrar etiquetas alternas para evitar superposición.
    for (int i = 0; i < 12; i += 2) {
      final x = chartLeft + (i / 11) * chartWidth;
      final tp = TextPainter(
        text: TextSpan(text: _bandLabels[i], style: labelStyle),
        textDirection: TextDirection.ltr,
      )..layout();
      tp.paint(canvas, Offset(x - tp.width / 2, chartBottom + 4));
    }
  }

  @override
  bool shouldRepaint(covariant _GainComparisonPainter oldDelegate) {
    return oldDelegate.nl2Gains != nl2Gains ||
        oldDelegate.nl3Gains != nl3Gains ||
        oldDelegate.cinGains != cinGains;
  }
}

/// Painter auxiliar para la línea de leyenda (sólida o punteada).
class _LegendLinePainter extends CustomPainter {
  final Color color;
  final bool isDashed;

  _LegendLinePainter({required this.color, required this.isDashed});

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..strokeWidth = 2.0
      ..style = PaintingStyle.stroke;

    final y = size.height / 2;

    if (isDashed) {
      const dashWidth = 4.0;
      const gapWidth = 2.0;
      double x = 0;
      while (x < size.width) {
        final end = (x + dashWidth).clamp(0.0, size.width);
        canvas.drawLine(Offset(x, y), Offset(end, y), paint);
        x += dashWidth + gapWidth;
      }
    } else {
      canvas.drawLine(Offset(0, y), Offset(size.width, y), paint);
    }
  }

  @override
  bool shouldRepaint(covariant _LegendLinePainter oldDelegate) {
    return oldDelegate.color != color || oldDelegate.isDashed != isDashed;
  }
}
