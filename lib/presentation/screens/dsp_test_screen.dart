import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../domain/entities/eq_preset.dart';
import '../bloc/amplification_bloc.dart';
import '../bloc/amplification_state.dart';

/// Pantalla de diagnóstico del pipeline DSP — muestra métricas en tiempo real
/// de cada etapa para cada preset EQ. Útil para depurar distorsión.
class DspTestScreen extends StatefulWidget {
  const DspTestScreen({super.key});

  @override
  State<DspTestScreen> createState() => _DspTestScreenState();
}

class _DspTestScreenState extends State<DspTestScreen> {
  static const _channel = MethodChannel('com.psk.hearing_aid/audio');
  Timer? _pollTimer;
  int? _activePresetIndex;
  Map<String, dynamic>? _metrics;
  bool _runningAll = false;
  int _runAllIndex = 0;
  final List<Map<String, dynamic>> _testLog = [];

  @override
  void dispose() {
    _pollTimer?.cancel();
    super.dispose();
  }

  void _startTest(int idx) {
    setState(() { _activePresetIndex = idx; _metrics = null; });
    _pollTimer?.cancel();
    _pollTimer = Timer.periodic(const Duration(milliseconds: 100), (_) => _fetch());
  }

  void _stopTest() {
    _pollTimer?.cancel();
    setState(() { _activePresetIndex = null; _metrics = null; });
  }

  Future<void> _fetch() async {
    try {
      final r = await _channel.invokeMethod<Map>('getDspStageMetrics');
      if (mounted && r != null) setState(() => _metrics = Map<String, dynamic>.from(r));
    } on MissingPluginException {
      if (mounted) setState(() => _metrics = null);
    } catch (_) {}
  }

  Future<void> _runAll() async {
    setState(() { _runningAll = true; _runAllIndex = 0; _testLog.clear(); });
    for (int i = 0; i < EqPreset.allPresets.length; i++) {
      if (!mounted || !_runningAll) break;
      setState(() => _runAllIndex = i);
      _startTest(i);
      await Future.delayed(const Duration(seconds: 3));
      _testLog.add({
        'preset': EqPreset.allPresets[i].name,
        'ts': DateTime.now().toIso8601String(),
        'metrics': _metrics ?? {'status': 'native_not_available'},
      });
    }
    _stopTest();
    if (mounted) setState(() => _runningAll = false);
  }

