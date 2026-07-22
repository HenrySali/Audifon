/// Smart Scene Engine — UI Fase 2.
///
/// Muestra los números crudos del clasificador C++ actualizados a 10 Hz:
/// dB SPL, SNR, VAD score, tilt espectral, centroide, energía por banda.
///
/// Fase 2 agrega:
///   - Toggle "Personalizar con mi audiograma" (persistido en Hive).
///   - Botón "Detectar y aplicar" que dispara `SceneEngine.analyze()` y
///     muestra clase + confianza + descripción.
///   - Aún NO aplica preset al pipeline (eso llega en Fase 3 con
///     `SceneEngine.apply()`).
///
/// Mantiene las herramientas de diagnóstico de Fase 1:
///   - Buffer rolling de los últimos 30 s de snapshots.
///   - "Grabar" + "Copiar CSV" + "Copiar errores".
///
/// Validates: Requirements 1.1, 1.6, 5.1, 5.2, 6.2

import 'dart:async';
import 'dart:collection';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../dnn_denoiser/dnn_denoiser_controller.dart';
import '../../domain/entities/audiogram.dart';
import '../../scene/scene_class.dart';
import '../../scene/scene_engine.dart';
import '../../scene/scene_recorder.dart';
import '../../scene/scene_snapshot.dart';
import '../../scene/smart_preset.dart';
import '../bloc/amplification_bloc.dart';
import '../widgets/default_audiogram_hint.dart';

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

  // ─── Smart Scene Engine (Fase 2/3/4) ────────────────────────────────
  final SceneEngine _engine = SceneEngine();
  bool _engineLoaded = false;
  bool _isAnalyzing = false;
  bool _isApplying = false;
  SceneAnalysisResult? _lastResult;
  SceneRecord? _lastRecord;
  String? _analysisError;
  Audiogram? _audiogram;
  bool _audiogramLoaded = false;
  List<SceneRecord> _history = const <SceneRecord>[];

  // ─── DNN Denoiser (GTCRN) ────────────────────────────────────────────
  /// Controller del denoiser DNN. Se inicializa en initState.
  /// La UI muestra un toggle ON/OFF + slider de intensidad.
  /// El estado "está procesando audio" se polea cada 500 ms.
  final DnnDenoiserController _dnnController = DnnDenoiserController();
  bool _dnnSettingsLoaded = false;
  Timer? _dnnIsActivePollTimer;
  static const Duration _dnnIsActivePollInterval = Duration(milliseconds: 500);

  @override
  void initState() {
    super.initState();
    _startPolling();
    _initEngineAndAudiogram();
    _initDnnDenoiser();
    // Técnico = MANUAL: ya no se arranca polling automático de ambiente.
  }

  Future<void> _initEngineAndAudiogram() async {
    await _loadEngineSettings();
    if (!mounted) return;
    await _loadAudiogram();
    if (!mounted) return;
    await _refreshHistory();
  }

  /// Carga settings persistidos del DNN denoiser, inicializa el modelo
  /// nativo (`gtcrn.onnx` desde assets) y arranca el polling de
  /// `isActive` para que la UI muestre cuándo está procesando audio.
  ///
  /// Si el motor de audio nativo todavía no está corriendo (porque el
  /// usuario no encendió el audífono), `nativeInitDnnDenoiser` falla
  /// limpiamente y queda en bypass. El polling de `isActive` se reintenta
  /// cada 500 ms, así que cuando el usuario active el audífono el modelo
  /// se va a cargar al próximo ciclo.
  Future<void> _initDnnDenoiser() async {
    await _dnnController.loadSettings();
    if (!mounted) return;
    setState(() {
      _dnnSettingsLoaded = true;
    });

    // Intento inicial de cargar el modelo nativo desde assets/.
    // Si falla (ej: motor de audio aún no inicializado), no es bloqueante:
    // los siguientes refreshIsActive() también disparan init si hace falta.
    await _dnnController.initializeNative();
    if (!mounted) return;
    setState(() {});

    _dnnIsActivePollTimer?.cancel();
    _dnnIsActivePollTimer = Timer.periodic(_dnnIsActivePollInterval, (_) async {
      if (!mounted) return;
      // Si todavía no está activo y el usuario quiere usarlo, reintentar
      // la inicialización nativa por si el motor de audio recién arrancó.
      if (_dnnController.isEnabled && !_dnnController.isActive) {
        await _dnnController.initializeNative();
      } else {
        await _dnnController.refreshIsActive();
      }
      if (!mounted) return;
      setState(() {});
    });
  }

  Future<void> _onDnnEnabledChanged(bool enabled) async {
    await _dnnController.setEnabled(enabled);
    if (!mounted) return;
    setState(() {});
  }

  Future<void> _onDnnIntensityChanged(double intensity) async {
    await _dnnController.setIntensity(intensity);
    if (!mounted) return;
    setState(() {});
  }

  Future<void> _refreshHistory() async {
    final list = await _engine.recorder.getHistory(limit: 10);
    if (!mounted) return;
    setState(() {
      _history = list;
    });
  }

  @override
  void dispose() {
    _pollTimer?.cancel();
    _dnnIsActivePollTimer?.cancel();
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

  // ────────────────────────────────────────────────────────────────────
  // Smart Scene Engine (Fase 2)
  // ────────────────────────────────────────────────────────────────────

  Future<void> _loadEngineSettings() async {
    await _engine.loadSettings();
    if (!mounted) return;
    setState(() {
      _engineLoaded = true;
    });
  }

  Future<void> _loadAudiogram() async {
    try {
      final bloc = context.read<AmplificationBloc>();
      final a = await bloc.audiogramRepository.getAudiogram();
      if (!mounted) return;
      setState(() {
        _audiogram = a;
        _audiogramLoaded = true;
      });

      // Default del toggle: ON si hay audiograma y el usuario nunca tocó
      // el switch. Si lo tocó alguna vez, respetamos su elección.
      if (a != null && _engineLoaded && !_engine.wasPersonalizeUserSet) {
        await _engine.setPersonalize(true);
        if (!mounted) return;
        setState(() {});
      }
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _audiogram = null;
        _audiogramLoaded = true;
      });
    }
  }

  Future<void> _togglePersonalize(bool value) async {
    await _engine.setPersonalize(value);
    if (!mounted) return;
    setState(() {});
  }

  Future<void> _runAnalysis() async {
    if (_isAnalyzing) return;
    setState(() {
      _isAnalyzing = true;
      _analysisError = null;
      _lastRecord = null; // limpiar feedback del análisis anterior
    });
    try {
      final result = await _engine.analyze(audiogram: _audiogram);
      if (!mounted) return;
      setState(() {
        _lastResult = result;
        _isAnalyzing = false;
      });
      _showSnack(
        'Detectado: ${result.sceneClass.label} '
        '(confianza ${(result.confidence * 100).toStringAsFixed(0)}%)',
      );
    } on SceneEngineException catch (e) {
      if (!mounted) return;
      setState(() {
        _analysisError = e.message;
        _isAnalyzing = false;
      });
      _logError(e.message);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _analysisError = e.toString();
        _isAnalyzing = false;
      });
      _logError(e.toString());
    }
  }

  Future<void> _applyPreset() async {
    final result = _lastResult;
    if (result == null || _isApplying) return;
    setState(() => _isApplying = true);
    try {
      final bloc = context.read<AmplificationBloc>();
      await _engine.apply(result, bloc: bloc);
      if (!mounted) return;
      _lastRecord = _engine.lastRecord;
      _showSnack('Preset "${result.preset.name}" aplicado.');
      await _refreshHistory();
    } catch (e) {
      if (!mounted) return;
      _logError('apply: $e');
      _showSnack('No se pudo aplicar: $e');
    } finally {
      if (mounted) setState(() => _isApplying = false);
    }
  }

  Future<void> _sendFeedback(bool positive) async {
    final rec = _lastRecord;
    if (rec == null) return;
    await _engine.recorder.updateFeedback(rec.id, positive);
    if (!mounted) return;
    setState(() {
      _lastRecord = rec.copyWith(feedback: positive);
    });
    _showSnack(positive ? 'Gracias por el 👍' : 'Anotado, lo mejoramos.');
    await _refreshHistory();
  }

  Future<void> _clearHistory() async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF16213e),
        title: const Text(
          'Borrar histórico',
          style: TextStyle(color: Colors.white),
        ),
        content: const Text(
          '¿Querés borrar todas las entradas del histórico de Smart Scene?',
          style: TextStyle(color: Colors.white70),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Cancelar'),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Borrar', style: TextStyle(color: Colors.redAccent)),
          ),
        ],
      ),
    );
    if (confirm == true) {
      await _engine.recorder.clearAll();
      if (!mounted) return;
      _showSnack('Histórico borrado.');
      await _refreshHistory();
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
  // Técnico = MANUAL (sin clasificador automático)
  // ────────────────────────────────────────────────────────────────────
  //
  // Decisión de producto: en el TÉCNICO los 3 ambientes
  // (Silencioso / Conversación / Ruidoso) se eligen SIEMPRE a mano desde
  // el selector de perfil. La ÚNICA app con cambio de ambiente automático
  // es V3. Por eso acá NO hay polling 1 Hz que despache `ChangeProfile`.
  //
  // El motor C++ sigue exponiendo `environmentClass` (lo usa V3 y el botón
  // manual "Detectar y aplicar" de esta pantalla vía `SceneEngine`), pero
  // esta screen ya no aplica ningún preset por su cuenta.

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
              DefaultAudiogramHint(sceneEngine: _engine),
              const SizedBox(height: 8),
              _DetectCard(
                isAnalyzing: _isAnalyzing,
                isApplying: _isApplying,
                personalize: _engine.personalizeWithAudiogram,
                personalizeReady: _engineLoaded,
                audiogramAvailable: _audiogram != null,
                audiogramLoaded: _audiogramLoaded,
                onPersonalizeChanged: _togglePersonalize,
                onDetect: _runAnalysis,
                onApply: _applyPreset,
                analysisError: _analysisError,
                lastResult: _lastResult,
                lastRecord: _lastRecord,
                onFeedback: _sendFeedback,
              ),
              const SizedBox(height: 12),
              _DnnDenoiserCard(
                settingsLoaded: _dnnSettingsLoaded,
                enabled: _dnnController.isEnabled,
                intensity: _dnnController.intensity,
                isActive: _dnnController.isActive,
                onEnabledChanged: _onDnnEnabledChanged,
                onIntensityChanged: _onDnnIntensityChanged,
              ),
              const SizedBox(height: 12),
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
              _HistoryCard(
                history: _history,
                onClear: _clearHistory,
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

class _FeedbackBar extends StatelessWidget {
  final bool? feedback;
  final ValueChanged<bool> onFeedback;

  const _FeedbackBar({required this.feedback, required this.onFeedback});

  @override
  Widget build(BuildContext context) {
    final answered = feedback != null;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: Colors.white.withOpacity(0.04),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: Colors.white12),
      ),
      child: Row(
        children: [
          const Expanded(
            child: Text(
              '¿Funcionó bien este preset?',
              style: TextStyle(color: Colors.white70, fontSize: 13),
            ),
          ),
          IconButton(
            tooltip: 'Sí',
            icon: Icon(
              Icons.thumb_up_alt_rounded,
              color: feedback == true
                  ? Colors.greenAccent
                  : Colors.white60,
            ),
            onPressed: answered ? null : () => onFeedback(true),
          ),
          IconButton(
            tooltip: 'No',
            icon: Icon(
              Icons.thumb_down_alt_rounded,
              color: feedback == false
                  ? Colors.redAccent
                  : Colors.white60,
            ),
            onPressed: answered ? null : () => onFeedback(false),
          ),
        ],
      ),
    );
  }
}

