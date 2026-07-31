// Feature: in-app-diagnostic-analyzer
// Module: ui/tabs/noise_tab
//
// Ruido tab — SNR pre/post/improvement triple, grouped BarChart for NR vs
// signal gain per spectral band, and a DataTable with the Spanish
// evaluation strings.

import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';

import '../../result/analysis_result.dart';

class NoiseTab extends StatelessWidget {
  final AnalysisResult result;
  const NoiseTab({super.key, required this.result});

  @override
  Widget build(BuildContext context) {
    final r = result;
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Text('SNR pre / post / mejora',
            style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 8),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              children: [
                _kv('SNR pre', _fmt(r.snr.snrPreDb), 'dB'),
                _kv('SNR post', _fmt(r.snr.snrPostDb), 'dB'),
                _kv('Mejora', _fmt(r.snr.snrImprovementDb), 'dB'),
                _kv('Segmentos ruido', '${r.snr.noiseSegmentCount}', ''),
                _kv('Segmentos señal', '${r.snr.signalSegmentCount}', ''),
                _kv('Segmentos transición',
                    '${r.snr.transitionSegmentCount}', ''),
              ],
            ),
          ),
        ),
        const SizedBox(height: 16),
        Text('Reducción de ruido vs ganancia de señal por banda',
            style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 8),
        SizedBox(height: 240, child: _NrBars(result: result)),
        const SizedBox(height: 16),
        Text('Evaluación por banda',
            style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 8),
        _NrTable(result: result),
        const SizedBox(height: 24),
      ],
    );
  }

  static Widget _kv(String k, String v, String suffix) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 2),
        child: Row(
          children: [
            Expanded(
              child: Text(k,
                  style: const TextStyle(
                      color: Colors.white70,
                      fontSize: 13,
                      fontWeight: FontWeight.w600)),
            ),
            Text('$v ${suffix.isEmpty ? '' : suffix}',
                style: const TextStyle(color: Colors.white, fontSize: 13)),
          ],
        ),
      );

  static String _fmt(double v) {
    if (v.isNaN) return 'N/D';
    return v.toStringAsFixed(2);
  }
}

class _NrBars extends StatelessWidget {
  final AnalysisResult result;
  const _NrBars({required this.result});

  @override
  Widget build(BuildContext context) {
    final r = result.noiseReduction;
    final groups = <BarChartGroupData>[];
    for (int i = 0; i < r.bandNames.length; i++) {
      groups.add(BarChartGroupData(x: i, barsSpace: 2, barRods: [
        BarChartRodData(
          toY: r.noiseReductionDb[i].isNaN ? 0.0 : r.noiseReductionDb[i],
          color: Colors.amber,
          width: 7,
        ),
        BarChartRodData(
          toY: r.signalGainDb[i].isNaN ? 0.0 : r.signalGainDb[i],
          color: Theme.of(context).colorScheme.primary,
          width: 7,
        ),
      ]));
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
            reservedSize: 40,
            getTitlesWidget: (v, meta) {
              final i = v.toInt();
              if (i < 0 || i >= r.bandLowHz.length) {
                return const SizedBox.shrink();
              }
              return Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text('${r.bandLowHz[i]}-${r.bandHighHz[i]}',
                    style: const TextStyle(
                        color: Colors.white70, fontSize: 9)),
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

class _NrTable extends StatelessWidget {
  final AnalysisResult result;
  const _NrTable({required this.result});

  @override
  Widget build(BuildContext context) {
    final r = result.noiseReduction;
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: DataTable(
        columns: const [
          DataColumn(label: Text('Banda')),
          DataColumn(label: Text('NR (dB)')),
          DataColumn(label: Text('Sig (dB)')),
          DataColumn(label: Text('Eval ruido')),
          DataColumn(label: Text('Eval señal')),
        ],
        rows: List.generate(r.bandNames.length, (i) {
          return DataRow(cells: [
            DataCell(Text(r.bandNames[i])),
            DataCell(Text(_fmt(r.noiseReductionDb[i]))),
            DataCell(Text(_fmt(r.signalGainDb[i]))),
            DataCell(Text(r.noiseEvaluations[i])),
            DataCell(Text(r.signalEvaluations[i])),
          ]);
        }),
      ),
    );
  }

  static String _fmt(double v) {
    if (v.isNaN) return 'N/D';
    return v.toStringAsFixed(2);
  }
}
