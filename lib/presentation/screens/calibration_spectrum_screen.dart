/// @file calibration_spectrum_screen.dart
/// @brief Pantalla del Calibration Spectrum Validator (Servicio Técnico).
///
/// Cubre REQ-1 a REQ-13:
///  - Disclaimer modal en primer uso.
///  - Selectors: preset (clínico/premium), nivel objetivo, freqs opcionales.
///  - Espectro instantáneo + waterfall + métricas vivas durante la secuencia.
///  - Tabla resumen al final con causas de fallo ordenadas.
///  - Botón "Aplicar" deshabilitado si globalVerdict = fail.

import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../calibration_spectrum/acceptance_criteria.dart';
import '../../calibration_spectrum/calibration_report_json.dart';
import '../../calibration_spectrum/tone_method_channel.dart';
import '../../calibration_spectrum/tone_snapshot.dart';
import '../../calibration_spectrum/tone_test_result.dart';
import '../../calibration_spectrum/validator_orchestrator.dart';
import '../../calibration_spectrum/widgets/metrics_panel.dart';
import '../../calibration_spectrum/widgets/results_table.dart';
import '../../calibration_spectrum/widgets/spectrum_view.dart';
import '../../calibration_spectrum/widgets/waterfall_view.dart';

const _kDisclaimerText =
    'Esta herramienta es un daily / biological calibration check. '
    'NO reemplaza la calibración exhaustiva anual trazable a NIST. '
    'Confirmá antes de emitir tonos: vas a escuchar señales puras de prueba.';

class CalibrationSpectrumScreen extends StatefulWidget {
  const CalibrationSpectrumScreen({super.key});

  @override
  State<CalibrationSpectrumScreen> createState() => _CalibrationSpectrumScreenState();
}

class _CalibrationSpectrumScreenState extends State<CalibrationSpectrumScreen> {
  final _orchestrator = ValidatorOrchestrator();
  final _channel = const ToneMethodChannel();

  // Configuración de la sesión.
  AcceptancePreset _preset = AcceptancePreset.clinical;
  double _targetLevelDbSpl = 50.0;
  bool _include125 = false;
  bool _include6k = false;
  WaterfallColormap _colormap = WaterfallColormap.viridis;

  // Estado.
  bool _running = false;
  bool _disclaimerAcked = false;
  ToneSnapshot _liveSnapshot = ToneSnapshot.empty();
  ToneTestProgress? _progress;
  CalibrationSequenceReport? _report;
  String? _errorMessage;

  Timer? _pollTimer;