class _HistoryCard extends StatelessWidget {
  final List<SceneRecord> history;
  final VoidCallback onClear;

  const _HistoryCard({required this.history, required this.onClear});

  String _formatTime(DateTime t) {
    final hh = t.hour.toString().padLeft(2, '0');
    final mm = t.minute.toString().padLeft(2, '0');
    return '$hh:$mm';
  }

  @override
  Widget build(BuildContext context) {
    return _SceneCard(
      icon: Icons.history,
      title: 'Histórico (últimas ${history.length})',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (history.isEmpty)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 8),
              child: Text(
                'Todavía no aplicaste ningún preset.',
                style: TextStyle(color: Colors.white54, fontSize: 12),
              ),
            )
          else
            ...history.map((rec) {
              final cls = rec.sceneClass;
              return Padding(
                padding: const EdgeInsets.symmetric(vertical: 4),
                child: Row(
                  children: [
                    Icon(cls.icon, color: cls.color, size: 18),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        '${cls.label}  ·  ${_formatTime(rec.timestamp)}'
                        '${rec.wasPersonalized ? "  ·  perso" : ""}',
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 12,
                        ),
                      ),
                    ),
                    if (rec.feedback != null)
                      Icon(
                        rec.feedback!
                            ? Icons.thumb_up_alt_rounded
                            : Icons.thumb_down_alt_rounded,
                        size: 14,
                        color: rec.feedback!
                            ? Colors.greenAccent
                            : Colors.redAccent,
                      ),
                  ],
                ),
              );
            }),
          if (history.isNotEmpty) ...[
            const SizedBox(height: 8),
            Align(
              alignment: Alignment.centerRight,
              child: TextButton.icon(
                onPressed: onClear,
                icon: const Icon(Icons.delete_outline, size: 16),
                label: const Text('Borrar histórico'),
                style: TextButton.styleFrom(
                  foregroundColor: Colors.redAccent,
                ),
              ),
            ),
          ],
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

