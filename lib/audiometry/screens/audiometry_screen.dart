/// @file audiometry_screen.dart
/// @brief Pantalla principal de la audiometría tonal del paciente.
///
/// Orquesta visualmente las fases expuestas por [AudiometryController]:
///
///  - `idle` / `precheck` → pantalla de bienvenida con descripción del flujo
///    y botón "Iniciar audiometría". En `precheck` se muestra un spinner
///    junto al `statusText` del controller (verificando calibración + volumen).
///  - `testing`           → [AudiometryProgressWidget] arriba (frecuencia y
///    nivel HL actual) + un mensaje claro al paciente y el
///    [PatientResponseButton] grande en el centro.
///  - `complete`          → [AudiometrySummaryWidget] con los umbrales y el
///    audiograma + 3 botones: "Aplicar al perfil" (si todavía no se aplicó),
///    "Volver" y "Repetir".
///  - `error`             → card roja con `errorMessage`. Si el mensaje menciona
///    falta de calibración biológica, se ofrecen dos botones:
///    "Ir a Calibración Biológica" (Navigator.pop con un sentinel que la
///    pantalla padre interpreta) y "Reintentar". En el resto de errores solo
///    aparece "Reintentar".
///
/// Lifecycle:
///  - `initState` crea [ToneEmitterDbfs], [SystemVolumeController] y
///    [AudiometryController]. El callback `onApplyToProfile` lee el
///    [AmplificationBloc] del `context` y despacha `UpdateAudiogram` con los
///    puntos del audiograma resultante.
///  - `dispose` libera el controller y el emitter (en ese orden, para que el
///    controller corte cualquier reproducción pendiente antes de que el
///    `AudioPlayer` interno se cierre).
///
/// Compatibilidad Flutter 3.19.6:
///  - Usa `withOpacity` (NO `withValues`).
///  - Usa `PopScope.onPopInvoked` (NO `onPopInvokedWithResult`).
///
/// Sentinel de pop:
///  - Cuando el operador pulsa "Ir a Calibración Biológica" se llama
///    `Navigator.of(context).pop(AudiometryScreen.openBiologicalCalibration)`.
///    La pantalla que pushea esta ruta puede así abrir la calibración
///    biológica de inmediato sin que el operador tenga que volver a
///    navegar manualmente.
library;

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../biological_calibration/core/system_volume_controller.dart';
import '../../biological_calibration/core/tone_emitter_dbfs.dart';
import '../../domain/entities/audiogram.dart';
import '../../presentation/bloc/amplification_bloc.dart';
import '../../presentation/bloc/amplification_event.dart';
import '../controllers/audiometry_controller.dart';
import 'widgets/audiometry_progress_widget.dart';
import 'widgets/audiometry_summary_widget.dart';
import 'widgets/patient_response_button.dart';

/// Pantalla principal de la audiometría del paciente.
class AudiometryScreen extends StatefulWidget {
  const AudiometryScreen({super.key});

  /// Sentinel que devuelve `Navigator.pop` cuando el operador pidió ir a la
  /// pantalla de Calibración Biológica desde el estado `error` por falta de
  /// calibración. La pantalla padre puede comparar el valor retornado con
  /// esta constante para decidir si abre `BiologicalCalibrationScreen`.
  static const String openBiologicalCalibration = 'open_biological_calibration';

  @override
  State<AudiometryScreen> createState() => _AudiometryScreenState();
}

class _AudiometryScreenState extends State<AudiometryScreen> {
  late final ToneEmitterDbfs _emitter;
  late final SystemVolumeController _volumeController;
  late final AudiometryController _controller;

  @override
  void initState() {
    super.initState();
    _emitter = ToneEmitterDbfs();
    _volumeController = SystemVolumeController();
    _controller = AudiometryController(
      emitter: _emitter,
      volumeController: _volumeController,
      onApplyToProfile: _applyAudiogramToProfile,
    );
  }

  @override
  void dispose() {
    // Orden importante: el controller cancela cualquier presentación pendiente
    // antes de que el AudioPlayer del emitter sea liberado.
    _controller.dispose();
    _emitter.dispose();
    super.dispose();
  }