  @override
  void initState() {
    super.initState();
    // Mostrar disclaimer en el primer frame del primer abrimiento de la pantalla.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_disclaimerAcked) _showDisclaimer(blocking: true);
    });
  }

  Future<void> _showDisclaimer({bool blocking = false}) async {
    final acked = await showDialog<bool>(
      context: context,
      barrierDismissible: !blocking,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF16213e),
        title: const Text('Aviso importante',
            style: TextStyle(color: Color(0xFF00e5ff))),
        content: const Text(
          _kDisclaimerText,
          style: TextStyle(color: Colors.white70, fontSize: 13),
        ),
        actions: [
          if (!blocking)
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(false),
              child: const Text('Cerrar'),
            ),
          ElevatedButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFF00e5ff),
              foregroundColor: Colors.black,
            ),
            child: const Text('Entendido'),
          ),
        ],
      ),
    );
    if (acked == true && mounted) setState(() => _disclaimerAcked = true);
  }

  List<double> _buildFrequencyList() {
    final list = <double>[];
    if (_include125) list.add(125);
    list.addAll([250, 500, 1000, 2000, 4000]);
    if (_include6k) list.add(6000);
    list.add(8000);
    return list;
  }

  Future<void> _startSequence() async {
    if (_running) return;
    if (!_disclaimerAcked) {
      await _showDisclaimer(blocking: true);
      if (!_disclaimerAcked) return;
    }

    final freqs = _buildFrequencyList();
    setState(() {
      _running = true;
      _report = null;
      _progress = null;
      _errorMessage = null;
      _liveSnapshot = ToneSnapshot.empty();
    });

    _startPolling();

    try {
      final report = await _orchestrator.runSequence(
        frequenciesHz: freqs,
        targetLevelDbSpl: _targetLevelDbSpl,
        preset: _preset,
        onProgress: (p) {
          if (mounted) setState(() => _progress = p);
        },
      );
      if (!mounted) return;
      setState(() {
        _report = report;
        if (report.tones.isEmpty &&
            report.noiseFloor.rejectionReason != null) {
          _errorMessage = report.noiseFloor.rejectionReason;
        }
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _errorMessage = 'Error: ${e.toString()}';
      });
    } finally {
      _stopPolling();
      if (mounted) setState(() => _running = false);
    }
  }

  Future<void> _cancel() async {
    await _orchestrator.cancel();
    if (!mounted) return;
    setState(() => _running = false);
    _stopPolling();
  }

  void _startPolling() {
    _stopPolling();
    _pollTimer = Timer.periodic(const Duration(milliseconds: 100), (_) async {
      if (!_running) return;
      try {
        final snap = await _channel.getSnapshot();
        if (!mounted) return;
        setState(() => _liveSnapshot = snap);
      } catch (_) {
        // tolerar lecturas inválidas
      }
    });
  }

  void _stopPolling() {
    _pollTimer?.cancel();
    _pollTimer = null;
  }

  @override
  void dispose() {
    _stopPolling();
    _orchestrator.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: !_running,
      onPopInvokedWithResult: (didPop, result) async {
        if (didPop) return;
        final confirm = await showDialog<bool>(
          context: context,
          builder: (ctx) => AlertDialog(
            backgroundColor: const Color(0xFF16213e),
            title: const Text('Cancelar validación',
                style: TextStyle(color: Colors.amberAccent)),
            content: const Text(
              'Hay una secuencia en curso. ¿Cancelarla y volver atrás?',
              style: TextStyle(color: Colors.white70),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(ctx).pop(false),
                child: const Text('Seguir validando'),
              ),
              ElevatedButton(
                onPressed: () => Navigator.of(ctx).pop(true),
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.amberAccent,
                  foregroundColor: Colors.black,
                ),
                child: const Text('Cancelar'),
              ),
            ],
          ),
        );
        if (confirm == true && mounted) {
          await _cancel();
          if (mounted) Navigator.of(context).pop();
        }
      },
      child: Scaffold(
        backgroundColor: const Color(0xFF1a1a2e),
        appBar: AppBar(
          backgroundColor: const Color(0xFF0f3460),
          title: const Text(
            'Validación Espectral',
            style: TextStyle(fontSize: 17, fontWeight: FontWeight.w600),
          ),
          iconTheme: const IconThemeData(color: Colors.white),
          actions: [
            IconButton(
              tooltip: 'Disclaimer',
              icon: const Icon(Icons.info_outline, color: Colors.white70),
              onPressed: () => _showDisclaimer(),
            ),
          ],
        ),
        body: SafeArea(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _buildConfigPanel(),
                const SizedBox(height: 12),
                if (_errorMessage != null) _buildErrorBanner(),
                if (_running || _liveSnapshot.peakFreqHz.isFinite) ...[
                  _buildLiveStatus(),
                  const SizedBox(height: 12),
                  SpectrumView(
                    snapshot: _liveSnapshot,
                    freqTolerancePercent:
                        AcceptanceCriteria.fromPreset(_preset).freqTolerancePercent,
                  ),
                  const SizedBox(height: 12),
                  WaterfallView(snapshot: _liveSnapshot, colormap: _colormap),
                  const SizedBox(height: 12),
                  MetricsPanel(
                    snapshot: _liveSnapshot,
                    targetLevelDbSpl: _targetLevelDbSpl,
                  ),
                  const SizedBox(height: 12),
                ],
                if (_report != null && _report!.tones.isNotEmpty) ...[
                  ResultsTable(report: _report!),
                  const SizedBox(height: 12),
                ],
                _buildActions(),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildConfigPanel() {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: const Color(0xFF16213e),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Configuración',
            style: TextStyle(
              color: Color(0xFF00e5ff),
              fontSize: 13,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              const Text('Preset:', style: TextStyle(color: Colors.white70, fontSize: 12)),
              const SizedBox(width: 8),
              for (final p in AcceptancePreset.values)
                Padding(
                  padding: const EdgeInsets.only(right: 6),
                  child: ChoiceChip(
                    label: Text(p == AcceptancePreset.clinical ? 'Clínico' : 'Premium'),
                    selected: _preset == p,
                    onSelected: _running ? null : (_) => setState(() => _preset = p),
                    selectedColor: const Color(0xFF00e5ff),
                    labelStyle: TextStyle(
                      color: _preset == p ? Colors.black : Colors.white70,
                      fontSize: 12,
                    ),
                    backgroundColor: const Color(0xFF1a1a2e),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              const Text('Nivel objetivo:',
                  style: TextStyle(color: Colors.white70, fontSize: 12)),
              const SizedBox(width: 8),
              DropdownButton<double>(
                value: _targetLevelDbSpl,
                dropdownColor: const Color(0xFF16213e),
                style: const TextStyle(color: Colors.white, fontSize: 12),
                items: const [40.0, 45.0, 50.0, 55.0, 60.0, 65.0, 70.0, 75.0, 80.0]
                    .map((v) => DropdownMenuItem(
                          value: v,
                          child: Text('${v.toInt()} dB SPL'),
                        ))
                    .toList(),
                onChanged: _running
                    ? null
                    : (v) => setState(() => _targetLevelDbSpl = v ?? _targetLevelDbSpl),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Wrap(
            children: [
              _buildOptionalToggle(
                label: '125 Hz',
                value: _include125,
                onChanged: (v) => setState(() => _include125 = v),
              ),
              _buildOptionalToggle(
                label: '6 kHz',
                value: _include6k,
                onChanged: (v) => setState(() => _include6k = v),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Row(
            children: [
              const Text('Colormap:',
                  style: TextStyle(color: Colors.white70, fontSize: 12)),
              const SizedBox(width: 8),
              for (final c in WaterfallColormap.values)
                Padding(
                  padding: const EdgeInsets.only(right: 6),
                  child: ChoiceChip(
                    label: Text(switch (c) {
                      WaterfallColormap.viridis => 'Viridis',
                      WaterfallColormap.grayscale => 'Grayscale',
                      WaterfallColormap.rainbow => 'Rainbow ⚠',
                    }),
                    selected: _colormap == c,
                    onSelected: (_) => _setColormap(c),
                    selectedColor: const Color(0xFF00e5ff),
                    labelStyle: TextStyle(
                      color: _colormap == c ? Colors.black : Colors.white70,
                      fontSize: 11,
                    ),
                    backgroundColor: const Color(0xFF1a1a2e),
                  ),
                ),
            ],
          ),
        ],
      ),
    );
  }

  Future<void> _setColormap(WaterfallColormap c) async {
    if (c == WaterfallColormap.rainbow) {
      final ok = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          backgroundColor: const Color(0xFF16213e),
          title: const Text('Rainbow no recomendado',
              style: TextStyle(color: Colors.amberAccent)),
          content: const Text(
            'El colormap rainbow puede generar lecturas falsas en datos cuantitativos. '
            'Se recomienda viridis o grayscale.',
            style: TextStyle(color: Colors.white70),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(false),
              child: const Text('Cancelar'),
            ),
            ElevatedButton(
              onPressed: () => Navigator.of(ctx).pop(true),
              child: const Text('Usar rainbow'),
            ),
          ],
        ),
      );
      if (ok != true) return;
    }
    setState(() => _colormap = c);
  }

  Widget _buildOptionalToggle({
    required String label,
    required bool value,
    required ValueChanged<bool> onChanged,
  }) {
    return Padding(
      padding: const EdgeInsets.only(right: 8),
      child: FilterChip(
        label: Text(label),
        selected: value,
        onSelected: _running ? null : onChanged,
        selectedColor: const Color(0xFF00e5ff),
        backgroundColor: const Color(0xFF1a1a2e),
        labelStyle: TextStyle(
          color: value ? Colors.black : Colors.white70,
          fontSize: 11,
        ),
      ),
    );
  }

  Widget _buildErrorBanner() {
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: Colors.redAccent.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(6),
        border: Border(left: BorderSide(color: Colors.redAccent, width: 4)),
      ),
      child: Row(
        children: [
          const Icon(Icons.error_outline, color: Colors.redAccent),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              _errorMessage ?? '',
              style: const TextStyle(color: Colors.redAccent, fontSize: 12),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildLiveStatus() {
    String text;
    if (_progress?.isMeasuringNoiseFloor == true) {
      text = 'Midiendo piso de ruido (1 s)…';
    } else if (_progress != null && _running) {
      text =
          'Tono ${_progress!.currentToneIndex + 1}/${_progress!.totalTones} · '
          '${_progress!.currentFreqHz.toInt()} Hz';
    } else if (_running) {
      text = 'Iniciando…';
    } else {
      text = 'Listo';
    }
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: const Color(0xFF16213e),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Row(
        children: [
          const SizedBox(
            width: 14,
            height: 14,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(text, style: const TextStyle(color: Colors.white70, fontSize: 12)),
          ),
        ],
      ),
    );
  }

  Future<void> _showExportDialog() async {
    if (_report == null) return;
    final json = calibrationReportToJson(_report!);
    final encoder = const JsonEncoder.withIndent('  ');
    final text = encoder.convert(json);
    final filename = suggestedReportFilename();

    if (!mounted) return;
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF16213e),
        title: Row(
          children: [
            const Icon(Icons.description_outlined, color: Color(0xFF00e5ff)),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                filename,
                style: const TextStyle(color: Color(0xFF00e5ff), fontSize: 13),
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
        content: SizedBox(
          width: 480,
          height: 360,
          child: Container(
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: const Color(0xFF1a1a2e),
              borderRadius: BorderRadius.circular(6),
            ),
            child: SingleChildScrollView(
              child: SelectableText(
                text,
                style: const TextStyle(
                  color: Colors.white70,
                  fontFamily: 'monospace',
                  fontSize: 11,
                  height: 1.3,
                ),
              ),
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('Cerrar'),
          ),
          ElevatedButton.icon(
            onPressed: () async {
              await Clipboard.setData(ClipboardData(text: text));
              if (!ctx.mounted) return;
              ScaffoldMessenger.of(ctx).showSnackBar(
                const SnackBar(content: Text('Reporte copiado al portapapeles')),
              );
            },
            icon: const Icon(Icons.copy),
            label: const Text('Copiar JSON'),
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFF00e5ff),
              foregroundColor: Colors.black,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildActions() {
    final hasReport = _report != null && _report!.tones.isNotEmpty;
    final isPass = hasReport && _report!.globalVerdict == ToneVerdict.pass;

    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        if (!_running)
          ElevatedButton.icon(
            onPressed: _startSequence,
            icon: const Icon(Icons.play_arrow),
            label: Text(hasReport ? 'Reintentar' : 'Iniciar validación'),
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFF00e5ff),
              foregroundColor: Colors.black,
            ),
          ),
        if (_running)
          OutlinedButton.icon(
            onPressed: _cancel,
            icon: const Icon(Icons.stop, color: Colors.amberAccent),
            label: const Text('Cancelar'),
            style: OutlinedButton.styleFrom(
              foregroundColor: Colors.amberAccent,
              side: const BorderSide(color: Colors.amberAccent),
            ),
          ),
        if (hasReport)
          OutlinedButton.icon(
            onPressed: () => _showExportDialog(),
            icon: const Icon(Icons.file_download_outlined),
            label: const Text('Exportar reporte'),
            style: OutlinedButton.styleFrom(foregroundColor: Colors.white70),
          ),
        if (hasReport)
          ElevatedButton.icon(
            onPressed: isPass
                ? () => ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(content: Text('Calibración aplicada')),
                    )
                : null,
            icon: const Icon(Icons.check),
            label: const Text('Aplicar'),
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.greenAccent,
              foregroundColor: Colors.black,
              disabledBackgroundColor: Colors.white12,
              disabledForegroundColor: Colors.white38,
            ),
          ),
      ],
    );
  }
}
