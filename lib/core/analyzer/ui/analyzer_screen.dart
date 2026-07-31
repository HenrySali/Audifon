// Feature: in-app-diagnostic-analyzer
// Module: ui/analyzer_screen
//
// Six-tab host (Resumen, Espectro, Audiograma, Ruido, WDRC, Calidad)
// driving the AnalysisRunner. Displays a file-picker entry, a progress
// indicator while the pipeline runs, and an error banner with a retry
// button on failure.
//
// On dispose / back navigation, discards the AnalysisResult and calls
// `runner.cancel()` (Req. 19.2 + Req. 15.5).

import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../result/analysis_error.dart';
import '../result/analysis_result.dart';
import '../runner/analysis_runner.dart';
import 'tabs/audiogram_tab.dart';
import 'tabs/noise_tab.dart';
import 'tabs/quality_tab.dart';
import 'tabs/spectrum_tab.dart';
import 'tabs/summary_tab.dart';
import 'tabs/wdrc_tab.dart';

enum AnalyzerScreenState { picking, analyzing, ready, error }

class AnalyzerScreen extends StatefulWidget {
  /// Optional pre-loaded WAV path. When non-null, the file picker is
  /// skipped (Req. 1.6).
  final String? preloadedWavPath;

  /// Optional pre-loaded JSON path.
  final String? preloadedJsonPath;

  const AnalyzerScreen({
    super.key,
    this.preloadedWavPath,
    this.preloadedJsonPath,
  });

  @override
  State<AnalyzerScreen> createState() => _AnalyzerScreenState();
}