// ─────────────────────────────────────────────────────────────────────────────
// Card "Detectar y aplicar" — Smart Scene Fase 2
// ─────────────────────────────────────────────────────────────────────────────

class _DetectCard extends StatelessWidget {
  final bool isAnalyzing;
  final bool isApplying;
  final bool personalize;
  final bool personalizeReady;
  final bool audiogramAvailable;
  final bool audiogramLoaded;
  final ValueChanged<bool> onPersonalizeChanged;
  final VoidCallback onDetect;
  final VoidCallback onApply;
  final String? analysisError;
  final SceneAnalysisResult? lastResult;
  final SceneRecord? lastRecord;
  final ValueChanged<bool> onFeedback;

  const _DetectCard({
    required this.isAnalyzing,
    required this.isApplying,
    required this.personalize,
    required this.personalizeReady,
    required this.audiogramAvailable,
    required this.audiogramLoaded,
    required this.onPersonalizeChanged,
    required this.onDetect,
    required this.onApply,
    required this.analysisError,
    required this.lastResult,
    required this.lastRecord,
    required this.onFeedback,
  });

  @override
  Widget build(BuildContext context) {
    final personalizeWanted = personalize;
    final audiogramMissing =
        personalizeWanted && audiogramLoaded && !audiogramAvailable;
    return _SceneCard(
      icon: Icons.psychology_alt,
      title: 'Detectar escena y preparar preset',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SwitchListTile.adaptive(
            value: personalize,
            onChanged: personalizeReady ? onPersonalizeChanged : null,
            activeColor: Colors.cyanAccent,
            contentPadding: EdgeInsets.zero,
            title: const Text(
              'Personalizar con mi audiograma',
              style: TextStyle(color: Colors.white, fontSize: 13),
            ),
            subtitle: const Text(
              'Si está activo y hay audiograma cargado, el preset se basa en NAL-NL2 + deltas de la escena.',
              style: TextStyle(color: Colors.white60, fontSize: 11),
            ),
          ),
          if (audiogramMissing) ...[
            const SizedBox(height: 4),
            Text(
              'No hay audiograma cargado. Hacé el diagnóstico audiométrico para usar la personalización.',
              style: TextStyle(
                color: Colors.amberAccent.shade200,
                fontSize: 11,
              ),
            ),
          ],
          const SizedBox(height: 8),
          ElevatedButton.icon(
            onPressed: isAnalyzing ? null : onDetect,
            icon: isAnalyzing
                ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: Colors.white,
                    ),
                  )
                : const Icon(Icons.search),
            label: Text(
              isAnalyzing ? 'Analizando 2.5 s…' : 'Detectar escena',
            ),
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.cyan.shade700,
              foregroundColor: Colors.white,
              padding: const EdgeInsets.symmetric(vertical: 12),
            ),
          ),
          if (analysisError != null) ...[
            const SizedBox(height: 10),
            Text(
              analysisError!,
              style: const TextStyle(color: Colors.redAccent, fontSize: 12),
            ),
          ],
          if (lastResult != null) ...[
            const Divider(color: Colors.white12, height: 24),
            _ResultBlock(result: lastResult!, personalize: personalize),
            const SizedBox(height: 12),
            ElevatedButton.icon(
              onPressed: isApplying ? null : onApply,
              icon: isApplying
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: Colors.black,
                      ),
                    )
                  : const Icon(Icons.bolt),
              label: Text(isApplying ? 'Aplicando…' : 'Aplicar al audífono'),
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.greenAccent.shade400,
                foregroundColor: Colors.black,
                padding: const EdgeInsets.symmetric(vertical: 12),
              ),
            ),
            if (lastRecord != null) ...[
              const SizedBox(height: 12),
              _FeedbackBar(
                feedback: lastRecord!.feedback,
                onFeedback: onFeedback,
              ),
            ],
          ],
        ],
      ),
    );
  }
}

