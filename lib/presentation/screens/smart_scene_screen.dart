/// Smart Scene Engine — UI mínima de Fase 1.
///
/// Muestra los números crudos del clasificador C++ actualizados a 10 Hz:
/// dB SPL, SNR, VAD score, tilt espectral, centroide, energía por banda.
/// No toma decisiones — la lógica de clasificación llega en Fase 2.
///
/// Incluye herramientas de diagnóstico para reportar bugs:
///   - Buffer rolling de los últimos 30 s de snapshots (siempre activo).
///   - Botón "Grabar" para capturar una sesión más larga (hasta 5 min).
///   - "Copiar CSV" copia los datos al portapapeles para pegar en chat.
///   - "Copiar log de errores" copia los errores acumulados.
///
/// Validates: Requirements 1.1, 6.2

import 'dart:async';
import 'dart:collection';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../scene/scene_snapshot.dart';

class SmartSceneScreen extends StatefulWidget {
  const SmartSceneScreen({super.key});

  @override
  State<SmartSceneScreen> createState() => _SmartSceneScreenState();
}

class _SmartSceneScreenState extends State<SmartSceneScreen> {
  static const _channel = MethodChannel('com.psk.hearing_aid/audio');
  static const Duration _pollInterval = Duration(milliseconds: 100);

  /// Capacidad del buffer rolling (siempre activo).
  /// 30 s a 10 Hz = 300 muestras. Costo en memoria ≈ 300 * 200 B ≈ 60 KB.
  static const int _rollingCapacity = 300;

  /// Capacidad máxima de una grabación manual (5 min a 10 Hz).
  static const int _recordingCapacity = 3000;

  /// Máximo de errores recordados.
  static const int _errorLogCapacity = 50;

  Timer? _pollTimer;
  SceneSnapshot _snapshot = SceneSnapshot.empty();
  bool _enginePresent = true;
  String? _errorMessage;

  // ─── Diagnóstico ────────────────────────────────────────────────────
  final ListQueue<SceneSnapshot> _rollingBuffer =
      ListQueue<SceneSnapshot>(_rollingCapacity + 1);
  final List<SceneSnapshot> _recordingBuffer = <SceneSnapshot>[];
  final ListQueue<_ErrorEntry> _errorLog =
      ListQueue<_ErrorEntry>(_errorLogCapacity + 1);
  bool _isRecording = false;
  DateTime? _recordingStartedAt;

  @override
  void initState() {
    super.initState();
    _startPolling();
  }

  @override
  void dispose() {
    _pollTimer?.cancel();
    super.dispose();
  }

  void _startPolling() {
    _pollTimer?.cancel();
    _pollTimer = Timer.periodic(_pollInterval, (_) => _pollSnapshot());
    // Hacer un poll inmediato para acelerar la primera lectura.
    _pollSnapshot();
  }

