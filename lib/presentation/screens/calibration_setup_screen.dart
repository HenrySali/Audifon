/// @file calibration_setup_screen.dart
/// @brief Pantalla de calibración inicial del dispositivo (1 sola vez).
///
/// El usuario reproduce cada tono al volumen del celu al máximo, mide
/// el SPL real con un sonómetro externo (físico o app), y lo ingresa.
/// La app guarda el offset dBFS↔dB SPL por frecuencia.
///
/// Cumple conceptualmente ANSI S3.6 §5: el usuario calibra contra una
/// referencia trazable externa (sonómetro). En validaciones diarias
/// sólo se verifica que los offsets no hayan derivado.

import 'dart:async';

import 'package:flutter/material.dart';

import '../../calibration_spectrum/device_calibration.dart';
import '../../calibration_spectrum/tone_emitter.dart';
import '../../calibration_spectrum/tone_method_channel.dart';
import '../../calibration_spectrum/tone_snapshot.dart';

class CalibrationSetupScreen extends StatefulWidget {
  const CalibrationSetupScreen({super.key});

  @override
  State<CalibrationSetupScreen> createState() => _CalibrationSetupScreenState();
}

class _CalibrationSetupScreenState extends State<CalibrationSetupScreen> {
  static const List<double> _freqs = [125, 250, 500, 1000, 2000, 4000, 6000, 8000];

  final _emitter = ToneEmitter();
  final _channel = const ToneMethodChannel();

  // Estado por frecuencia.
  final Map<double, double?> _measuredDbFs = {};
  final Map<double, double> _userSpl = {};
  final Map<double, TextEditingController> _ctrls = {};

  bool _busyFreq = false;
  double? _currentFreq;
  Timer? _captureTimer;

  @override
  void initState() {
    super.initState();
    for (final f in _freqs) {
      _measuredDbFs[f] = null;
      _userSpl[f] = 70.0;
      _ctrls[f] = TextEditingController(text: '70');
    }
    _loadExisting();
  }

  Future<void> _loadExisting() async {
    final cal = await DeviceCalibrationStore.load();
    if (cal == null || !mounted) return;
    setState(() {
      for (final f in _freqs) {
        final e = cal.entryFor(f);
        if (e != null) {
          _measuredDbFs[f] = e.referenceDbFs;
          _userSpl[f] = e.referenceDbSpl;
          _ctrls[f]!.text = e.referenceDbSpl.toStringAsFixed(0);
        }
      }
    });
  }

  @override
  void dispose() {
    _captureTimer?.cancel();
    _emitter.stop();
    _emitter.dispose();
    _channel.setActive(false);
    for (final c in _ctrls.values) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _measureFreq(double freqHz) async {
    if (_busyFreq) return;
    setState(() {
      _busyFreq = true;
      _currentFreq = freqHz;
    });

    try {
      // Configurar analyzer (offset 76 default - lo recalibramos justamente acá).
      await _channel.configure(
        sampleRate: 48000,
        fftSize: 4096,
        windowType: WindowType.hann,
        harmonicsCount: 4,
        dbfsToDbsplOffset: 76.0,
      );
      await _channel.setExpectedFrequency(freqHz);
      await _channel.setActive(true);

      // Reproducir tono 4 segundos para que estabilice.
      await _emitter.playTone(
        freqHz: freqHz,
        levelDbSpl: 70.0,
        durationMs: 4000,
      );

      // Esperar 1 segundo para que el ToneAnalyzer estabilice y leer.
      await Future.delayed(const Duration(milliseconds: 1500));
      final snap = await _channel.getSnapshot();
      double? dbFs;
      if (snap.peakMagnitudeDbfs.isFinite) {
        dbFs = snap.peakMagnitudeDbfs;
      }

      // Esperar que termine.
      await Future.delayed(const Duration(milliseconds: 2700));
      await _emitter.stop();
      await _channel.setActive(false);

      if (!mounted) return;
      setState(() {
        _measuredDbFs[freqHz] = dbFs;
      });
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Error midiendo $freqHz Hz: $e')),
      );
    } finally {
      if (mounted) {
        setState(() {
          _busyFreq = false;
          _currentFreq = null;
        });
      }
    }
  }

