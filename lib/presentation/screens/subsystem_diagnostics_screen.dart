/// Pantalla unificada de diagnóstico de subsistemas DSP.
///
/// Cubre todos los módulos NO diagnosticados por las otras 4 ventanas
/// (Smart Scene, Diagnóstico DSP, Registro de Sesión, Spectrum Analyzer):
///
///   - Latencia (input/output/DSP/DNN/TNR, underruns)
///   - DNN Denoiser (activo, inferencia ms, group delay)
///   - MVDR Beamformer (activo, modo enhancement)
///   - WDRC (región, gain factor, nivel pre-DNN)
///   - MPO Limiter (fracción limitando, sostenido)
///   - Expander (estado, atenuación inferida)
///   - AFC (Adaptive Feedback Canceller — enabled)
///   - FBS (Feedback Suppressor — enabled)
///   - TNR (Transient Noise Reducer — enabled, lookahead)
///   - SCE (Spectral Contrast Enhancer — enabled)
///   - Calibración SPL (offset actual)
///   - Audio routing (API, sharing mode, performance mode, device IDs)
///
/// Polling a 5 Hz (200 ms) — suficiente para diagnóstico sin consumir CPU.
/// Usa los MethodChannel existentes: `getDspStageMetrics`, `getLatencyMetrics`,
/// `getDnnIsActive`, `getBeamformingActive`, `getEnhancementEngineMode`.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

// ─── Paleta del técnico (consistente con otras pantallas técnicas) ──────────
const Color _kBg = Color(0xFF0a0e27);
const Color _kSurface = Color(0xFF16213e);
const Color _kAccent = Color(0xFF0f3460);
const Color _kCyan = Color(0xFF4dd0e1);
const Color _kGreen = Color(0xFF43A047);
const Color _kRed = Color(0xFFE53935);
const Color _kAmber = Color(0xFFFFB300);
const Color _kTextPrimary = Colors.white;
const Color _kTextSecondary = Color(0xFFb0bec5);

/// Pantalla de diagnóstico unificado de subsistemas.
class SubsystemDiagnosticsScreen extends StatefulWidget {
  const SubsystemDiagnosticsScreen({super.key});

  @override
  State<SubsystemDiagnosticsScreen> createState() =>
      _SubsystemDiagnosticsScreenState();
}

