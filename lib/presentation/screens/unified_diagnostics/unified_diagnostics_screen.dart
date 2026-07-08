/// Pantalla unificada de diagnóstico del sistema completo.
///
/// Consolida los 13 tests de diagnóstico en una sola ventana.
/// Cada test se puede ejecutar individualmente o todos en paralelo.
/// Resultados copiables al portapapeles (individual o completo).
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../data/bridges/spectrum_bridge.dart';
import '../../../data/services/analyzer_inbox_service.dart';
import '../../../data/services/session_log_service.dart';
import '../../bloc/amplification_bloc.dart';
import '../../bloc/amplification_state.dart';
import 'models/diag_test_id.dart';
import 'models/test_result.dart';
import 'runners/ab_comparative_runner.dart';
import 'runners/dnn_runner.dart';
import 'runners/dsp_recording_runner.dart';
import 'runners/enhancement_runner.dart';
import 'runners/health_runner.dart';
import 'runners/latency_runner.dart';
import 'runners/mpo_runner.dart';
import 'runners/protection_runner.dart';
import 'runners/routing_runner.dart';
import 'runners/session_log_runner.dart';
import 'runners/smart_scene_runner.dart';
import 'runners/spectrum_runner.dart';
import 'runners/test_runner_base.dart';
import 'runners/wdrc_runner.dart';
import 'theme/diagnostics_colors.dart';
import 'widgets/control_bar.dart';
import 'widgets/test_card.dart';

/// Pantalla unificada de diagnóstico.
class UnifiedDiagnosticsScreen extends StatefulWidget {
  const UnifiedDiagnosticsScreen({super.key});

  @override
  State<UnifiedDiagnosticsScreen> createState() =>
      _UnifiedDiagnosticsScreenState();
}


class _UnifiedDiagnosticsScreenState extends State<UnifiedDiagnosticsScreen> {
  static final SpectrumBridge _spectrumBridge = SpectrumBridge();

  // ─── Estado ESTÁTICO: sobrevive al cierre de la pantalla ──────────────────
  static Map<String, TestResult> _results = {
    for (final id in DiagTestId.all)
      id: TestResult(testName: DiagTestId.displayName(id)),
  };
  static bool _allRunning = false;
  static bool _cancelled = false;
  static AmplificationBloc? _bloc;
  static final StreamController<void> _changeController =
      StreamController<void>.broadcast();

  SessionLogService get _sessionSvc => SessionLogService.instance;
  StreamSubscription<void>? _sessionSub;
  StreamSubscription<void>? _changeSub;

  @override
  void initState() {
    super.initState();
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
    super.dispose();
  }

  // ─── Crear runner para un test ID ─────────────────────────────────────────

  TestRunnerBase _createRunner(String id) {
    bool isCancelled() => _cancelled;
    final isActive = _bloc?.state is AmplificationActive;

    switch (id) {
      case DiagTestId.smartScene:
        return SmartSceneRunner(isCancelled: isCancelled);
      case DiagTestId.dspRecording:
        return DspRecordingRunner(
          isCancelled: isCancelled,
          isMotorActive: isActive,
        );
      case DiagTestId.sessionLog:
        return SessionLogRunner(
          isCancelled: isCancelled,
          bloc: _bloc,
          sessionSvc: _sessionSvc,
        );
      case DiagTestId.spectrum:
        return SpectrumRunner(
          isCancelled: isCancelled,
          spectrumBridge: _spectrumBridge,
        );
      case DiagTestId.enhancement:
        return EnhancementRunner(isCancelled: isCancelled);
      case DiagTestId.latency:
        return LatencyRunner(isCancelled: isCancelled);
      case DiagTestId.dnnDenoiser:
        return DnnRunner(isCancelled: isCancelled);
      case DiagTestId.wdrc:
        return WdrcRunner(isCancelled: isCancelled);
      case DiagTestId.mpoLimiter:
        return MpoRunner(isCancelled: isCancelled);
      case DiagTestId.protection:
        return ProtectionRunner(isCancelled: isCancelled);
      case DiagTestId.routing:
        return RoutingRunner(isCancelled: isCancelled);
      case DiagTestId.health:
        return HealthRunner(isCancelled: isCancelled);
      case DiagTestId.abComparative:
        return AbComparativeRunner(
          isCancelled: isCancelled,
          isMotorActive: isActive,
        );
      default:
        throw ArgumentError('Test desconocido: $id');
    }
  }

  // ─── Ejecutar UN test ─────────────────────────────────────────────────────

  Future<void> _runTest(String id) async {
    _results[id] = _results[id]!.copyWith(
      status: TestStatus.running,
      errorMessage: null,
    );
    _changeController.add(null);

    try {
      final selfRecording = {
        DiagTestId.dspRecording,
        DiagTestId.abComparative,
        DiagTestId.routing,
      };

      final runner = _createRunner(id);
      String? wavFile;
      if (!selfRecording.contains(id)) {
        wavFile = await runner.startTestWav(id);
      }

      final data = await runner.run();

      if (wavFile != null) {
        await runner.stopTestWav();
      }

      final finalData =
          wavFile != null ? {...data, 'wavExportado': wavFile} : data;

      if (wavFile != null) {
        AnalyzerInboxService.instance.addWav(wavFile);
      }

      _results[id] = _results[id]!.copyWith(
        status: TestStatus.completed,
        data: finalData,
        completedAt: DateTime.now(),
      );
    } catch (e) {
      _results[id] = _results[id]!.copyWith(
        status: TestStatus.error,
        errorMessage: e.toString(),
        completedAt: DateTime.now(),
      );
    }
    _changeController.add(null);
  }

  // ─── Ejecutar TODOS ───────────────────────────────────────────────────────

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
      backgroundColor: DiagnosticsColors.bg,
      appBar: AppBar(
        title: const Text('Diagnóstico · Sistema Completo'),
        backgroundColor: DiagnosticsColors.accent,
        foregroundColor: DiagnosticsColors.text,
        actions: [
          IconButton(
            icon: const Icon(Icons.copy_all),
            tooltip: 'Copiar todos los resultados',
            onPressed: completedCount > 0 ? _copyAll : null,
          ),
        ],
      ),
      body: Column(
        children: [
          DiagnosticsControlBar(
            allRunning: _allRunning,
            completedCount: completedCount,
            errorCount: errorCount,
            onRunAll: _runAll,
          ),
          Expanded(
            child: ListView.builder(
              padding: const EdgeInsets.all(12),
              itemCount: DiagTestId.all.length,
              itemBuilder: (ctx, i) {
                final id = DiagTestId.all[i];
                return DiagnosticsTestCard(
                  result: _results[id]!,
                  onRun: () {
                    _bloc ??= context.read<AmplificationBloc>();
                    _runTest(id);
                  },
                  onCopy: () => _copyOne(id),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}