class _ResultBlock extends StatelessWidget {
  final SceneAnalysisResult result;
  final bool personalize;

  const _ResultBlock({required this.result, required this.personalize});

  @override
  Widget build(BuildContext context) {
    final cls = result.sceneClass;
    final pct = (result.confidence * 100).toStringAsFixed(0);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Icon(cls.icon, color: cls.color, size: 28),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    cls.label,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 16,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  Text(
                    cls.description,
                    style: const TextStyle(
                      color: Colors.white60,
                      fontSize: 11,
                    ),
                  ),
                ],
              ),
            ),
            Container(
              padding:
                  const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
              decoration: BoxDecoration(
                color: cls.color.withOpacity(0.18),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: cls.color.withOpacity(0.5)),
              ),
              child: Text(
                '$pct%',
                style: TextStyle(
                  color: cls.color,
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        Text(
          'Muestras: ${result.sampleCount} · '
          '${result.wasPersonalized ? "Personalizado (NAL-NL2 + deltas)" : "Genérico"}',
          style: const TextStyle(color: Colors.white60, fontSize: 11),
        ),
        const SizedBox(height: 6),
        _PresetSummary(preset: result.preset),
      ],
    );
  }
}

class _PresetSummary extends StatelessWidget {
  final SmartPreset preset;

