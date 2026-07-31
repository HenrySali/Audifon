/// @file feedback_checklist_dialog.dart
/// @brief Diálogo modal con el checklist de evaluación de la configuración.
library;

import 'package:flutter/material.dart';

import '../models/feedback_checklist_item.dart';
import '../models/preset_feedback.dart';
import '../store/preset_feedback_store.dart';

/// Muestra un diálogo modal con el checklist de feedback y guarda el
/// resultado en Hive si el usuario presiona "Guardar".
///
/// Devuelve `true` si se guardó algún feedback, `false` si se canceló.
Future<bool> showFeedbackChecklistDialog(
  BuildContext context, {
  required String? sceneClass,
  required String presetName,
  required List<double> gains,
  required bool? thumbsUp,
}) async {
  final res = await showDialog<bool>(
    context: context,
    barrierDismissible: false,
    builder: (ctx) => FeedbackChecklistDialog(
      sceneClass: sceneClass,
      presetName: presetName,
      gains: gains,
      thumbsUp: thumbsUp,
    ),
  );
  return res ?? false;
}

class FeedbackChecklistDialog extends StatefulWidget {
  final String? sceneClass;
  final String presetName;
  final List<double> gains;
  final bool? thumbsUp;

  const FeedbackChecklistDialog({
    super.key,
    required this.sceneClass,
    required this.presetName,
    required this.gains,
    required this.thumbsUp,
  });

  @override
  State<FeedbackChecklistDialog> createState() =>
      _FeedbackChecklistDialogState();
}

class _FeedbackChecklistDialogState extends State<FeedbackChecklistDialog> {
  late List<FeedbackChecklistItem> _items;
  final TextEditingController _commentCtrl = TextEditingController();

  @override
  void initState() {
    super.initState();
    _items = List<FeedbackChecklistItem>.from(kFeedbackItemsTemplate);
  }

  @override
  void dispose() {
    _commentCtrl.dispose();
    super.dispose();
  }

  void _setRating(int idx, FeedbackRating r) {
    setState(() {
      _items[idx] = _items[idx].copyWith(rating: r);
    });
  }

  Future<void> _save() async {
    // Solo guardamos si el usuario marcó al menos un ítem o escribió comentario.
    final bool hasAnyRating =
        _items.any((it) => it.rating != FeedbackRating.noOpinion);
    final bool hasComment = _commentCtrl.text.trim().isNotEmpty;
    if (!hasAnyRating && !hasComment) {
      Navigator.of(context).pop(false);
      return;
    }

    final fb = PresetFeedback(
      id: DateTime.now().microsecondsSinceEpoch,
      timestamp: DateTime.now(),
      sceneClass: widget.sceneClass,
      presetName: widget.presetName,
      gains: List<double>.from(widget.gains),
      items: List<FeedbackChecklistItem>.from(_items),
      comment: hasComment ? _commentCtrl.text.trim() : null,
      thumbsUp: widget.thumbsUp,
    );
    await PresetFeedbackStore.add(fb);
    if (!mounted) return;
    Navigator.of(context).pop(true);
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return AlertDialog(
      title: Row(
        children: [
          const Icon(Icons.feedback_outlined),
          const SizedBox(width: 8),
          const Expanded(child: Text('¿Cómo se escuchó?')),
        ],
      ),
      content: SizedBox(
        width: 480,
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                'Marcá cada aspecto. Tu feedback ayuda a mejorar el sistema.',
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: colors.onSurface.withOpacity(0.7),
                    ),
              ),
              const SizedBox(height: 12),
              ...List.generate(_items.length, (i) => _buildItemRow(context, i)),
              const Divider(height: 24),
              Text(
                'Comentario (opcional)',
                style: Theme.of(context).textTheme.titleSmall,
              ),
              const SizedBox(height: 8),
              TextField(
                controller: _commentCtrl,
                maxLength: 500,
                maxLines: 3,
                decoration: const InputDecoration(
                  hintText: 'Escribí cualquier observación adicional...',
                  border: OutlineInputBorder(),
                  isDense: true,
                ),
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(false),
          child: const Text('Saltar'),
        ),
        FilledButton(
          onPressed: _save,
          child: const Text('Guardar feedback'),
        ),
      ],
    );
  }

  Widget _buildItemRow(BuildContext context, int idx) {
    final item = _items[idx];
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Expanded(
            child: Text(
              item.humanLabel,
              style: Theme.of(context).textTheme.bodyMedium,
            ),
          ),
          _ratingButton(
            idx,
            FeedbackRating.good,
            Icons.thumb_up,
            Colors.greenAccent,
            item.rating,
            tooltip: 'Bien',
          ),
          _ratingButton(
            idx,
            FeedbackRating.bad,
            Icons.thumb_down,
            Colors.redAccent,
            item.rating,
            tooltip: 'Mal',
          ),
          _ratingButton(
            idx,
            FeedbackRating.noOpinion,
            Icons.remove,
            Colors.grey,
            item.rating,
            tooltip: 'Sin opinión',
          ),
        ],
      ),
    );
  }

  Widget _ratingButton(
    int idx,
    FeedbackRating r,
    IconData icon,
    Color activeColor,
    FeedbackRating current, {
    required String tooltip,
  }) {
    final bool active = current == r;
    return IconButton(
      tooltip: tooltip,
      icon: Icon(icon, color: active ? activeColor : Colors.white38, size: 20),
      onPressed: () => _setRating(idx, r),
    );
  }
}