  void _exportLog() {
    if (_testLog.isEmpty) return;
    final json = const JsonEncoder.withIndent('  ').convert({
      'date': DateTime.now().toIso8601String(),
      'results': _testLog,
    });
    Clipboard.setData(ClipboardData(text: json));
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('📋 Log copied (${_testLog.length} presets)')),
    );
  }

  Color _lvlColor(double? v) {
    if (v == null) return Colors.white38;
    if (v > 0.95) return Colors.red;
    if (v > 0.8) return Colors.orange;
    return Colors.green;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF0a0e21),
      appBar: AppBar(
        title: const Text('DSP Pipeline Test'),
        backgroundColor: const Color(0xFF0f3460),
        foregroundColor: Colors.white,
        actions: [
          if (_testLog.isNotEmpty)
            IconButton(icon: const Icon(Icons.copy), tooltip: 'Export JSON', onPressed: _exportLog),
        ],
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(12),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          _buildRunAll(),
          const SizedBox(height: 10),
          if (_activePresetIndex != null) ...[
            _buildMetrics(),
            const SizedBox(height: 8),
            _buildEqBars(),
            const SizedBox(height: 8),
            _buildWdrc(),
            const SizedBox(height: 12),
          ],
          _buildPresets(),
        ]),
      ),
    );
  }

  Widget _buildRunAll() {
    return ElevatedButton.icon(
      onPressed: _runningAll ? () => setState(() => _runningAll = false) : _runAll,
      icon: Icon(_runningAll ? Icons.stop : Icons.play_arrow, size: 18),
      label: Text(_runningAll
          ? 'Stop (${_runAllIndex + 1}/${EqPreset.allPresets.length})'
          : 'Run All Tests'),
      style: ElevatedButton.styleFrom(
        backgroundColor: _runningAll ? Colors.red.withOpacity(0.2) : Colors.cyan.withOpacity(0.15),
        foregroundColor: _runningAll ? Colors.red : Colors.cyan,
        side: BorderSide(color: _runningAll ? Colors.red : Colors.cyan),
        padding: const EdgeInsets.symmetric(vertical: 12),
      ),
    );
  }

  Widget _buildMetrics() {
    final preset = EqPreset.allPresets[_activePresetIndex!];
    final m = _metrics;
    return Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: const Color(0xFF16213e),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: Colors.cyan.withOpacity(0.3)),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          const Icon(Icons.analytics, color: Color(0xFF00e5ff), size: 16),
          const SizedBox(width: 6),
          Text('Testing: ${preset.name}',
              style: const TextStyle(color: Color(0xFF00e5ff), fontSize: 13, fontWeight: FontWeight.w600)),
          const Spacer(),
          if (m == null)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
              decoration: BoxDecoration(color: Colors.orange.withOpacity(0.2), borderRadius: BorderRadius.circular(4)),
              child: const Text('Native N/A', style: TextStyle(color: Colors.orange, fontSize: 9)),
            ),
        ]),
        const SizedBox(height: 8),
        _mRow('Input', m?['inputLevel']),
        _mRow('Post-NR', m?['postNrLevel']),
        _mRow('Post-EQ', m?['postEqLevel']),
        _mRow('Post-WDRC', m?['postWdrcLevel']),
        _mRow('Post-Vol', m?['postVolumeLevel']),
        _mRow('Output', m?['outputLevel']),
        const Divider(color: Colors.white12, height: 12),
        _peakClipRow(m),
      ]),
    );
  }

  Widget _mRow(String label, dynamic val) {
    final double? v = val is num ? val.toDouble() : null;
    final norm = v != null ? (v / 120.0).clamp(0.0, 1.0) : null;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 1.5),
      child: Row(children: [
        SizedBox(width: 70, child: Text(label, style: const TextStyle(color: Color(0xFF00e5ff), fontSize: 11))),
        Expanded(
          child: ClipRRect(
            borderRadius: BorderRadius.circular(2),
            child: SizedBox(height: 6, child: LinearProgressIndicator(
              value: norm ?? 0, backgroundColor: Colors.white.withOpacity(0.05), color: _lvlColor(norm),
            )),
          ),
        ),
        const SizedBox(width: 6),
        SizedBox(width: 60, child: Text(
          v != null ? '${v.toStringAsFixed(1)} dB' : 'N/A',
          style: TextStyle(color: v != null ? Colors.white : Colors.white38, fontSize: 10),
          textAlign: TextAlign.right,
        )),
      ]),
    );
  }

  Widget _peakClipRow(Map<String, dynamic>? m) {
    final peak = m?['peakSample'] is num ? (m!['peakSample'] as num).toDouble() : null;
    final clips = m?['clipCount'] is num ? (m!['clipCount'] as num).toInt() : null;
    final peakC = peak != null && peak >= 0.95 ? Colors.red : (peak != null && peak >= 0.8 ? Colors.orange : Colors.green);
    final clipC = clips != null && clips > 0 ? Colors.red : Colors.green;
    return Row(children: [
      Icon(peak != null && peak >= 0.95 ? Icons.warning_amber : Icons.check_circle_outline, color: peakC, size: 13),
      const SizedBox(width: 4),
      Text('Peak: ${peak?.toStringAsFixed(3) ?? "N/A"}', style: TextStyle(color: peakC, fontSize: 11)),
      const SizedBox(width: 16),
      Icon(clips != null && clips > 0 ? Icons.error : Icons.check_circle_outline, color: clipC, size: 13),
      const SizedBox(width: 4),
      Text('Clips: ${clips ?? "N/A"}', style: TextStyle(color: clipC, fontSize: 11)),
    ]);
  }

  Widget _buildEqBars() {
    final preset = EqPreset.allPresets[_activePresetIndex!];
    final maxG = preset.gains.reduce((a, b) => a > b ? a : b);
    return Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(color: const Color(0xFF16213e), borderRadius: BorderRadius.circular(8)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          const Icon(Icons.equalizer, color: Color(0xFF00e5ff), size: 14),
          const SizedBox(width: 4),
          const Text('EQ Gains', style: TextStyle(color: Color(0xFF00e5ff), fontSize: 11)),
          const Spacer(),
          Text('Max: ${maxG.toInt()} dB', style: TextStyle(color: maxG > 14 ? Colors.orange : Colors.white54, fontSize: 10)),
        ]),
        const SizedBox(height: 6),
        SizedBox(
          height: 50,
          child: Row(crossAxisAlignment: CrossAxisAlignment.end, children: List.generate(12, (i) {
            final g = preset.gains[i];
            final c = g > 14 ? Colors.orange : Colors.cyan.withOpacity(g > 8 ? 1.0 : 0.6);
            return Expanded(child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 1),
              child: Column(mainAxisAlignment: MainAxisAlignment.end, children: [
                Text('${g.toInt()}', style: TextStyle(color: c, fontSize: 7)),
                const SizedBox(height: 1),
                Container(height: (g / 50.0 * 40).clamp(2.0, 40.0), decoration: BoxDecoration(color: c, borderRadius: BorderRadius.circular(2))),
              ]),
            ));
          })),
        ),
        const SizedBox(height: 3),
        Row(children: List.generate(12, (i) => Expanded(
          child: Text(EqPreset.bandLabels[i], style: const TextStyle(color: Colors.white38, fontSize: 7), textAlign: TextAlign.center),
        ))),
      ]),
    );
  }

  Widget _buildWdrc() {
    final m = _metrics;
    final gf = m?['wdrcGainFactor'];
    final region = m?['wdrcRegion'] as String?;
    Color rc(String? r) => switch (r) { 'expansion' => Colors.blue, 'linear' => Colors.green, 'compression' => Colors.orange, _ => Colors.white38 };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(color: const Color(0xFF16213e), borderRadius: BorderRadius.circular(8)),
      child: Row(children: [
        const Icon(Icons.compress, color: Color(0xFF00e5ff), size: 14),
        const SizedBox(width: 6),
        const Text('WDRC', style: TextStyle(color: Color(0xFF00e5ff), fontSize: 11)),
        const SizedBox(width: 12),
        Text('Gain: ${gf is num ? gf.toStringAsFixed(3) : "N/A"}', style: const TextStyle(color: Colors.white, fontSize: 11)),
        const SizedBox(width: 12),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
          decoration: BoxDecoration(color: rc(region).withOpacity(0.2), borderRadius: BorderRadius.circular(4), border: Border.all(color: rc(region).withOpacity(0.5))),
          child: Text(region ?? 'N/A', style: TextStyle(color: rc(region), fontSize: 10, fontWeight: FontWeight.w600)),
        ),
      ]),
    );
  }

  Widget _buildPresets() {
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      const Padding(
        padding: EdgeInsets.only(left: 4, bottom: 6),
        child: Text('EQ Presets', style: TextStyle(color: Color(0xFF00e5ff), fontSize: 12, fontWeight: FontWeight.w600)),
      ),
      ...List.generate(EqPreset.allPresets.length, (i) {
        final p = EqPreset.allPresets[i];
        final active = _activePresetIndex == i;
        final maxG = p.gains.reduce((a, b) => a > b ? a : b);
        return Container(
          margin: const EdgeInsets.only(bottom: 5),
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
          decoration: BoxDecoration(
            color: active ? Colors.cyan.withOpacity(0.08) : const Color(0xFF16213e),
            borderRadius: BorderRadius.circular(7),
            border: active ? Border.all(color: Colors.cyan.withOpacity(0.4)) : null,
          ),
          child: Row(children: [
            Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(p.name, style: TextStyle(color: active ? Colors.cyan : Colors.white, fontSize: 12, fontWeight: FontWeight.w600)),
              Text('${p.description} · Max ${maxG.toInt()} dB · CR ${p.compressionRatio}:1',
                  style: const TextStyle(color: Colors.white38, fontSize: 9)),
            ])),
            SizedBox(height: 28, child: ElevatedButton(
              onPressed: _runningAll ? null : () => active ? _stopTest() : _startTest(i),
              style: ElevatedButton.styleFrom(
                backgroundColor: active ? Colors.red.withOpacity(0.2) : Colors.cyan.withOpacity(0.12),
                foregroundColor: active ? Colors.red : Colors.cyan,
                side: BorderSide(color: active ? Colors.red : Colors.cyan, width: 0.5),
                padding: const EdgeInsets.symmetric(horizontal: 10),
                textStyle: const TextStyle(fontSize: 10),
              ),
              child: Text(active ? 'Stop' : 'Test'),
            )),
          ]),
        );
      }),
    ]);
  }
}
