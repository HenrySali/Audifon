/// @file spectrum_view.dart
/// @brief Visualización del espectro instantáneo con marcadores (REQ-7, REQ-9).
///
/// CustomPainter con eje X logarítmico (octavas equiespaciadas) y eje Y dB FS.
/// Renderiza:
///  - Línea vertical en la frecuencia esperada (gris si dentro de tolerancia, roja si fuera).
///  - Triángulo en el pico detectado.
///  - Cruces en posiciones de armónicos H2..H5.
///
/// Nota: como solo recibimos el ToneSnapshot (con armónicos en dB y pico),
/// dibujamos un "espectro estilizado" — no una curva continua: barras altas
/// en el fundamental y los armónicos. Esto es suficiente para el caso de uso
/// (tonos puros con armónicos discretos) y mantiene el costo bajo.

import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../tone_snapshot.dart';

class SpectrumView extends StatelessWidget {
  final ToneSnapshot snapshot;
  final double freqMinHz;
  final double freqMaxHz;
  final double dbMin;
  final double dbMax;
  final double freqTolerancePercent;

  const SpectrumView({
    super.key,
    required this.snapshot,
    this.freqMinHz = 100,
    this.freqMaxHz = 8000,
    this.dbMin = -100,
    this.dbMax = 0,
    this.freqTolerancePercent = 5.0,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: const Color(0xFF1a1a2e),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: Colors.white12),
      ),
      child: AspectRatio(
        aspectRatio: 2.4,
        child: CustomPaint(
          painter: _SpectrumPainter(
            snapshot: snapshot,
            freqMinHz: freqMinHz,
            freqMaxHz: freqMaxHz,
            dbMin: dbMin,
            dbMax: dbMax,
            freqTolerancePercent: freqTolerancePercent,
          ),
          child: snapshot.peakFreqHz.isFinite
              ? null
              : const Center(
                  child: Text(
                    'Sin datos',
                    style: TextStyle(color: Colors.white38, fontSize: 12),
                  ),
                ),
        ),
      ),
    );
  }
}

class _SpectrumPainter extends CustomPainter {
  final ToneSnapshot snapshot;
  final double freqMinHz;
  final double freqMaxHz;
  final double dbMin;
  final double dbMax;
  final double freqTolerancePercent;