  Future<void> _save() async {
    final entries = <double, CalibrationEntry>{};
    for (final f in _freqs) {
      final m = _measuredDbFs[f];
      final s = double.tryParse(_ctrls[f]!.text.trim().replaceAll(',', '.'));
      if (m != null && s != null) {
        entries[f] = CalibrationEntry(
          freqHz: f,
          referenceDbFs: m,
          referenceDbSpl: s,
        );
      }
    }
    if (entries.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Mediná al menos una frecuencia.')),
      );
      return;
    }
    final cal = DeviceCalibration(
      timestamp: DateTime.now(),
      entries: entries,
    );
    await DeviceCalibrationStore.save(cal);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('Calibración guardada para ${entries.length} frecuencias'),
        backgroundColor: Colors.greenAccent,
      ),
    );
    Navigator.of(context).pop(true);
  }

  Future<void> _clear() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF16213e),
        title: const Text('Borrar calibración',
            style: TextStyle(color: Colors.amberAccent)),
        content: const Text(
          'Vas a borrar la calibración guardada de este dispositivo. '
          'Esto requiere recalibrar con un sonómetro externo. ¿Continuar?',
          style: TextStyle(color: Colors.white70),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Cancelar'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            style: ElevatedButton.styleFrom(backgroundColor: Colors.redAccent),
            child: const Text('Borrar'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    await DeviceCalibrationStore.clear();
    if (!mounted) return;
    setState(() {
      for (final f in _freqs) {
        _measuredDbFs[f] = null;
        _userSpl[f] = 70.0;
        _ctrls[f]!.text = '70';
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF1a1a2e),
      appBar: AppBar(
        backgroundColor: const Color(0xFF16213e),
        title: const Text('Calibración del dispositivo'),
        foregroundColor: Colors.white,
      ),
      body: SafeArea(
        child: Column(
          children: [
            _buildHeader(),
            Expanded(child: _buildList()),
            _buildBottomBar(),
          ],
        ),
      ),
    );
  }

  Widget _buildHeader() {
    return Container(
      padding: const EdgeInsets.all(12),
      color: const Color(0xFF16213e),
      child: const Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Cómo calibrar',
            style: TextStyle(
              color: Color(0xFF00e5ff),
              fontSize: 14,
              fontWeight: FontWeight.w700,
            ),
          ),
          SizedBox(height: 4),
          Text(
            '1. Subí el volumen del celu al máximo.\n'
            '2. Ponéte un sonómetro (app o físico) cerca del parlante.\n'
            '3. Por cada frecuencia: tocá "Reproducir", anotá el dB SPL del sonómetro y escribilo.\n'
            '4. Cuando termines, tocá "Guardar".',
            style: TextStyle(color: Colors.white70, fontSize: 12, height: 1.4),
          ),
        ],
      ),
    );
  }

  Widget _buildList() {
    return ListView.builder(
      itemCount: _freqs.length,
      itemBuilder: (ctx, i) {
        final f = _freqs[i];
        final dbFs = _measuredDbFs[f];
        final isCurrent = _currentFreq == f;
        return _buildRow(f, dbFs, isCurrent);
      },
    );
  }

  Widget _buildRow(double freqHz, double? measuredDbFs, bool isCurrent) {
    final freqLabel = freqHz >= 1000
        ? '${(freqHz / 1000).toStringAsFixed(freqHz % 1000 == 0 ? 0 : 1)} kHz'
        : '${freqHz.toInt()} Hz';

    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: const Color(0xFF16213e),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(
          color: isCurrent ? const Color(0xFF00e5ff) : Colors.white12,
          width: isCurrent ? 2 : 1,
        ),
      ),
      child: Row(
        children: [
          SizedBox(
            width: 60,
            child: Text(
              freqLabel,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 13,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
          const SizedBox(width: 8),
          // Botón reproducir.
          IconButton(
            icon: Icon(
              isCurrent ? Icons.stop_circle : Icons.play_circle_outline,
              color: const Color(0xFF00e5ff),
              size: 30,
            ),
            onPressed: _busyFreq && !isCurrent ? null : () => _measureFreq(freqHz),
          ),
          const SizedBox(width: 8),
          // dBFS medido.
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  measuredDbFs != null
                      ? 'dBFS: ${measuredDbFs.toStringAsFixed(1)}'
                      : 'Sin medir',
                  style: TextStyle(
                    color: measuredDbFs != null
                        ? Colors.greenAccent
                        : Colors.white38,
                    fontSize: 11,
                  ),
                ),
                const SizedBox(height: 2),
                Row(
                  children: [
                    const Text('SPL real:',
                        style: TextStyle(color: Colors.white70, fontSize: 11)),
                    const SizedBox(width: 6),
                    SizedBox(
                      width: 70,
                      child: TextField(
                        controller: _ctrls[freqHz],
                        style: const TextStyle(color: Colors.white, fontSize: 12),
                        keyboardType: const TextInputType.numberWithOptions(
                            decimal: true),
                        decoration: const InputDecoration(
                          isDense: true,
                          contentPadding: EdgeInsets.symmetric(
                              horizontal: 6, vertical: 4),
                          border: OutlineInputBorder(),
                          suffixText: 'dB',
                          suffixStyle:
                              TextStyle(color: Colors.white38, fontSize: 10),
                        ),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildBottomBar() {
    return Container(
      padding: const EdgeInsets.all(12),
      color: const Color(0xFF16213e),
      child: Row(
        children: [
          TextButton.icon(
            onPressed: _clear,
            icon: const Icon(Icons.delete_outline, color: Colors.redAccent),
            label: const Text('Borrar',
                style: TextStyle(color: Colors.redAccent)),
          ),
          const Spacer(),
          ElevatedButton.icon(
            onPressed: _busyFreq ? null : _save,
            icon: const Icon(Icons.save),
            label: const Text('Guardar calibración'),
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFF00e5ff),
              foregroundColor: Colors.black,
            ),
          ),
        ],
      ),
    );
  }
}
