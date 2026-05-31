/// @file biological_calibration_screen.dart
/// @brief Pantalla principal de la calibración biológica.
///
/// Orquesta visualmente las fases expuestas por
/// [BiologicalCalibrationController]:
///
///  - `idle` / `setup`     → pantalla de bienvenida con botón "Iniciar".
///  - `questionnaire`      → [EligibilityQuestionnaireWidget].
///  - `testing`            → [CalibrationProgressIndicatorWidget] arriba +
///                           [ToneResponseButton] grande en el centro.
///  - `sessionComplete`    → resumen del sujeto + botones "Agregar otro
///                           sujeto" / "Finalizar".
///  - `allComplete`        → [CalibrationSummaryWidget] + botón "Volver".
///  - `error`              → card roja con `errorMessage` + "Reintentar".
///
/// El widget posee la lifecycle del [ToneEmitterDbfs], el
/// [SystemVolumeController] y el [BiologicalCalibrationController]: los crea
/// en `initState` y los libera en `dispose`. La UI se reconstruye usando un
/// [ListenableBuilder] sobre el controller (que extiende `ChangeNotifier`).
///
/// Compatibilidad Flutter 3.19.6:
///  - Usa `withOpacity(...)` (NO `withValues`).
///  - Usa `PopScope.onPopInvoked` (NO `onPopInvokedWithResult`).
///  - Material 3 con `Theme.of(context).colorScheme`.

library;

import 'package:flutter/material.dart';

import '../controllers/biological_calibration_controller.dart';
import '../core/system_volume_controller.dart';
import '../core/tone_emitter_dbfs.dart';
import '../models/subject_session.dart';
import 'widgets/calibration_summary_widget.dart';
import 'widgets/eligibility_questionnaire_widget.dart';
import 'widgets/progress_indicator_widget.dart';
import 'widgets/tone_response_button.dart';

/// Pantalla principal de la calibración biológica.
class BiologicalCalibrationScreen extends StatefulWidget {
  const BiologicalCalibrationScreen({super.key});

  @override
  State<BiologicalCalibrationScreen> createState() =>
      _BiologicalCalibrationScreenState();
}

