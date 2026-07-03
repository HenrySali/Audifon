/// Pantalla de Aprendizaje Adaptativo (solo app técnico).
///
/// Permite al técnico:
/// 1. Escribir observaciones sobre el entorno acústico actual
/// 2. Ver sugerencias de Hermes con ajustes DSP propuestos
/// 3. Aplicar o descartar sugerencias
/// 4. Dar feedback (👍/👎) sobre ajustes aplicados
/// 5. Ver historial de observaciones y aprendizaje acumulado
///
/// La telemetría DSP se captura automáticamente al enviar la observación.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../data/services/adaptive_learning_service.dart';
import '../../domain/adaptive_learning/learning_observation.dart';
import '../../scene/scene_snapshot.dart' show SceneClass, sceneClassLabel;
import '../bloc/amplification_bloc.dart';
import '../bloc/amplification_state.dart';

class AdaptiveLearningScreen extends StatefulWidget {
  const AdaptiveLearningScreen({super.key});

  @override
  State<AdaptiveLearningScreen> createState() => _AdaptiveLearningScreenState();
}

class _AdaptiveLearningScreenState extends State<AdaptiveLearningScreen> {
  final _textController = TextEditingController();
  final _service = AdaptiveLearningService.instance;
  StreamSubscription<void>? _sub;
  bool _sending = false;

  @override
  void initState() {
    super.initState();
    _service.init();
    _sub = _service.onChange.listen((_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _sub?.cancel();
    _textController.dispose();
    super.dispose();
  }

  Future<void> _submitObservation() async {
    final text = _textController.text.trim();
    if (text.isEmpty) return;

    setState(() => _sending = true);
    final bloc = context.read<AmplificationBloc>();
    await _service.addObservation(userText: text, bloc: bloc);
    _textController.clear();
    setState(() => _sending = false);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Aprendizaje Adaptativo'),
        actions: [
          IconButton(
            icon: const Icon(Icons.history),
            tooltip: 'Historial de ajustes',
            onPressed: () => _showAppliedHistory(context),
          ),
          if (_service.observations.isNotEmpty)
            IconButton(
              icon: const Icon(Icons.delete_outline),
              tooltip: 'Limpiar historial',
              onPressed: () => _confirmClear(context),
            ),
        ],
      ),
      body: Column(
        children: [
          // ─── Barra de estado ───────────────────────────────────────
          _StatusBar(service: _service),

          // ─── Toggle auto-apply ─────────────────────────────────────
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
            child: Row(
              children: [
                Icon(Icons.auto_mode, size: 18, color: colors.primary),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'Hermes aplica automáticamente',
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: colors.onSurface,
                    ),
                  ),
                ),
                Switch(
                  value: _service.autoApply,
                  onChanged: (value) {
                    _service.setAutoApply(value);
                    setState(() {});
                  },
                  activeColor: colors.primary,
                ),
              ],
            ),
          ),