  Future<void> _pollSnapshot() async {
    try {
      final raw = await _channel.invokeMethod<Uint8List>('getSceneSnapshot');
      if (!mounted) return;
      if (raw == null || raw.isEmpty) {
        setState(() {
          _enginePresent = false;
        });
        return;
      }
      final snap = SceneSnapshot.fromBytes(raw);
      if (snap == null) {
        return;
      }
      setState(() {
        _snapshot = snap;
        _enginePresent = true;
        _errorMessage = null;
      });
      _appendToBuffers(snap);
    } on PlatformException catch (e) {
      if (!mounted) return;
      final msg = e.message ?? e.code;
      setState(() {
        _enginePresent = false;
        _errorMessage = msg;
      });
      _logError('PlatformException: $msg');
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _errorMessage = e.toString();
      });
      _logError(e.toString());
    }
  }

  // ────────────────────────────────────────────────────────────────────
  // Buffers de diagnóstico
  // ────────────────────────────────────────────────────────────────────

  void _appendToBuffers(SceneSnapshot snap) {
    _rollingBuffer.addLast(snap);
    while (_rollingBuffer.length > _rollingCapacity) {
      _rollingBuffer.removeFirst();
    }
    if (_isRecording && _recordingBuffer.length < _recordingCapacity) {
      _recordingBuffer.add(snap);
      if (_recordingBuffer.length >= _recordingCapacity) {
        _isRecording = false;
        _logError(
            'Grabación: tope de $_recordingCapacity muestras alcanzado, detenida.');
      }
    }
  }

  void _logError(String message) {
    _errorLog.addLast(_ErrorEntry(DateTime.now(), message));
    while (_errorLog.length > _errorLogCapacity) {
      _errorLog.removeFirst();
    }
  }

  void _toggleRecording() {
    setState(() {
      if (_isRecording) {
        _isRecording = false;
      } else {
        _recordingBuffer.clear();
        _recordingStartedAt = DateTime.now();
        _isRecording = true;
      }
    });
  }

  void _clearRecording() {
    setState(() {
      _recordingBuffer.clear();
      _recordingStartedAt = null;
    });
  }

  Future<void> _copyRecording() async {
    if (_recordingBuffer.isEmpty) {
      _showSnack('No hay muestras grabadas todavía.');
      return;
    }
    final csv = _buildCsv(_recordingBuffer,
        header: 'Recording start: ${_recordingStartedAt?.toIso8601String()}');
    await Clipboard.setData(ClipboardData(text: csv));
    _showSnack(
        'CSV de grabación copiado (${_recordingBuffer.length} muestras).');
  }

  Future<void> _copyRolling() async {
    if (_rollingBuffer.isEmpty) {
      _showSnack('Buffer rolling vacío.');
      return;
    }
    final samples = _rollingBuffer.toList();
    final csv =
        _buildCsv(samples, header: 'Rolling buffer (últimos ${samples.length} samples)');
    await Clipboard.setData(ClipboardData(text: csv));
    _showSnack(
        'CSV últimos ${(samples.length * 100 / 1000).toStringAsFixed(1)} s copiado.');
  }

  Future<void> _copyErrorLog() async {
    if (_errorLog.isEmpty) {
      _showSnack('No hay errores registrados.');
      return;
    }
    final lines = <String>[
      'Error log — ${_errorLog.length} entradas',
      'timestamp;message',
      ..._errorLog.map((e) =>
          '${e.timestamp.toIso8601String()};${e.message.replaceAll(';', ',')}'),
    ];
    await Clipboard.setData(ClipboardData(text: lines.join('\n')));
    _showSnack('Log de errores copiado (${_errorLog.length} entradas).');
  }

  String _buildCsv(List<SceneSnapshot> data, {String? header}) {
    final buffer = StringBuffer();
    if (header != null) {
      buffer.writeln('# $header');
    }
    buffer.writeln('# samples=${data.length}, period=${_pollInterval.inMilliseconds}ms');
    buffer.writeln([
      'idx',
      'time_us',
      'input_db_spl',
      'noise_db_spl',
      'snr_db',
      'vad_score',
      'vad_conf',
      'voice_active',
      'hangover',
      'mid_snr_db',
      'stationarity',
      'tilt_db_oct',
      'centroid_hz',
      'flatness',
      'flux',
      'low_db',
      'mid_db',
      'high_db',
      'scene_class',
    ].join(';'));
    for (var i = 0; i < data.length; ++i) {
      final s = data[i];
      buffer.writeln([
        i,
        s.timestampUs,
        s.inputDbSpl.toStringAsFixed(2),
        s.noiseFloorDbSpl.toStringAsFixed(2),
        s.snrDb.toStringAsFixed(2),
        s.vadScore.toStringAsFixed(3),
        s.vadConfidence.toStringAsFixed(3),
        s.voiceActive ? 1 : 0,
        s.vadHangoverActive ? 1 : 0,
        s.vadMidSnrDb.toStringAsFixed(2),
        s.vadStationarity.toStringAsFixed(3),
        s.spectralTiltDb.toStringAsFixed(3),
        s.spectralCentroidHz.toStringAsFixed(0),
        s.spectralFlatness.toStringAsFixed(4),
        s.spectralFlux.toStringAsFixed(4),
        s.lowBandEnergyDb.toStringAsFixed(2),
        s.midBandEnergyDb.toStringAsFixed(2),
        s.highBandEnergyDb.toStringAsFixed(2),
        s.sceneClass.name,
      ].join(';'));
    }
    return buffer.toString();
  }

  void _showSnack(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        duration: const Duration(seconds: 2),
        behavior: SnackBarBehavior.floating,
      ),
    );
  }

  // ────────────────────────────────────────────────────────────────────
  // Build
  // ────────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF0a0e27),
      appBar: AppBar(
        title: const Text('Smart Scene · diagnóstico'),
        backgroundColor: const Color(0xFF0f3460),
        foregroundColor: Colors.white,
      ),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (!_enginePresent) _engineOffBanner(),
              if (_errorMessage != null) _errorBanner(_errorMessage!),
              const SizedBox(height: 8),
              _LevelsCard(snapshot: _snapshot),
              const SizedBox(height: 12),
              _VadCard(snapshot: _snapshot),
              const SizedBox(height: 12),
              _SpectralCard(snapshot: _snapshot),
              const SizedBox(height: 12),
              _BandsCard(snapshot: _snapshot),
              const SizedBox(height: 12),
              _DiagnosticsCard(
                isRecording: _isRecording,
                recordingCount: _recordingBuffer.length,
                rollingCount: _rollingBuffer.length,
                errorCount: _errorLog.length,
                onToggleRecording: _toggleRecording,
                onCopyRecording: _copyRecording,
                onCopyRolling: _copyRolling,
                onCopyErrors: _copyErrorLog,
                onClearRecording: _clearRecording,
              ),
              const SizedBox(height: 12),
              _MetaCard(snapshot: _snapshot),
            ],
          ),
        ),
      ),
    );
  }

  Widget _engineOffBanner() {
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.orange.withOpacity(0.12),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: Colors.orange.withOpacity(0.4)),
      ),
      child: const Row(
        children: [
          Icon(Icons.info_outline, color: Colors.orangeAccent, size: 20),
          SizedBox(width: 8),
          Expanded(
            child: Text(
              'El motor de audio no está activo. Activá el audífono para ver mediciones en vivo.',
              style: TextStyle(color: Colors.white, fontSize: 13),
            ),
          ),
        ],
      ),
    );
  }

  Widget _errorBanner(String message) {
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.redAccent.withOpacity(0.12),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: Colors.redAccent.withOpacity(0.4)),
      ),
      child: Row(
        children: [
          const Icon(Icons.warning_amber, color: Colors.redAccent, size: 20),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              message,
              style: const TextStyle(color: Colors.white, fontSize: 13),
            ),
          ),
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Tarjetas
// ─────────────────────────────────────────────────────────────────────────────

