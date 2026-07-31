// Feature: in-app-diagnostic-analyzer
// Module: ui/tabs/quality_tab
//
// Calidad tab — DataTable with the QualityResult, the LatencyResult
// (with `lowConfidence`), and the ThdResult (with `compliantWithS322`).

import 'package:flutter/material.dart';

import '../../result/analysis_result.dart';

class QualityTab extends StatelessWidget {
  final AnalysisResult result;
  const QualityTab({super.key, required this.result});

  @override
  Widget build(BuildContext context) {
    final r = result;
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Text('Métricas de calidad',
            style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 8),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(8),
            child: Column(
              children: [
                _row('Ganancia global', _fmt(r.quality.globalGainDb), 'dB'),
                _row('RMS pre', _fmt(r.quality.rmsPreDbfs), 'dBFS'),
                _row('RMS post', _fmt(r.quality.rmsPostDbfs), 'dBFS'),
                _row('Pico pre', _fmt(r.quality.peakPreDbfs), 'dBFS'),
                _row('Pico post', _fmt(r.quality.peakPostDbfs), 'dBFS'),
                _row('Clipping pre',
                    _fmt(r.quality.clippingPrePercent), '%'),
                _row('Clipping post',
                    _fmt(r.quality.clippingPostPercent), '%'),
              ],
            ),
          ),
        ),
        const SizedBox(height: 16),
        Text('Latencia',
            style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 8),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _row('Lag', '${r.latency.lagSamples}', 'muestras'),
                _row('Latencia', _fmt(r.latency.latencyMs), 'ms'),
                _row('Pico normalizado', _fmt(r.latency.normalizedPeak), ''),
                if (r.latency.lowConfidence)
                  const Padding(
                    padding: EdgeInsets.only(top: 8),
                    child: Text(
                      'Baja confianza: |corr| < 0.1',
                      style: TextStyle(color: Colors.amber, fontSize: 12),
                    ),
                  ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 16),
        Text('Distorsión armónica (THD)',
            style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 8),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _row('Fundamental', _fmt(r.thd.fundamentalHz), 'Hz'),
                _row('THD', _fmt(r.thd.thdPercent), '%'),
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Row(
                    children: [
                      Icon(
                        r.thd.compliantWithS322
                            ? Icons.check_circle
                            : Icons.error,
                        color: r.thd.compliantWithS322
                            ? Colors.greenAccent
                            : Colors.redAccent,
                        size: 18,
                      ),
                      const SizedBox(width: 6),
                      Text(
                        r.thd.compliantWithS322
                            ? 'Cumple ANSI/ASA S3.22-2024 (THD < 5%)'
                            : 'NO cumple ANSI/ASA S3.22-2024 (THD ≥ 5%)',
                        style: TextStyle(
                          color: r.thd.compliantWithS322
                              ? Colors.greenAccent
                              : Colors.redAccent,
                          fontSize: 12,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 24),
      ],
    );
  }

  static Widget _row(String k, String v, String suffix) => Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
        child: Row(
          children: [
            Expanded(
              child: Text(k,
                  style: const TextStyle(
                      color: Colors.white70, fontSize: 13)),
            ),
            Text(suffix.isEmpty ? v : '$v $suffix',
                style:
                    const TextStyle(color: Colors.white, fontSize: 13)),
          ],
        ),
      );

  static String _fmt(double v) {
    if (v.isNaN) return 'N/D';
    if (!v.isFinite) return v.isNegative ? '-∞' : '+∞';
    return v.toStringAsFixed(2);
  }
}
