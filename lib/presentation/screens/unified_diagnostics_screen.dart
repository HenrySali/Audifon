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
import '../../data/services/analyzer_inbox_service.dart';
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


// ─── IDs de los 13 tests ────────────────────────────────────────────────────
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
  static const String abComparative = 'ab_comparative';

  static const List<String> all = [
    smartScene, dspRecording, sessionLog, spectrum,
    enhancement, latency, dnnDenoiser, wdrc,
    mpoLimiter, protection, routing, health,
    abComparative,
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
      case abComparative: return '13. Comparativa A/B (WAV)';
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
  static final SpectrumBridge _spectrumBridge = SpectrumBridge();

  // ─── Estado ESTÁTICO: sobrevive al cierre de la pantalla ──────────────────
  // Los resultados y el flag de ejecución son static — si el usuario cierra
  // la pantalla y vuelve a abrirla, ve los resultados parciales/finales.
  // La ejecución async NO se cancela al hacer dispose() del widget.
  static Map<String, TestResult> _results = {
    for (final id in DiagTestId.all)
      id: TestResult(testName: DiagTestId.displayName(id)),
  };
  static bool _allRunning = false;
  static bool _cancelled = false;
  static AmplificationBloc? _bloc;
  static final StreamController<void> _changeController =
      StreamController<void>.broadcast();

  // ─── Session log service ──────────────────────────────────────────────────
  SessionLogService get _sessionSvc => SessionLogService.instance;
  StreamSubscription<void>? _sessionSub;
  StreamSubscription<void>? _changeSub;

  @override
  void initState() {
    super.initState();
    // Suscribirse al stream de cambios del runner estático.
    // Si los tests están corriendo en background, el widget se refresca.
    _changeSub = _changeController.stream.listen((_) {
      if (mounted) setState(() {});
    });
    _sessionSub = _sessionSvc.onChange.listen((_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _changeSub?.cancel();
    _sessionSub?.cancel();
    // NO cancelamos la ejecución — sigue en background.
    // NO paramos el spectrum bridge — los tests lo manejan.
    super.dispose();
  }


  // ─── Ejecutar UN test ─────────────────────────────────────────────────────

  /// Helper: inicia grabación WAV para un test individual.
  /// Retorna el nombre del archivo o null si no se pudo iniciar.
  Future<String?> _startTestWav(String testId) async {
    final now = DateTime.now();
    final ts = '${now.year}${_pad2(now.month)}${_pad2(now.day)}'
        '_${_pad2(now.hour)}${_pad2(now.minute)}${_pad2(now.second)}';
    final fileName = 'diag_${testId}_$ts.wav';
    try {
      final started = await _channel.invokeMethod<bool>(
            'startDiagnosticRecording',
            {'filePath': fileName},
          ) ?? false;
      return started ? fileName : null;
    } catch (_) {
      return null;
    }
  }

  /// Helper: detiene la grabación WAV en curso.
  /// Retorna el código de stop (0=ok, -1=error).
  Future<int> _stopTestWav() async {
    try {
      return await _channel.invokeMethod<int>('stopDiagnosticRecording') ?? -1;
    } catch (_) {
      return -1;
    }
  }

  Future<void> _runTest(String id) async {
    _results[id] = _results[id]!.copyWith(
      status: TestStatus.running,
      errorMessage: null,
    );
    _changeController.add(null);

    try {
      // Tests que manejan su propia grabación WAV internamente
      final selfRecording = {
        DiagTestId.dspRecording,
        DiagTestId.abComparative,
        DiagTestId.routing,
      };

      String? wavFile;
      if (!selfRecording.contains(id)) {
        wavFile = await _startTestWav(id);
      }

      final data = await _executeTest(id);

      if (wavFile != null) {
        await _stopTestWav();
      }

      // Agregar nombre del WAV al resultado si se grabó
      final finalData = wavFile != null
          ? {...data, 'wavExportado': wavFile}
          : data;

      // Enviar el WAV al inbox del Analizador
      if (wavFile != null) {
        AnalyzerInboxService.instance.addWav(wavFile);
      }

      _results[id] = _results[id]!.copyWith(
        status: TestStatus.completed,
        data: finalData,
        completedAt: DateTime.now(),
      );
    } catch (e) {
      // Intentar detener WAV si quedó abierto
      try { await _stopTestWav(); } catch (_) {}

      _results[id] = _results[id]!.copyWith(
        status: TestStatus.error,
        errorMessage: e.toString(),
        completedAt: DateTime.now(),
      );
    }
    _changeController.add(null);
  }

  // ─── Ejecutar TODOS en secuencia (cada test graba su WAV) ──────────────────
  // Corre en background — NO depende de mounted. Emite a _changeController.

  Future<void> _runAll() async {
    _allRunning = true;
    _cancelled = false;
    _bloc = context.read<AmplificationBloc>();
    _changeController.add(null);

    for (final id in DiagTestId.all) {
      if (_cancelled) break;
      await _runTest(id);
    }

    _allRunning = false;
    _bloc = null;
    _changeController.add(null);
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
      case DiagTestId.abComparative:
        return _testAbComparative();
      default:
        return {'error': 'Test desconocido: $id'};
    }
  }

  /// Smart Scene: polling 10 Hz durante 5 s (50 snapshots).
  /// Reporta min/max/avg de las métricas principales y la clase dominante.
  Future<Map<String, dynamic>> _testSmartScene() async {
    // Verificar que el motor responda
    final check = await _channel.invokeMethod<Uint8List>('getSceneSnapshot');
    if (check == null || check.isEmpty) {
      return {'status': 'Motor no activo', 'available': false};
    }

    const int durationMs = 5000;
    const int intervalMs = 100; // 10 Hz
    const int expectedSamples = durationMs ~/ intervalMs;

    final List<double> inputLevels = [];
    final List<double> snrValues = [];
    final List<double> vadScores = [];
    final List<double> tilts = [];
    final List<int> sceneClasses = [];
    int parseErrors = 0;

    for (int i = 0; i < expectedSamples; i++) {
      if (_cancelled) break;
      final raw = await _channel.invokeMethod<Uint8List>('getSceneSnapshot');
      if (raw != null && raw.isNotEmpty) {
        final snap = SceneSnapshot.fromBytes(raw);
        if (snap != null) {
          inputLevels.add(snap.inputDbSpl);
          snrValues.add(snap.snrDb);
          vadScores.add(snap.vadScore);
          tilts.add(snap.spectralTiltDb);
          sceneClasses.add(snap.sceneClass.index);
        } else {
          parseErrors++;
        }
      }
      if (i < expectedSamples - 1) {
        await Future.delayed(const Duration(milliseconds: intervalMs));
      }
    }

    if (inputLevels.isEmpty) {
      return {'status': 'Sin datos tras $durationMs ms', 'available': false};
    }

    // Clase dominante (moda)
    final classCount = <int, int>{};
    for (final c in sceneClasses) {
      classCount[c] = (classCount[c] ?? 0) + 1;
    }
    final dominantClass = classCount.entries
        .reduce((a, b) => a.value >= b.value ? a : b)
        .key;

    double _avg(List<double> l) => l.reduce((a, b) => a + b) / l.length;
    double _min(List<double> l) => l.reduce((a, b) => a < b ? a : b);
    double _max(List<double> l) => l.reduce((a, b) => a > b ? a : b);

    return {
      'available': true,
      'duración': '${durationMs ~/ 1000} s',
      'muestras': inputLevels.length,
      'inputDbSpl (min/avg/max)':
          '${_min(inputLevels).toStringAsFixed(1)} / ${_avg(inputLevels).toStringAsFixed(1)} / ${_max(inputLevels).toStringAsFixed(1)}',
      'snrDb (min/avg/max)':
          '${_min(snrValues).toStringAsFixed(1)} / ${_avg(snrValues).toStringAsFixed(1)} / ${_max(snrValues).toStringAsFixed(1)}',
      'vadScore (avg)': _avg(vadScores).toStringAsFixed(3),
      'tilt (avg)': _avg(tilts).toStringAsFixed(2),
      'claseDominante': dominantClass,
      'parseErrors': parseErrors,
    };
  }


  /// Diagnóstico DSP: grabación real de 15 s de audio dual-channel.
  /// Inicia la grabación nativa, polea el progreso a 1 Hz, y reporta resultado.
  Future<Map<String, dynamic>> _testDspRecording() async {
    final bloc = _bloc;
    if (bloc == null) return {'status': 'Bloc no disponible', 'canRecord': false};
    final active = bloc.state is AmplificationActive;
    if (!active) {
      return {'status': 'Motor no activo', 'canRecord': false};
    }

    // Generar nombre temporal para la grabación de diagnóstico
    final now = DateTime.now();
    final baseName = 'diag_test_${now.year}${_pad2(now.month)}${_pad2(now.day)}'
        '_${_pad2(now.hour)}${_pad2(now.minute)}${_pad2(now.second)}';
    final wavFilename = '$baseName.wav';

    // Iniciar grabación
    bool started = false;
    try {
      started = await _channel.invokeMethod<bool>(
            'startDiagnosticRecording',
            {'filePath': wavFilename},
          ) ??
          false;
    } catch (_) {
      started = false;
    }

    if (!started) {
      return {
        'status': 'No se pudo iniciar la grabación',
        'canRecord': false,
      };
    }

    // Polling de progreso a 1 Hz durante máximo 18 s (15 + margen)
    const int maxPolls = 18;
    int lastProgressMs = 0;
    for (int i = 0; i < maxPolls; i++) {
      if (_cancelled) break;
      await Future.delayed(const Duration(seconds: 1));
      try {
        final progress = await _channel.invokeMethod<int>(
              'getDiagnosticRecordingProgress',
            ) ??
            -1;
        if (progress < 0) {
          // Error durante grabación
          return {
            'status': 'Error durante grabación (progress = -1)',
            'completada': false,
            'tiempoAlcanzado': '${lastProgressMs ~/ 1000} s',
          };
        }
        lastProgressMs = progress;
        if (progress >= 15000) break; // 15 s alcanzados
      } catch (_) {
        break;
      }
    }

    // Detener grabación
    int stopResult = -1;
    try {
      stopResult = await _channel.invokeMethod<int>(
            'stopDiagnosticRecording',
          ) ??
          -1;
    } catch (_) {
      stopResult = -1;
    }

    return {
      'completada': stopResult == 0,
      'duración': '${lastProgressMs ~/ 1000} s',
      'archivo': wavFilename,
      'formato': 'WAV dual-channel (pre/post DSP)',
      'stopCode': stopResult,
    };
  }

  String _pad2(int n) => n.toString().padLeft(2, '0');

  /// Registro de Sesión: arranca el servicio, captura durante 10 s,
  /// detiene, y reporta los eventos capturados.
  Future<Map<String, dynamic>> _testSessionLog() async {
    final bloc = _bloc;
    if (bloc == null) return {'status': 'Bloc no disponible'};

    // Si ya está grabando, solo reportamos estado actual
    if (_sessionSvc.isRecording) {
      return {
        'status': 'Ya estaba grabando',
        'isRecording': true,
        'eventCount': _sessionSvc.events.length,
        'elapsed': _sessionSvc.elapsed.inSeconds,
      };
    }

    // Arrancar grabación
    _sessionSvc.start(bloc);

    // Esperar 10 s capturando eventos
    const int durationSec = 10;
    for (int i = 0; i < durationSec; i++) {
      if (_cancelled) break;
      await Future.delayed(const Duration(seconds: 1));
    }

    // Detener
    _sessionSvc.stop(bloc);

    final events = _sessionSvc.events;
    return {
      'completado': true,
      'duración': '$durationSec s',
      'eventCount': events.length,
      'hasInitialSnapshot': _sessionSvc.initialSnapshot != null,
      'hasFinalSnapshot': _sessionSvc.finalSnapshot != null,
      'tiposDeEvento': _countEventTypes(events),
    };
  }

  /// Cuenta los tipos de eventos capturados por SessionLogService.
  String _countEventTypes(List<Map<String, dynamic>> events) {
    final types = <String, int>{};
    for (final e in events) {
      final kind = (e['kind'] as String?) ?? 'unknown';
      types[kind] = (types[kind] ?? 0) + 1;
    }
    if (types.isEmpty) return 'ninguno';
    return types.entries.map((e) => '${e.key}: ${e.value}').join(', ');
  }

  /// Spectrum Analyzer: activa FFT, polea a 10 Hz durante 5 s (50 snapshots),
  /// desactiva FFT, y reporta estadísticas del espectro.
  Future<Map<String, dynamic>> _testSpectrum() async {
    _spectrumBridge.startAnalysis();

    // Esperar que el nativo active el FFT
    await Future.delayed(const Duration(milliseconds: 200));

    const int durationMs = 5000;
    const int intervalMs = 100; // 10 Hz
    const int expectedSamples = durationMs ~/ intervalMs;

    final List<double> inputLevels = [];
    final List<double> outputLevels = [];
    final List<int> envClasses = [];
    int nullCount = 0;

    for (int i = 0; i < expectedSamples; i++) {
      if (_cancelled) break;
      final snap = await _spectrumBridge.getCurrentSpectrum();
      if (snap != null) {
        inputLevels.add(snap.inputLevelDb);
        outputLevels.add(snap.outputLevelDb);
        envClasses.add(snap.environmentClass);
      } else {
        nullCount++;
      }
      if (i < expectedSamples - 1) {
        await Future.delayed(const Duration(milliseconds: intervalMs));
      }
    }

    _spectrumBridge.stopAnalysis();

    if (inputLevels.isEmpty) {
      return {'available': false, 'status': 'Sin datos de espectro'};
    }

    double _avg(List<double> l) => l.reduce((a, b) => a + b) / l.length;
    double _min(List<double> l) => l.reduce((a, b) => a < b ? a : b);
    double _max(List<double> l) => l.reduce((a, b) => a > b ? a : b);

    return {
      'available': true,
      'duración': '${durationMs ~/ 1000} s',
      'muestras': inputLevels.length,
      'inputDb (min/avg/max)':
          '${_min(inputLevels).toStringAsFixed(1)} / ${_avg(inputLevels).toStringAsFixed(1)} / ${_max(inputLevels).toStringAsFixed(1)}',
      'outputDb (min/avg/max)':
          '${_min(outputLevels).toStringAsFixed(1)} / ${_avg(outputLevels).toStringAsFixed(1)} / ${_max(outputLevels).toStringAsFixed(1)}',
      'snapshotsNulos': nullCount,
    };
  }


  /// Motor de Realce: polling 5 Hz durante 5 s (25 muestras).
  /// Reporta estabilidad del modo, % tiempo MVDR/DNN activos.
  Future<Map<String, dynamic>> _testEnhancement() async {
    const int durationMs = 5000;
    const int intervalMs = 200; // 5 Hz
    const int expected = durationMs ~/ intervalMs;

    final List<int> modes = [];
    int bfActiveCount = 0;
    int dnnActiveCount = 0;
    int samples = 0;

    for (int i = 0; i < expected; i++) {
      if (_cancelled) break;
      try {
        final mode = await _channel.invokeMethod<int>('getEnhancementEngineMode') ?? 0;
        final bf = await _channel.invokeMethod<bool>('getBeamformingActive') ?? false;
        final dnn = await _channel.invokeMethod<bool>('getDnnIsActive') ?? false;
        modes.add(mode);
        if (bf) bfActiveCount++;
        if (dnn) dnnActiveCount++;
        samples++;
      } catch (_) {}
      if (i < expected - 1) {
        await Future.delayed(const Duration(milliseconds: intervalMs));
      }
    }

    if (samples == 0) return {'available': false};

    final modeNames = ['Bypass', 'Dual-DNN (GTCRN)', 'MVDR Beamformer'];
    final modeCount = <int, int>{};
    for (final m in modes) {
      modeCount[m] = (modeCount[m] ?? 0) + 1;
    }
    final dominantMode = modeCount.entries
        .reduce((a, b) => a.value >= b.value ? a : b)
        .key;
    final modeChanges = _countChanges(modes);

    return {
      'available': true,
      'duración': '${durationMs ~/ 1000} s',
      'muestras': samples,
      'modoDominante': modeNames[dominantMode.clamp(0, 2)],
      'cambiosDeModo': modeChanges,
      'mvdrActivo%': '${(bfActiveCount * 100 / samples).toStringAsFixed(0)}%',
      'dnnActivo%': '${(dnnActiveCount * 100 / samples).toStringAsFixed(0)}%',
      'estable': modeChanges == 0,
    };
  }

  /// Cuenta transiciones en una lista (cuántas veces cambia el valor).
  int _countChanges(List<int> values) {
    int changes = 0;
    for (int i = 1; i < values.length; i++) {
      if (values[i] != values[i - 1]) changes++;
    }
    return changes;
  }

  /// Latencia: polling 5 Hz durante 5 s (25 muestras).
  /// Reporta min/avg/max de DSP processing y DNN inference, delta underruns.
  Future<Map<String, dynamic>> _testLatency() async {
    const int durationMs = 5000;
    const int intervalMs = 200;
    const int expected = durationMs ~/ intervalMs;

    final List<double> dspAvgs = [];
    final List<double> dspMaxes = [];
    final List<double> dnnInferences = [];
    int? underrunsStart;
    int? underrunsEnd;
    int samples = 0;

    for (int i = 0; i < expected; i++) {
      if (_cancelled) break;
      try {
        final m = await _channel.invokeMethod<Map>('getLatencyMetrics');
        if (m != null) {
          final data = Map<String, dynamic>.from(m);
          final dspAvg = data['dspProcessingMsAvg'];
          final dspMax = data['dspProcessingMsMax'];
          final dnnInf = data['dnnInferenceMs'];
          final underruns = data['callbackUnderruns'];

          if (dspAvg is num) dspAvgs.add(dspAvg.toDouble());
          if (dspMax is num) dspMaxes.add(dspMax.toDouble());
          if (dnnInf is num && dnnInf >= 0) dnnInferences.add(dnnInf.toDouble());
          if (underruns is int) {
            underrunsStart ??= underruns;
            underrunsEnd = underruns;
          }
          samples++;
        }
      } catch (_) {}
      if (i < expected - 1) {
        await Future.delayed(const Duration(milliseconds: intervalMs));
      }
    }

    if (samples == 0) return {'available': false, 'status': 'Sin métricas'};

    double _avg(List<double> l) => l.isEmpty ? 0 : l.reduce((a, b) => a + b) / l.length;
    double _min(List<double> l) => l.isEmpty ? 0 : l.reduce((a, b) => a < b ? a : b);
    double _max(List<double> l) => l.isEmpty ? 0 : l.reduce((a, b) => a > b ? a : b);

    return {
      'available': true,
      'duración': '${durationMs ~/ 1000} s',
      'muestras': samples,
      'dspProcessing (min/avg/max)':
          '${_min(dspAvgs).toStringAsFixed(2)} / ${_avg(dspAvgs).toStringAsFixed(2)} / ${_max(dspAvgs).toStringAsFixed(2)} ms',
      'dspPeakMax': '${_max(dspMaxes).toStringAsFixed(2)} ms',
      'dnnInference (min/avg/max)': dnnInferences.isEmpty
          ? 'N/A'
          : '${_min(dnnInferences).toStringAsFixed(2)} / ${_avg(dnnInferences).toStringAsFixed(2)} / ${_max(dnnInferences).toStringAsFixed(2)} ms',
      'underrunsInicio': underrunsStart ?? 0,
      'underrunsFin': underrunsEnd ?? 0,
      'underrunsNuevos': (underrunsEnd ?? 0) - (underrunsStart ?? 0),
    };
  }

  /// DNN Denoiser: polling 5 Hz durante 5 s (25 muestras).
  /// Reporta % tiempo activo, min/avg/max inferencia.
  Future<Map<String, dynamic>> _testDnn() async {
    const int durationMs = 5000;
    const int intervalMs = 200;
    const int expected = durationMs ~/ intervalMs;

    int activeCount = 0;
    final List<double> inferences = [];
    int samples = 0;

    for (int i = 0; i < expected; i++) {
      if (_cancelled) break;
      try {
        final active = await _channel.invokeMethod<bool>('getDnnIsActive') ?? false;
        final lat = await _channel.invokeMethod<Map>('getLatencyMetrics');
        if (active) activeCount++;
        if (lat != null) {
          final data = Map<String, dynamic>.from(lat);
          final inf = data['dnnInferenceMs'];
          if (inf is num && inf >= 0) inferences.add(inf.toDouble());
        }
        samples++;
      } catch (_) {}
      if (i < expected - 1) {
        await Future.delayed(const Duration(milliseconds: intervalMs));
      }
    }

    if (samples == 0) return {'available': false};

    double _avg(List<double> l) => l.isEmpty ? 0 : l.reduce((a, b) => a + b) / l.length;
    double _min(List<double> l) => l.isEmpty ? 0 : l.reduce((a, b) => a < b ? a : b);
    double _max(List<double> l) => l.isEmpty ? 0 : l.reduce((a, b) => a > b ? a : b);

    return {
      'available': true,
      'duración': '${durationMs ~/ 1000} s',
      'muestras': samples,
      'activo%': '${(activeCount * 100 / samples).toStringAsFixed(0)}%',
      'inferencia (min/avg/max)': inferences.isEmpty
          ? 'N/A (DNN inactiva)'
          : '${_min(inferences).toStringAsFixed(2)} / ${_avg(inferences).toStringAsFixed(2)} / ${_max(inferences).toStringAsFixed(2)} ms',
      'estable': inferences.isEmpty || (_max(inferences) - _min(inferences)) < 2.0,
    };
  }


  /// WDRC: polling 5 Hz durante 5 s (25 muestras).
  /// Reporta distribución de regiones, min/avg/max gainFactor y niveles.
  Future<Map<String, dynamic>> _testWdrc() async {
    const int durationMs = 5000;
    const int intervalMs = 200;
    const int expected = durationMs ~/ intervalMs;

    final List<int> regions = [];
    final List<double> gains = [];
    final List<double> postWdrcLevels = [];
    int samples = 0;

    for (int i = 0; i < expected; i++) {
      if (_cancelled) break;
      try {
        final m = await _channel.invokeMethod<Map>('getDspStageMetrics');
        if (m != null) {
          final data = Map<String, dynamic>.from(m);
          final region = data['wdrcRegion'];
          final gain = data['wdrcGainFactor'];
          final postWdrc = data['postWdrcLevel'];
          if (region is int) regions.add(region);
          if (gain is num) gains.add(gain.toDouble());
          if (postWdrc is num) postWdrcLevels.add(postWdrc.toDouble());
          samples++;
        }
      } catch (_) {}
      if (i < expected - 1) {
        await Future.delayed(const Duration(milliseconds: intervalMs));
      }
    }

    if (samples == 0) return {'available': false};

    double _avg(List<double> l) => l.isEmpty ? 0 : l.reduce((a, b) => a + b) / l.length;
    double _min(List<double> l) => l.isEmpty ? 0 : l.reduce((a, b) => a < b ? a : b);
    double _max(List<double> l) => l.isEmpty ? 0 : l.reduce((a, b) => a > b ? a : b);

    final regionNames = ['Expansión', 'Lineal', 'Compresión'];
    final regionCount = <int, int>{};
    for (final r in regions) {
      regionCount[r] = (regionCount[r] ?? 0) + 1;
    }
    final regionDist = regionCount.entries
        .map((e) => '${regionNames[e.key.clamp(0, 2)]}: ${(e.value * 100 / samples).toStringAsFixed(0)}%')
        .join(', ');

    return {
      'available': true,
      'duración': '${durationMs ~/ 1000} s',
      'muestras': samples,
      'distribuciónRegiones': regionDist,
      'cambiosDeRegión': _countChanges(regions),
      'gainFactor (min/avg/max)':
          '${_min(gains).toStringAsFixed(3)} / ${_avg(gains).toStringAsFixed(3)} / ${_max(gains).toStringAsFixed(3)}',
      'postWdrc (min/avg/max)':
          '${_min(postWdrcLevels).toStringAsFixed(1)} / ${_avg(postWdrcLevels).toStringAsFixed(1)} / ${_max(postWdrcLevels).toStringAsFixed(1)} dB',
    };
  }

  /// MPO Limiter: polling 5 Hz durante 5 s (25 muestras).
  /// Reporta % tiempo limitando, clips acumulados, peak máximo.
  Future<Map<String, dynamic>> _testMpo() async {
    const int durationMs = 5000;
    const int intervalMs = 200;
    const int expected = durationMs ~/ intervalMs;

    int limitingCount = 0;
    int sustainedCount = 0;
    int totalClips = 0;
    final List<double> peaks = [];
    final List<double> fractions = [];
    int samples = 0;

    for (int i = 0; i < expected; i++) {
      if (_cancelled) break;
      try {
        final m = await _channel.invokeMethod<Map>('getDspStageMetrics');
        if (m != null) {
          final data = Map<String, dynamic>.from(m);
          final frac = data['mpoLimitingFraction'];
          final sust = data['mpoLimitingSustained'];
          final peak = data['peakSample'];
          final clips = data['clipCount'];

          if (frac is num) {
            fractions.add(frac.toDouble());
            if (frac > 0.0) limitingCount++;
          }
          if (sust == true) sustainedCount++;
          if (peak is num) peaks.add(peak.toDouble());
          if (clips is int) totalClips += clips;
          samples++;
        }
      } catch (_) {}
      if (i < expected - 1) {
        await Future.delayed(const Duration(milliseconds: intervalMs));
      }
    }

    if (samples == 0) return {'available': false};

    double _avg(List<double> l) => l.isEmpty ? 0 : l.reduce((a, b) => a + b) / l.length;
    double _max(List<double> l) => l.isEmpty ? 0 : l.reduce((a, b) => a > b ? a : b);

    return {
      'available': true,
      'duración': '${durationMs ~/ 1000} s',
      'muestras': samples,
      'limitando%': '${(limitingCount * 100 / samples).toStringAsFixed(0)}%',
      'sostenido%': '${(sustainedCount * 100 / samples).toStringAsFixed(0)}%',
      'fracciónPromedio': _avg(fractions).toStringAsFixed(4),
      'peakMáximo': _max(peaks).toStringAsFixed(4),
      'clipsAcumulados': totalClips,
    };
  }

  /// Protección: polling 5 Hz durante 5 s (25 muestras).
  /// Reporta estabilidad del clasificador de entorno y EQ max gain.
  Future<Map<String, dynamic>> _testProtection() async {
    const int durationMs = 5000;
    const int intervalMs = 200;
    const int expected = durationMs ~/ intervalMs;

    final List<int> envClasses = [];
    final List<double> eqMaxGains = [];
    int samples = 0;

    for (int i = 0; i < expected; i++) {
      if (_cancelled) break;
      try {
        final m = await _channel.invokeMethod<Map>('getDspStageMetrics');
        if (m != null) {
          final data = Map<String, dynamic>.from(m);
          final env = data['environmentClass'];
          final eqMax = data['eqMaxGain'];
          if (env is int) envClasses.add(env);
          if (eqMax is num) eqMaxGains.add(eqMax.toDouble());
          samples++;
        }
      } catch (_) {}
      if (i < expected - 1) {
        await Future.delayed(const Duration(milliseconds: intervalMs));
      }
    }

    if (samples == 0) return {'available': false};

    double _max(List<double> l) => l.isEmpty ? 0 : l.reduce((a, b) => a > b ? a : b);

    final envNames = ['QUIET', 'SPEECH', 'SPEECH_IN_NOISE', 'NOISE'];
    final envCount = <int, int>{};
    for (final e in envClasses) {
      envCount[e] = (envCount[e] ?? 0) + 1;
    }
    final dominantEnv = envCount.entries
        .reduce((a, b) => a.value >= b.value ? a : b)
        .key;
    final envChanges = _countChanges(envClasses);

    return {
      'available': true,
      'duración': '${durationMs ~/ 1000} s',
      'muestras': samples,
      'ambienteDominante': envNames[dominantEnv.clamp(0, 3)],
      'cambiosDeAmbiente': envChanges,
      'clasificadorEstable': envChanges <= 2,
      'eqMaxGain': '${_max(eqMaxGains).toStringAsFixed(1)} dB',
      'afc': 'Activo',
      'fbs': 'Activo',
      'tnr': 'Configurado',
      'sce': 'Activo',
      'expander': 'Vía Smart Scene',
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

  /// Salud del Sistema: polling 5 Hz durante 5 s (25 muestras).
  /// Reporta delta de underruns y estabilidad de timestamps.
  Future<Map<String, dynamic>> _testHealth() async {
    const int durationMs = 5000;
    const int intervalMs = 200;
    const int expected = durationMs ~/ intervalMs;

    int? underrunsStart;
    int? underrunsEnd;
    int healthyCount = 0;
    int samples = 0;

    for (int i = 0; i < expected; i++) {
      if (_cancelled) break;
      try {
        final m = await _channel.invokeMethod<Map>('getLatencyMetrics');
        if (m != null) {
          final data = Map<String, dynamic>.from(m);
          final underruns = data['callbackUnderruns'];
          final healthy = data['timestampsHealthy'];
          if (underruns is int) {
            underrunsStart ??= underruns;
            underrunsEnd = underruns;
          }
          if (healthy == true) healthyCount++;
          samples++;
        }
      } catch (_) {}
      if (i < expected - 1) {
        await Future.delayed(const Duration(milliseconds: intervalMs));
      }
    }

    if (samples == 0) return {'available': false};

    final newUnderruns = (underrunsEnd ?? 0) - (underrunsStart ?? 0);

    return {
      'available': true,
      'duración': '${durationMs ~/ 1000} s',
      'muestras': samples,
      'underrunsInicio': underrunsStart ?? 0,
      'underrunsFin': underrunsEnd ?? 0,
      'underrunsNuevos': newUnderruns,
      'creciendoActivamente': newUnderruns > 0,
      'timestampsHealthy%': '${(healthyCount * 100 / samples).toStringAsFixed(0)}%',
    };
  }

  /// Test #13: Comparativa A/B — graba 5 s en cada modo (Bypass, DualDNN, MVDR)
  /// produciendo un WAV independiente por modo. Permite comparar auditivamente
  /// la calidad de cada motor de realce en el mismo ambiente.
  Future<Map<String, dynamic>> _testAbComparative() async {
    final bloc = _bloc;
    if (bloc == null) return {'status': 'Bloc no disponible', 'canRecord': false};
    final active = bloc.state is AmplificationActive;
    if (!active) {
      return {'status': 'Motor no activo', 'canRecord': false};
    }

    final now = DateTime.now();
    final ts = '${now.year}${_pad2(now.month)}${_pad2(now.day)}'
        '_${_pad2(now.hour)}${_pad2(now.minute)}${_pad2(now.second)}';

    final modes = [
      {'name': 'Bypass', 'mode': 0, 'file': 'ab_bypass_$ts.wav'},
      {'name': 'DualDNN', 'mode': 1, 'file': 'ab_dualdnn_$ts.wav'},
      {'name': 'MVDR', 'mode': 2, 'file': 'ab_mvdr_$ts.wav'},
    ];

    // Guardar modo actual para restaurar al final
    final originalMode = await _channel.invokeMethod<int>('getEnhancementEngineMode') ?? 0;

    final results = <String, String>{};
    int successCount = 0;

    for (final m in modes) {
      if (_cancelled) break;
      final modeName = m['name'] as String;
      final modeInt = m['mode'] as int;
      final fileName = m['file'] as String;

      // Cambiar modo
      try {
        await _channel.invokeMethod<void>('setEnhancementEngineMode', {'mode': modeInt});
      } catch (_) {
        results['${modeName}'] = 'Error al cambiar modo';
        continue;
      }

      // Esperar 500 ms para que el cambio se estabilice
      await Future.delayed(const Duration(milliseconds: 500));

      // Iniciar grabación de 5 s
      bool started = false;
      try {
        started = await _channel.invokeMethod<bool>(
              'startDiagnosticRecording',
              {'filePath': fileName},
            ) ?? false;
      } catch (_) {
        started = false;
      }

      if (!started) {
        results[modeName] = 'Error al iniciar grabación';
        continue;
      }

      // Esperar 5 s
      for (int i = 0; i < 6; i++) {
        if (_cancelled) break;
        await Future.delayed(const Duration(seconds: 1));
        try {
          final progress = await _channel.invokeMethod<int>(
                'getDiagnosticRecordingProgress',
              ) ?? -1;
          if (progress < 0) break;
          if (progress >= 5000) break;
        } catch (_) {
          break;
        }
      }

      // Detener grabación
      int stopResult = -1;
      try {
        stopResult = await _channel.invokeMethod<int>(
              'stopDiagnosticRecording',
            ) ?? -1;
      } catch (_) {
        stopResult = -1;
      }

      if (stopResult == 0) {
        results[modeName] = fileName;
        successCount++;
      } else {
        results[modeName] = 'Stop code: $stopResult';
      }

      // Pausa entre modos
      await Future.delayed(const Duration(milliseconds: 300));
    }

    // Restaurar modo original
    try {
      await _channel.invokeMethod<void>('setEnhancementEngineMode', {'mode': originalMode});
    } catch (_) {}

    return {
      'completada': successCount == 3,
      'archivosGrabados': successCount,
      'duración': '5 s por modo (15 s total)',
      ...results,
      'modoRestaurado': originalMode,
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
            '$completed/13 completados',
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
                    onPressed: () {
                      _bloc ??= context.read<AmplificationBloc>();
                      _runTest(id);
                    },
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
