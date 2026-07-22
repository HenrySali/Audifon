import 'package:flutter/material.dart';

import '../../services/denoiser_service.dart';

/// Panel de UI para el registro de "matraca" (crackle/clicks) y calidad de los
/// 3 sistemas de limpieza de ruido (RNNoise/DFN3/GTCRN).
///
/// Muestra, por sesión, la calidad y la tasa de clicks en la ENTRADA a los
/// sistemas, en cada uno de los 3 sistemas y en la SALIDA FINAL (lo que
/// escucha el usuario), permitiendo identificar en qué etapa aparece la
/// matraca o si viene de la fuente. Permite:
///   - Actualizar el resumen en vivo.
///   - Copiar el registro completo (texto con diagnóstico) al portapapeles.
///   - Reiniciar la sesión de medición.
class DenoiserArtifactLogPanel extends StatefulWidget {
  final DenoiserService service;
  const DenoiserArtifactLogPanel({super.key, required this.service});

  @override
  State<DenoiserArtifactLogPanel> createState() =>
      _DenoiserArtifactLogPanelState();
}

class _DenoiserArtifactLogPanelState extends State<DenoiserArtifactLogPanel> {
  Map<String, dynamic> _summary = <String, dynamic>{};
  bool _loading = false;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  Future<void> _refresh() async {
    if (_loading) return;
    setState(() => _loading = true);
    final s = await widget.service.getArtifactSummary();
    if (!mounted) return;
    setState(() {
      _summary = s;
      _loading = false;
    });
  }

  Future<void> _copy() async {
    if (_busy) return;
    setState(() => _busy = true);
    final ok = await widget.service.copyArtifactReportToClipboard();
    if (!mounted) return;
    setState(() => _busy = false);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(ok
            ? 'Registro de matraca copiado al portapapeles'
            : 'No hay registro para copiar (¿motor activo?)'),
        duration: const Duration(seconds: 2),
      ),
    );
  }

  Future<void> _reset() async {
    if (_busy) return;
    setState(() => _busy = true);
    await widget.service.resetArtifactLog();
    await _refresh();
    if (!mounted) return;
    setState(() => _busy = false);
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('Sesión de registro reiniciada'),
        duration: Duration(seconds: 2),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final int activeEngine = (_summary['activeEngine'] as int?) ?? -1;

    return Container(
      margin: const EdgeInsets.only(top: 6),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: Colors.black.withOpacity(0.35),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.graphic_eq, color: Colors.cyanAccent, size: 16),
              const SizedBox(width: 6),
              const Expanded(
                child: Text(
                  'Registro de matraca / calidad',
                  style: TextStyle(
                    color: Colors.cyanAccent,
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              if (_loading)
                const SizedBox(
                  width: 12,
                  height: 12,
                  child: CircularProgressIndicator(
                    strokeWidth: 2, color: Colors.cyanAccent),
                ),
            ],
          ),
          const SizedBox(height: 6),

          if (_summary.isEmpty)
            Text(
              'Sin datos aún. Con el limpiador de ruido activo, deja pasar unos '
              'segundos de audio y presiona "Actualizar".',
              style: TextStyle(color: Colors.grey[400], fontSize: 10.5),
            )
          else ...[
            _stageRow('Mic crudo', 'raw', highlight: false),
            _stageRow('Entrada (post-realce)', 'input', highlight: false),
            _stageRow('1· RNNoise', 'sys0', highlight: activeEngine == 0),
            _stageRow('2· DFN3', 'sys1', highlight: activeEngine == 1),
            _stageRow('3· GTCRN', 'sys2', highlight: activeEngine == 2),
            const Divider(height: 10, color: Colors.white12),
            _stageRow('Salida final', 'output', highlight: true),
          ],

          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 4,
            children: [
              _btn(Icons.refresh, 'Actualizar', _busy ? null : _refresh),
              _btn(Icons.copy, 'Copiar registro', _busy ? null : _copy),
              _btn(Icons.restart_alt, 'Reiniciar', _busy ? null : _reset),
            ],
          ),
        ],
      ),
    );
  }

  /// Fila compacta de una etapa: nombre + calidad (chip color) + clicks/s.
  Widget _stageRow(String label, String prefix, {required bool highlight}) {
    final bool active = (_summary['${prefix}Active'] as bool?) ?? false;
    final double quality =
        (_summary['${prefix}Quality'] as num?)?.toDouble() ?? 100.0;
    final double clicksPerSec =
        (_summary['${prefix}ClicksPerSec'] as num?)?.toDouble() ?? 0.0;
    final int clip = (_summary['${prefix}Clip'] as int?) ?? 0;
    final int nanInf = (_summary['${prefix}NanInf'] as int?) ?? 0;
    final double envFlutter =
        (_summary['${prefix}EnvFlutterDb'] as num?)?.toDouble() ?? 0.0;

    if (!active) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 2),
        child: Row(
          children: [
            Expanded(
              child: Text(label,
                  style: TextStyle(
                    color: Colors.grey[600],
                    fontSize: 11,
                    fontFamily: 'monospace',
                    fontWeight: highlight ? FontWeight.w700 : FontWeight.w400,
                  )),
            ),
            Text('— inactivo',
                style: TextStyle(color: Colors.grey[600], fontSize: 10.5)),
          ],
        ),
      );
    }

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        children: [
          Expanded(
            child: Text(
              label,
              style: TextStyle(
                color: highlight ? Colors.white : Colors.grey[300],
                fontSize: 11,
                fontFamily: 'monospace',
                fontWeight: highlight ? FontWeight.w700 : FontWeight.w400,
              ),
            ),
          ),
          // Clicks/s + aspereza (indicadores de matraca y "ronco").
          Text(
            '${clicksPerSec.toStringAsFixed(1)}/s'
            '${envFlutter >= 2.0 ? " ·ronco" : ""}'
            '${clip > 0 ? " ·clip" : ""}'
            '${nanInf > 0 ? " ·NaN" : ""}',
            style: TextStyle(
              color: clicksPerSec >= 0.5 || envFlutter >= 2.0 || clip > 0 || nanInf > 0
                  ? Colors.orangeAccent
                  : Colors.grey[400],
              fontSize: 10.5,
              fontFamily: 'monospace',
            ),
          ),
          const SizedBox(width: 8),
          _qualityChip(quality),
        ],
      ),
    );
  }

  Widget _qualityChip(double quality) {
    final Color c = quality >= 85
        ? Colors.greenAccent
        : (quality >= 60 ? Colors.amberAccent : Colors.redAccent);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
      decoration: BoxDecoration(
        color: c.withOpacity(0.18),
        borderRadius: BorderRadius.circular(4),
        border: Border.all(color: c.withOpacity(0.6), width: 0.8),
      ),
      child: Text(
        '${quality.round()}',
        style: TextStyle(
          color: c,
          fontSize: 11,
          fontFamily: 'monospace',
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }

  Widget _btn(IconData icon, String label, VoidCallback? onTap) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(6),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
        decoration: BoxDecoration(
          color: Colors.white.withOpacity(onTap == null ? 0.04 : 0.08),
          borderRadius: BorderRadius.circular(6),
          border: Border.all(color: Colors.white24, width: 0.8),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon,
                size: 13,
                color: onTap == null ? Colors.white38 : Colors.cyanAccent),
            const SizedBox(width: 4),
            Text(
              label,
              style: TextStyle(
                color: onTap == null ? Colors.white38 : Colors.white70,
                fontSize: 10.5,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