  const _PresetSummary({required this.preset});

  @override
  Widget build(BuildContext context) {
    final maxGain = preset.gains.fold<double>(0, (m, g) => g > m ? g : m);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Preset: ${preset.name}',
          style: const TextStyle(color: Colors.cyanAccent, fontSize: 11),
        ),
        const SizedBox(height: 4),
        SizedBox(
          height: 36,
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: List.generate(preset.gains.length, (i) {
              final norm =
                  maxGain > 0 ? (preset.gains[i] / maxGain).clamp(0.0, 1.0) : 0.0;
              return Expanded(
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 1.5),
                  child: Container(
                    height: 32 * norm,
                    decoration: BoxDecoration(
                      color: Colors.cyan.withOpacity(0.7),
                      borderRadius:
                          const BorderRadius.vertical(top: Radius.circular(2)),
                    ),
                  ),
                ),
              );
            }),
          ),
        ),
        const SizedBox(height: 4),
        Text(
          'CR ${preset.compressionRatio.toStringAsFixed(1)}:1 · '
          'Knee ${preset.compressionKnee.toStringAsFixed(0)} dB SPL · '
          'NR ${preset.nrLevel} · TNR ${preset.tnrEnabled ? "ON" : "OFF"} · '
          'Vol ${preset.volumeDeltaDb >= 0 ? "+" : ""}${preset.volumeDeltaDb.toStringAsFixed(1)} dB',
          style: const TextStyle(color: Colors.white60, fontSize: 11),
        ),
      ],
    );
  }
}


// ─────────────────────────────────────────────────────────────────────────────
// DNN Denoiser Card
// ─────────────────────────────────────────────────────────────────────────────

/// Card de control del DNN denoiser (GTCRN).
///
/// Muestra:
///   - Toggle ON/OFF (controla [DnnDenoiserController.setEnabled]).
///   - Slider de intensidad 0–100 % (controla [DnnDenoiserController.setIntensity]).
///   - Badge de estado:
///       gris  = OFF (bypass por configuración)
///       cyan  = ON + isActive=true (procesando audio)
///       rojo  = ON pero isActive=false (modelo no cargó)
///   - Aviso de que activar el DNN agrega ~16–25 ms de latencia.
///
/// Política UX:
///   - El toggle siempre es manipulable, incluso si el modelo no cargó.
///     En ese caso el flag se persiste en Hive pero el wrapper nativo
///     queda en bypass. Cuando el usuario active el modo "tono fuerte"
///     o reinicie con el modelo OK, el flag ya estará prendido.
///   - El slider sólo es interactivo cuando [enabled] es true (visualmente
///     deshabilitado en OFF para evitar confusión).
class _DnnDenoiserCard extends StatelessWidget {
  /// true cuando ya se hizo `loadSettings()`. Antes de eso mostramos el
  /// toggle deshabilitado para evitar pisar el último valor persistido.
  final bool settingsLoaded;

