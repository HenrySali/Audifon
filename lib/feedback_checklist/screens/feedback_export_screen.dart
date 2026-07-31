/// @file feedback_export_screen.dart
/// @brief Pantalla para ver feedbacks acumulados y exportarlos a archivo.
library;

import 'package:flutter/material.dart';

import '../controllers/feedback_export_controller.dart';
import '../models/feedback_checklist_item.dart';
import '../models/preset_feedback.dart';
import '../store/preset_feedback_store.dart';

class FeedbackExportScreen extends StatefulWidget {
  const FeedbackExportScreen({super.key});

  @override
  State<FeedbackExportScreen> createState() => _FeedbackExportScreenState();
}

class _FeedbackExportScreenState extends State<FeedbackExportScreen> {
  bool _loading = true;
  bool _exporting = false;
  List<PresetFeedback> _items = const [];

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    final list = await PresetFeedbackStore.getAll();
    if (!mounted) return;
    setState(() {
      _items = list;
      _loading = false;
    });
  }

  Future<void> _confirmExport() async {
    if (_items.isEmpty) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Exportar y borrar'),
        content: Text(
          'Se generará un archivo JSON con ${_items.length} feedbacks y se '
          'borrarán todos los registros de la app. Esta acción no se puede '
          'deshacer.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Cancelar'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(ctx).colorScheme.error,
            ),
            child: const Text('Exportar y borrar'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    if (!mounted) return;

    setState(() => _exporting = true);
    final path = await FeedbackExportController().exportAndClear();
    if (!mounted) return;
    setState(() => _exporting = false);

    if (path == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
            content: Text('Error al exportar. No se borró ningún feedback.')),
      );
      return;
    }

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('Exportado a: $path'),
        duration: const Duration(seconds: 8),
      ),
    );
    await _load();
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Scaffold(
      backgroundColor: const Color(0xFF1a1a2e),
      appBar: AppBar(
        backgroundColor: const Color(0xFF0f3460),
        title: const Text('Feedback Acumulado'),
        iconTheme: const IconThemeData(color: Colors.white),
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : Column(
              children: [
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(12),
                  color: const Color(0xFF16213e),
                  child: Text(
                    '${_items.length} feedback(s) acumulados',
                    style: TextStyle(
                        color: colors.primary, fontWeight: FontWeight.w600),
                  ),
                ),
                Expanded(
                  child: _items.isEmpty
                      ? Center(
                          child: Text(
                            'No hay feedback para exportar',
                            style: TextStyle(
                                color: Colors.white.withOpacity(0.6)),
                          ),
                        )
                      : ListView.builder(
                          itemCount: _items.length,
                          itemBuilder: (ctx, i) => _buildRow(_items[i]),
                        ),
                ),
                Padding(
                  padding: const EdgeInsets.all(16),
                  child: FilledButton.icon(
                    onPressed: _items.isEmpty || _exporting
                        ? null
                        : _confirmExport,
                    icon: _exporting
                        ? const SizedBox(
                            width: 16,
                            height: 16,
                            child:
                                CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.download),
                    label: Padding(
                      padding: const EdgeInsets.symmetric(vertical: 12),
                      child: Text(
                        _exporting ? 'Exportando...' : 'Exportar todo y borrar',
                        style: const TextStyle(fontSize: 16),
                      ),
                    ),
                  ),
                ),
              ],
            ),
    );
  }

  Widget _buildRow(PresetFeedback fb) {
    final goods = fb.items
        .where((it) => it.rating == FeedbackRating.good)
        .length;
    final bads =
        fb.items.where((it) => it.rating == FeedbackRating.bad).length;
    final ts = fb.timestamp;
    final tsStr =
        '${ts.day.toString().padLeft(2, "0")}/${ts.month.toString().padLeft(2, "0")} '
        '${ts.hour.toString().padLeft(2, "0")}:${ts.minute.toString().padLeft(2, "0")}';
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: const Color(0xFF16213e),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(tsStr,
                  style: const TextStyle(color: Colors.white70, fontSize: 12)),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  fb.presetName,
                  style: const TextStyle(
                      color: Colors.white, fontWeight: FontWeight.w600),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              if (fb.thumbsUp == true)
                const Icon(Icons.thumb_up,
                    color: Colors.greenAccent, size: 14),
              if (fb.thumbsUp == false)
                const Icon(Icons.thumb_down,
                    color: Colors.redAccent, size: 14),
            ],
          ),
          const SizedBox(height: 4),
          Row(
            children: [
              Icon(Icons.thumb_up,
                  color: Colors.greenAccent.withOpacity(0.7), size: 12),
              const SizedBox(width: 4),
              Text('$goods',
                  style: const TextStyle(
                      color: Colors.greenAccent, fontSize: 11)),
              const SizedBox(width: 12),
              Icon(Icons.thumb_down,
                  color: Colors.redAccent.withOpacity(0.7), size: 12),
              const SizedBox(width: 4),
              Text('$bads',
                  style: const TextStyle(
                      color: Colors.redAccent, fontSize: 11)),
              if (fb.sceneClass != null) ...[
                const SizedBox(width: 12),
                Text(fb.sceneClass!,
                    style: const TextStyle(
                        color: Colors.white54, fontSize: 11)),
              ],
            ],
          ),
          if (fb.comment != null && fb.comment!.isNotEmpty) ...[
            const SizedBox(height: 4),
            Text(
              '"${fb.comment!}"',
              style: const TextStyle(
                  color: Colors.white70, fontSize: 11, fontStyle: FontStyle.italic),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
          ],
        ],
      ),
    );
  }
}
