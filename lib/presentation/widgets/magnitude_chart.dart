import 'package:flutter/material.dart';

import '../../domain/entities/spectrum_snapshot.dart';

/// Chart de magnitud del espectro (dB SPL).
///
/// Soporta dos modos de visualización:
/// - 12 bandas EQ: bar chart con barras azules (input) y verdes (output)
/// - 64 bins FFT: line chart con línea azul (input) y verde (output)
///
/// Eje Y: dB SPL (rango 0-100, grid lines cada 20 dB)
/// Eje X: frecuencia (etiquetas de banda o bins)
class MagnitudeChart extends StatelessWidget {
  /// Snapshot actual del espectro (null = sin datos).
  final SpectrumSnapshot? snapshot;

  /// true = 12 bandas (bar chart), false = 64 bins (line chart).
  final bool showBands;

  const MagnitudeChart({
    super.key,
    required this.snapshot,
    this.showBands = true,
  });

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 200,
      width: double.infinity,
      child: CustomPaint(
        painter: _MagnitudePainter(
          snapshot: snapshot,
          showBands: showBands,
        ),
      ),
    );
  }
}

class _MagnitudePainter extends CustomPainter {
  final SpectrumSnapshot? snapshot;
  final bool showBands;

  static const double _yMin = 0.0;
  static const double _yMax = 100.0;
  static const double _padding = 40.0;
  static const double _rightPadding = 16.0;
  static const double _topPadding = 20.0;
  static const double _bottomPadding = 30.0;

  /// Etiquetas de frecuencia para las 12 bandas EQ.
  static const List<String> _bandLabels = [
    '250', '500', '750', '1k', '1.5k', '2k',
    '2.5k', '3k', '3.5k', '4k', '6k', '8k',
  ];

  _MagnitudePainter({this.snapshot, this.showBands = true});

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
    _drawGrid(canvas, size, chartLeft, chartRight, chartTop, chartBottom);

    // Draw data
    if (snapshot != null) {
      if (showBands) {
        _drawBars(canvas, chartLeft, chartTop, chartWidth, chartHeight);
      } else {
        _drawLines(canvas, chartLeft, chartTop, chartWidth, chartHeight);
      }
    }

    // X axis labels
    _drawXLabels(canvas, chartLeft, chartBottom, chartWidth);

    // Legend
    _drawLegend(canvas, size);