class _LevelsCard extends StatelessWidget {
  final SceneSnapshot snapshot;
  const _LevelsCard({required this.snapshot});

  @override
  Widget build(BuildContext context) {
    return _SceneCard(
      icon: Icons.volume_up,
      title: 'Niveles',
      child: Column(
        children: [
          _MetricRow(
            label: 'Entrada',
            value: '${snapshot.inputDbSpl.toStringAsFixed(1)} dB SPL',
          ),
          _MetricRow(
            label: 'Piso de ruido',
            value: '${snapshot.noiseFloorDbSpl.toStringAsFixed(1)} dB SPL',
          ),
          _MetricRow(
            label: 'SNR',
            value: '${snapshot.snrDb.toStringAsFixed(1)} dB',
          ),
        ],
      ),
    );
  }
}

class _VadCard extends StatelessWidget {
  final SceneSnapshot snapshot;
  const _VadCard({required this.snapshot});

  @override
  Widget build(BuildContext context) {
    final voiceColor =
        snapshot.voiceActive ? Colors.greenAccent : Colors.white60;
    final hangoverColor =
        snapshot.vadHangoverActive ? Colors.amberAccent : Colors.white38;
    return _SceneCard(
      icon: Icons.record_voice_over,
      title: 'VAD híbrido (LRT + pitch + SNR + LTSD + estacionariedad)',
      child: Column(
        children: [
          _MetricRow(
            label: 'Score',
            value: snapshot.vadScore.toStringAsFixed(2),
          ),
          _MetricRow(
            label: 'Confianza',
            value: snapshot.vadConfidence.toStringAsFixed(2),
          ),
          _MetricRow(
            label: 'Voz activa',
            value: snapshot.voiceActive ? 'SÍ' : 'NO',
            valueColor: voiceColor,
          ),
          _MetricRow(
            label: 'Hangover activo',
            value: snapshot.vadHangoverActive ? 'SÍ' : 'NO',
            valueColor: hangoverColor,
          ),
          _MetricRow(
            label: 'Mid-SNR (1-5 kHz)',
            value: '${snapshot.vadMidSnrDb.toStringAsFixed(1)} dB',
          ),
          _MetricRow(
            label: 'Estacionariedad ruido',
            value: snapshot.vadStationarity.toStringAsFixed(2),
          ),
        ],
      ),
    );
  }
}

