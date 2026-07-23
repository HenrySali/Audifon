import 'package:flutter/material.dart';

import '../../domain/entities/spectrum_snapshot.dart';

/// Chart de fase del espectro (grados).
///
/// Siempre muestra line chart con:
/// - Línea azul: fase de entrada
/// - Línea verde: fase de salida
///
/// Eje Y: grados [-180, +180] con grid lines cada 90°
/// Eje X: bins 1-64 (frecuencia)
class PhaseChart extends StatelessWidget {
  /// Snapshot actual del espectro (null = sin datos).
  final SpectrumSnapshot? snapshot;

  const PhaseChart({
    super.key,
    required this.snapshot,
  });

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 150,
      width: double.infinity,
      child: CustomPaint(
        painter: _PhasePainter(snapshot: snapshot),
      ),
    );
  }
}

class _PhasePainter extends CustomPainter {
  final SpectrumSnapshot? snapshot;

  static const double _yMin = -180.0;
  static const double _yMax = 180.0;
  static const double _padding = 40.0;
  static const double _rightPadding = 16.0;
  static const double _topPadding = 20.0;
  static const double _bottomPadding = 24.0;

  _PhasePainter({this.snapshot});

  @override
  void paint(Canvas canvas, Size size) {
    final chartLeft = _padding;
    final chartRight = size.width - _rightPadding;
    final chartTop = _topPadding;
    final chartBottom = size.height - _bottomPadding;
    final chartWidth = chartRight - chartLeft;
    final chartHeight = chartBottom - chartTop;

    // Background
    final bgPaint = Paint()..color = const Color(0xFF1a1a2e);
    canvas.drawRect(
      Rect.fromLTRB(chartLeft, chartTop, chartRight, chartBottom),
      bgPaint,
    );

    // Grid lines and Y axis labels
    _drawGrid(canvas, chartLeft, chartRight, chartTop, chartBottom, chartHeight);

    // Draw phase lines
    if (snapshot != null) {
      _drawPhaseLines(canvas, chartLeft, chartTop, chartWidth, chartHeight);
    }

    // X axis labels
    _drawXLabels(canvas, chartLeft, chartBottom, chartWidth);

    // Legend
    _drawLegend(canvas, size);

    // Title
    final titlePainter = TextPainter(
      text: const TextSpan(
        text: 'Phase (64 Bins)',
        style: TextStyle(color: Colors.white70, fontSize: 11),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    titlePainter.paint(canvas, Offset(chartLeft, 2));
  }

  void _drawGrid(Canvas canvas, double left, double right, double top,
      double bottom, double chartHeight) {
    final gridPaint = Paint()
      ..color = Colors.white12
      ..strokeWidth = 0.5;

    final labelStyle = const TextStyle(color: Colors.white54, fontSize: 9);

    // Horizontal grid lines every 90°
    for (double deg = _yMin; deg <= _yMax; deg += 90) {
      final y = bottom - (deg - _yMin) / (_yMax - _yMin) * chartHeight;
      canvas.drawLine(Offset(left, y), Offset(right, y), gridPaint);

      final label = deg == 0 ? '0°' : '${deg.toInt()}°';
      final tp = TextPainter(
        text: TextSpan(text: label, style: labelStyle),
        textDirection: TextDirection.ltr,
      )..layout();
      tp.paint(canvas, Offset(left - tp.width - 4, y - tp.height / 2));
    }
  }

  void _drawPhaseLines(Canvas canvas, double chartLeft, double chartTop,
      double chartWidth, double chartHeight) {
    final snap = snapshot!;
    const numBins = 64;

    final inputPaint = Paint()
      ..color = Colors.blue
      ..strokeWidth = 1.2
      ..style = PaintingStyle.stroke;

    final outputPaint = Paint()
      ..color = Colors.green
      ..strokeWidth = 1.2
      ..style = PaintingStyle.stroke;

    final inputPath = Path();
    final outputPath = Path();

    for (int i = 0; i < numBins; i++) {
      final x = chartLeft + (i / (numBins - 1)) * chartWidth;
      final inY = chartTop +
          chartHeight -
          ((snap.inputPhase[i] - _yMin) / (_yMax - _yMin) * chartHeight)
              .clamp(0.0, chartHeight);
      final outY = chartTop +
          chartHeight -
          ((snap.outputPhase[i] - _yMin) / (_yMax - _yMin) * chartHeight)
              .clamp(0.0, chartHeight);

      if (i == 0) {
        inputPath.moveTo(x, inY);
        outputPath.moveTo(x, outY);
      } else {
        inputPath.lineTo(x, inY);
        outputPath.lineTo(x, outY);
      }
    }

    canvas.drawPath(inputPath, inputPaint);
    canvas.drawPath(outputPath, outputPaint);
  }

  void _drawXLabels(
      Canvas canvas, double chartLeft, double chartBottom, double chartWidth) {
    final labelStyle = const TextStyle(color: Colors.white54, fontSize: 8);
    const labels = ['1', '16', '32', '48', '64'];
    const positions = [0.0, 15.0 / 63, 31.0 / 63, 47.0 / 63, 1.0];

    for (int i = 0; i < labels.length; i++) {
      final x = chartLeft + positions[i] * chartWidth;
      final tp = TextPainter(
        text: TextSpan(text: labels[i], style: labelStyle),
        textDirection: TextDirection.ltr,
      )..layout();
      tp.paint(canvas, Offset(x - tp.width / 2, chartBottom + 4));
    }
  }

  void _drawLegend(Canvas canvas, Size size) {
    const legendY = 4.0;
    final legendX = size.width - 150.0;

    // Input phase legend
    final inputPaint = Paint()
      ..color = Colors.blue
      ..strokeWidth = 2;
    canvas.drawLine(
      Offset(legendX, legendY + 6),
      Offset(legendX + 14, legendY + 6),
      inputPaint,
    );
    final inputLabel = TextPainter(
      text: const TextSpan(
        text: 'In Phase',
        style: TextStyle(color: Colors.blue, fontSize: 9),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    inputLabel.paint(canvas, Offset(legendX + 18, legendY));

    // Output phase legend
    final outputPaint = Paint()
      ..color = Colors.green
      ..strokeWidth = 2;
    canvas.drawLine(
      Offset(legendX + 75, legendY + 6),
      Offset(legendX + 89, legendY + 6),
      outputPaint,
    );
    final outputLabel = TextPainter(
      text: const TextSpan(
        text: 'Out Phase',
        style: TextStyle(color: Colors.green, fontSize: 9),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    outputLabel.paint(canvas, Offset(legendX + 93, legendY));
  }

  @override
  bool shouldRepaint(covariant _PhasePainter oldDelegate) {
    return oldDelegate.snapshot != snapshot;
  }
}
