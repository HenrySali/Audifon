import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

import '../../data/bridges/spectrum_bridge.dart';
import '../../domain/entities/spectrum_snapshot.dart';
import '../widgets/magnitude_chart.dart';
import '../widgets/phase_chart.dart';

/// Pantalla de analizador de espectro en tiempo real.
///
/// Muestra magnitud (dB SPL) y fase (grados) del espectro de entrada y salida
/// del pipeline DSP. Soporta grabación de hasta 3 minutos y exportación JSON.
///
/// Usa StatefulWidget con Timer para polling a 10 Hz (herramienta de
/// diagnóstico, no requiere BLoC).
class SpectrumAnalyzerScreen extends StatefulWidget {
  const SpectrumAnalyzerScreen({super.key});

  @override
  State<SpectrumAnalyzerScreen> createState() => _SpectrumAnalyzerScreenState();
}

class _SpectrumAnalyzerScreenState extends State<SpectrumAnalyzerScreen>
    with SingleTickerProviderStateMixin {
  final SpectrumBridge _bridge = SpectrumBridge();

  // Polling timer (10 Hz)
  Timer? _pollingTimer;

  // Current spectrum data
  SpectrumSnapshot? _currentSnapshot;

  // Display mode
  bool _showBands = true; // true = 12 bands, false = 64 bins

  // Recording state
  bool _isRecording = false;
  int _recordedCount = 0;
  Timer? _recordingTimer;
  int _elapsedSeconds = 0;
  static const int _maxRecordingSeconds = 180; // 3 minutes

  // Export state
  bool _hasRecordingData = false;
  // ignore: unused_field
  String? _lastExportPath;

  // Pulsing animation for record button
  late AnimationController _pulseController;
  late Animation<double> _pulseAnimation;

  @override
  void initState() {
    super.initState();

    // Setup pulse animation for recording indicator
    _pulseController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 800),
    );
    _pulseAnimation = Tween<double>(begin: 1.0, end: 0.5).animate(
      CurvedAnimation(parent: _pulseController, curve: Curves.easeInOut),
    );

    // Start spectrum analysis and polling
    _bridge.startAnalysis();
    _startPolling();
  }

  @override
  void dispose() {
    _pollingTimer?.cancel();
    _recordingTimer?.cancel();
    _pulseController.dispose();
    _bridge.stopAnalysis();
    super.dispose();
  }

  void _startPolling() {
    _pollingTimer = Timer.periodic(
      const Duration(milliseconds: 100),
      (_) async {
        final snapshot = await _bridge.getCurrentSpectrum();
        if (mounted && snapshot != null) {
          setState(() => _currentSnapshot = snapshot);
        }
      },
    );
  }

  // ─── Recording Logic ────────────────────────────────────────────────────────

  Future<void> _startRecording() async {
    await _bridge.startRecording();
    if (mounted) {
      _showSnackBar('🔴 Recording started — 3 min max');
    }
    setState(() {
      _isRecording = true;
      _elapsedSeconds = 0;
      _hasRecordingData = false;
      _recordedCount = 0;
    });

    _pulseController.repeat(reverse: true);

    _recordingTimer = Timer.periodic(
      const Duration(seconds: 1),
      (_) {
        if (!mounted) return;
        setState(() {
          _elapsedSeconds++;
        });
        if (_elapsedSeconds >= _maxRecordingSeconds) {
          _stopRecording();
        }
      },
    );
  }

  Future<void> _stopRecording() async {
    _recordingTimer?.cancel();
    _recordingTimer = null;
    _pulseController.stop();
    _pulseController.reset();

    final count = await _bridge.stopRecording();
    if (mounted) {
      setState(() {
        _isRecording = false;
        _recordedCount = count;
        _hasRecordingData = count > 0;
      });
      _showSnackBar('⏹ Recording stopped — $count snapshots captured');
    }
  }

  // ─── Export Logic ───────────────────────────────────────────────────────────

  Future<void> _exportJson() async {
    if (!_hasRecordingData) return;

    // Show loading indicator
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Exporting...'),
          duration: Duration(seconds: 1),
        ),
      );
    }

    try {
      // Get raw recording data from native
      final bytes = await _bridge.getRecordingData();
      if (bytes.isEmpty) {
        _showSnackBar('No recording data available');
        return;
      }

      // Deserialize all snapshots
      final snapshotCount = bytes.length ~/ SpectrumSnapshot.sizeInBytes;
      final snapshots = <SpectrumSnapshot>[];
      for (int i = 0; i < snapshotCount; i++) {
        final offset = i * SpectrumSnapshot.sizeInBytes;
        if (offset + SpectrumSnapshot.sizeInBytes <= bytes.length) {
          snapshots.add(SpectrumSnapshot.fromBytes(bytes, offset));
        }
      }

      // Build JSON with metadata
      final now = DateTime.now();
      final json = {
        'metadata': {
          'appVersion': '1.0.0',
          'exportDate': now.toIso8601String(),
          'sampleRate': 16000,
          'fftSize': 128,
          'binsUsed': 64,
          'binResolutionHz': 125,
          'recordDurationSec': _elapsedSeconds,
          'snapshotIntervalMs': 100,
          'totalSnapshots': snapshots.length,
          'bands': [250, 500, 750, 1000, 1500, 2000, 2500, 3000, 3500, 4000, 6000, 8000],
          'environmentClassNames': SpectrumSnapshot.environmentClassNames,
        },
        'snapshots': snapshots.map((s) => s.toJson()).toList(),
      };

      // Save to documents directory
      final dir = await getApplicationDocumentsDirectory();
      final timestamp = '${now.year}-${_pad(now.month)}-${_pad(now.day)}'
          '_${_pad(now.hour)}-${_pad(now.minute)}-${_pad(now.second)}';
      final filePath = '${dir.path}/spectrum_$timestamp.json';
      final file = File(filePath);
      await file.writeAsString(const JsonEncoder.withIndent('  ').convert(json));

      setState(() => _lastExportPath = filePath);
      _showSnackBar('Saved: $filePath');
    } catch (e) {
      _showSnackBar('Export error: $e');
    }
  }

  // ─── Clipboard Logic ────────────────────────────────────────────────────────

  Future<void> _copyToClipboard() async {
    final snapshot = _currentSnapshot;
    if (snapshot == null) {
      _showSnackBar('No spectrum data available');
      return;
    }

    final clipText = snapshot.toClipboardString();
    await Clipboard.setData(ClipboardData(text: clipText));
    _showSnackBar('Snapshot copied to clipboard');
  }

  // ─── Helpers ────────────────────────────────────────────────────────────────

  void _showSnackBar(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message), duration: const Duration(seconds: 3)),
    );
  }

  String _pad(int n) => n.toString().padLeft(2, '0');

  String _formatElapsed() {
    final min = _elapsedSeconds ~/ 60;
    final sec = _elapsedSeconds % 60;
    return '${_pad(min)}:${_pad(sec)} / 03:00';
  }

  // ─── Build ──────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF0a0a1a),
      appBar: AppBar(
        title: const Text('Spectrum Analyzer'),
        backgroundColor: const Color(0xFF0f3460),
        foregroundColor: Colors.white,
        actions: [
          // Copy button
          IconButton(
            icon: const Icon(Icons.copy),
            tooltip: 'Copy snapshot to clipboard',
            onPressed: _currentSnapshot != null ? _copyToClipboard : null,
          ),
          // Export button
          IconButton(
            icon: const Icon(Icons.save_alt),
            tooltip: 'Export JSON',
            onPressed: _hasRecordingData ? _exportJson : null,
          ),
        ],
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // Toggle: 12 Bands / FFT Full
            _buildModeToggle(),
            const SizedBox(height: 8),

            // Magnitude chart
            Container(
              decoration: BoxDecoration(
                color: const Color(0xFF16213e),
                borderRadius: BorderRadius.circular(8),
              ),
              padding: const EdgeInsets.all(8),
              child: MagnitudeChart(
                snapshot: _currentSnapshot,
                showBands: _showBands,
              ),
            ),
            const SizedBox(height: 8),

            // Phase chart
            Container(
              decoration: BoxDecoration(
                color: const Color(0xFF16213e),
                borderRadius: BorderRadius.circular(8),
              ),
              padding: const EdgeInsets.all(8),
              child: PhaseChart(snapshot: _currentSnapshot),
            ),
            const SizedBox(height: 12),

            // Status bar
            _buildStatusBar(),
            const SizedBox(height: 12),

            // Recording controls
            _buildRecordingControls(),
          ],
        ),
      ),
    );
  }

  Widget _buildModeToggle() {
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        ToggleButtons(
          isSelected: [_showBands, !_showBands],
          onPressed: (index) {
            setState(() => _showBands = index == 0);
          },
          borderRadius: BorderRadius.circular(8),
          selectedColor: Colors.white,
          fillColor: Colors.cyan.withOpacity(0.3),
          color: Colors.white54,
          borderColor: Colors.white24,
          selectedBorderColor: Colors.cyan,
          constraints: const BoxConstraints(minWidth: 100, minHeight: 36),
          children: const [
            Text('12 Bands', style: TextStyle(fontSize: 13)),
            Text('FFT Full', style: TextStyle(fontSize: 13)),
          ],
        ),
      ],
    );
  }

  Widget _buildStatusBar() {
    final snap = _currentSnapshot;
    final inputLevel = snap?.inputLevelDb ?? 0.0;
    // ignore: unused_local_variable
    final outputLevel = snap?.outputLevelDb ?? 0.0;
    final gain = snap != null ? snap.effectiveGainDb : 0.0;
    final envName = snap?.environmentClassName ?? 'N/A';

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: const Color(0xFF16213e),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: const Color(0xFF2a3a4a)),
      ),
      child: Row(
        children: [
          _StatusItem(
            label: 'Input',
            value: '${inputLevel.toStringAsFixed(1)} dB',
            color: Colors.blue,
          ),
          const SizedBox(width: 16),
          _StatusItem(
            label: 'Gain',
            value: '${gain >= 0 ? "+" : ""}${gain.toStringAsFixed(1)} dB',
            color: gain >= 0 ? Colors.green : Colors.orange,
          ),
          const SizedBox(width: 16),
          _StatusItem(
            label: 'Env',
            value: envName,
            color: Colors.cyan,
          ),
        ],
      ),
    );
  }

  Widget _buildRecordingControls() {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: const Color(0xFF16213e),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              // Record / Stop button
              _buildRecordButton(),
              const SizedBox(width: 16),
              // Timer display
              if (_isRecording || _hasRecordingData)
                Text(
                  _isRecording
                      ? _formatElapsed()
                      : '$_recordedCount snapshots',
                  style: TextStyle(
                    color: _isRecording ? Colors.red.shade300 : Colors.white70,
                    fontSize: 14,
                    fontWeight: FontWeight.w500,
                  ),
                ),
            ],
          ),
          if (_hasRecordingData && !_isRecording) ...[
            const SizedBox(height: 12),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                ElevatedButton.icon(
                  onPressed: _exportJson,
                  icon: const Icon(Icons.save_alt, size: 18),
                  label: const Text('Export JSON'),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.cyan.withOpacity(0.2),
                    foregroundColor: Colors.cyan,
                    side: const BorderSide(color: Colors.cyan),
                  ),
                ),
                const SizedBox(width: 12),
                ElevatedButton.icon(
                  onPressed: _copyToClipboard,
                  icon: const Icon(Icons.copy, size: 18),
                  label: const Text('Copy'),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.green.withOpacity(0.2),
                    foregroundColor: Colors.green,
                    side: const BorderSide(color: Colors.green),
                  ),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildRecordButton() {
    if (_isRecording) {
      // RECORDING STATE: pulsing red circle with STOP icon
      return AnimatedBuilder(
        animation: _pulseAnimation,
        builder: (context, child) {
          return GestureDetector(
            onTap: _stopRecording,
            child: Container(
              width: 64,
              height: 64,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: Colors.red.withOpacity(_pulseAnimation.value),
                border: Border.all(color: Colors.red, width: 3),
                boxShadow: [
                  BoxShadow(
                    color: Colors.red.withOpacity(0.4),
                    blurRadius: 12,
                    spreadRadius: 2,
                  ),
                ],
              ),
              child: const Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(Icons.stop, color: Colors.white, size: 24),
                  Text('STOP', style: TextStyle(color: Colors.white, fontSize: 8, fontWeight: FontWeight.bold)),
                ],
              ),
            ),
          );
        },
      );
    }

    // IDLE STATE: gray/dark circle with REC label — clearly NOT recording
    return GestureDetector(
      onTap: _startRecording,
      child: Container(
        width: 64,
        height: 64,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: const Color(0xFF2a2a3e),
          border: Border.all(color: Colors.white38, width: 2),
        ),
        child: const Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.fiber_manual_record, color: Colors.white54, size: 20),
            Text('REC', style: TextStyle(color: Colors.white54, fontSize: 9, fontWeight: FontWeight.w600)),
          ],
        ),
      ),
    );
  }
}

// ─── Helper Widgets ───────────────────────────────────────────────────────────

class _StatusItem extends StatelessWidget {
  final String label;
  final String value;
  final Color color;

  const _StatusItem({
    required this.label,
    required this.value,
    required this.color,
  });

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Text(
            label,
            style: const TextStyle(color: Colors.white38, fontSize: 10),
          ),
          const SizedBox(height: 2),
          Text(
            value,
            style: TextStyle(
              color: color,
              fontSize: 13,
              fontWeight: FontWeight.w600,
            ),
            overflow: TextOverflow.ellipsis,
          ),
        ],
      ),
    );
  }
}
