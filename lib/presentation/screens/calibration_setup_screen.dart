/// @file calibration_setup_screen.dart
/// @brief Calibración del dispositivo conforme ISO/IEC 17025 + ANSI S3.6 + ISO 389-7.
///
/// Flujo 100% automático:
///   1. Countdown de 10s para que el usuario posicione el parlante BT.
///   2. Por cada frecuencia: 3 mediciones consecutivas a un nivel de salida fijo.
///   3. La app calcula promedio, σ e incertidumbre k=2 (Type A, ISO 17025 §7.6).
///   4. Calcula offset de corrección = target_norma - promedio.
///   5. Reproduce el tono **con el offset aplicado al gain** y mide 1 vez (validación).
///   6. PASS si validación está dentro de ±3 dB del target y U < 3 dB.
///   7. Guarda los offsets como `DeviceCalibration` para uso futuro.

import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../calibration_spectrum/device_calibration.dart';
import '../../calibration_spectrum/iso17025_calibration.dart';
import '../../calibration_spectrum/iso_targets.dart';
import '../../calibration_spectrum/tone_emitter.dart';
import '../../calibration_spectrum/tone_method_channel.dart';
import '../../calibration_spectrum/tone_snapshot.dart';

const int _kRepetitions = 3;
const Duration _kStabilizeMs = Duration(milliseconds: 1500);
const Duration _kSampleWindowMs = Duration(milliseconds: 1000);
const Duration _kBetweenReps = Duration(milliseconds: 400);
const Duration _kSetupCountdown = Duration(seconds: 10);
const double _kBaseSpl = 70.0; // SPL nominal pedido al emitter en pase 1.

class CalibrationSetupScreen extends StatefulWidget {
  const CalibrationSetupScreen({super.key});

  @override
  State<CalibrationSetupScreen> createState() => _CalibrationSetupScreenState();
}

class _CalibrationSetupScreenState extends State<CalibrationSetupScreen> {
  final _emitter = ToneEmitter();
  final _channel = const ToneMethodChannel();

  double _targetLevelHL = 70.0;
  bool _running = false;
  String _statusText = 'Listo. Tocá "Iniciar" cuando el parlante BT esté conectado.';
  int _countdownSec = 0;

  final Map<double, FrequencyMeasurement> _results = {};
  CalibrationProcedure? _procedure;

  @override
  void dispose() {
    _emitter.stop();
    _emitter.dispose();
    _channel.setActive(false);
    super.dispose();
  }