  /// Despacha `UpdateAudiogram` al [AmplificationBloc] del `context`. Se
  /// invoca desde [AudiometryController.applyToProfile] cuando el operador
  /// pulsa "Aplicar al perfil".
  void _applyAudiogramToProfile(List<AudiogramPoint> points) {
    if (!mounted) return;
    context.read<AmplificationBloc>().add(
          UpdateAudiogram(audiogram: List<AudiogramPoint>.from(points)),
        );
  }

  // ─── Helpers de navegación ──────────────────────────────────────────

  /// Maneja el "back" del sistema. Si estamos en `testing` muestra un
  /// diálogo de confirmación; en cualquier otra fase, deja salir.
  Future<void> _handlePop(bool didPop) async {
    if (didPop) return;
    final NavigatorState navigator = Navigator.of(context);
    final bool confirm = _controller.phase == AudiometryPhase.testing
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
        title: const Text('¿Abandonar la audiometría?'),
        content: const Text(
          'Hay una prueba en curso. Si salís ahora, los umbrales medidos '
          'hasta el momento se perderán y la audiometría no quedará guardada.',
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

  // ─── Construcción de la UI ──────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: _controller.phase != AudiometryPhase.testing,
      onPopInvoked: _handlePop,
      child: Scaffold(
        appBar: AppBar(
          leading: const Padding(
            padding: EdgeInsets.only(left: 12),
            child: Icon(Icons.medical_services),
          ),
          title: const Text('Audiometría del Paciente'),
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
      case AudiometryPhase.idle:
      case AudiometryPhase.precheck:
        return _buildWelcome(context);
      case AudiometryPhase.testing:
        return _buildTesting(context);
      case AudiometryPhase.complete:
        return _buildComplete(context);
      case AudiometryPhase.error:
        return _buildError(context);
    }
  }

  // ─── Fase: idle / precheck ──────────────────────────────────────────

  Widget _buildWelcome(BuildContext context) {
    final ColorScheme colors = Theme.of(context).colorScheme;
    final bool busy = _controller.phase == AudiometryPhase.precheck;
    return SingleChildScrollView(
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
                      Icon(Icons.record_voice_over,
                          size: 40, color: colors.primary),
                      const SizedBox(width: 16),
                      Expanded(
                        child: Text(
                          'Audiometría tonal del paciente',
                          style: Theme.of(context).textTheme.headlineSmall,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 16),
                  Text(
                    'La app le presentará tonos puros al paciente en distintas '
                    'frecuencias y buscará el umbral por cada una usando el '
                    'método Hughson-Westlake (ascendente 5 dB / descendente '
                    '10 dB, criterio 2 de 3). El audiograma resultante puede '
                    'aplicarse al perfil al finalizar.',
                    style: Theme.of(context).textTheme.bodyMedium,
                  ),
                  const SizedBox(height: 12),
                  _buildChecklistItem(
                    context,
                    icon: Icons.science_outlined,
                    text: 'Necesita una calibración biológica vigente para el '
                        'dispositivo de audio actual.',
                  ),
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
            onPressed: busy ? null : () => _controller.start(),
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
                busy ? 'Verificando...' : 'Iniciar audiometría',
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

  // ─── Fase: testing ──────────────────────────────────────────────────

  Widget _buildTesting(BuildContext context) {
    final ColorScheme colors = Theme.of(context).colorScheme;
    final int? freq = _controller.currentFreqHz;
    final PatientButtonStage btnStage =
        _mapPresentationStage(_controller.presentationStage);

    return Column(
      children: <Widget>[
        AudiometryProgressWidget(
          currentFreqIndex: _controller.currentFreqIndex,
          totalFreqs: AudiometryController.frequencyOrder.length,
          currentFreqHz: freq ?? 0,
          currentLevelHL: _controller.currentLevelHL,
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
                    'Presioná cuando escuches el tono',
                    textAlign: TextAlign.center,
                    style: Theme.of(context).textTheme.titleLarge?.copyWith(
                          color: colors.onSurface.withOpacity(0.85),
                        ),
                  ),
                  const SizedBox(height: 24),
                  PatientResponseButton(
                    stage: btnStage,
                    lastResponseHeard:
                        btnStage == PatientButtonStage.recorded
                            ? _controller.lastResponseHeard
                            : null,
                    onPressed: () => _controller.onUserResponse(true),
                  ),
                  const SizedBox(height: 18),
                  Text(
                    'Presentación N° ${_controller.presentationsCount}'
                    ' · Nivel ${_controller.currentLevelHL.toStringAsFixed(0)} dB HL',
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

  PatientButtonStage _mapPresentationStage(AudiometryPresentationStage s) {
    switch (s) {
      case AudiometryPresentationStage.idle:
        return PatientButtonStage.waiting;
      case AudiometryPresentationStage.playing:
        return PatientButtonStage.playing;
      case AudiometryPresentationStage.listening:
        return PatientButtonStage.listening;
      case AudiometryPresentationStage.recorded:
        return PatientButtonStage.recorded;
    }
  }

  // ─── Fase: complete ─────────────────────────────────────────────────

  Widget _buildComplete(BuildContext context) {
    final ColorScheme colors = Theme.of(context).colorScheme;
    final result = _controller.finalResult!;
    final bool applied = _controller.appliedToProfile;

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
                      color: applied ? Colors.green.shade700 : colors.primary,
                      fontWeight: FontWeight.w600,
                    ),
              ),
            ),
          AudiometrySummaryWidget(result: result),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                if (!applied)
                  FilledButton.icon(
                    onPressed: () => _controller.applyToProfile(),
                    icon: const Icon(Icons.person_pin_circle),
                    label: const Padding(
                      padding: EdgeInsets.symmetric(vertical: 14),
                      child: Text(
                        'Aplicar al perfil',
                        style: TextStyle(fontSize: 16),
                      ),
                    ),
                  ),
                if (applied)
                  Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: Colors.green.withOpacity(0.12),
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(
                        color: Colors.green.withOpacity(0.4),
                      ),
                    ),
                    child: Row(
                      children: <Widget>[
                        Icon(Icons.check_circle,
                            color: Colors.green.shade700),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Text(
                            'Audiograma aplicado al perfil. La prescripción '
                            'NAL-NL2 ya fue recalculada.',
                            style:
                                Theme.of(context).textTheme.bodyMedium?.copyWith(
                                      color: Colors.green.shade800,
                                    ),
                          ),
                        ),
                      ],
                    ),
                  ),
                const SizedBox(height: 12),
                Row(
                  children: <Widget>[
                    Expanded(
                      child: OutlinedButton.icon(
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
                    const SizedBox(width: 12),
                    Expanded(
                      child: OutlinedButton.icon(
                        onPressed: () => _controller.retry(),
                        icon: const Icon(Icons.refresh),
                        label: const Padding(
                          padding: EdgeInsets.symmetric(vertical: 14),
                          child: Text('Repetir'),
                        ),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  // ─── Fase: error ────────────────────────────────────────────────────

  Widget _buildError(BuildContext context) {
    final ColorScheme colors = Theme.of(context).colorScheme;
    final String message = _controller.errorMessage ??
        'Ocurrió un error desconocido. Volvé a intentarlo.';
    final bool missingCalibration =
        message.toLowerCase().contains('falta calibración biológica');

    return SingleChildScrollView(
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
                          'No se pudo iniciar la audiometría',
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
                    message,
                    style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                          color: colors.onErrorContainer,
                        ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 20),
          if (missingCalibration) ...<Widget>[
            FilledButton.icon(
              onPressed: () {
                Navigator.of(context).pop(
                  AudiometryScreen.openBiologicalCalibration,
                );
              },
              icon: const Icon(Icons.science_outlined),
              label: const Padding(
                padding: EdgeInsets.symmetric(vertical: 14),
                child: Text('Ir a Calibración Biológica'),
              ),
            ),
            const SizedBox(height: 12),
            OutlinedButton.icon(
              onPressed: () => _controller.start(),
              icon: const Icon(Icons.refresh),
              label: const Padding(
                padding: EdgeInsets.symmetric(vertical: 14),
                child: Text('Reintentar'),
              ),
            ),
          ] else
            FilledButton.icon(
              onPressed: () => _controller.start(),
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