    // Title
    final titlePainter = TextPainter(
      text: TextSpan(
        text: showBands ? 'Magnitude (12 Bands)' : 'Magnitude (64 Bins)',
        style: const TextStyle(color: Colors.white70, fontSize: 11),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    titlePainter.paint(canvas, Offset(chartLeft, 2));
  }

  void _drawGrid(Canvas canvas, Size size, double left, double right,
      double top, double bottom) {
    final gridPaint = Paint()
      ..color = Colors.white12
      ..strokeWidth = 0.5;

    final labelStyle = const TextStyle(color: Colors.white54, fontSize: 9);
    final chartHeight = bottom - top;

    // Horizontal grid lines every 20 dB
    for (double db = _yMin; db <= _yMax; db += 20) {
      final y = bottom - (db - _yMin) / (_yMax - _yMin) * chartHeight;
      canvas.drawLine(Offset(left, y), Offset(right, y), gridPaint);

      final tp = TextPainter(
        text: TextSpan(text: '${db.toInt()}', style: labelStyle),
        textDirection: TextDirection.ltr,
      )..layout();
      tp.paint(canvas, Offset(left - tp.width - 4, y - tp.height / 2));
    }

    // Y axis title
    final yTitle = TextPainter(
      text: const TextSpan(
        text: 'dB SPL',
        style: TextStyle(color: Colors.white38, fontSize: 8),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    yTitle.paint(canvas, Offset(0, top - 14));
  }

  void _drawBars(Canvas canvas, double chartLeft, double chartTop,
      double chartWidth, double chartHeight) {
    final snap = snapshot!;
    const numBands = 12;
    final bandWidth = chartWidth / numBands;
    final barWidth = bandWidth * 0.35;

    final inputPaint = Paint()..color = Colors.blue.withOpacity(0.8);
    final outputPaint = Paint()..color = Colors.green.withOpacity(0.8);

    for (int i = 0; i < numBands; i++) {
      final x = chartLeft + i * bandWidth + bandWidth / 2;

      // Input bar (left)
      final inHeight =
          ((snap.inputBands[i] - _yMin) / (_yMax - _yMin) * chartHeight)
              .clamp(0.0, chartHeight);
      final inRect = Rect.fromLTWH(
        x - barWidth - 1,
        chartTop + chartHeight - inHeight,
        barWidth,
        inHeight,
      );
      canvas.drawRect(inRect, inputPaint);

      // Output bar (right)
      final outHeight =
          ((snap.outputBands[i] - _yMin) / (_yMax - _yMin) * chartHeight)
              .clamp(0.0, chartHeight);
      final outRect = Rect.fromLTWH(
        x + 1,
        chartTop + chartHeight - outHeight,
        barWidth,
        outHeight,
      );
      canvas.drawRect(outRect, outputPaint);
    }
  }

  void _drawLines(Canvas canvas, double chartLeft, double chartTop,
      double chartWidth, double chartHeight) {
    final snap = snapshot!;
    const numBins = 64;

    final inputPaint = Paint()
      ..color = Colors.blue
      ..strokeWidth = 1.5
      ..style = PaintingStyle.stroke;

    final outputPaint = Paint()
      ..color = Colors.green
      ..strokeWidth = 1.5
      ..style = PaintingStyle.stroke;

    final inputPath = Path();
    final outputPath = Path();

    for (int i = 0; i < numBins; i++) {
      final x = chartLeft + (i / (numBins - 1)) * chartWidth;
      final inY = chartTop +
          chartHeight -
          ((snap.inputMagnitude[i] - _yMin) / (_yMax - _yMin) * chartHeight)
              .clamp(0.0, chartHeight);
      final outY = chartTop +
          chartHeight -
          ((snap.outputMagnitude[i] - _yMin) / (_yMax - _yMin) * chartHeight)
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

    if (showBands) {
      const numBands = 12;
      final bandWidth = chartWidth / numBands;
      for (int i = 0; i < numBands; i += 2) {
        final x = chartLeft + i * bandWidth + bandWidth / 2;
        final tp = TextPainter(
          text: TextSpan(text: _bandLabels[i], style: labelStyle),
          textDirection: TextDirection.ltr,
        )..layout();
        tp.paint(canvas, Offset(x - tp.width / 2, chartBottom + 4));
      }
    } else {
      // Show a few bin frequency labels
      const labels = ['125', '1k', '2k', '4k', '6k', '8k'];
      const positions = [0, 7, 15, 31, 47, 63]; // bin indices
      for (int i = 0; i < labels.length; i++) {
        final x = chartLeft + (positions[i] / 63) * chartWidth;
        final tp = TextPainter(
          text: TextSpan(text: '${labels[i]}Hz', style: labelStyle),
          textDirection: TextDirection.ltr,
        )..layout();
        tp.paint(canvas, Offset(x - tp.width / 2, chartBottom + 4));
      }
    }
  }

  void _drawLegend(Canvas canvas, Size size) {
    const legendY = 4.0;
    final legendX = size.width - 120.0;

    // Input legend
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
        text: 'Input',
        style: TextStyle(color: Colors.blue, fontSize: 9),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    inputLabel.paint(canvas, Offset(legendX + 18, legendY));

    // Output legend
    final outputPaint = Paint()
      ..color = Colors.green
      ..strokeWidth = 2;
    canvas.drawLine(
      Offset(legendX + 60, legendY + 6),
      Offset(legendX + 74, legendY + 6),
      outputPaint,
    );
    final outputLabel = TextPainter(
      text: const TextSpan(
        text: 'Output',
        style: TextStyle(color: Colors.green, fontSize: 9),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    outputLabel.paint(canvas, Offset(legendX + 78, legendY));
  }

  @override
  bool shouldRepaint(covariant _MagnitudePainter oldDelegate) {
    return oldDelegate.snapshot != snapshot ||
        oldDelegate.showBands != showBands;
  }
}
