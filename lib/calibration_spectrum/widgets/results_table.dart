/// @file results_table.dart
/// @brief Tabla resumen de los tonos de la secuencia (REQ-11).

import 'package:flutter/material.dart';

import '../tone_test_result.dart';
import '../validator_orchestrator.dart' show CalibrationSequenceReport;

class ResultsTable extends StatelessWidget {
  final CalibrationSequenceReport report;

  const ResultsTable({super.key, required this.report});

  @override
  Widget build(BuildContext context) {
    final globalIsPass = report.globalVerdict == ToneVerdict.pass;
    final globalIsFail = report.globalVerdict == ToneVerdict.fail;

    final bannerColor = globalIsPass
        ? Colors.greenAccent
        : (globalIsFail ? Colors.redAccent : Colors.amberAccent);
    final bannerText = globalIsPass
        ? 'Calibración válida'
        : (globalIsFail ? 'Calibración rechazada' : 'Sin veredicto');

    return Container(
      decoration: BoxDecoration(
        color: const Color(0xFF16213e),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Banner global.
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: bannerColor.withOpacity(0.15),
              borderRadius: const BorderRadius.vertical(top: Radius.circular(8)),
              border: Border(
                left: BorderSide(color: bannerColor, width: 4),
              ),
            ),
            child: Row(
              children: [
                Icon(
                  globalIsPass
                      ? Icons.check_circle_outline
                      : (globalIsFail ? Icons.error_outline : Icons.help_outline),
                  color: bannerColor,
                  size: 22,
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        bannerText,
                        style: TextStyle(
                          color: bannerColor,
                          fontSize: 14,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      Text(
                        'Preset ${report.preset.name} · objetivo ${report.targetLevelDbSpl.toStringAsFixed(0)} dB SPL · '
                        'piso ${report.noiseFloor.noiseFloorDbFs.toStringAsFixed(1)} dB FS',
                        style: const TextStyle(color: Colors.white70, fontSize: 11),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          // Filas.
          for (final r in report.tones) _buildRow(r),
        ],
      ),
    );
  }

  Widget _buildRow(ToneTestResult r) {
    final isPass = r.isPass;
    final color = isPass ? Colors.greenAccent : Colors.redAccent;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: const BoxDecoration(
        border: Border(top: BorderSide(color: Colors.white12)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                isPass ? Icons.check : Icons.close,
                color: color,
                size: 16,
              ),
              const SizedBox(width: 8),
              Text(
                r.expectedFreqHz >= 1000
                    ? '${(r.expectedFreqHz / 1000).toStringAsFixed(1)} kHz'
                    : '${r.expectedFreqHz.toInt()} Hz',
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const Spacer(),
              _Chip(
                label: 'pico',
                value: r.peakFreqHz.isFinite
                    ? '${r.peakFreqHz.toStringAsFixed(0)} Hz'
                    : '—',
              ),
              const SizedBox(width: 6),
              _Chip(
                label: 'THD',
                value: r.thdPercent.isFinite ? '${r.thdPercent.toStringAsFixed(2)}%' : '—',
              ),
              const SizedBox(width: 6),
              _Chip(
                label: 'SNR',
                value: r.snrDb.isFinite ? '${r.snrDb.toStringAsFixed(0)} dB' : '—',
              ),
              const SizedBox(width: 6),
              _Chip(
                label: 'nivel',
                value: r.levelDbSpl.isFinite
                    ? '${r.levelDbSpl.toStringAsFixed(0)} dB SPL'
                    : '—',
              ),
            ],
          ),
          if (r.failureReasons.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 6, left: 24),
              child: Wrap(
                spacing: 6,
                runSpacing: 4,
                children: [
                  for (final reason in r.failureReasons)
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                      decoration: BoxDecoration(
                        color: Colors.redAccent.withOpacity(0.15),
                        borderRadius: BorderRadius.circular(4),
                      ),
                      child: Text(
                        reason.label,
                        style: const TextStyle(color: Colors.redAccent, fontSize: 10),
                      ),
                    ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

class _Chip extends StatelessWidget {
  final String label;
  final String value;
  const _Chip({required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
      decoration: BoxDecoration(
        color: const Color(0xFF1a1a2e),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(label, style: const TextStyle(color: Colors.white38, fontSize: 9)),
          const SizedBox(width: 4),
          Text(value, style: const TextStyle(color: Colors.white, fontSize: 10)),
        ],
      ),
    );
  }
}
