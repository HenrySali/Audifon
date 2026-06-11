// Feature: in-app-diagnostic-analyzer
// Module: ui/tabs/spectrum_tab
//
// Espectro tab — PSD pre/post (log-x 100 Hz–12 kHz) line chart, the
// Spectral_Gain_Curve with a 0 dB reference, and side-by-side
// spectrograms via CustomPaint with a viridis colormap.

import 'dart:math' as math;
import 'dart:typed_data';

import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';

import '../../result/analysis_result.dart';
import '../../result/spectrogram_result.dart';

class SpectrumTab extends StatelessWidget {
  final AnalysisResult result;
  const SpectrumTab({super.key, required this.result});

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Text('PSD pre vs post (dB)',
            style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 8),
        SizedBox(
          height: 240,
          child: _PsdChart(result: result),
        ),
        const SizedBox(height: 24),
        Text('Curva de ganancia espectral (dB)',
            style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 8),
        SizedBox(
          height: 200,
          child: _GainChart(result: result),
        ),
        const SizedBox(height: 24),
        Text('Espectrograma comparativo',
            style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 8),
        Row(
          children: [
            Expanded(
              child: _SpectrogramView(
                title: 'Pre',
                matrix: result.spectrogram.preDb,
                rows: result.spectrogram.rows,
                cols: result.spectrogram.cols,
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: _SpectrogramView(
                title: 'Post',
                matrix: result.spectrogram.postDb,
                rows: result.spectrogram.rows,
                cols: result.spectrogram.cols,
              ),
            ),
          ],
        ),
        const SizedBox(height: 24),
      ],
    );
  }
}

class _PsdChart extends StatelessWidget {
  final AnalysisResult result;
  const _PsdChart({required this.result});

  @override
  Widget build(BuildContext context) {
    final pre = _toLogXdB(result.psdPre.frequencies, result.psdPre.power);
    final post = _toLogXdB(result.psdPost.frequencies, result.psdPost.power);
    return LineChart(LineChartData(
      gridData: const FlGridData(show: true),
      titlesData: const FlTitlesData(
        leftTitles: AxisTitles(
          sideTitles: SideTitles(showTitles: true, reservedSize: 36),
        ),
        bottomTitles: AxisTitles(
          sideTitles: SideTitles(showTitles: true, reservedSize: 24),
        ),
        topTitles: AxisTitles(sideTitles: SideTitles(showTitles: false)),
        rightTitles: AxisTitles(sideTitles: SideTitles(showTitles: false)),
      ),
      borderData: FlBorderData(show: true),
      lineBarsData: [
        LineChartBarData(
          spots: pre,
          isCurved: false,
          color: Colors.white54,
          dotData: const FlDotData(show: false),
          barWidth: 1.5,
        ),
        LineChartBarData(
          spots: post,
          isCurved: false,
          color: Theme.of(context).colorScheme.primary,
          dotData: const FlDotData(show: false),
          barWidth: 1.5,
        ),
      ],
    ));
  }

  static List<FlSpot> _toLogXdB(Float64List freqs, Float64List power) {
    final out = <FlSpot>[];
    for (int k = 0; k < freqs.length; k++) {
      final f = freqs[k];
      if (f < 100.0 || f > 12000.0) continue;
      final x = math.log(f) / math.ln10; // log10
      final db = 10.0 * (math.log(power[k] + 1e-20) / math.ln10);
      out.add(FlSpot(x, db));
    }
    return out;
  }
}

class _GainChart extends StatelessWidget {
  final AnalysisResult result;
  const _GainChart({required this.result});

