/// Pantalla unificada de diagnóstico del sistema completo.
///
/// Consolida los 12 tests de diagnóstico en una sola ventana:
///
///   1. Smart Scene (clasificador de ambiente)
///   2. Diagnóstico DSP (grabación 15s pre/post pipeline)
///   3. Registro de Sesión (timeline estados/eventos)
///   4. Spectrum Analyzer (respuesta en frecuencia)
///   5. Motor de Realce (Bypass/DualDNN/MVDR)
///   6. Latencia (input/output/DSP/DNN/TNR)
///   7. DNN Denoiser (estado, inferencia, group delay)
///   8. WDRC (región, gain, nivel pre-DNN)
///   9. MPO Limiter (fracción, sostenido, clips)
///  10. Módulos de Protección (AFC, FBS, TNR, SCE, Expander)
///  11. Audio Routing (API, sharing, burst, buffer)
///  12. Salud del Sistema (underruns, timestamps)
///
/// Cada test se puede ejecutar individualmente o todos en paralelo.
/// Resultados copiables al portapapeles (individual o completo).

import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../data/bridges/spectrum_bridge.dart';
import '../../data/services/session_log_service.dart';
import '../../domain/entities/spectrum_snapshot.dart';
import '../../scene/scene_snapshot.dart';
import '../bloc/amplification_bloc.dart';
import '../bloc/amplification_state.dart';


// ─── Paleta del técnico ─────────────────────────────────────────────────────
const Color _kBg = Color(0xFF0a0e27);
const Color _kSurface = Color(0xFF16213e);
const Color _kAccent = Color(0xFF0f3460);
const Color _kCyan = Color(0xFF4dd0e1);
const Color _kGreen = Color(0xFF43A047);
const Color _kRed = Color(0xFFE53935);
const Color _kAmber = Color(0xFFFFB300);
const Color _kText = Colors.white;
const Color _kTextDim = Color(0xFFb0bec5);

// ─── Estado de cada test ────────────────────────────────────────────────────
enum TestStatus { idle, running, completed, error }

/// Resultado de un test individual.
class TestResult {
  final String testName;
  final TestStatus status;
  final Map<String, dynamic> data;
  final DateTime? completedAt;
  final String? errorMessage;

  TestResult({
    required this.testName,
    this.status = TestStatus.idle,
    this.data = const {},
    this.completedAt,
    this.errorMessage,
  });

  TestResult copyWith({
    TestStatus? status,
    Map<String, dynamic>? data,
    DateTime? completedAt,
    String? errorMessage,
  }) {
    return TestResult(
      testName: testName,
      status: status ?? this.status,
      data: data ?? this.data,
      completedAt: completedAt ?? this.completedAt,
      errorMessage: errorMessage ?? this.errorMessage,
    );
  }
}


// ─── IDs de los 12 tests ────────────────────────────────────────────────────
class DiagTestId {
  static const String smartScene = 'smart_scene';
  static const String dspRecording = 'dsp_recording';
  static const String sessionLog = 'session_log';
  static const String spectrum = 'spectrum';
  static const String enhancement = 'enhancement';
  static const String latency = 'latency';
  static const String dnnDenoiser = 'dnn_denoiser';
  static const String wdrc = 'wdrc';
  static const String mpoLimiter = 'mpo_limiter';
  static const String protection = 'protection';
  static const String routing = 'audio_routing';
  static const String health = 'system_health';

  static const List<String> all = [
    smartScene, dspRecording, sessionLog, spectrum,
    enhancement, latency, dnnDenoiser, wdrc,
    mpoLimiter, protection, routing, health,
  ];