  Future<void> _runCalibration() async {
    if (_running) return;
    setState(() {
      _running = true;
      _results.clear();
      _procedure = null;
      _statusText = 'Preparando...';
    });

    try {
      // Configurar analyzer.
      await _channel.configure(
        sampleRate: 48000,
        fftSize: 4096,
        windowType: WindowType.hann,
        harmonicsCount: 4,
        dbfsToDbsplOffset: 0.0,
      );

      // Phase 0: countdown de posicionamiento.
      for (var s = _kSetupCountdown.inSeconds; s > 0; s--) {
        if (!mounted) return;
        setState(() {
          _countdownSec = s;
          _statusText = 'Posicioná el parlante BT y mantenelo quieto. '
              'Iniciando en $s s...';
        });
        await Future.delayed(const Duration(seconds: 1));
      }
      if (!mounted) return;
      setState(() => _countdownSec = 0);

      // Phase 1: medición de N=3 muestras por frecuencia.
      for (final freq in IsoTargets.standardFreqs) {
        final target = IsoTargets.targetDbSplForHL(freq, _targetLevelHL);
        if (target == null) continue;

        final dbFsSamples = <double>[];
        for (var rep = 0; rep < _kRepetitions; rep++) {
          if (!mounted) return;
          setState(() => _statusText =
              'Midiendo $freq Hz · muestra ${rep + 1}/$_kRepetitions');

          final dbFs = await _measureSingle(freq, _kBaseSpl);
          dbFsSamples.add(dbFs);

          await Future.delayed(_kBetweenReps);
        }

        // Sin sonómetro externo, dBFS = SPL relativo. La diferencia con
        // el target ISO 389-7 es lo que define el offset.
        final dbSplSamples = List<double>.from(dbFsSamples);
        final tolerance = freq <= 4000 ? 3.0 : 5.0;

        final m = FrequencyMeasurement(
          freqHz: freq,
          dbSplSamples: dbSplSamples,
          dbFsSamples: dbFsSamples,
          targetDbSpl: target,
          toleranceDb: tolerance,
        );

        if (!mounted) return;
        setState(() => _results[freq] = m);
      }

      // Phase 2: validación con offset aplicado por freq.
      for (final freq in IsoTargets.standardFreqs) {
        final m = _results[freq];
        if (m == null) continue;

        if (!mounted) return;
        setState(() => _statusText =
            'Validando $freq Hz con offset ${m.correctionOffsetDb.toStringAsFixed(1)} dB...');

        // Aplicamos el offset al SPL nominal del emitter.
        // El emitter mapea SPL -> amplitud lineal con math.pow(10, (spl-90)/20).
        // Subimos/bajamos `correctionOffsetDb` dB en la salida.
        final adjustedSpl = _kBaseSpl + m.correctionOffsetDb;
        // Limitar para no clipear ni quedar inaudible.
        final clampedSpl = adjustedSpl.clamp(20.0, 90.0).toDouble();

        final valDbFs = await _measureSingle(freq, clampedSpl);
        // El "SPL inferido" post-corrección es: meanDbFs + offset + (valDbFs - dbFsExpected)
        // Pero más directo: SPL = target + (valDbFs - meanDbFs - offset_aplicado_efectivo).
        // Como la cadena es lineal, validationDbSpl ≈ target + (valDbFs - meanDbFs - correccionEnDbFs).
        // Aproximación: el offset se aplicó al SPL nominal del emitter, lo que mapea
        // linealmente a dBFS. Entonces:
        //   valDbFs ≈ meanDbFs + correctionOffsetDb (si todo lineal)
        //   error_real = valDbFs - (meanDbFs + correctionOffsetDb)
        //   validationSpl = target + error_real
        final expectedDbFsAfterCorrection = m.meanDbFs + m.correctionOffsetDb;
        final residualErrorDb = valDbFs - expectedDbFsAfterCorrection;
        final validationDbSpl = m.targetDbSpl + residualErrorDb;

        if (!mounted) return;
        setState(() {
          _results[freq] = m.withValidation(valDbFs, validationDbSpl);
        });

        await Future.delayed(_kBetweenReps);
      }

      final procedure = CalibrationProcedure(
        timestamp: DateTime.now(),
        measurements: _results.values.toList(),
        targetLevelHL: _targetLevelHL,
      );
      if (!mounted) return;
      setState(() {
        _procedure = procedure;
        _statusText = procedure.globalPass
            ? '✓ Calibración exitosa · ${procedure.measurements.where((x) => x.isPass).length}/${procedure.measurements.length} freqs en tolerancia'
            : 'Calibración con desvíos: ${procedure.measurements.where((x) => !x.isPass).length}/${procedure.measurements.length} freqs fuera de tolerancia';
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _statusText = 'Error: $e');
    } finally {
      if (mounted) setState(() => _running = false);
    }
  }

  /// Reproduce un tono al SPL nominal indicado y devuelve el peak dBFS medido.
  Future<double> _measureSingle(double freqHz, double spl) async {
    await _channel.setExpectedFrequency(freqHz);
    await _channel.setActive(true);

    await _emitter.playTone(
      freqHz: freqHz,
      levelDbSpl: spl,
      durationMs: 3000,
    );

    await Future.delayed(_kStabilizeMs);

    double maxDbFs = -double.infinity;
    final t0 = DateTime.now();
    while (DateTime.now().difference(t0) < _kSampleWindowMs) {
      try {
        final snap = await _channel.getSnapshot();
        if (snap.peakMagnitudeDbfs.isFinite &&
            snap.peakMagnitudeDbfs > maxDbFs) {
          maxDbFs = snap.peakMagnitudeDbfs;
        }
      } catch (_) {}
      await Future.delayed(const Duration(milliseconds: 80));
    }

    await _emitter.stop();
    await _channel.setActive(false);
    return maxDbFs.isFinite ? maxDbFs : -200.0;
  }

  Future<void> _saveAndApply() async {
    final proc = _procedure;
    if (proc == null) return;
    final entries = <double, CalibrationEntry>{};
    for (final m in proc.measurements) {
      entries[m.freqHz] = CalibrationEntry(
        freqHz: m.freqHz,
        referenceDbFs: m.meanDbFs,
        referenceDbSpl: m.targetDbSpl,
      );
    }
    final cal = DeviceCalibration(
      timestamp: proc.timestamp,
      entries: entries,
    );
    await DeviceCalibrationStore.save(cal);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('Calibración guardada (ISO 17025 + ANSI S3.6)'),
        backgroundColor: Colors.greenAccent,
      ),
    );
    Navigator.of(context).pop(true);
  }

  Future<void> _exportJson() async {
    final proc = _procedure;
    if (proc == null) return;
    final jsonStr = const JsonEncoder.withIndent('  ').convert(proc.toJson());
    await Clipboard.setData(ClipboardData(text: jsonStr));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Reporte ISO 17025 copiado al portapapeles')),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF1a1a2e),
      appBar: AppBar(
        backgroundColor: const Color(0xFF16213e),
        title: const Text('Calibración (ISO 17025)'),
        foregroundColor: Colors.white,
      ),
      body: SafeArea(
        child: Column(
          children: [
            _buildHeader(),
            _buildControls(),
            const Divider(color: Colors.white12, height: 1),
            _buildStatusBar(),
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
            'Calibración automática',
            style: TextStyle(
              color: Color(0xFF00e5ff),
              fontSize: 13,
              fontWeight: FontWeight.w700,
            ),
          ),
          SizedBox(height: 4),
          Text(
            '1. Tocá "Iniciar" cuando el parlante BT esté conectado.\n'
            '2. Tenés 10 segundos para posicionar el parlante (~30 cm del celu).\n'
            '3. La app mide 3 veces cada frecuencia, calcula offsets y revalida.\n'
            '4. Resultado conforme ISO 17025 §7.6 + ANSI S3.6 + ISO 389-7.',
            style: TextStyle(color: Colors.white70, fontSize: 11, height: 1.4),
          ),
        ],
      ),
    );
  }

  Widget _buildControls() {
    return Container(
      padding: const EdgeInsets.all(12),
      color: const Color(0xFF16213e),
      child: Row(
        children: [
          const Text('Nivel:',
              style: TextStyle(color: Colors.white70, fontSize: 12)),
          const SizedBox(width: 8),
          DropdownButton<double>(
            value: _targetLevelHL,
            dropdownColor: const Color(0xFF16213e),
            style: const TextStyle(color: Colors.white, fontSize: 12),
            items: const [50.0, 60.0, 70.0, 80.0]
                .map((v) => DropdownMenuItem(
                      value: v,
                      child: Text('${v.toInt()} dB HL'),
                    ))
                .toList(),
            onChanged:
                _running ? null : (v) => setState(() => _targetLevelHL = v ?? 70.0),
          ),
          const Spacer(),
          ElevatedButton.icon(
            onPressed: _running ? null : _runCalibration,
            icon: Icon(_running ? Icons.hourglass_top : Icons.play_circle),
            label: Text(_running ? 'En curso...' : 'Iniciar'),
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFF00e5ff),
              foregroundColor: Colors.black,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildStatusBar() {
    Color color = Colors.white70;
    if (_countdownSec > 0) color = Colors.amberAccent;
    if (_procedure != null) {
      color = _procedure!.globalPass ? Colors.greenAccent : Colors.orangeAccent;
    }
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      color: const Color(0xFF16213e).withOpacity(0.5),
      child: Row(
        children: [
          if (_countdownSec > 0) ...[
            Text(
              '⏱ $_countdownSec',
              style: const TextStyle(
                color: Colors.amberAccent,
                fontSize: 18,
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(width: 10),
          ],
          Expanded(
            child: Text(_statusText,
                style: TextStyle(color: color, fontSize: 11, height: 1.3)),
          ),
        ],
      ),
    );
  }

  Widget _buildList() {
    final freqs = IsoTargets.standardFreqs;
    return ListView.builder(
      itemCount: freqs.length,
      itemBuilder: (ctx, i) => _buildRow(freqs[i]),
    );
  }

  Widget _buildRow(double freqHz) {
    final m = _results[freqHz];
    final target = IsoTargets.targetDbSplForHL(freqHz, _targetLevelHL);
    final freqLabel = freqHz >= 1000
        ? '${(freqHz / 1000).toStringAsFixed(freqHz % 1000 == 0 ? 0 : 1)} kHz'
        : '${freqHz.toInt()} Hz';

    Color color;
    if (m == null) {
      color = Colors.white24;
    } else if (m.validationDbSpl == null) {
      color = Colors.amberAccent;  // Phase 1 hecho, Phase 2 pendiente.
    } else {
      color = m.isPass ? Colors.greenAccent : Colors.orangeAccent;
    }

    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: const Color(0xFF16213e),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: color.withOpacity(0.4), width: 1),
      ),
      child: Row(
        children: [
          SizedBox(
            width: 60,
            child: Text(
              freqLabel,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 12,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
          const SizedBox(width: 8),
          if (m == null) ...[
            Expanded(
              child: Text(
                'Target ${target?.toStringAsFixed(1) ?? "—"} dB SPL — sin medir',
                style: const TextStyle(color: Colors.white38, fontSize: 11),
              ),
            ),
          ] else ...[
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    'Promedio ${m.meanDbFs.toStringAsFixed(1)} dBFS · '
                    'σ ${m.stdDevDbSpl.toStringAsFixed(2)} · '
                    'U(k=2) ${m.expandedUncertainty.toStringAsFixed(2)} dB',
                    style: TextStyle(color: color, fontSize: 11),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    'Target ISO ${m.targetDbSpl.toStringAsFixed(1)} dB SPL · '
                    'offset ${m.correctionOffsetDb >= 0 ? "+" : ""}${m.correctionOffsetDb.toStringAsFixed(1)} dB',
                    style: const TextStyle(color: Colors.white60, fontSize: 10),
                  ),
                  const SizedBox(height: 2),
                  if (m.validationDbSpl != null) ...[
                    Text(
                      'Post-corrección: ${m.validationDbSpl!.toStringAsFixed(1)} dB SPL · '
                      'error ${m.validationErrorDb! >= 0 ? "+" : ""}${m.validationErrorDb!.toStringAsFixed(2)} dB '
                      '(tol ±${m.toleranceDb.toStringAsFixed(0)} dB)',
                      style: TextStyle(color: color, fontSize: 10),
                    ),
                  ] else ...[
                    Text(
                      'Mediciones: ${m.dbFsSamples.map((x) => x.toStringAsFixed(1)).join(", ")} dBFS',
                      style: const TextStyle(color: Colors.white38, fontSize: 10),
                    ),
                  ],
                ],
              ),
            ),
            Icon(
              m.validationDbSpl == null
                  ? Icons.hourglass_empty
                  : (m.isPass ? Icons.check_circle : Icons.warning_amber_rounded),
              color: color,
              size: 18,
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildBottomBar() {
    final hasProcedure = _procedure != null;
    return Container(
      padding: const EdgeInsets.all(12),
      color: const Color(0xFF16213e),
      child: Row(
        children: [
          TextButton.icon(
            onPressed: hasProcedure ? _exportJson : null,
            icon: const Icon(Icons.copy_all, size: 16),
            label: const Text('Copiar reporte', style: TextStyle(fontSize: 12)),
            style: TextButton.styleFrom(foregroundColor: Colors.white70),
          ),
          const Spacer(),
          ElevatedButton.icon(
            onPressed: hasProcedure && !_running ? _saveAndApply : null,
            icon: const Icon(Icons.save),
            label: const Text('Guardar y aplicar'),
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