  _SpectrumPainter({
    required this.snapshot,
    required this.freqMinHz,
    required this.freqMaxHz,
    required this.dbMin,
    required this.dbMax,
    required this.freqTolerancePercent,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final padding = const EdgeInsets.fromLTRB(34, 8, 8, 22);
    final plotL = padding.left;
    final plotR = size.width - padding.right;
    final plotT = padding.top;
    final plotB = size.height - padding.bottom;
    final plotW = plotR - plotL;
    final plotH = plotB - plotT;

    final logMin = math.log(freqMinHz) / math.ln10;
    final logMax = math.log(freqMaxHz) / math.ln10;

    double xForFreq(double hz) {
      final clamped = hz.clamp(freqMinHz, freqMaxHz);
      final logF = math.log(clamped) / math.ln10;
      return plotL + (logF - logMin) / (logMax - logMin) * plotW;
    }

    double yForDb(double db) {
      final clamped = db.clamp(dbMin, dbMax);
      return plotB - (clamped - dbMin) / (dbMax - dbMin) * plotH;
    }

    // Fondo grilla.
    final gridPaint = Paint()
      ..color = Colors.white12
      ..strokeWidth = 1;
    final axisStyle = const TextStyle(color: Colors.white54, fontSize: 9);

    // Grilla horizontal cada 20 dB.
    for (var db = dbMin.toInt(); db <= dbMax.toInt(); db += 20) {
      final y = yForDb(db.toDouble());
      canvas.drawLine(Offset(plotL, y), Offset(plotR, y), gridPaint);
      _drawText(canvas, '$db', Offset(2, y - 5), axisStyle);
    }

    // Grilla vertical en frecuencias estándar.
    const gridFreqs = [100, 250, 500, 1000, 2000, 4000, 8000];
    for (final f in gridFreqs) {
      if (f < freqMinHz || f > freqMaxHz) continue;
      final x = xForFreq(f.toDouble());
      canvas.drawLine(Offset(x, plotT), Offset(x, plotB), gridPaint);
      final label = f >= 1000 ? '${f ~/ 1000}k' : '$f';
      _drawText(canvas, label, Offset(x - 8, plotB + 4), axisStyle);
    }

    // Línea de la frecuencia esperada (gris u rojo si pico fuera de tolerancia).
    if (snapshot.expectedFreqHz > 0 &&
        snapshot.expectedFreqHz >= freqMinHz &&
        snapshot.expectedFreqHz <= freqMaxHz) {
      final outOfTolerance = snapshot.peakFreqHz.isFinite &&
          ((snapshot.peakFreqHz - snapshot.expectedFreqHz).abs() /
                  snapshot.expectedFreqHz *
                  100.0) >
              freqTolerancePercent;
      final color = outOfTolerance ? Colors.redAccent : Colors.cyan.shade300;
      final paint = Paint()
        ..color = color.withValues(alpha: 0.6)
        ..strokeWidth = 1.2;
      final x = xForFreq(snapshot.expectedFreqHz);
      canvas.drawLine(Offset(x, plotT), Offset(x, plotB), paint);
      _drawText(
        canvas,
        snapshot.expectedFreqHz >= 1000
            ? '${(snapshot.expectedFreqHz / 1000).toStringAsFixed(1)}k esp'
            : '${snapshot.expectedFreqHz.toInt()} esp',
        Offset(x + 2, plotT + 2),
        TextStyle(color: color, fontSize: 9),
      );
    }

    // Magnitud del fundamental (barra).
    if (snapshot.peakFreqHz.isFinite && snapshot.peakMagnitudeDbfs.isFinite) {
      final px = xForFreq(snapshot.peakFreqHz);
      final py = yForDb(snapshot.peakMagnitudeDbfs);
      final paint = Paint()
        ..color = Colors.amberAccent
        ..strokeWidth = 2;
      canvas.drawLine(Offset(px, plotB), Offset(px, py), paint);
      // Triángulo en el pico.
      final triPath = Path()
        ..moveTo(px - 5, py - 8)
        ..lineTo(px + 5, py - 8)
        ..lineTo(px, py)
        ..close();
      canvas.drawPath(triPath, Paint()..color = Colors.amberAccent);
    }

    // Armónicos H2..H8 (cruces).
    if (snapshot.peakFreqHz.isFinite) {
      final crossPaint = Paint()
        ..color = Colors.orangeAccent
        ..strokeWidth = 1.5;
      for (var i = 0; i < snapshot.harmonicsDbfs.length; ++i) {
        final K = i + 2;
        final hf = snapshot.peakFreqHz * K;
        if (hf < freqMinHz || hf > freqMaxHz) continue;
        final hdb = snapshot.harmonicsDbfs[i];
        if (!hdb.isFinite) continue;
        final hx = xForFreq(hf);
        final hy = yForDb(hdb);
        canvas.drawLine(Offset(hx - 4, hy - 4), Offset(hx + 4, hy + 4), crossPaint);
        canvas.drawLine(Offset(hx - 4, hy + 4), Offset(hx + 4, hy - 4), crossPaint);
      }
    }

    // Borde del plot.
    final borderPaint = Paint()
      ..color = Colors.white24
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1;
    canvas.drawRect(Rect.fromLTRB(plotL, plotT, plotR, plotB), borderPaint);
  }

  void _drawText(Canvas canvas, String text, Offset offset, TextStyle style) {
    final tp = TextPainter(
      text: TextSpan(text: text, style: style),
      textDirection: TextDirection.ltr,
    )..layout();
    tp.paint(canvas, offset);
  }

  @override
  bool shouldRepaint(covariant _SpectrumPainter oldDelegate) =>
      oldDelegate.snapshot.timestampUs != snapshot.timestampUs ||
      oldDelegate.freqTolerancePercent != freqTolerancePercent;
}