          // ─── Input de observación ──────────────────────────────────
          Padding(
            padding: const EdgeInsets.all(12),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Expanded(
                  child: TextField(
                    controller: _textController,
                    maxLines: 3,
                    minLines: 1,
                    textInputAction: TextInputAction.send,
                    onSubmitted: (_) => _submitObservation(),
                    decoration: InputDecoration(
                      hintText:
                          'Describe el entorno...\nej: "Restaurante ruidoso, voz baja del compañero"',
                      border: const OutlineInputBorder(),
                      filled: true,
                      fillColor: colors.surface,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                FloatingActionButton(
                  mini: true,
                  onPressed: _sending ? null : _submitObservation,
                  child: _sending
                      ? const SizedBox(
                          width: 20,
                          height: 20,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.send),
                ),
              ],
            ),
          ),

          const Divider(height: 1),

          // ─── Lista de observaciones ────────────────────────────────
          Expanded(
            child: _buildObservationsList(theme, colors),
          ),
        ],
      ),
    );
  }

  /// Construye la lista principal (solo observaciones manuales) con
  /// un botón para ver los eventos automáticos en un bottom sheet.
  Widget _buildObservationsList(ThemeData theme, ColorScheme colors) {
    // Separar manuales de auto-applied.
    // Cualquier observación que contenga [Auto] en cualquier posición
    // es un evento automático del widget de recomendaciones.
    final manualObs = _service.observations
        .where((o) => !o.userText.contains('[Auto'))
        .toList();
    final autoObs = _service.observations
        .where((o) => o.userText.contains('[Auto'))
        .toList();

    if (manualObs.isEmpty && autoObs.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.psychology_outlined, size: 64, color: colors.outline),
              const SizedBox(height: 16),
              Text(
                'Describe lo que experimentas en distintos entornos.\n'
                'Hermes aprenderá y sugerirá ajustes automáticos.',
                textAlign: TextAlign.center,
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: colors.outline,
                ),
              ),
            ],
          ),
        ),
      );
    }

    return Column(
      children: [
        // Botón de eventos automáticos (si hay).
        if (autoObs.isNotEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
            child: InkWell(
              onTap: () => _showAutoEventsModal(context, autoObs),
              borderRadius: BorderRadius.circular(8),
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                decoration: BoxDecoration(
                  color: Colors.green.withOpacity(0.08),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: Colors.green.withOpacity(0.3)),
                ),
                child: Row(
                  children: [
                    Container(
                      width: 10,
                      height: 10,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: Colors.green.shade400,
                        boxShadow: [
                          BoxShadow(
                            color: Colors.green.withOpacity(0.4),
                            blurRadius: 4,
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        '${autoObs.length} ajustes automáticos',
                        style: theme.textTheme.bodyMedium?.copyWith(
                          color: Colors.green.shade300,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                    Icon(Icons.expand_more, color: Colors.green.shade300, size: 20),
                  ],
                ),
              ),
            ),
          ),
        // Lista principal (solo manuales).
        Expanded(
          child: manualObs.isEmpty
              ? Center(
                  child: Text(
                    'Sin observaciones manuales.\nEscribí arriba para agregar.',
                    textAlign: TextAlign.center,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: colors.outline,
                    ),
                  ),
                )
              : ListView.builder(
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  itemCount: manualObs.length,
                  itemBuilder: (ctx, i) =>
                      _ObservationCard(observation: manualObs[i]),
                ),
        ),
      ],
    );
  }

  /// Modal (bottom sheet) con los eventos automáticos en acordeón.
  void _showAutoEventsModal(BuildContext context, List<LearningObservation> autoObs) {
    final theme = Theme.of(context);
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: const Color(0xFF0f1b2d),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (ctx) => DraggableScrollableSheet(
        initialChildSize: 0.6,
        minChildSize: 0.3,
        maxChildSize: 0.9,
        expand: false,
        builder: (ctx, scrollController) => Column(
          children: [
            // Handle.
            Padding(
              padding: const EdgeInsets.only(top: 12, bottom: 8),
              child: Container(
                width: 40,
                height: 4,
                decoration: BoxDecoration(
                  color: Colors.white30,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            // Title.
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: Row(
                children: [
                  Container(
                    width: 12,
                    height: 12,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: Colors.green.shade400,
                    ),
                  ),
                  const SizedBox(width: 10),
                  Text(
                    'Ajustes automáticos (${autoObs.length})',
                    style: theme.textTheme.titleMedium?.copyWith(
                      color: Colors.white,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
              ),
            ),
            const Divider(color: Colors.white12),
            // List of auto events as expandable tiles.
            Expanded(
              child: ListView.builder(
                controller: scrollController,
                itemCount: autoObs.length,
                itemBuilder: (ctx, i) {
                  final obs = autoObs[i];
                  return _AutoEventTile(
                    observation: obs,
                    onFeedback: (positive) {
                      _service.addFeedback(obs.id, positive: positive);
                      Navigator.pop(ctx);
                    },
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }

  void _confirmClear(BuildContext context) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Limpiar historial'),
        content: const Text(
            '¿Borrar todas las observaciones y sugerencias?\nEsto no afecta lo que Hermes ya aprendió.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancelar'),
          ),
          FilledButton(
            onPressed: () {
              _service.clearHistory();
              Navigator.pop(ctx);
            },
            child: const Text('Borrar'),
          ),
        ],
      ),
    );
  }

  void _showAppliedHistory(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final history = _service.appliedHistory;

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: const Color(0xFF1a1a2e),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (ctx) {
        return DraggableScrollableSheet(
          initialChildSize: 0.7,
          minChildSize: 0.4,
          maxChildSize: 0.9,
          expand: false,
          builder: (_, scrollController) {
            return Column(
              children: [
                // Handle bar
                Container(
                  margin: const EdgeInsets.only(top: 12, bottom: 8),
                  width: 40,
                  height: 4,
                  decoration: BoxDecoration(
                    color: colors.outline,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                  child: Row(
                    children: [
                      Icon(Icons.history, color: colors.primary),
                      const SizedBox(width: 8),
                      Text(
                        'Ajustes aplicados por Hermes',
                        style: theme.textTheme.titleMedium?.copyWith(
                          fontWeight: FontWeight.bold,
                          color: colors.onSurface,
                        ),
                      ),
                    ],
                  ),
                ),
                const Divider(height: 1),
                Expanded(
                  child: history.isEmpty
                      ? Center(
                          child: Padding(
                            padding: const EdgeInsets.all(32),
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Icon(Icons.history_toggle_off,
                                    size: 48, color: colors.outline),
                                const SizedBox(height: 12),
                                Text(
                                  'No hay ajustes aplicados aún',
                                  style: theme.textTheme.bodyMedium?.copyWith(
                                    color: colors.outline,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        )
                      : ListView.builder(
                          controller: scrollController,
                          padding: const EdgeInsets.symmetric(vertical: 8),
                          itemCount: history.length,
                          itemBuilder: (_, i) {
                            final obs = history[i];
                            final suggestion = obs.suggestion!;
                            final truncatedText = obs.userText.length > 50
                                ? '${obs.userText.substring(0, 50)}...'
                                : obs.userText;

                            return Card(
                              margin: const EdgeInsets.symmetric(
                                  horizontal: 12, vertical: 4),
                              color: colors.surface,
                              child: Padding(
                                padding: const EdgeInsets.all(12),
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    // Date/time
                                    Row(
                                      children: [
                                        Icon(Icons.access_time,
                                            size: 14, color: colors.outline),
                                        const SizedBox(width: 4),
                                        Text(
                                          '${obs.timestamp.day}/${obs.timestamp.month}/${obs.timestamp.year} '
                                          '${obs.timestamp.hour.toString().padLeft(2, '0')}:'
                                          '${obs.timestamp.minute.toString().padLeft(2, '0')}',
                                          style: theme.textTheme.labelSmall
                                              ?.copyWith(color: colors.outline),
                                        ),
                                        const Spacer(),
                                        // Feedback indicator
                                        if (obs.feedback != null)
                                          Icon(
                                            obs.feedback!
                                                ? Icons.thumb_up
                                                : Icons.thumb_down,
                                            size: 14,
                                            color: obs.feedback!
                                                ? Colors.green
                                                : Colors.orange,
                                          )
                                        else
                                          Text('Pendiente',
                                              style: theme.textTheme.labelSmall
                                                  ?.copyWith(
                                                      color: colors.outline)),
                                      ],
                                    ),
                                    const SizedBox(height: 6),
                                    // User text
                                    Text(
                                      truncatedText,
                                      style: theme.textTheme.bodySmall?.copyWith(
                                        fontWeight: FontWeight.w500,
                                      ),
                                    ),
                                    const SizedBox(height: 4),
                                    // Reasoning
                                    Text(
                                      suggestion.reasoning,
                                      style: theme.textTheme.bodySmall?.copyWith(
                                        color: colors.secondary,
                                        fontStyle: FontStyle.italic,
                                      ),
                                      maxLines: 2,
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                    const SizedBox(height: 4),
                                    // NR level change
                                    Text(
                                      'NR: ${obs.telemetry.nrLevel} → ${suggestion.suggestedNrLevel}',
                                      style: theme.textTheme.labelSmall?.copyWith(
                                        fontFamily: 'monospace',
                                        color: colors.primary,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            );
                          },
                        ),
                ),
              ],
            );
          },
        );
      },
    );
  }
}

// ─── Widgets internos ──────────────────────────────────────────────────────

class _StatusBar extends StatelessWidget {
  final AdaptiveLearningService service;
  const _StatusBar({required this.service});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      color: colors.surfaceVariant,
      child: Row(
        children: [
          Icon(Icons.auto_awesome, size: 16, color: colors.primary),
          const SizedBox(width: 6),
          Text(
            '${service.observations.length} observaciones',
            style: theme.textTheme.labelMedium,
          ),
          const Spacer(),
          if (service.pendingCount > 0) ...[
            Icon(Icons.hourglass_top, size: 14, color: colors.tertiary),
            const SizedBox(width: 4),
            Text('${service.pendingCount} pendientes',
                style: theme.textTheme.labelSmall),
            const SizedBox(width: 12),
          ],
          if (service.readyCount > 0) ...[
            Icon(Icons.lightbulb, size: 14, color: colors.secondary),
            const SizedBox(width: 4),
            Text('${service.readyCount} sugerencias',
                style: theme.textTheme.labelSmall?.copyWith(
                  color: colors.secondary,
                  fontWeight: FontWeight.bold,
                )),
          ],
        ],
      ),
    );
  }
}

class _ObservationCard extends StatelessWidget {
  final LearningObservation observation;
  const _ObservationCard({required this.observation});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;

    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Header: hora + escena + status
            Row(
              children: [
                Text(
                  _formatTime(observation.timestamp),
                  style: theme.textTheme.labelSmall
                      ?.copyWith(color: colors.outline),
                ),
                const SizedBox(width: 8),
                _SceneChip(scene: observation.detectedScene),
                const Spacer(),
                _StatusIcon(status: observation.status),
              ],
            ),
            const SizedBox(height: 8),

            // Texto de la observación
            Text(observation.userText, style: theme.textTheme.bodyMedium),

            // Telemetría resumida
            const SizedBox(height: 6),
            _TelemetrySummary(telemetry: observation.telemetry),

            // Sugerencia (si hay)
            if (observation.suggestion != null &&
                observation.status == ObservationStatus.suggestionReady) ...[
              const Divider(height: 16),
              _SuggestionWidget(observation: observation),
            ],

            // Feedback (si ya fue aplicada)
            if (observation.status == ObservationStatus.applied &&
                observation.feedback == null) ...[
              const Divider(height: 16),
              _FeedbackButtons(observationId: observation.id),
            ],

            // Feedback dado
            if (observation.feedback != null) ...[
              const SizedBox(height: 4),
              Row(
                children: [
                  Icon(
                    observation.feedback! ? Icons.thumb_up : Icons.thumb_down,
                    size: 14,
                    color: observation.feedback!
                        ? Colors.green
                        : Colors.orange,
                  ),
                  const SizedBox(width: 4),
                  Text(
                    observation.feedback!
                        ? 'Buen ajuste'
                        : 'Necesita mejorar',
                    style: theme.textTheme.labelSmall,
                  ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }

  String _formatTime(DateTime dt) {
    return '${dt.hour.toString().padLeft(2, '0')}:'
        '${dt.minute.toString().padLeft(2, '0')}';
  }
}

class _SceneChip extends StatelessWidget {
  final SceneClass scene;
  const _SceneChip({required this.scene});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.primaryContainer,
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(
        sceneClassLabel(scene),
        style: Theme.of(context).textTheme.labelSmall?.copyWith(
              color: Theme.of(context).colorScheme.onPrimaryContainer,
            ),
      ),
    );
  }
}

class _StatusIcon extends StatelessWidget {
  final ObservationStatus status;
  const _StatusIcon({required this.status});

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    switch (status) {
      case ObservationStatus.pending:
        return Icon(Icons.schedule, size: 16, color: colors.outline);
      case ObservationStatus.analyzing:
        return SizedBox(
          width: 14,
          height: 14,
          child: CircularProgressIndicator(
              strokeWidth: 2, color: colors.tertiary),
        );
      case ObservationStatus.suggestionReady:
        return Icon(Icons.lightbulb, size: 16, color: colors.secondary);
      case ObservationStatus.applied:
        return const Icon(Icons.check_circle, size: 16, color: Colors.green);
      case ObservationStatus.dismissed:
        return Icon(Icons.close, size: 16, color: colors.outline);
    }
  }
}

class _TelemetrySummary extends StatelessWidget {
  final DspTelemetrySnapshot telemetry;
  const _TelemetrySummary({required this.telemetry});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Wrap(
      spacing: 8,
      children: [
        _MiniChip('In: ${telemetry.inputLevelDb.toStringAsFixed(0)} dB'),
        _MiniChip('Out: ${telemetry.outputLevelDb.toStringAsFixed(0)} dB'),
        _MiniChip('NR: ${telemetry.nrLevel}'),
        if (telemetry.clipCount > 0)
          _MiniChip('⚠️ Clip: ${telemetry.clipCount}',
              color: theme.colorScheme.error),
      ],
    );
  }
}

class _MiniChip extends StatelessWidget {
  final String label;
  final Color? color;
  const _MiniChip(this.label, {this.color});

  @override
  Widget build(BuildContext context) {
    return Text(
      label,
      style: Theme.of(context).textTheme.labelSmall?.copyWith(
            color: color ?? Theme.of(context).colorScheme.outline,
            fontSize: 10,
          ),
    );
  }
}

class _SuggestionWidget extends StatelessWidget {
  final LearningObservation observation;
  const _SuggestionWidget({required this.observation});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final suggestion = observation.suggestion!;
    final service = AdaptiveLearningService.instance;

    return Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: colors.secondaryContainer.withOpacity(0.3),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: colors.secondary.withOpacity(0.3)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.auto_awesome, size: 14, color: colors.secondary),
              const SizedBox(width: 4),
              Text('Sugerencia de Hermes',
                  style: theme.textTheme.labelMedium?.copyWith(
                    color: colors.secondary,
                    fontWeight: FontWeight.bold,
                  )),
              const Spacer(),
              Text('${(suggestion.confidence * 100).toInt()}%',
                  style: theme.textTheme.labelSmall),
            ],
          ),
          const SizedBox(height: 6),
          Text(suggestion.reasoning, style: theme.textTheme.bodySmall),
          const SizedBox(height: 8),
          // Resumen de cambios propuestos
          Text(
            'NR: ${observation.telemetry.nrLevel} → ${suggestion.suggestedNrLevel} | '
            'Vol: ${observation.telemetry.volumeDb.toStringAsFixed(0)} → ${suggestion.suggestedVolumeDb.toStringAsFixed(0)} dB',
            style: theme.textTheme.labelSmall?.copyWith(
              fontFamily: 'monospace',
            ),
          ),
          const SizedBox(height: 8),
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              TextButton(
                onPressed: () =>
                    service.dismissSuggestion(observation.id),
                child: const Text('Descartar'),
              ),
              const SizedBox(width: 8),
              FilledButton.icon(
                onPressed: () {
                  final bloc = context.read<AmplificationBloc>();
                  service.applySuggestion(observation.id, bloc);
                },
                icon: const Icon(Icons.play_arrow, size: 18),
                label: const Text('Aplicar'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _FeedbackButtons extends StatelessWidget {
  final int observationId;
  const _FeedbackButtons({required this.observationId});

  @override
  Widget build(BuildContext context) {
    final service = AdaptiveLearningService.instance;
    return Row(
      children: [
        Text('¿Mejoró?', style: Theme.of(context).textTheme.labelSmall),
        const Spacer(),
        IconButton(
          icon: const Icon(Icons.thumb_up_outlined, size: 18),
          color: Colors.green,
          onPressed: () =>
              service.addFeedback(observationId, positive: true),
        ),
        IconButton(
          icon: const Icon(Icons.thumb_down_outlined, size: 18),
          color: Colors.orange,
          onPressed: () =>
              service.addFeedback(observationId, positive: false),
        ),
      ],
    );
  }
}


/// Tile expandible para eventos automáticos en el modal.
///
/// Muestra: evento detectado + solución aplicada + botones 👍/👎.
/// Solo envía feedback al servidor cuando el usuario confirma con 👍.
class _AutoEventTile extends StatelessWidget {
  final LearningObservation observation;
  final void Function(bool positive) onFeedback;

  const _AutoEventTile({
    required this.observation,
    required this.onFeedback,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    // Extraer el tipo de evento del texto (entre [Auto-Applied] y el primer punto).
    final text = observation.userText
        .replaceFirst('[Auto-Applied] ', '')
        .replaceFirst('[Auto] ', '');
    final eventTitle = text.split('.').first;
    final detail = text.contains('.') ? text.substring(text.indexOf('.') + 1).trim() : '';
    final suggestion = observation.suggestion;
    final time = '${observation.timestamp.hour.toString().padLeft(2, '0')}:'
        '${observation.timestamp.minute.toString().padLeft(2, '0')}';

    return ExpansionTile(
      tilePadding: const EdgeInsets.symmetric(horizontal: 16),
      childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
      leading: Container(
        width: 8,
        height: 8,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: observation.feedback == true
              ? Colors.green
              : observation.feedback == false
                  ? Colors.orange
                  : Colors.green.shade300,
        ),
      ),
      title: Text(
        eventTitle,
        style: theme.textTheme.bodySmall?.copyWith(
          color: Colors.white,
          fontWeight: FontWeight.w600,
        ),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      subtitle: Text(
        time,
        style: theme.textTheme.labelSmall?.copyWith(color: Colors.white38),
      ),
      trailing: observation.feedback != null
          ? Icon(
              observation.feedback! ? Icons.thumb_up : Icons.thumb_down,
              size: 16,
              color: observation.feedback! ? Colors.green : Colors.orange,
            )
          : const Icon(Icons.expand_more, color: Colors.white38, size: 18),
      children: [
        // Detalle del evento.
        if (detail.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Text(
              detail,
              style: theme.textTheme.bodySmall?.copyWith(
                color: Colors.white60,
                height: 1.3,
              ),
            ),
          ),
        // Lo que se aplicó como solución.
        if (suggestion != null) ...[
          Container(
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: Colors.green.withOpacity(0.08),
              borderRadius: BorderRadius.circular(6),
              border: Border.all(color: Colors.green.withOpacity(0.2)),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Solución aplicada:',
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: Colors.green.shade300,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  suggestion.reasoning.isNotEmpty
                      ? suggestion.reasoning
                      : 'NR: ${observation.telemetry.nrLevel} → ${suggestion.suggestedNrLevel}',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: Colors.white70,
                  ),
                ),
              ],
            ),
          ),
        ],
        // Feedback buttons (solo si no hay feedback aún).
        if (observation.feedback == null) ...[
          const SizedBox(height: 10),
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              Text(
                '¿Funcionó?',
                style: theme.textTheme.labelSmall?.copyWith(
                  color: Colors.white38,
                ),
              ),
              const SizedBox(width: 12),
              IconButton(
                icon: const Icon(Icons.thumb_down_outlined),
                iconSize: 18,
                color: Colors.orange,
                onPressed: () => onFeedback(false),
                tooltip: 'No funcionó',
              ),
              IconButton(
                icon: const Icon(Icons.thumb_up_outlined),
                iconSize: 18,
                color: Colors.green,
                onPressed: () => onFeedback(true),
                tooltip: 'Funcionó correctamente',
              ),
            ],
          ),
        ],
      ],
    );
  }
}