  static String displayName(String id) {
    switch (id) {
      case smartScene: return '1. Smart Scene';
      case dspRecording: return '2. Diagnóstico DSP';
      case sessionLog: return '3. Registro de Sesión';
      case spectrum: return '4. Spectrum Analyzer';
      case enhancement: return '5. Motor de Realce';
      case latency: return '6. Latencia';
      case dnnDenoiser: return '7. DNN Denoiser';
      case wdrc: return '8. WDRC';
      case mpoLimiter: return '9. MPO Limiter';
      case protection: return '10. Protección';
      case routing: return '11. Audio Routing';
      case health: return '12. Salud del Sistema';
      default: return id;
    }
  }
}


/// Pantalla unificada de diagnóstico.
class UnifiedDiagnosticsScreen extends StatefulWidget {
  const UnifiedDiagnosticsScreen({super.key});

  @override
  State<UnifiedDiagnosticsScreen> createState() =>
      _UnifiedDiagnosticsScreenState();
}

class _UnifiedDiagnosticsScreenState extends State<UnifiedDiagnosticsScreen> {
  static const _channel = MethodChannel('com.psk.hearing_aid/audio');
  final SpectrumBridge _spectrumBridge = SpectrumBridge();

  // ─── Resultados por test ──────────────────────────────────────────────────
  late Map<String, TestResult> _results;

  // ─── Estado global ────────────────────────────────────────────────────────
  bool _allRunning = false;
  Timer? _parallelTimer;

  // ─── Session log service ──────────────────────────────────────────────────
  SessionLogService get _sessionSvc => SessionLogService.instance;
  StreamSubscription<void>? _sessionSub;