class _SpectralCard extends StatelessWidget {
  final SceneSnapshot snapshot;
  const _SpectralCard({required this.snapshot});

  @override
  Widget build(BuildContext context) {
    return _SceneCard(
      icon: Icons.show_chart,
      title: 'Features espectrales',
      child: Column(
        children: [
          _MetricRow(
            label: 'Tilt',
            value: '${snapshot.spectralTiltDb.toStringAsFixed(2)} dB/oct',
          ),
          _MetricRow(
            label: 'Centroide',
            value: '${snapshot.spectralCentroidHz.toStringAsFixed(0)} Hz',
          ),
          _MetricRow(
            label: 'Flatness',
            value: snapshot.spectralFlatness.toStringAsFixed(3),
          ),
          _MetricRow(
            label: 'Flux',
            value: snapshot.spectralFlux.toStringAsFixed(3),
          ),
          const Divider(color: Colors.white12, height: 16),
          _MetricRow(
            label: 'Energía graves (250-750 Hz)',
            value: '${snapshot.lowBandEnergyDb.toStringAsFixed(1)} dB',
          ),
          _MetricRow(
            label: 'Energía medios (750 Hz-3 kHz)',
            value: '${snapshot.midBandEnergyDb.toStringAsFixed(1)} dB',
          ),
          _MetricRow(
            label: 'Energía agudos (3-8 kHz)',
            value: '${snapshot.highBandEnergyDb.toStringAsFixed(1)} dB',
          ),
        ],
      ),
    );
  }
}

class _BandsCard extends StatelessWidget {
  final SceneSnapshot snapshot;
  const _BandsCard({required this.snapshot});

  @override
  Widget build(BuildContext context) {
    final bands = snapshot.noisePerBandDb;
    // Normalizamos a [0, 1] para el barchart usando rango -90..-20 dB típico.
    const minDb = -90.0;
    const maxDb = -20.0;

    return _SceneCard(
      icon: Icons.equalizer,
      title: 'Piso de ruido por banda',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            height: 96,
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: List.generate(bands.length, (i) {
                final value = bands[i];
                final norm = ((value - minDb) / (maxDb - minDb)).clamp(0.0, 1.0);
                return Expanded(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 2),
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.end,
                      children: [
                        Container(
                          height: 80 * norm,
                          decoration: BoxDecoration(
                            color: Colors.cyan.withOpacity(0.7),
                            borderRadius: const BorderRadius.vertical(
                                top: Radius.circular(2)),
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          '${i + 1}',
                          style: const TextStyle(
                            color: Colors.white54,
                            fontSize: 9,
                          ),
                        ),
                      ],
                    ),
                  ),
                );
              }),
            ),
          ),
          const SizedBox(height: 8),
          Text(
            'Rango visual: $minDb a $maxDb dB',
            style: const TextStyle(color: Colors.white38, fontSize: 11),
          ),
        ],
      ),
    );
  }
}

class _DiagnosticsCard extends StatelessWidget {
  final bool isRecording;
  final int recordingCount;
  final int rollingCount;
  final int errorCount;
  final VoidCallback onToggleRecording;
  final VoidCallback onCopyRecording;
  final VoidCallback onCopyRolling;
  final VoidCallback onCopyErrors;
  final VoidCallback onClearRecording;

  const _DiagnosticsCard({
    required this.isRecording,
    required this.recordingCount,
    required this.rollingCount,
    required this.errorCount,
    required this.onToggleRecording,
    required this.onCopyRecording,
    required this.onCopyRolling,
    required this.onCopyErrors,
    required this.onClearRecording,
  });

