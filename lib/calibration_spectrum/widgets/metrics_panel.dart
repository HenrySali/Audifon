/// @file metrics_panel.dart
/// @brief Panel de métricas en vivo del tono actual (REQ-7.1).

import 'package:flutter/material.dart';

import '../tone_snapshot.dart';

class MetricsPanel extends StatelessWidget {
  final ToneSnapshot snapshot;
  final double targetLevelDbSpl;

  const MetricsPanel({
    super.key,
    required this.snapshot,
    required this.targetLevelDbSpl,
  });

  @override
  Widget build(BuildContext context) {
    final hasData = snapshot.peakFreqHz.isFinite;

    Color verdictColor;
    String verdictLabel;
    switch (snapshot.verdict) {
      case ToneVerdict.pass:
        verdictColor = Colors.greenAccent;
        verdictLabel = 'PASS';
        break;
      case ToneVerdict.fail:
        verdictColor = Colors.redAccent;
        verdictLabel = 'FAIL';
        break;
      default:
        verdictColor = Colors.white54;
        verdictLabel = '—';
    }

    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: const Color(0xFF16213e),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.monitor_heart_outlined, color: Color(0xFF00e5ff), size: 18),
              const SizedBox(width: 8),
              const Text(
                'Métricas en vivo',
                style: TextStyle(color: Color(0xFF00e5ff), fontSize: 13, fontWeight: FontWeight.w600),
              ),
              const Spacer(),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                decoration: BoxDecoration(
                  color: verdictColor.withValues(alpha: 0.2),
                  borderRadius: BorderRadius.circular(4),
                  border: Border.all(color: verdictColor.withValues(alpha: 0.6)),
                ),
                child: Text(
                  verdictLabel,
                  style: TextStyle(color: verdictColor, fontSize: 12, fontWeight: FontWeight.w700),
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          GridView.count(
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            crossAxisCount: 2,
            childAspectRatio: 3.6,
            mainAxisSpacing: 6,
            crossAxisSpacing: 8,
            children: [
              _Metric(
                label: 'Pico',
                value: hasData ? '${snapshot.peakFreqHz.toStringAsFixed(1)} Hz' : '—',
                hint: snapshot.expectedFreqHz > 0
                    ? 'esperado ${snapshot.expectedFreqHz.toStringAsFixed(0)} Hz'
                    : null,
              ),
              _Metric(
                label: 'Nivel',
                value: snapshot.peakMagnitudeDbspl.isFinite
                    ? '${snapshot.peakMagnitudeDbspl.toStringAsFixed(1)} dB SPL'
                    : '—',
                hint: 'objetivo ${targetLevelDbSpl.toStringAsFixed(0)} dB SPL',
              ),
              _Metric(
                label: 'THD',
                value: snapshot.thdPercent.isFinite
                    ? '${snapshot.thdPercent.toStringAsFixed(2)} %'
                    : '—',
              ),
              _Metric(
                label: 'SNR',
                value: snapshot.snrDb.isFinite
                    ? '${snapshot.snrDb.toStringAsFixed(1)} dB'
                    : '—',
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _Metric extends StatelessWidget {
  final String label;
  final String value;
  final String? hint;
  const _Metric({required this.label, required this.value, this.hint});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: const Color(0xFF1a1a2e),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Row(
        children: [
          SizedBox(
            width: 50,
            child: Text(
              label,
              style: const TextStyle(color: Colors.white54, fontSize: 11),
            ),
          ),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  value,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                if (hint != null)
                  Text(
                    hint!,
                    style: const TextStyle(color: Colors.white38, fontSize: 9),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