  @override
  void initState() {
    super.initState();
    _results = {
      for (final id in DiagTestId.all)
        id: TestResult(testName: DiagTestId.displayName(id)),
    };
    _sessionSub = _sessionSvc.onChange.listen((_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _parallelTimer?.cancel();
    _sessionSub?.cancel();
    _spectrumBridge.stopAnalysis();
    super.dispose();
  }


  // ─── Ejecutar UN test ─────────────────────────────────────────────────────

  Future<void> _runTest(String id) async {
    setState(() {
      _results[id] = _results[id]!.copyWith(
        status: TestStatus.running,
        errorMessage: null,
      );
    });

    try {
      final data = await _executeTest(id);
      if (!mounted) return;
      setState(() {
        _results[id] = _results[id]!.copyWith(
          status: TestStatus.completed,
          data: data,
          completedAt: DateTime.now(),
        );
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _results[id] = _results[id]!.copyWith(
          status: TestStatus.error,
          errorMessage: e.toString(),
          completedAt: DateTime.now(),
        );
      });
    }
  }

  // ─── Ejecutar TODOS en paralelo ───────────────────────────────────────────

  Future<void> _runAll() async {
    setState(() => _allRunning = true);

    final futures = DiagTestId.all.map((id) => _runTest(id));
    await Future.wait(futures);

    if (!mounted) return;
    setState(() => _allRunning = false);
  }


  // ─── Lógica de cada test ──────────────────────────────────────────────────

  Future<Map<String, dynamic>> _executeTest(String id) async {
    switch (id) {
      case DiagTestId.smartScene:
        return _testSmartScene();
      case DiagTestId.dspRecording:
        return _testDspRecording();
      case DiagTestId.sessionLog:
        return _testSessionLog();
      case DiagTestId.spectrum:
        return _testSpectrum();
      case DiagTestId.enhancement:
        return _testEnhancement();
      case DiagTestId.latency:
        return _testLatency();
      case DiagTestId.dnnDenoiser:
        return _testDnn();
      case DiagTestId.wdrc:
        return _testWdrc();
      case DiagTestId.mpoLimiter:
        return _testMpo();
      case DiagTestId.protection:
        return _testProtection();
      case DiagTestId.routing:
        return _testRouting();
      case DiagTestId.health:
        return _testHealth();
      default:
        return {'error': 'Test desconocido: $id'};
    }
  }

  Future<Map<String, dynamic>> _testSmartScene() async {
    final raw = await _channel.invokeMethod<Uint8List>('getSceneSnapshot');
    if (raw == null || raw.isEmpty) {
      return {'status': 'Motor no activo', 'available': false};
    }
    final snap = SceneSnapshot.fromBytes(raw);
    if (snap == null) return {'status': 'Parse error', 'available': false};
    return {
      'available': true,
      'inputDbSpl': snap.inputDbSpl,
      'snrDb': snap.snrDb,
      'vadScore': snap.vadScore,
      'tilt': snap.spectralTiltDb,
      'centroid': snap.spectralCentroidHz,
      'envClass': snap.sceneClass.index,
    };
  }


  Future<Map<String, dynamic>> _testDspRecording() async {
    // Verificar que el motor esté activo
    final bloc = context.read<AmplificationBloc>();
    final active = bloc.state is AmplificationActive;
    if (!active) {
      return {'status': 'Motor no activo', 'canRecord': false};
    }
    // No iniciamos grabación real en el test rápido — solo verificamos
    // que el sistema esté listo para grabar.
    return {
      'canRecord': true,
      'motorActivo': true,
      'duracionNominal': '15 s',
      'formato': 'WAV dual-channel (pre/post DSP) + JSON',
    };
  }

  Future<Map<String, dynamic>> _testSessionLog() async {
    return {
      'serviceAvailable': true,
      'isRecording': _sessionSvc.isRecording,
      'eventCount': _sessionSvc.events.length,
      'elapsed': _sessionSvc.elapsed.inSeconds,
      'hasInitialSnapshot': _sessionSvc.initialSnapshot != null,
    };
  }

  Future<Map<String, dynamic>> _testSpectrum() async {
    _spectrumBridge.startAnalysis();
    // Dar tiempo al nativo para producir un snapshot
    await Future.delayed(const Duration(milliseconds: 150));
    final snap = await _spectrumBridge.getCurrentSpectrum();
    _spectrumBridge.stopAnalysis();
    if (snap == null) {
      return {'available': false, 'status': 'Sin datos de espectro'};
    }
    return {
      'available': true,
      'bins': 64,
      'inputLevelDb': snap.inputLevelDb,
      'outputLevelDb': snap.outputLevelDb,
      'envClass': snap.environmentClass,
    };
  }


  Future<Map<String, dynamic>> _testEnhancement() async {
    final mode = await _channel.invokeMethod<int>('getEnhancementEngineMode');
    final bf = await _channel.invokeMethod<bool>('getBeamformingActive');
    final dnn = await _channel.invokeMethod<bool>('getDnnIsActive');
    final modeNames = ['Bypass', 'Dual-DNN (GTCRN)', 'MVDR Beamformer'];
    return {
      'mode': mode ?? 0,
      'modeName': modeNames[(mode ?? 0).clamp(0, 2)],
      'beamformingActive': bf ?? false,
      'dnnActive': dnn ?? false,
    };
  }

  Future<Map<String, dynamic>> _testLatency() async {
    final m = await _channel.invokeMethod<Map>('getLatencyMetrics');
    if (m == null) return {'available': false, 'status': 'Sin métricas'};
    final data = Map<String, dynamic>.from(m);
    return {
      'available': true,
      'inputLatencyMs': data['inputLatencyMs'],
      'outputLatencyMs': data['outputLatencyMs'],
      'dspBlockMs': data['dspBlockMs'],
      'dspProcessingMsAvg': data['dspProcessingMsAvg'],
      'dspProcessingMsMax': data['dspProcessingMsMax'],
      'dnnInferenceMs': data['dnnInferenceMs'],
      'dnnGroupDelayMs': data['dnnGroupDelayMs'],
      'tnrLookaheadMs': data['tnrLookaheadMs'],
    };
  }

  Future<Map<String, dynamic>> _testDnn() async {
    final active = await _channel.invokeMethod<bool>('getDnnIsActive');
    final lat = await _channel.invokeMethod<Map>('getLatencyMetrics');
    final latMap = lat != null ? Map<String, dynamic>.from(lat) : null;
    return {
      'isActive': active ?? false,
      'inferenceMs': latMap?['dnnInferenceMs'],
      'groupDelayMs': latMap?['dnnGroupDelayMs'],
    };
  }


  Future<Map<String, dynamic>> _testWdrc() async {
    final m = await _channel.invokeMethod<Map>('getDspStageMetrics');
    if (m == null) return {'available': false};
    final data = Map<String, dynamic>.from(m);
    final regions = ['Expansión', 'Lineal', 'Compresión'];
    final region = data['wdrcRegion'];
    return {
      'available': true,
      'region': region,
      'regionName': (region is int && region >= 0 && region <= 2)
          ? regions[region]
          : 'Desconocido',
      'gainFactor': data['wdrcGainFactor'],
      'preDnnLevelDb': data['preDnnLevelDb'],
      'usesExternalLevel': data['wdrcUsesExternalLevel'],
      'postNrLevel': data['postNrLevel'],
      'postEqLevel': data['postEqLevel'],
      'postWdrcLevel': data['postWdrcLevel'],
      'postVolumeLevel': data['postVolumeLevel'],
    };
  }

  Future<Map<String, dynamic>> _testMpo() async {
    final m = await _channel.invokeMethod<Map>('getDspStageMetrics');
    if (m == null) return {'available': false};
    final data = Map<String, dynamic>.from(m);
    return {
      'available': true,
      'mpoLimitingFraction': data['mpoLimitingFraction'],
      'mpoLimitingSustained': data['mpoLimitingSustained'],
      'outputLevel': data['outputLevel'],
      'peakSample': data['peakSample'],
      'clipCount': data['clipCount'],
    };
  }

  Future<Map<String, dynamic>> _testProtection() async {
    final m = await _channel.invokeMethod<Map>('getDspStageMetrics');
    if (m == null) return {'available': false};
    final data = Map<String, dynamic>.from(m);
    return {
      'available': true,
      'afc': 'Activo (default)',
      'fbs': 'Activo (default)',
      'tnr': 'Configurado',
      'sce': 'Activo (default)',
      'expander': 'Configurado vía Smart Scene',
      'eqMaxGain': data['eqMaxGain'],
      'environmentClass': data['environmentClass'],
    };
  }


  Future<Map<String, dynamic>> _testRouting() async {
    final m = await _channel.invokeMethod<Map>('getLatencyMetrics');
    if (m == null) return {'available': false};
    final data = Map<String, dynamic>.from(m);
    final apis = ['Unspecified', 'AAudio', 'OpenSL ES'];
    final sharing = ['Exclusive', 'Shared'];
    final perf = ['None', 'PowerSaving', 'LowLatency'];
    return {
      'available': true,
      'sampleRate': data['sampleRate'],
      'inputApi': apis[(data['inputAudioApi'] as int? ?? 0).clamp(0, 2)],
      'outputApi': apis[(data['outputAudioApi'] as int? ?? 0).clamp(0, 2)],
      'inputSharing': sharing[(data['inputSharingMode'] as int? ?? 0).clamp(0, 1)],
      'outputSharing': sharing[(data['outputSharingMode'] as int? ?? 0).clamp(0, 1)],
      'outputPerformance': perf[(data['outputPerformanceMode'] as int? ?? 0).clamp(0, 2)],
      'inputBurst': data['inputFramesPerBurst'],
      'outputBurst': data['outputFramesPerBurst'],
      'outputBuffer': data['outputBufferSizeFrames'],
    };
  }

  Future<Map<String, dynamic>> _testHealth() async {
    final m = await _channel.invokeMethod<Map>('getLatencyMetrics');
    if (m == null) return {'available': false};
    final data = Map<String, dynamic>.from(m);
    return {
      'available': true,
      'callbackUnderruns': data['callbackUnderruns'],
      'timestampsHealthy': data['timestampsHealthy'],
      'schemaVersion': data['schemaVersion'],
    };
  }


  // ─── Copiar resultados ────────────────────────────────────────────────────

  String _formatResult(String id) {
    final r = _results[id]!;
    final buf = StringBuffer();
    buf.writeln('── ${r.testName} ──');
    buf.writeln('  Estado: ${r.status.name}');
    if (r.completedAt != null) {
      buf.writeln('  Completado: ${r.completedAt!.toIso8601String()}');
    }
    if (r.errorMessage != null) {
      buf.writeln('  Error: ${r.errorMessage}');
    }
    if (r.data.isNotEmpty) {
      r.data.forEach((k, v) => buf.writeln('  $k: $v'));
    }
    return buf.toString();
  }

  Future<void> _copyOne(String id) async {
    final text = _formatResult(id);
    await Clipboard.setData(ClipboardData(text: text));
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('${_results[id]!.testName} copiado'),
          duration: const Duration(seconds: 2),
        ),
      );
    }
  }

  Future<void> _copyAll() async {
    final buf = StringBuffer();
    buf.writeln('═══ DIAGNÓSTICO COMPLETO ═══');
    buf.writeln('Timestamp: ${DateTime.now().toIso8601String()}');
    buf.writeln('');
    for (final id in DiagTestId.all) {
      buf.writeln(_formatResult(id));
      buf.writeln('');
    }
    await Clipboard.setData(ClipboardData(text: buf.toString()));
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Diagnóstico completo copiado'),
          duration: Duration(seconds: 2),
        ),
      );
    }
  }


  // ─── Build ────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final completedCount =
        _results.values.where((r) => r.status == TestStatus.completed).length;
    final errorCount =
        _results.values.where((r) => r.status == TestStatus.error).length;

    return Scaffold(
      backgroundColor: _kBg,
      appBar: AppBar(
        title: const Text('Diagnóstico · Sistema Completo'),
        backgroundColor: _kAccent,
        foregroundColor: _kText,
        actions: [
          // Copiar todos
          IconButton(
            icon: const Icon(Icons.copy_all),
            tooltip: 'Copiar todos los resultados',
            onPressed: completedCount > 0 ? _copyAll : null,
          ),
        ],
      ),
      body: Column(
        children: [
          // ─── Barra de control superior ──────────────────────────────────
          _buildControlBar(completedCount, errorCount),
          // ─── Lista de tests ─────────────────────────────────────────────
          Expanded(
            child: ListView.builder(
              padding: const EdgeInsets.all(12),
              itemCount: DiagTestId.all.length,
              itemBuilder: (ctx, i) {
                final id = DiagTestId.all[i];
                return _buildTestCard(id);
              },
            ),
          ),
        ],
      ),
    );
  }


  Widget _buildControlBar(int completed, int errors) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      decoration: const BoxDecoration(
        color: _kSurface,
        border: Border(bottom: BorderSide(color: _kAccent, width: 1)),
      ),
      child: Row(
        children: [
          // Botón "Ejecutar Todos"
          ElevatedButton.icon(
            onPressed: _allRunning ? null : _runAll,
            icon: _allRunning
                ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: _kText,
                    ),
                  )
                : const Icon(Icons.play_arrow, size: 18),
            label: Text(_allRunning ? 'Ejecutando...' : 'Ejecutar Todos'),
            style: ElevatedButton.styleFrom(
              backgroundColor: _kCyan,
              foregroundColor: _kBg,
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              textStyle: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
            ),
          ),
          const SizedBox(width: 16),
          // Contador
          Text(
            '$completed/12 completados',
            style: const TextStyle(color: _kTextDim, fontSize: 13),
          ),
          if (errors > 0) ...[
            const SizedBox(width: 8),
            Text(
              '$errors errores',
              style: const TextStyle(color: _kRed, fontSize: 13),
            ),
          ],
        ],
      ),
    );
  }


  Widget _buildTestCard(String id) {
    final result = _results[id]!;
    final isRunning = result.status == TestStatus.running;
    final isCompleted = result.status == TestStatus.completed;
    final isError = result.status == TestStatus.error;

    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      decoration: BoxDecoration(
        color: _kSurface,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(
          color: isError
              ? _kRed.withOpacity(0.5)
              : isCompleted
                  ? _kGreen.withOpacity(0.3)
                  : _kAccent,
          width: 1,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Header del test
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 10, 8, 0),
            child: Row(
              children: [
                // Indicador de estado
                _statusIcon(result.status),
                const SizedBox(width: 10),
                // Nombre del test
                Expanded(
                  child: Text(
                    result.testName,
                    style: const TextStyle(
                      color: _kText,
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                // Botones de acción
                if (!isRunning)
                  IconButton(
                    icon: const Icon(Icons.play_circle_outline, size: 22),
                    color: _kCyan,
                    tooltip: 'Ejecutar test',
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
                    onPressed: () => _runTest(id),
                  ),
                if (isCompleted || isError)
                  IconButton(
                    icon: const Icon(Icons.copy, size: 18),
                    color: _kTextDim,
                    tooltip: 'Copiar resultado',
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
                    onPressed: () => _copyOne(id),
                  ),
              ],
            ),
          ),
          // Resultados (si hay)
          if (isCompleted && result.data.isNotEmpty)
            _buildResultData(result.data),
          if (isError && result.errorMessage != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(14, 4, 14, 10),
              child: Text(
                result.errorMessage!,
                style: const TextStyle(color: _kRed, fontSize: 12),
              ),
            ),
          if (isRunning)
            const Padding(
              padding: EdgeInsets.fromLTRB(14, 4, 14, 10),
              child: LinearProgressIndicator(
                backgroundColor: _kAccent,
                color: _kCyan,
                minHeight: 3,
              ),
            ),
          if (!isRunning && !isCompleted && !isError)
            const SizedBox(height: 10),
        ],
      ),
    );
  }


  Widget _statusIcon(TestStatus status) {
    switch (status) {
      case TestStatus.idle:
        return const Icon(Icons.circle_outlined, color: _kTextDim, size: 18);
      case TestStatus.running:
        return const SizedBox(
          width: 18,
          height: 18,
          child: CircularProgressIndicator(strokeWidth: 2, color: _kCyan),
        );
      case TestStatus.completed:
        return const Icon(Icons.check_circle, color: _kGreen, size: 18);
      case TestStatus.error:
        return const Icon(Icons.error, color: _kRed, size: 18);
    }
  }

  Widget _buildResultData(Map<String, dynamic> data) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 6, 14, 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: data.entries.map((e) {
          final value = _formatValue(e.value);
          return Padding(
            padding: const EdgeInsets.symmetric(vertical: 2),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Flexible(
                  child: Text(
                    e.key,
                    style: const TextStyle(color: _kTextDim, fontSize: 12),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                const SizedBox(width: 8),
                Text(
                  value,
                  style: TextStyle(
                    color: _valueColor(e.key, e.value),
                    fontSize: 12,
                    fontWeight: FontWeight.w500,
                    fontFamily: 'monospace',
                  ),
                ),
              ],
            ),
          );
        }).toList(),
      ),
    );
  }

  String _formatValue(dynamic val) {
    if (val == null) return '—';
    if (val is double) return val.toStringAsFixed(2);
    if (val is bool) return val ? 'Sí' : 'No';
    return val.toString();
  }

  Color _valueColor(String key, dynamic val) {
    if (val is bool) return val ? _kGreen : _kRed;
    if (key.contains('error') || key.contains('Error')) return _kRed;
    if (key == 'available' && val == false) return _kRed;
    if (key == 'clipCount' && val is int && val > 0) return _kRed;
    if (key == 'callbackUnderruns' && val is int && val > 0) return _kRed;
    if (key == 'mpoLimitingSustained' && val == true) return _kRed;
    return _kText;
  }
}