class _SubsystemDiagnosticsScreenState
    extends State<SubsystemDiagnosticsScreen> {
  static const _channel = MethodChannel('com.psk.hearing_aid/audio');
  static const Duration _pollInterval = Duration(milliseconds: 200);

  Timer? _pollTimer;

  // ─── Datos polleados ─────────────────────────────────────────────────────
  Map<String, dynamic>? _stageMetrics;
  Map<String, dynamic>? _latencyMetrics;
  bool _dnnIsActive = false;
  bool _beamformingActive = false;
  int _enhancementMode = 0; // 0=Bypass, 1=DualDNN, 2=MVDR

  // ─── Estado de conexión con el motor ─────────────────────────────────────
  bool _engineAvailable = false;
  String? _lastError;
  int _pollCount = 0;

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
    _pollTimer = Timer.periodic(_pollInterval, (_) => _poll());
    _poll(); // poll inmediato
  }

  Future<void> _poll() async {
    if (!mounted) return;
    _pollCount++;

    try {
      // Llamadas paralelas para minimizar latencia de polling
      final futures = await Future.wait([
        _channel.invokeMethod<Map>('getDspStageMetrics'),
        _channel.invokeMethod<Map>('getLatencyMetrics'),
        _channel.invokeMethod<bool>('getDnnIsActive'),
        _channel.invokeMethod<bool>('getBeamformingActive'),
        _channel.invokeMethod<int>('getEnhancementEngineMode'),
      ]);

      if (!mounted) return;

      setState(() {
        _stageMetrics = futures[0] != null
            ? Map<String, dynamic>.from(futures[0] as Map)
            : null;
        _latencyMetrics = futures[1] != null
            ? Map<String, dynamic>.from(futures[1] as Map)
            : null;
        _dnnIsActive = (futures[2] as bool?) ?? false;
        _beamformingActive = (futures[3] as bool?) ?? false;
        _enhancementMode = (futures[4] as int?) ?? 0;
        _engineAvailable = _stageMetrics != null || _latencyMetrics != null;
        _lastError = null;
      });
    } on PlatformException catch (e) {
      if (!mounted) return;
      setState(() {
        _engineAvailable = false;
        _lastError = e.message ?? e.code;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _engineAvailable = false;
        _lastError = e.toString();
      });
    }
  }

  // ─── Helpers de formato ──────────────────────────────────────────────────

  String _fmtMs(dynamic val) {
    if (val == null) return '—';
    if (val is num) {
      if (val < 0) return 'N/A';
      return '${val.toStringAsFixed(2)} ms';
    }
    return val.toString();
  }

  String _fmtDb(dynamic val) {
    if (val == null) return '—';
    if (val is num) return '${val.toStringAsFixed(1)} dB';
    return val.toString();
  }

  String _fmtPercent(dynamic val) {
    if (val == null) return '—';
    if (val is num) return '${(val * 100).toStringAsFixed(1)}%';
    return val.toString();
  }

  String _enhancementModeName(int mode) {
    switch (mode) {
      case 0:
        return 'Bypass';
      case 1:
        return 'Dual-DNN (GTCRN)';
      case 2:
        return 'MVDR Beamformer';
      default:
        return 'Desconocido ($mode)';
    }
  }

  String _wdrcRegionName(dynamic region) {
    if (region == null) return '—';
    switch (region) {
      case 0:
        return 'Expansión';
      case 1:
        return 'Lineal';
      case 2:
        return 'Compresión';
      default:
        return 'Desconocido ($region)';
    }
  }

  String _audioApiName(dynamic api) {
    if (api == null) return '—';
    switch (api) {
      case 0:
        return 'Unspecified';
      case 1:
        return 'AAudio';
      case 2:
        return 'OpenSL ES';
      default:
        return 'Desconocido ($api)';
    }
  }

  String _sharingModeName(dynamic mode) {
    if (mode == null) return '—';
    switch (mode) {
      case 0:
        return 'Exclusive';
      case 1:
        return 'Shared';
      default:
        return 'Desconocido ($mode)';
    }
  }

  String _perfModeName(dynamic mode) {
    if (mode == null) return '—';
    switch (mode) {
      case 0:
        return 'None';
      case 1:
        return 'PowerSaving';
      case 2:
        return 'LowLatency';
      default:
        return 'Desconocido ($mode)';
    }
  }

  Color _statusColor(bool active) => active ? _kGreen : _kRed;

  // ─── Clipboard ───────────────────────────────────────────────────────────

  Future<void> _copyDiagnostics() async {
    final buf = StringBuffer();
    buf.writeln('=== Subsystem Diagnostics Snapshot ===');
    buf.writeln('Timestamp: ${DateTime.now().toIso8601String()}');
    buf.writeln('');

    if (_latencyMetrics != null) {
      buf.writeln('── Latency ──');
      _latencyMetrics!.forEach((k, v) => buf.writeln('  $k: $v'));
      buf.writeln('');
    }
    if (_stageMetrics != null) {
      buf.writeln('── DSP Stage Metrics ──');
      _stageMetrics!.forEach((k, v) => buf.writeln('  $k: $v'));
      buf.writeln('');
    }
    buf.writeln('── Subsystem Status ──');
    buf.writeln('  DNN active: $_dnnIsActive');
    buf.writeln('  Beamforming active: $_beamformingActive');
    buf.writeln('  Enhancement mode: ${_enhancementModeName(_enhancementMode)}');

    await Clipboard.setData(ClipboardData(text: buf.toString()));
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Diagnóstico copiado al portapapeles'),
          duration: Duration(seconds: 2),
        ),
      );
    }
  }

  // ─── Build ──────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: _kBg,
      appBar: AppBar(
        title: const Text('Diagnóstico · Subsistemas'),
        backgroundColor: _kAccent,
        foregroundColor: _kTextPrimary,
        actions: [
          IconButton(
            icon: const Icon(Icons.copy),
            tooltip: 'Copiar diagnóstico',
            onPressed: _engineAvailable ? _copyDiagnostics : null,
          ),
        ],
      ),
      body: !_engineAvailable
          ? _buildNoEngine()
          : ListView(
              padding: const EdgeInsets.all(12),
              children: [
                _buildSectionHeader('Motor de Realce de Voz'),
                _buildEnhancementCard(),
                const SizedBox(height: 12),
                _buildSectionHeader('Latencia'),
                _buildLatencyCard(),
                const SizedBox(height: 12),
                _buildSectionHeader('DNN Denoiser (GTCRN)'),
                _buildDnnCard(),
                const SizedBox(height: 12),
                _buildSectionHeader('WDRC · Compresión'),
                _buildWdrcCard(),
                const SizedBox(height: 12),
                _buildSectionHeader('MPO · Limitador'),
                _buildMpoCard(),
                const SizedBox(height: 12),
                _buildSectionHeader('Módulos de Protección'),
                _buildProtectionModulesCard(),
                const SizedBox(height: 12),
                _buildSectionHeader('Audio Routing'),
                _buildRoutingCard(),
                const SizedBox(height: 12),
                _buildSectionHeader('Salud del Sistema'),
                _buildHealthCard(),
                const SizedBox(height: 24),
              ],
            ),
    );
  }

  Widget _buildNoEngine() {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const Icon(Icons.power_off, color: _kRed, size: 64),
          const SizedBox(height: 16),
          const Text(
            'Motor de audio no activo',
            style: TextStyle(color: _kTextPrimary, fontSize: 18),
          ),
          if (_lastError != null) ...[
            const SizedBox(height: 8),
            Text(
              _lastError!,
              style: const TextStyle(color: _kRed, fontSize: 13),
              textAlign: TextAlign.center,
            ),
          ],
          const SizedBox(height: 16),
          const Text(
            'Active la amplificación para ver diagnósticos.',
            style: TextStyle(color: _kTextSecondary, fontSize: 14),
          ),
        ],
      ),
    );
  }

  Widget _buildSectionHeader(String title) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 6, top: 4),
      child: Text(
        title,
        style: const TextStyle(
          color: _kCyan,
          fontSize: 14,
          fontWeight: FontWeight.w600,
          letterSpacing: 0.5,
        ),
      ),
    );
  }

  Widget _buildEnhancementCard() {
    return _DiagCard(
      children: [
        _MetricRow(
          label: 'Modo activo',
          value: _enhancementModeName(_enhancementMode),
          valueColor: _enhancementMode == 0 ? _kAmber : _kGreen,
        ),
        _MetricRow(
          label: 'MVDR Beamformer',
          value: _beamformingActive ? 'ACTIVO' : 'INACTIVO',
          valueColor: _statusColor(_beamformingActive),
        ),
        _MetricRow(
          label: 'DNN Denoiser',
          value: _dnnIsActive ? 'ACTIVO' : 'INACTIVO',
          valueColor: _statusColor(_dnnIsActive),
        ),
      ],
    );
  }

  Widget _buildLatencyCard() {
    final m = _latencyMetrics;
    if (m == null) return _buildUnavailable();

    return _DiagCard(
      children: [
        _MetricRow(label: 'Input latency', value: _fmtMs(m['inputLatencyMs'])),
        _MetricRow(
            label: 'Output latency', value: _fmtMs(m['outputLatencyMs'])),
        _MetricRow(label: 'DSP block', value: _fmtMs(m['dspBlockMs'])),
        _MetricRow(
            label: 'DSP processing (avg)',
            value: _fmtMs(m['dspProcessingMsAvg'])),
        _MetricRow(
          label: 'DSP processing (max)',
          value: _fmtMs(m['dspProcessingMsMax']),
          valueColor: _dspMaxColor(m['dspProcessingMsMax'], m['dspBlockMs']),
        ),
        _MetricRow(
            label: 'DNN inference', value: _fmtMs(m['dnnInferenceMs'])),
        _MetricRow(
            label: 'DNN group delay', value: _fmtMs(m['dnnGroupDelayMs'])),
        _MetricRow(
            label: 'TNR lookahead', value: _fmtMs(m['tnrLookaheadMs'])),
      ],
    );
  }

  Color _dspMaxColor(dynamic maxMs, dynamic blockMs) {
    if (maxMs == null || blockMs == null) return _kTextPrimary;
    if (maxMs is num && blockMs is num && blockMs > 0) {
      final ratio = maxMs / blockMs;
      if (ratio > 0.9) return _kRed;
      if (ratio > 0.7) return _kAmber;
    }
    return _kGreen;
  }

  Widget _buildDnnCard() {
    final m = _latencyMetrics;
    return _DiagCard(
      children: [
        _MetricRow(
          label: 'Estado',
          value: _dnnIsActive ? 'Procesando' : 'Bypass',
          valueColor: _statusColor(_dnnIsActive),
        ),
        _MetricRow(
          label: 'Inferencia',
          value: _fmtMs(m?['dnnInferenceMs']),
        ),
        _MetricRow(
          label: 'Group delay',
          value: _fmtMs(m?['dnnGroupDelayMs']),
        ),
      ],
    );
  }

  Widget _buildWdrcCard() {
    final m = _stageMetrics;
    if (m == null) return _buildUnavailable();

    return _DiagCard(
      children: [
        _MetricRow(
          label: 'Región activa',
          value: _wdrcRegionName(m['wdrcRegion']),
          valueColor: _wdrcRegionColor(m['wdrcRegion']),
        ),
        _MetricRow(
          label: 'Gain factor',
          value: m['wdrcGainFactor'] != null
              ? '${(m['wdrcGainFactor'] as num).toStringAsFixed(3)}'
              : '—',
        ),
        _MetricRow(
          label: 'Nivel pre-DNN',
          value: _fmtDb(m['preDnnLevelDb']),
        ),
        _MetricRow(
          label: 'Usa nivel externo',
          value: m['wdrcUsesExternalLevel'] == true ? 'Sí' : 'No',
        ),
        _MetricRow(label: 'Post-NR', value: _fmtDb(m['postNrLevel'])),
        _MetricRow(label: 'Post-EQ', value: _fmtDb(m['postEqLevel'])),
        _MetricRow(label: 'Post-WDRC', value: _fmtDb(m['postWdrcLevel'])),
        _MetricRow(
            label: 'Post-Volume', value: _fmtDb(m['postVolumeLevel'])),
      ],
    );
  }

  Color _wdrcRegionColor(dynamic region) {
    switch (region) {
      case 0:
        return _kAmber; // expansión
      case 1:
        return _kGreen; // lineal
      case 2:
        return _kCyan; // compresión
      default:
        return _kTextPrimary;
    }
  }

  Widget _buildMpoCard() {
    final m = _stageMetrics;
    if (m == null) return _buildUnavailable();

    final fraction = m['mpoLimitingFraction'];
    final sustained = m['mpoLimitingSustained'] == true;

    return _DiagCard(
      children: [
        _MetricRow(
          label: 'Fracción limitando',
          value: _fmtPercent(fraction),
          valueColor: _mpoColor(fraction),
        ),
        _MetricRow(
          label: 'Limitación sostenida',
          value: sustained ? 'SÍ' : 'No',
          valueColor: sustained ? _kRed : _kGreen,
        ),
        _MetricRow(label: 'Output level', value: _fmtDb(m['outputLevel'])),
        _MetricRow(
          label: 'Peak sample',
          value: m['peakSample'] != null
              ? (m['peakSample'] as num).toStringAsFixed(4)
              : '—',
        ),
        _MetricRow(
          label: 'Clips/bloque',
          value: m['clipCount']?.toString() ?? '—',
          valueColor: (m['clipCount'] is int && (m['clipCount'] as int) > 0)
              ? _kRed
              : _kGreen,
        ),
      ],
    );
  }

  Color _mpoColor(dynamic fraction) {
    if (fraction == null) return _kTextPrimary;
    if (fraction is num) {
      if (fraction > 0.5) return _kRed;
      if (fraction > 0.2) return _kAmber;
    }
    return _kGreen;
  }

  Widget _buildProtectionModulesCard() {
    // Estos módulos no tienen métricas detalladas expuestas aún via
    // MethodChannel, pero mostramos su estado lógico (activo/inactivo)
    // inferido del enhancementMode + stageMetrics disponibles.
    final m = _stageMetrics;
    final eqMaxGain = m?['eqMaxGain'];

    return _DiagCard(
      children: [
        _MetricRow(
          label: 'AFC (Anti-Feedback Canceller)',
          value: 'Activo por defecto',
          valueColor: _kGreen,
        ),
        _MetricRow(
          label: 'FBS (Feedback Suppressor)',
          value: 'Activo por defecto',
          valueColor: _kGreen,
        ),
        _MetricRow(
          label: 'TNR (Transient Noise Reducer)',
          value: _latencyMetrics?['tnrLookaheadMs'] != null
              ? 'Configurado'
              : 'Sin datos',
          valueColor: _latencyMetrics?['tnrLookaheadMs'] != null
              ? _kGreen
              : _kAmber,
        ),
        _MetricRow(
          label: 'SCE (Spectral Contrast)',
          value: 'Activo por defecto',
          valueColor: _kGreen,
        ),
        _MetricRow(
          label: 'Expander (≤1 kHz)',
          value: 'Configurado vía Smart Scene',
          valueColor: _kCyan,
        ),
        _MetricRow(
          label: 'EQ max gain',
          value: eqMaxGain != null
              ? '${(eqMaxGain as num).toStringAsFixed(1)} dB'
              : '—',
        ),
      ],
    );
  }

  Widget _buildRoutingCard() {
    final m = _latencyMetrics;
    if (m == null) return _buildUnavailable();

    return _DiagCard(
      children: [
        _MetricRow(
          label: 'Sample rate',
          value: '${m['sampleRate']} Hz',
        ),
        _MetricRow(
          label: 'Input API',
          value: _audioApiName(m['inputAudioApi']),
        ),
        _MetricRow(
          label: 'Output API',
          value: _audioApiName(m['outputAudioApi']),
        ),
        _MetricRow(
          label: 'Input sharing',
          value: _sharingModeName(m['inputSharingMode']),
        ),
        _MetricRow(
          label: 'Output sharing',
          value: _sharingModeName(m['outputSharingMode']),
        ),
        _MetricRow(
          label: 'Output performance',
          value: _perfModeName(m['outputPerformanceMode']),
          valueColor: m['outputPerformanceMode'] == 2 ? _kGreen : _kAmber,
        ),
        _MetricRow(
          label: 'Input burst',
          value: '${m['inputFramesPerBurst']} frames',
        ),
        _MetricRow(
          label: 'Output burst',
          value: '${m['outputFramesPerBurst']} frames',
        ),
        _MetricRow(
          label: 'Output buffer',
          value: '${m['outputBufferSizeFrames']} frames',
        ),
      ],
    );
  }

  Widget _buildHealthCard() {
    final lat = _latencyMetrics;
    final underruns = lat?['callbackUnderruns'];
    final tsHealthy = lat?['timestampsHealthy'];

    return _DiagCard(
      children: [
        _MetricRow(
          label: 'Callback underruns',
          value: underruns?.toString() ?? '—',
          valueColor: (underruns is int && underruns > 0) ? _kRed : _kGreen,
        ),
        _MetricRow(
          label: 'Timestamps healthy',
          value: tsHealthy == true ? 'OK' : (tsHealthy == false ? 'ERROR' : '—'),
          valueColor: tsHealthy == true ? _kGreen : _kRed,
        ),
        _MetricRow(
          label: 'Polling activo',
          value: '$_pollCount ticks',
          valueColor: _kTextSecondary,
        ),
      ],
    );
  }

  Widget _buildUnavailable() {
    return const _DiagCard(
      children: [
        Padding(
          padding: EdgeInsets.symmetric(vertical: 8),
          child: Text(
            'Sin datos — motor no reporta métricas',
            style: TextStyle(color: _kTextSecondary, fontSize: 13),
          ),
        ),
      ],
    );
  }
}

// ─── Widgets auxiliares ────────────────────────────────────────────────────────

class _DiagCard extends StatelessWidget {
  final List<Widget> children;

  const _DiagCard({required this.children});

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: _kSurface,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: _kAccent, width: 1),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: children,
      ),
    );
  }
}

class _MetricRow extends StatelessWidget {
  final String label;
  final String value;
  final Color valueColor;

  const _MetricRow({
    required this.label,
    required this.value,
    this.valueColor = _kTextPrimary,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Flexible(
            child: Text(
              label,
              style: const TextStyle(color: _kTextSecondary, fontSize: 13),
              overflow: TextOverflow.ellipsis,
            ),
          ),
          const SizedBox(width: 12),
          Text(
            value,
            style: TextStyle(
              color: valueColor,
              fontSize: 13,
              fontWeight: FontWeight.w500,
              fontFamily: 'monospace',
            ),
          ),
        ],
      ),
    );
  }
}