  /// Último valor de enabled (in-memory snapshot del controller).
  final bool enabled;

  /// Intensidad de mezcla dry/wet en [0, 1].
  final double intensity;

  /// true si el wrapper nativo está realmente procesando audio (modelo
  /// cargado, sesión OK, sin errores). Distinto de [enabled].
  final bool isActive;

  final ValueChanged<bool> onEnabledChanged;
  final ValueChanged<double> onIntensityChanged;

  const _DnnDenoiserCard({
    required this.settingsLoaded,
    required this.enabled,
    required this.intensity,
    required this.isActive,
    required this.onEnabledChanged,
    required this.onIntensityChanged,
  });

  @override
  Widget build(BuildContext context) {
    final intensityPct = (intensity * 100).round();
    return _SceneCard(
      icon: Icons.psychology,
      title: 'Limpiador de ruido (IA)',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // ─── Fila superior: badge de estado + switch ───────────────
          Row(
            children: [
              _buildStatusBadge(),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  enabled
                      ? (isActive
                          ? 'Activo: limpiando ruido en tiempo real'
                          : 'Encendido pero el modelo aún no cargó')
                      : 'Apagado: usando reducción clásica de ruido',
                  style: TextStyle(
                    color: Colors.white.withOpacity(0.85),
                    fontSize: 12.5,
                  ),
                ),
              ),
              Switch(
                value: enabled,
                onChanged: settingsLoaded ? onEnabledChanged : null,
                activeColor: Colors.cyanAccent,
                inactiveThumbColor: Colors.white60,
                inactiveTrackColor: Colors.white12,
              ),
            ],
          ),
          const SizedBox(height: 8),
          // ─── Slider de intensidad ───────────────────────────────────
          Opacity(
            opacity: enabled ? 1.0 : 0.5,
            child: Row(
              children: [
                const Icon(Icons.tune, color: Colors.white60, size: 16),
                const SizedBox(width: 4),
                const Text(
                  'Fuerza',
                  style: TextStyle(color: Colors.white70, fontSize: 12),
                ),
                Expanded(
                  child: Slider(
                    value: intensity,
                    min: 0.0,
                    max: 1.0,
                    divisions: 20,
                    label: '$intensityPct %',
                    activeColor: Colors.cyanAccent,
                    inactiveColor: Colors.white24,
                    onChanged: enabled ? onIntensityChanged : null,
                  ),
                ),
                SizedBox(
                  width: 38,
                  child: Text(
                    '$intensityPct%',
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 12.5,
                      fontFeatures: [FontFeature.tabularFigures()],
                    ),
                    textAlign: TextAlign.right,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 6),
          // ─── Aviso de latencia ──────────────────────────────────────
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
            decoration: BoxDecoration(
              color: Colors.amber.withOpacity(0.08),
              borderRadius: BorderRadius.circular(6),
              border: Border.all(color: Colors.amber.withOpacity(0.3)),
            ),
            child: const Row(
              children: [
                Icon(Icons.access_time, color: Colors.amber, size: 14),
                SizedBox(width: 6),
                Expanded(
                  child: Text(
                    'Cuando está activo, el sonido llega ~20 ms más tarde. '
                    'Apagalo para llamadas o música si te molesta.',
                    style: TextStyle(
                      color: Colors.white70,
                      fontSize: 11.5,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildStatusBadge() {
    final Color color;
    final String label;
    if (!enabled) {
      color = Colors.white38;
      label = 'OFF';
    } else if (isActive) {
      color = Colors.cyanAccent;
      label = 'ON';
    } else {
      color = Colors.redAccent;
      label = 'ERR';
    }
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: color.withOpacity(0.15),
        borderRadius: BorderRadius.circular(4),
        border: Border.all(color: color.withOpacity(0.6)),
      ),
      child: Text(
        label,
        style: TextStyle(
          color: color,
          fontSize: 11,
          fontWeight: FontWeight.bold,
          letterSpacing: 0.5,
        ),
      ),
    );
  }
}