  @override
  Widget build(BuildContext context) {
    final freqs = result.psdPre.frequencies;
    final gain = result.bandGain.spectralGainCurveDb;
    final spots = <FlSpot>[];
    for (int k = 0; k < freqs.length; k++) {
      final f = freqs[k];
      if (f < 100.0 || f > 12000.0) continue;
      spots.add(FlSpot(math.log(f) / math.ln10, gain[k]));
    }
    return LineChart(LineChartData(
      gridData: const FlGridData(show: true),
      titlesData: const FlTitlesData(
        leftTitles: AxisTitles(
          sideTitles: SideTitles(showTitles: true, reservedSize: 36),
        ),
        bottomTitles: AxisTitles(
          sideTitles: SideTitles(showTitles: true, reservedSize: 24),
        ),
        topTitles: AxisTitles(sideTitles: SideTitles(showTitles: false)),
        rightTitles: AxisTitles(sideTitles: SideTitles(showTitles: false)),
      ),
      borderData: FlBorderData(show: true),
      extraLinesData: ExtraLinesData(
        horizontalLines: [
          HorizontalLine(
              y: 0,
              color: Colors.white30,
              strokeWidth: 1.0,
              dashArray: const [4, 4]),
        ],
      ),
      lineBarsData: [
        LineChartBarData(
          spots: spots,
          isCurved: false,
          color: Theme.of(context).colorScheme.primary,
          dotData: const FlDotData(show: false),
          barWidth: 1.5,
        ),
      ],
    ));
  }
}

class _SpectrogramView extends StatelessWidget {
  final String title;
  final Float32List matrix;
  final int rows;
  final int cols;
  const _SpectrogramView({
    required this.title,
    required this.matrix,
    required this.rows,
    required this.cols,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(title,
            textAlign: TextAlign.center,
            style: const TextStyle(color: Colors.white70, fontSize: 12)),
        AspectRatio(
          aspectRatio: 1.5,
          child: CustomPaint(
            painter: _SpectrogramPainter(matrix: matrix, rows: rows, cols: cols),
          ),
        ),
      ],
    );
  }
}

class _SpectrogramPainter extends CustomPainter {
  final Float32List matrix;
  final int rows;
  final int cols;
  _SpectrogramPainter({
    required this.matrix,
    required this.rows,
    required this.cols,
  });

  @override
  void paint(Canvas canvas, Size size) {
    if (rows == 0 || cols == 0) return;
    final cellW = size.width / cols;
    final cellH = size.height / rows;
    final paint = Paint();
    for (int r = 0; r < rows; r++) {
      // Invert y so low frequencies appear at the bottom.
      final ry = rows - 1 - r;
      for (int c = 0; c < cols; c++) {
        final db = matrix[ry * cols + c];
        // Map [-120, 0] dB to [0, 1].
        final t = ((db + 120.0) / 120.0).clamp(0.0, 1.0);
        paint.color = _viridis(t);
        canvas.drawRect(
          Rect.fromLTWH(c * cellW, r * cellH, cellW + 0.5, cellH + 0.5),
          paint,
        );
      }
    }
  }

  /// Approximation of the viridis colormap. Cubic interpolation between
  /// six anchor colors covers the perceptual ramp adequately.
  static Color _viridis(double t) {
    const stops = <Color>[
      Color(0xFF440154),
      Color(0xFF3B528B),
      Color(0xFF21908C),
      Color(0xFF5DC863),
      Color(0xFFFDE725),
    ];
    final tt = t.clamp(0.0, 1.0);
    final scaled = tt * (stops.length - 1);
    final lo = scaled.floor();
    final hi = math.min(lo + 1, stops.length - 1);
    final frac = scaled - lo;
    final a = stops[lo];
    final b = stops[hi];
    return Color.fromARGB(
      255,
      _lerp(a.red, b.red, frac),
      _lerp(a.green, b.green, frac),
      _lerp(a.blue, b.blue, frac),
    );
  }

  static int _lerp(int a, int b, double t) => (a + (b - a) * t).round();

  @override
  bool shouldRepaint(covariant _SpectrogramPainter old) =>
      old.matrix != matrix || old.rows != rows || old.cols != cols;
}