class _BiologicalCalibrationScreenState
    extends State<BiologicalCalibrationScreen> {
  /// Orden ASHA de frecuencias usado por el controller para renderizar el
  /// progreso. Debe mantenerse sincronizado con
  /// `BiologicalCalibrationController._frequencyOrder` (privado).
  static const List<int> _frequencyOrder = <int>[
    1000,
    2000,
    4000,
    8000,
    500,
    250,
  ];

  late final ToneEmitterDbfs _emitter;
  late final SystemVolumeController _volumeController;
  late final BiologicalCalibrationController _controller;

  @override
  void initState() {
    super.initState();
    _emitter = ToneEmitterDbfs();
    _volumeController = SystemVolumeController();
    _controller = BiologicalCalibrationController(
      emitter: _emitter,
      volumeController: _volumeController,
    );
  }

  @override
  void dispose() {
    _controller.dispose();
    _emitter.dispose();
    super.dispose();
  }

  // ─── Helpers de navegación / interacción con el controller ───────────

  /// Maneja el "back" del sistema. Si estamos en `testing` muestra un
  /// diálogo de confirmación; en cualquier otra fase, deja salir.
  Future<void> _handlePop(bool didPop) async {
    if (didPop) return;
    final NavigatorState navigator = Navigator.of(context);
    final bool confirm =
        _controller.phase == CalibrationPhase.testing
            ? (await _showAbandonDialog() ?? false)
            : true;
    if (!mounted) return;
    if (confirm) {
      navigator.pop();
    }
  }

  Future<bool?> _showAbandonDialog() {
    return showDialog<bool>(
      context: context,
      builder: (BuildContext ctx) => AlertDialog(
        title: const Text('¿Abandonar la calibración?'),
        content: const Text(
          'Hay un test en curso. Si salís ahora, los datos del sujeto '
          'actual se perderán y la calibración no quedará guardada.',
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Continuar test'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(ctx).colorScheme.error,
            ),
            child: const Text('Abandonar'),
          ),
        ],
      ),
    );
  }

  // ─── Construcción de la UI ───────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: _controller.phase != CalibrationPhase.testing,
      onPopInvoked: _handlePop,
      child: Scaffold(
        appBar: AppBar(
          leading: const Padding(
            padding: EdgeInsets.only(left: 12),
            child: Icon(Icons.hearing),
          ),
          title: const Text('Calibración Biológica'),
        ),
        body: SafeArea(
          child: ListenableBuilder(
            listenable: _controller,
            builder: (BuildContext context, _) => _buildPhase(context),
          ),
        ),
      ),
    );
  }

  Widget _buildPhase(BuildContext context) {
    switch (_controller.phase) {
      case CalibrationPhase.idle:
      case CalibrationPhase.setup:
        return _buildWelcome(context);
      case CalibrationPhase.questionnaire:
        return SingleChildScrollView(
          child: EligibilityQuestionnaireWidget(
            onSubmit: _controller.submitQuestionnaire,
          ),
        );
      case CalibrationPhase.testing:
        return _buildTesting(context);
      case CalibrationPhase.sessionComplete:
        return _buildSessionComplete(context);
      case CalibrationPhase.allComplete:
        return _buildAllComplete(context);
      case CalibrationPhase.error:
        return _buildError(context);
    }
  }

  // ─── Fase: idle / setup ──────────────────────────────────────────────

  Widget _buildWelcome(BuildContext context) {
    final ColorScheme colors = Theme.of(context).colorScheme;
    final bool busy = _controller.phase == CalibrationPhase.setup;
    return Padding(
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Card(
            child: Padding(
              padding: const EdgeInsets.all(20),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Row(
                    children: <Widget>[
                      Icon(Icons.hearing, size: 40, color: colors.primary),
                      const SizedBox(width: 16),
                      Expanded(
                        child: Text(
                          'Calibración con normoyentes',
                          style: Theme.of(context).textTheme.headlineSmall,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 16),
                  Text(
                    'Esta calibración mide los umbrales auditivos de al menos '
                    '${_controller.totalSubjectsTarget} adultos jóvenes con '
                    'audición normal usando el algoritmo Hughson-Westlake. '
                    'El promedio se usa como referencia biológica para '
                    'convertir niveles de la app entre dBFS y dB HL.',
                    style: Theme.of(context).textTheme.bodyMedium,
                  ),
                  const SizedBox(height: 12),
                  _buildChecklistItem(
                    context,
                    icon: Icons.bluetooth_audio,
                    text: 'Auricular Bluetooth conectado y emparejado.',
                  ),
                  _buildChecklistItem(
                    context,
                    icon: Icons.volume_up,
                    text: 'Volumen del sistema al máximo (lo fija la app).',
                  ),
                  _buildChecklistItem(
                    context,
                    icon: Icons.do_not_disturb_off,
                    text: 'Modo "No molestar" desactivado.',
                  ),
                  _buildChecklistItem(
                    context,
                    icon: Icons.volume_off,
                    text: 'Ambiente silencioso (< 35 dB SPL ambiente).',
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 24),
          FilledButton.icon(
            onPressed: busy ? null : () => _controller.startSession(),
            icon: busy
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.play_arrow),
            label: Padding(
              padding: const EdgeInsets.symmetric(vertical: 14),
              child: Text(
                busy ? 'Configurando...' : 'Iniciar',
                style: const TextStyle(fontSize: 17),
              ),
            ),
          ),
          if (busy && _controller.statusText != null) ...<Widget>[
            const SizedBox(height: 12),
            Text(
              _controller.statusText!,
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: colors.onSurface.withOpacity(0.7),
                  ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildChecklistItem(
    BuildContext context, {
    required IconData icon,
    required String text,
  }) {
    final ColorScheme colors = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Icon(icon, size: 20, color: colors.primary),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              text,
              style: Theme.of(context).textTheme.bodyMedium,
            ),
          ),
        ],
      ),
    );
  }

  // ─── Fase: testing ───────────────────────────────────────────────────

  Widget _buildTesting(BuildContext context) {
    final ColorScheme colors = Theme.of(context).colorScheme;
    final double? freq = _controller.currentFreqHz;
    final int freqIndex = freq == null
        ? 0
        : (_frequencyOrder.indexOf(freq.round()) >= 0
            ? _frequencyOrder.indexOf(freq.round())
            : _frequencyOrder.length);
    final String freqLabel = freq == null
        ? '—'
        : (freq >= 1000
            ? '${(freq / 1000).toStringAsFixed(freq % 1000 == 0 ? 0 : 1)} kHz'
            : '${freq.round()} Hz');

    return Column(
      children: <Widget>[
        CalibrationProgressIndicatorWidget(
          currentSubject: _controller.currentSubjectIndex,
          totalSubjects: _controller.totalSubjectsTarget,
          currentFreqIndex: freqIndex,
          totalFreqs: _frequencyOrder.length,
          statusText: _controller.statusText,
        ),
        Expanded(
          child: Center(
            child: Padding(
              padding: const EdgeInsets.all(20),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: <Widget>[
                  Text(
                    'Frecuencia $freqLabel',
                    textAlign: TextAlign.center,
                    style: Theme.of(context).textTheme.headlineMedium,
                  ),
                  const SizedBox(height: 8),
                  Text(
                    _controller.isCatchTrialPending
                        ? 'Atención: presentación silenciosa de control.'
                        : 'Pulsá el botón apenas escuches el tono.',
                    textAlign: TextAlign.center,
                    style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                          color: colors.onSurface.withOpacity(0.75),
                        ),
                  ),
                  const SizedBox(height: 32),
                  ToneResponseButton(
                    onPressed: () => _controller.onUserResponse(true),
                  ),
                  const SizedBox(height: 24),
                  Text(
                    'Nivel actual: '
                    '${_controller.currentLevelDbFS.toStringAsFixed(0)} dBFS',
                    textAlign: TextAlign.center,
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: colors.onSurface.withOpacity(0.6),
                        ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }

  // ─── Fase: sessionComplete ───────────────────────────────────────────

  Widget _buildSessionComplete(BuildContext context) {
    final ColorScheme colors = Theme.of(context).colorScheme;
    final SubjectSession? last = _controller.completedSessions.isEmpty
        ? null
        : _controller.completedSessions.last;
    final int validCount = _controller.validSessionsCount;
    final int target = _controller.totalSubjectsTarget;
    final bool canFinalize = validCount >= target;

    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Row(
                    children: <Widget>[
                      Icon(
                        last == null || !last.valid
                            ? Icons.error_outline
                            : Icons.check_circle_outline,
                        size: 32,
                        color: last == null || !last.valid
                            ? colors.error
                            : Colors.green,
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Text(
                          last == null
                              ? 'Sesión finalizada'
                              : '${last.alias} · ${last.valid ? "válido" : "inválido"}',
                          style: Theme.of(context).textTheme.titleLarge,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  if (_controller.statusText != null)
                    Text(
                      _controller.statusText!,
                      style: Theme.of(context).textTheme.bodyMedium,
                    ),
                  const SizedBox(height: 12),
                  if (last != null) _buildSubjectSummary(context, last),
                  const Divider(height: 24),
                  Text(
                    'Sujetos válidos: $validCount de $target',
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 16),
          Row(
            children: <Widget>[
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: _controller.addAnotherSubject,
                  icon: const Icon(Icons.person_add),
                  label: const Padding(
                    padding: EdgeInsets.symmetric(vertical: 14),
                    child: Text('Agregar otro sujeto'),
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: FilledButton.icon(
                  onPressed: canFinalize ? _controller.finalize : null,
                  icon: const Icon(Icons.flag),
                  label: const Padding(
                    padding: EdgeInsets.symmetric(vertical: 14),
                    child: Text('Finalizar'),
                  ),
                ),
              ),
            ],
          ),
          if (!canFinalize)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(
                'Se necesitan al menos $target sujetos válidos para finalizar.',
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: colors.onSurface.withOpacity(0.7),
                    ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildSubjectSummary(BuildContext context, SubjectSession s) {
    final ColorScheme colors = Theme.of(context).colorScheme;
    final List<MapEntry<int, double>> sorted =
        s.thresholdsDbFS.entries.toList()
          ..sort((MapEntry<int, double> a, MapEntry<int, double> b) =>
              a.key.compareTo(b.key));
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: colors.surfaceVariant.withOpacity(0.4),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          for (final MapEntry<int, double> e in sorted)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 2),
              child: Row(
                children: <Widget>[
                  SizedBox(
                    width: 80,
                    child: Text(
                      '${e.key} Hz',
                      style: Theme.of(context).textTheme.bodyMedium,
                    ),
                  ),
                  Expanded(
                    child: Text(
                      '${e.value.toStringAsFixed(1)} dBFS',
                      style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                            fontWeight: FontWeight.w600,
                          ),
                    ),
                  ),
                ],
              ),
            ),
          if (s.retest1000DbFS != null && s.retestDifferenceDb != null)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(
                'Retest 1000 Hz: ${s.retest1000DbFS!.toStringAsFixed(1)} dBFS '
                '(Δ ${s.retestDifferenceDb!.toStringAsFixed(1)} dB)',
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: s.retestDifferenceDb!.abs() > 10.0
                          ? colors.error
                          : colors.onSurface.withOpacity(0.75),
                    ),
              ),
            ),
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text(
              'Catch trials: ${s.catchTrials.falsePositives}/${s.catchTrials.total} '
              '(${(s.catchTrials.rate * 100).toStringAsFixed(0)}%)',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: colors.onSurface.withOpacity(0.7),
                  ),
            ),
          ),
        ],
      ),
    );
  }

  // ─── Fase: allComplete ───────────────────────────────────────────────

  Widget _buildAllComplete(BuildContext context) {
    final ColorScheme colors = Theme.of(context).colorScheme;
    return SingleChildScrollView(
      padding: const EdgeInsets.only(bottom: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          if (_controller.statusText != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
              child: Text(
                _controller.statusText!,
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                      color: colors.primary,
                    ),
              ),
            ),
          if (_controller.finalResult != null)
            CalibrationSummaryWidget(result: _controller.finalResult!),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
            child: FilledButton.icon(
              onPressed: () {
                if (Navigator.of(context).canPop()) {
                  Navigator.of(context).pop();
                }
              },
              icon: const Icon(Icons.arrow_back),
              label: const Padding(
                padding: EdgeInsets.symmetric(vertical: 14),
                child: Text('Volver'),
              ),
            ),
          ),
        ],
      ),
    );
  }

  // ─── Fase: error ─────────────────────────────────────────────────────

  Widget _buildError(BuildContext context) {
    final ColorScheme colors = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.all(20),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: <Widget>[
          Card(
            color: colors.errorContainer.withOpacity(0.8),
            child: Padding(
              padding: const EdgeInsets.all(20),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Row(
                    children: <Widget>[
                      Icon(Icons.error_outline,
                          color: colors.onErrorContainer, size: 32),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Text(
                          'Error en la calibración',
                          style: Theme.of(context)
                              .textTheme
                              .titleLarge
                              ?.copyWith(color: colors.onErrorContainer),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  Text(
                    _controller.errorMessage ??
                        'Ocurrió un error desconocido. Volvé a intentarlo.',
                    style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                          color: colors.onErrorContainer,
                        ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 20),
          FilledButton.icon(
            onPressed: () => _controller.startSession(),
            icon: const Icon(Icons.refresh),
            label: const Padding(
              padding: EdgeInsets.symmetric(vertical: 14),
              child: Text('Reintentar'),
            ),
          ),
        ],
      ),
    );
  }
}