class _AnalyzerScreenState extends State<AnalyzerScreen>
    with SingleTickerProviderStateMixin {
  AnalyzerScreenState _state = AnalyzerScreenState.picking;
  String? _wavPath;
  String? _jsonPath;
  AnalysisResult? _result;
  AnalysisError? _error;
  String? _bannerMessage;
  double _progress = 0.0;

  late final AnalysisRunner _runner = AnalysisRunner();
  TabController? _tabController;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 6, vsync: this);

    // Listen for progress updates.
    _runner.progress.listen((v) {
      if (!mounted) return;
      setState(() => _progress = v);
    });

    // Auto-launch with pre-loaded paths when entering from the recorder.
    if (widget.preloadedWavPath != null && widget.preloadedJsonPath != null) {
      _wavPath = widget.preloadedWavPath;
      _jsonPath = widget.preloadedJsonPath;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _startAnalysis();
      });
    }
  }

  @override
  void dispose() {
    _tabController?.dispose();
    // Idempotent cancel + dispose; result is discarded.
    _result = null;
    _runner.dispose();
    super.dispose();
  }

  // ─── State transitions ───────────────────────────────────────────────

  Future<void> _pickFile() async {
    setState(() {
      _bannerMessage = null;
    });
    try {
      final picked = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: const ['wav'],
        withData: false,
      );
      if (picked == null || picked.files.isEmpty) return;
      final wavPath = picked.files.single.path;
      if (wavPath == null) {
        setState(() =>
            _bannerMessage = 'El archivo seleccionado no se puede abrir');
        return;
      }
      // Resolve companion JSON: same directory, replace `.wav` with `.json`.
      final jsonPath = _companionJsonPath(wavPath);
      if (jsonPath == null) {
        setState(() => _bannerMessage =
            'No se encontró el archivo JSON de configuración acompañante');
        return;
      }
      setState(() {
        _wavPath = wavPath;
        _jsonPath = jsonPath;
      });
    } catch (e) {
      setState(
          () => _bannerMessage = 'El archivo seleccionado no se puede abrir');
    }
  }

  String? _companionJsonPath(String wavPath) {
    final lower = wavPath.toLowerCase();
    if (!lower.endsWith('.wav')) return null;
    final candidate = wavPath.substring(0, wavPath.length - 4) + '.json';
    if (!File(candidate).existsSync()) return null;
    return candidate;
  }

  Future<void> _startAnalysis() async {
    final wav = _wavPath;
    final json = _jsonPath;
    if (wav == null || json == null) return;
    setState(() {
      _state = AnalyzerScreenState.analyzing;
      _progress = 0.0;
      _error = null;
      _bannerMessage = null;
    });
    try {
      final result = await _runner.run(wavPath: wav, jsonPath: json);
      if (!mounted) return;
      setState(() {
        _result = result;
        _state = AnalyzerScreenState.ready;
      });
    } on AnalysisError catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e;
        _state = AnalyzerScreenState.error;
      });
    } catch (e, st) {
      if (!mounted) return;
      setState(() {
        _error = AnalysisError(
          stageName: 'Pipeline',
          message: 'Error inesperado durante el análisis: $e',
          cause: e,
          stackTrace: st,
        );
        _state = AnalyzerScreenState.error;
      });
    }
  }

  Future<void> _resetToPicker() async {
    await _runner.cancel();
    if (!mounted) return;
    setState(() {
      _state = AnalyzerScreenState.picking;
      _result = null;
      _error = null;
      _wavPath = null;
      _jsonPath = null;
      _progress = 0.0;
    });
  }

  // ─── Build ───────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: _state != AnalyzerScreenState.analyzing,
      onPopInvoked: (didPop) {
        if (!didPop) return;
        _runner.cancel();
        _result = null;
      },
      child: Scaffold(
        appBar: AppBar(
          title: const Text('Analizador'),
          bottom: _state == AnalyzerScreenState.ready
              ? TabBar(
                  controller: _tabController,
                  isScrollable: true,
                  tabs: const [
                    Tab(text: 'Resumen'),
                    Tab(text: 'Espectro'),
                    Tab(text: 'Audiograma'),
                    Tab(text: 'Ruido'),
                    Tab(text: 'WDRC'),
                    Tab(text: 'Calidad'),
                  ],
                )
              : null,
        ),
        body: SafeArea(child: _buildBody()),
      ),
    );
  }

  Widget _buildBody() {
    switch (_state) {
      case AnalyzerScreenState.picking:
        return _buildPicker();
      case AnalyzerScreenState.analyzing:
        return _buildAnalyzing();
      case AnalyzerScreenState.ready:
        return _buildReady();
      case AnalyzerScreenState.error:
        return _buildError();
    }
  }

  Widget _buildPicker() {
    final wav = _wavPath;
    final json = _jsonPath;
    final base = wav == null ? null : _basename(wav);
    return Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (_bannerMessage != null) ...[
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Colors.redAccent.withOpacity(0.12),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: Colors.redAccent.withOpacity(0.4)),
              ),
              child: Text(_bannerMessage!,
                  style: const TextStyle(
                      color: Colors.redAccent, fontSize: 13)),
            ),
            const SizedBox(height: 16),
          ],
          const Text(
            'Seleccione un Recording_Package (.wav) — el JSON acompañante se buscará automáticamente.',
            style: TextStyle(color: Colors.white70, fontSize: 14),
          ),
          const SizedBox(height: 16),
          ElevatedButton.icon(
            icon: const Icon(Icons.folder_open),
            label: const Text('Seleccionar archivo .wav'),
            onPressed: _pickFile,
          ),
          if (base != null && json != null) ...[
            const SizedBox(height: 16),
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Colors.white12,
                borderRadius: BorderRadius.circular(8),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Archivo: $base',
                      style: const TextStyle(color: Colors.white)),
                  const SizedBox(height: 4),
                  Text('JSON: ${_basename(json)}.json',
                      style: const TextStyle(
                          color: Colors.white60, fontSize: 12)),
                ],
              ),
            ),
            const SizedBox(height: 16),
            ElevatedButton.icon(
              icon: const Icon(Icons.analytics),
              label: const Text('Analizar'),
              onPressed: _startAnalysis,
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildAnalyzing() {
    return Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const Text(
            'Analizando grabación...',
            style: TextStyle(color: Colors.white, fontSize: 16),
          ),
          const SizedBox(height: 24),
          LinearProgressIndicator(value: _progress),
          const SizedBox(height: 8),
          Text(
            '${(_progress * 100).round()} %',
            style: const TextStyle(color: Colors.white70, fontSize: 12),
          ),
          const SizedBox(height: 24),
          OutlinedButton(
            onPressed: () async {
              await _runner.cancel();
              if (!mounted) return;
              setState(() => _state = AnalyzerScreenState.picking);
            },
            child: const Text('Cancelar'),
          ),
        ],
      ),
    );
  }

  Widget _buildReady() {
    final r = _result!;
    return TabBarView(
      controller: _tabController,
      children: [
        SummaryTab(result: r),
        SpectrumTab(result: r),
        AudiogramTab(result: r),
        NoiseTab(result: r),
        WdrcTab(result: r),
        QualityTab(result: r),
      ],
    );
  }

  Widget _buildError() {
    final e = _error!;
    return Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const Icon(Icons.error_outline,
              color: Colors.redAccent, size: 48),
          const SizedBox(height: 12),
          Text(e.stageName,
              style: const TextStyle(
                  color: Colors.redAccent,
                  fontSize: 18,
                  fontWeight: FontWeight.w600)),
          const SizedBox(height: 8),
          Text(e.message,
              textAlign: TextAlign.center,
              style:
                  const TextStyle(color: Colors.white70, fontSize: 14)),
          const SizedBox(height: 24),
          Row(
            children: [
              Expanded(
                child: OutlinedButton(
                  onPressed: _resetToPicker,
                  child: const Text('Volver'),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: ElevatedButton(
                  onPressed: _startAnalysis,
                  child: const Text('Reintentar'),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  static String _basename(String path) {
    final norm = path.replaceAll('\\', '/');
    final lastSlash = norm.lastIndexOf('/');
    final filename =
        lastSlash >= 0 ? norm.substring(lastSlash + 1) : norm;
    final dot = filename.lastIndexOf('.');
    return dot > 0 ? filename.substring(0, dot) : filename;
  }
}

// Avoid the unused-import warning for `kDebugMode` when imports are
// trimmed by the Dart formatter.
// ignore: unused_element
const _kDebug = kDebugMode;
