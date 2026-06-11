// Feature: in-app-diagnostic-analyzer
// Module: ui/tabs/summary_tab
//
// Resumen tab — recording metadata card + scrollable list of
// `Recommendation` items color-coded by severity. Insufficient-data
// banner when applicable.

import 'package:flutter/material.dart';

import '../../result/analysis_result.dart';
import '../../result/recommendations_result.dart';

class SummaryTab extends StatelessWidget {
  final AnalysisResult result;
  const SummaryTab({super.key, required this.result});

  @override
  Widget build(BuildContext context) {
    final r = result;
    final flags = _insufficientFlags(r);
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        _MetadataCard(result: r),
        const SizedBox(height: 12),
        _MetricsCard(result: r),
        const SizedBox(height: 12),
        if (flags.isNotEmpty) _InsufficientBanner(flags: flags),
        if (flags.isNotEmpty) const SizedBox(height: 12),
        if (r.recommendations.items.isEmpty)
          const _NoRecommendationsCard()
        else
          ...r.recommendations.items.map((item) => Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: _RecommendationTile(item: item),
              )),
      ],
    );
  }

  static List<String> _insufficientFlags(AnalysisResult r) {
    final out = <String>[];
    if (r.snr.insufficientVad) out.add('SNR: VAD insuficiente');
    if (r.noiseReduction.noiseInsufficient) out.add('NR: pocos segmentos de ruido');
    if (r.noiseReduction.signalInsufficient) out.add('NR: pocos segmentos de señal');
    if (r.wdrcIo.low.insufficientData) out.add('WDRC: zona Baja insuficiente');
    if (r.wdrcIo.mid.insufficientData) out.add('WDRC: zona Media insuficiente');
    if (r.wdrcIo.high.insufficientData) out.add('WDRC: zona Alta insuficiente');
    if (r.latency.lowConfidence) out.add('Latencia: baja confianza');
    if (r.thd.thdPercent.isNaN) out.add('THD: fundamental no detectado');
    return out;
  }
}

class _MetadataCard extends StatelessWidget {
  final AnalysisResult result;
  const _MetadataCard({required this.result});
  @override
  Widget build(BuildContext context) {
    final m = result.metadata;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Grabación: ${result.wavBaseName}',
                style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 8),
            _kv('Fecha', m.recordingTimestamp),
            _kv('Preset activo', m.activePreset),
            _kv('Dispositivo entrada', m.device.inputDevice),
            _kv('Dispositivo salida', m.device.outputDevice),
            _kv('Bluetooth', m.device.bluetoothDevice.isEmpty
                ? 'No conectado'
                : '${m.device.bluetoothDevice} (${m.device.bluetoothConnectionType})'),
            _kv('App version', m.appVersion),
            _kv('Schema version', m.schemaVersion),
          ],
        ),
      ),
    );
  }

  Widget _kv(String k, String v) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 2),
        child: RichText(
          text: TextSpan(
            style: const TextStyle(color: Colors.white70, fontSize: 13),
            children: [
              TextSpan(
                text: '$k: ',
                style: const TextStyle(fontWeight: FontWeight.w600),
              ),
              TextSpan(text: v),
            ],
          ),
        ),
      );
}

class _MetricsCard extends StatelessWidget {
  final AnalysisResult result;
  const _MetricsCard({required this.result});
  @override
  Widget build(BuildContext context) {
    final r = result;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Métricas globales',
                style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 8),
            _kv('Ganancia global', '${_fmt(r.quality.globalGainDb)} dB'),
            _kv('SNR mejora', '${_fmt(r.snr.snrImprovementDb)} dB'),
            _kv('THD', '${_fmt(r.thd.thdPercent)} %'),
            _kv('Latencia', '${_fmt(r.latency.latencyMs)} ms'),
            _kv('Ratio observado',
                '${_fmt(r.wdrcIo.observedCompressionRatio)} : 1'),
            _kv('Ratio configurado',
                '${_fmt(r.wdrcIo.configuredCompressionRatio)} : 1'),
          ],
        ),
      ),
    );
  }

  Widget _kv(String k, String v) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 2),
        child: RichText(
          text: TextSpan(
            style: const TextStyle(color: Colors.white70, fontSize: 13),
            children: [
              TextSpan(
                text: '$k: ',
                style: const TextStyle(fontWeight: FontWeight.w600),
              ),
              TextSpan(text: v),
            ],
          ),
        ),
      );

  static String _fmt(double v) {
    if (v.isNaN) return 'N/D';
    if (!v.isFinite) return v.isNegative ? '-∞' : '+∞';
    return v.toStringAsFixed(2);
  }
}

class _InsufficientBanner extends StatelessWidget {
  final List<String> flags;
  const _InsufficientBanner({required this.flags});
  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.amber.withOpacity(0.12),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: Colors.amber.withOpacity(0.4)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('Datos insuficientes en algunas métricas',
              style: TextStyle(
                  color: Colors.amber,
                  fontSize: 13,
                  fontWeight: FontWeight.w600)),
          const SizedBox(height: 4),
          ...flags.map((f) => Text(' • $f',
              style: const TextStyle(color: Colors.white70, fontSize: 12))),
        ],
      ),
    );
  }
}

class _NoRecommendationsCard extends StatelessWidget {
  const _NoRecommendationsCard();
  @override
  Widget build(BuildContext context) {
    return Card(
      color: Colors.green.withOpacity(0.1),
      child: const Padding(
        padding: EdgeInsets.all(16),
        child: Text(
          'Sin recomendaciones — la cadena DSP funciona dentro de los rangos esperados.',
          style: TextStyle(color: Colors.greenAccent, fontSize: 13),
        ),
      ),
    );
  }
}

class _RecommendationTile extends StatelessWidget {
  final Recommendation item;
  const _RecommendationTile({required this.item});
  @override
  Widget build(BuildContext context) {
    final color = _color(context, item.severity);
    final icon = _icon(item.severity);
    final label = _label(item.severity);
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: color.withOpacity(0.12),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: color.withOpacity(0.4)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, color: color, size: 20),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(label,
                    style: TextStyle(
                        color: color,
                        fontSize: 12,
                        fontWeight: FontWeight.w700)),
                const SizedBox(height: 2),
                Text(item.message,
                    style: const TextStyle(
                        color: Colors.white, fontSize: 13)),
              ],
            ),
          ),
        ],
      ),
    );
  }

  static Color _color(BuildContext context, RecommendationSeverity s) {
    switch (s) {
      case RecommendationSeverity.info:
        return Theme.of(context).colorScheme.primary;
      case RecommendationSeverity.warn:
        return Colors.amber;
      case RecommendationSeverity.error:
        return Theme.of(context).colorScheme.error;
    }
  }

  static IconData _icon(RecommendationSeverity s) {
    switch (s) {
      case RecommendationSeverity.info:
        return Icons.info_outline;
      case RecommendationSeverity.warn:
        return Icons.warning_amber_rounded;
      case RecommendationSeverity.error:
        return Icons.error_outline;
    }
  }

  static String _label(RecommendationSeverity s) {
    switch (s) {
      case RecommendationSeverity.info:
        return 'INFO';
      case RecommendationSeverity.warn:
        return 'AVISO';
      case RecommendationSeverity.error:
        return 'ERROR';
    }
  }
}