  String _formatSeconds(int samples) =>
      '${(samples * 100 / 1000).toStringAsFixed(1)} s';

  @override
  Widget build(BuildContext context) {
    return _SceneCard(
      icon: Icons.fiber_manual_record,
      title: 'Diagnóstico — grabar y copiar datos',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: ElevatedButton.icon(
                  onPressed: onToggleRecording,
                  icon: Icon(isRecording
                      ? Icons.stop_circle
                      : Icons.fiber_manual_record),
                  label: Text(isRecording ? 'Detener grabación' : 'Grabar'),
                  style: ElevatedButton.styleFrom(
                    backgroundColor:
                        isRecording ? Colors.redAccent : Colors.cyan.shade700,
                    foregroundColor: Colors.white,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            isRecording
                ? 'Grabando · $recordingCount muestras (${_formatSeconds(recordingCount)})'
                : recordingCount > 0
                    ? 'Grabación detenida · $recordingCount muestras (${_formatSeconds(recordingCount)})'
                    : 'Sin grabación activa.',
            style: const TextStyle(color: Colors.white70, fontSize: 12),
          ),
          const SizedBox(height: 4),
          Text(
            'Buffer rolling automático: $rollingCount muestras (${_formatSeconds(rollingCount)})',
            style: const TextStyle(color: Colors.white38, fontSize: 11),
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              OutlinedButton.icon(
                onPressed: recordingCount > 0 ? onCopyRecording : null,
                icon: const Icon(Icons.copy_all, size: 16),
                label: const Text('Copiar grabación (CSV)'),
              ),
              OutlinedButton.icon(
                onPressed: rollingCount > 0 ? onCopyRolling : null,
                icon: const Icon(Icons.history, size: 16),
                label: const Text('Copiar últimos 30 s'),
              ),
              OutlinedButton.icon(
                onPressed: errorCount > 0 ? onCopyErrors : null,
                icon: const Icon(Icons.bug_report, size: 16),
                label: Text('Copiar errores ($errorCount)'),
              ),
              OutlinedButton.icon(
                onPressed: recordingCount > 0 ? onClearRecording : null,
                icon: const Icon(Icons.delete_outline, size: 16),
                label: const Text('Limpiar grabación'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _MetaCard extends StatelessWidget {
  final SceneSnapshot snapshot;
  const _MetaCard({required this.snapshot});

  @override
  Widget build(BuildContext context) {
    return _SceneCard(
      icon: Icons.info,
      title: 'Meta (Fase 1)',
      child: Column(
        children: [
          _MetricRow(
            label: 'Clase detectada',
            value: sceneClassLabel(snapshot.sceneClass),
          ),
          _MetricRow(
            label: 'Confianza',
            value: snapshot.sceneConfidence.toStringAsFixed(2),
          ),
          _MetricRow(
            label: 'Timestamp',
            value: '${(snapshot.timestampUs / 1000).toStringAsFixed(0)} ms',
          ),
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Widgets compartidos
// ─────────────────────────────────────────────────────────────────────────────

class _SceneCard extends StatelessWidget {
  final IconData icon;
  final String title;
  final Widget child;

  const _SceneCard({
    required this.icon,
    required this.title,
    required this.child,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: const Color(0xFF16213e),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.white.withOpacity(0.06)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon, color: Colors.cyan, size: 18),
              const SizedBox(width: 8),
              Text(
                title,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          child,
        ],
      ),
    );
  }
}

class _MetricRow extends StatelessWidget {
  final String label;
  final String value;
  final Color? valueColor;

  const _MetricRow({
    required this.label,
    required this.value,
    this.valueColor,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        children: [
          Expanded(
            child: Text(
              label,
              style: const TextStyle(color: Colors.white70, fontSize: 13),
            ),
          ),
          Text(
            value,
            style: TextStyle(
              color: valueColor ?? Colors.cyanAccent,
              fontSize: 13,
              fontFeatures: const [FontFeature.tabularFigures()],
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }
}

class _ErrorEntry {
  final DateTime timestamp;
  final String message;
  const _ErrorEntry(this.timestamp, this.message);
}
