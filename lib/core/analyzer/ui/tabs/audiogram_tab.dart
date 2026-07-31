// Feature: in-app-diagnostic-analyzer
// Module: ui/tabs/audiogram_tab
//
// Audiograma tab — grouped BarChart for measured vs prescribed gains, and
// an inverted-y LineChart for inferred vs reference dB HL thresholds.

import 'dart:math' as math;

import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';

import '../../result/analysis_result.dart';

class AudiogramTab extends StatelessWidget {
  final AnalysisResult result;
  const AudiogramTab({super.key, required this.result});

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Text('Ganancia medida vs prescrita por banda',
            style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 8),
        SizedBox(height: 240, child: _GainBars(result: result)),
        const SizedBox(height: 24),
        Text('Audiograma inferido vs referencia (dB HL)',
            style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 8),
        SizedBox(height: 240, child: _AudiogramChart(result: result)),
        const SizedBox(height: 24),
        _LegendRow(),
      ],
    );
  }
}

class _GainBars extends StatelessWidget {
  final AnalysisResult result;
  const _GainBars({required this.result});

  @override
  Widget build(BuildContext context) {
    final r = result.bandGain;
    final groups = <BarChartGroupData>[];
    for (int i = 0; i < r.bandFrequencies.length; i++) {
      final m = r.measuredGainsDb[i];
      final p = r.prescribedGainsDb[i];
      groups.add(
        BarChartGroupData(x: i, barsSpace: 2, barRods: [
          BarChartRodData(
            toY: m.isNaN ? 0.0 : m,
            color: Theme.of(context).colorScheme.primary,
            width: 6,
          ),
          BarChartRodData(
            toY: p.isNaN ? 0.0 : p,
            color: Colors.white54,
            width: 6,
          ),
        ]),
      );
    }
    return BarChart(BarChartData(
      barGroups: groups,
      gridData: const FlGridData(show: true),
      borderData: FlBorderData(show: true),
      titlesData: FlTitlesData(
        leftTitles: const AxisTitles(
          sideTitles: SideTitles(showTitles: true, reservedSize: 36),
        ),
        bottomTitles: AxisTitles(
          sideTitles: SideTitles(
            showTitles: true,
            reservedSize: 32,
            getTitlesWidget: (v, meta) {
              final i = v.toInt();
              if (i < 0 || i >= r.bandFrequencies.length) {
                return const SizedBox.shrink();
              }
              final f = r.bandFrequencies[i];
              final label = f >= 1000 ? '${(f / 1000).toStringAsFixed(0)}k' : '$f';
              return Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text(label,
                    style: const TextStyle(
                        color: Colors.white70, fontSize: 10)),
              );
            },
          ),
        ),
        topTitles:
            const AxisTitles(sideTitles: SideTitles(showTitles: false)),
        rightTitles:
            const AxisTitles(sideTitles: SideTitles(showTitles: false)),
      ),
    ));
  }
}

class _AudiogramChart extends StatelessWidget {
  final AnalysisResult result;
  const _AudiogramChart({required this.result});

  @override
  Widget build(BuildContext context) {
    final a = result.audiogram;
    final inferred = <FlSpot>[];
    final reference = <FlSpot>[];
    for (int i = 0; i < a.frequenciesHz.length; i++) {
      final f = a.frequenciesHz[i].toDouble();
      final logF = math.log(f) / math.ln10;
      // Negate values so the chart's natural y-axis goes 0 → -120 (visually
      // inverted, matching the audiogram convention).
      if (!a.inferredThresholdsDbHl[i].isNaN) {
        inferred.add(FlSpot(logF, -a.inferredThresholdsDbHl[i]));
      }
      if (!a.referenceThresholdsDbHl[i].isNaN) {
        reference.add(FlSpot(logF, -a.referenceThresholdsDbHl[i]));
      }
    }

    return LineChart(LineChartData(
      gridData: const FlGridData(show: true),
      borderData: FlBorderData(show: true),
      minY: -120,
      maxY: 0,
      titlesData: FlTitlesData(
        leftTitles: AxisTitles(
          sideTitles: SideTitles(
            showTitles: true,
            reservedSize: 36,
            getTitlesWidget: (v, meta) {
              return Text('${(-v).toStringAsFixed(0)}',
                  style: const TextStyle(
                      color: Colors.white70, fontSize: 10));
            },
          ),
        ),
        bottomTitles: AxisTitles(
          sideTitles: SideTitles(
            showTitles: true,
            reservedSize: 32,
            getTitlesWidget: (v, meta) {
              final f = math.pow(10.0, v).round();
              return Text(
                f >= 1000 ? '${(f / 1000).toStringAsFixed(1)}k' : '$f',
                style: const TextStyle(color: Colors.white70, fontSize: 10),
              );
            },
          ),
        ),
        topTitles:
            const AxisTitles(sideTitles: SideTitles(showTitles: false)),
        rightTitles:
            const AxisTitles(sideTitles: SideTitles(showTitles: false)),
      ),
      lineBarsData: [
        LineChartBarData(
          spots: reference,
          isCurved: false,
          color: Colors.white54,
          dotData: const FlDotData(show: true),
          barWidth: 1.5,
        ),
        LineChartBarData(
          spots: inferred,
          isCurved: false,
          color: Theme.of(context).colorScheme.primary,
          dotData: const FlDotData(show: true),
          barWidth: 1.5,
        ),
      ],
    ));
  }
}

class _LegendRow extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final cyan = Theme.of(context).colorScheme.primary;
    return Row(
      children: [
        _legend(cyan, 'Medido / inferido'),
        const SizedBox(width: 16),
        _legend(Colors.white54, 'Prescrito / referencia'),
      ],
    );
  }

  Widget _legend(Color c, String t) => Row(
        children: [
          Container(width: 16, height: 4, color: c),
          const SizedBox(width: 6),
          Text(t,
              style:
                  const TextStyle(color: Colors.white70, fontSize: 12)),
        ],
      );
}
