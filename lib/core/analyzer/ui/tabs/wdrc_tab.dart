// Feature: in-app-diagnostic-analyzer
// Module: ui/tabs/wdrc_tab
//
// WDRC tab — ScatterChart with all per-segment (inDb, outDb) points and
// three regression overlays clipped per zone, plus a side panel with
// per-zone numeric breakdown.

import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';

import '../../result/analysis_result.dart';
import '../../result/wdrc_io_result.dart';

class WdrcTab extends StatelessWidget {
  final AnalysisResult result;
  const WdrcTab({super.key, required this.result});

  @override
  Widget build(BuildContext context) {
    final w = result.wdrcIo;
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Text('Curva I/O del WDRC',
            style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 8),
        SizedBox(height: 280, child: _WdrcScatter(result: result)),
        const SizedBox(height: 16),
        _CompressionRatioCard(
          observed: w.observedCompressionRatio,
          configured: w.configuredCompressionRatio,
        ),
        const SizedBox(height: 12),
        _ZoneCard(zone: w.low, color: Colors.blueAccent),
        const SizedBox(height: 8),
        _ZoneCard(zone: w.mid, color: Colors.greenAccent),
        const SizedBox(height: 8),
        _ZoneCard(zone: w.high, color: Colors.amber),
        const SizedBox(height: 24),
      ],
    );
  }
}

class _WdrcScatter extends StatelessWidget {
  final AnalysisResult result;
  const _WdrcScatter({required this.result});

  @override
  Widget build(BuildContext context) {
    final w = result.wdrcIo;
    final spots = <ScatterSpot>[];
    for (final p in w.allPoints) {
      spots.add(ScatterSpot(p.inDb, p.outDb,
          dotPainter: FlDotCirclePainter(radius: 3, color: Colors.white70)));
    }
    return ScatterChart(ScatterChartData(
      scatterSpots: spots,
      gridData: const FlGridData(show: true),
      borderData: FlBorderData(show: true),
      titlesData: const FlTitlesData(
        leftTitles: AxisTitles(
          sideTitles: SideTitles(showTitles: true, reservedSize: 36),
        ),
        bottomTitles: AxisTitles(
          sideTitles: SideTitles(showTitles: true, reservedSize: 24),
        ),
        topTitles: AxisTitles(sideTitles: SideTitles(showTitles: false)),
        rightTitles:
            AxisTitles(sideTitles: SideTitles(showTitles: false)),
      ),
    ));
  }
}

class _CompressionRatioCard extends StatelessWidget {
  final double observed;
  final double configured;
  const _CompressionRatioCard({
    required this.observed,
    required this.configured,
  });
  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Compression ratio',
                style: Theme.of(context).textTheme.titleSmall),
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child:
                      Text('Observado:  ${_fmt(observed)} : 1',
                          style: const TextStyle(color: Colors.white)),
                ),
                Expanded(
                  child:
                      Text('Configurado: ${_fmt(configured)} : 1',
                          style: const TextStyle(color: Colors.white70)),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  static String _fmt(double v) {
    if (v.isNaN) return 'N/D';
    if (!v.isFinite) return v.isNegative ? '-∞' : '+∞';
    return v.toStringAsFixed(2);
  }
}

class _ZoneCard extends StatelessWidget {
  final WdrcZoneResult zone;
  final Color color;
  const _ZoneCard({required this.zone, required this.color});
  @override
  Widget build(BuildContext context) {
    return Card(
      color: color.withOpacity(0.08),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(width: 8, height: 8, color: color),
                const SizedBox(width: 8),
                Text(zone.name,
                    style: TextStyle(
                        color: color, fontWeight: FontWeight.w600)),
                const Spacer(),
                if (zone.insufficientData)
                  const Text('Datos insuficientes',
                      style:
                          TextStyle(color: Colors.amber, fontSize: 11)),
                if (!zone.insufficientData)
                  Text('${zone.points.length} segmentos',
                      style: const TextStyle(
                          color: Colors.white54, fontSize: 11)),
              ],
            ),
            const SizedBox(height: 6),
            _row('In medio', _fmt(zone.meanInputDbfs), 'dBFS'),
            _row('Out medio', _fmt(zone.meanOutputDbfs), 'dBFS'),
            _row('Ganancia media', _fmt(zone.meanGainDb), 'dB'),
            _row('Pendiente', _fmt(zone.slope), ''),
            _row('Intercepto', _fmt(zone.intercept), 'dB'),
          ],
        ),
      ),
    );
  }

  Widget _row(String k, String v, String suffix) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 1),
        child: Row(
          children: [
            Expanded(
                child: Text(k,
                    style: const TextStyle(
                        color: Colors.white60, fontSize: 12))),
            Text(suffix.isEmpty ? v : '$v $suffix',
                style:
                    const TextStyle(color: Colors.white, fontSize: 12)),
          ],
        ),
      );

  static String _fmt(double v) {
    if (v.isNaN) return 'N/D';
    if (!v.isFinite) return v.isNegative ? '-∞' : '+∞';
    return v.toStringAsFixed(2);
  }
}
