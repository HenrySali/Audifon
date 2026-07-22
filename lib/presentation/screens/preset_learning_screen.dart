import 'package:flutter/material.dart';

import '../../data/services/preset_learning_service.dart';
import '../../domain/services/preset_advisor.dart';

/// Pantalla "Mi historial de aprendizaje".
///
/// Muestra al usuario qué ha aprendido la app de él:
///  - Total de calificaciones registradas.
///  - Por cada clase de ambiente, qué preset prefirió y cuántas veces.
///  - Qué presets se evitan en qué ambientes.
///
/// Permite borrar todo el historial en cualquier momento (transparencia y
/// control del usuario).
class PresetLearningScreen extends StatefulWidget {
  const PresetLearningScreen({super.key});

  @override
  State<PresetLearningScreen> createState() => _PresetLearningScreenState();
}

class _PresetLearningScreenState extends State<PresetLearningScreen> {
  final _learning = PresetLearningService();
  bool _loaded = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    await _learning.load();
    if (mounted) setState(() => _loaded = true);
  }

  Future<void> _confirmClear() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF1a2332),
        title: const Text(
          'Borrar historial',
          style: TextStyle(color: Colors.white),
        ),
        content: const Text(
          'La app olvidará todas las preferencias aprendidas y volverá a usar las sugerencias por defecto.',
          style: TextStyle(color: Colors.white70),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancelar'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text(
              'Borrar',
              style: TextStyle(color: Colors.redAccent),
            ),
          ),
        ],
      ),
    );
    if (ok == true) {
      await _learning.clearAll();
      if (mounted) setState(() {});
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF0a0e21),
      appBar: AppBar(
        title: const Text('Aprendizaje del audífono'),
        backgroundColor: const Color(0xFF0f3460),
        foregroundColor: Colors.white,
        actions: [
          IconButton(
            icon: const Icon(Icons.delete_outline),
            tooltip: 'Borrar historial',
            onPressed: _loaded ? _confirmClear : null,
          ),
        ],
      ),
      body: !_loaded
          ? const Center(child: CircularProgressIndicator(color: Colors.cyan))
          : _buildBody(),
    );
  }

  Widget _buildBody() {
    final all = _learning.getAllScores();
    final total = _learning.totalFeedbackCount;
    final allEntries = _learning.allEntries;

    return SingleChildScrollView(
      padding: const EdgeInsets.all(14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _summaryCard(total, allEntries.length),
          const SizedBox(height: 14),
          if (total == 0)
            _emptyHint()
          else ...[
            for (final envClass in [0, 1, 2, 3])
              if (all.containsKey(envClass))
                _envCard(envClass, all[envClass]!),
          ],
          const SizedBox(height: 14),
          _historyCard(allEntries),
        ],
      ),
    );
  }

  Widget _summaryCard(int rated, int totalApplied) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: const Color(0xFF16213e),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: Colors.cyan.withOpacity(0.3)),
      ),
      child: Row(children: [
        const Icon(Icons.school, color: Color(0xFF00e5ff), size: 28),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'Lo que aprendió la app',
                style: TextStyle(
                  color: Color(0xFF00e5ff),
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                '$totalApplied aplicaciones · $rated calificadas',
                style: const TextStyle(color: Colors.white70, fontSize: 12),
              ),
              if (rated < PresetLearningService.minSampleSize)
                Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: Text(
                    'Faltan ${PresetLearningService.minSampleSize - rated} calificaciones para que empiece a sugerir distinto.',
                    style: const TextStyle(
                      color: Colors.amberAccent,
                      fontSize: 11,
                    ),
                  ),
                ),
            ],
          ),
        ),
      ]),
    );
  }

  Widget _emptyHint() {
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: const Color(0xFF16213e),
        borderRadius: BorderRadius.circular(10),
      ),
      child: const Column(children: [
        Icon(Icons.lightbulb_outline, color: Colors.amberAccent, size: 36),
        SizedBox(height: 10),
        Text(
          'Todavía no hay datos',
          style: TextStyle(color: Colors.white, fontSize: 14, fontWeight: FontWeight.w600),
        ),
        SizedBox(height: 8),
        Text(
          'Usá el botón "Auto" en la pantalla principal y respondé 👍 / 👎 después de cada sugerencia. Después de 5 calificaciones la app empieza a aprender tus preferencias.',
          style: TextStyle(color: Colors.white70, fontSize: 12, height: 1.5),
          textAlign: TextAlign.center,
        ),
      ]),
    );
  }

  Widget _envCard(int envClass, Map<String, int> scores) {
    final label = PresetAdvisor.labelFor(envClass);
    final defaultName = PresetAdvisor.suggestFor(envClass).name;
    // Ordenar de mayor a menor score.
    final sorted = scores.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));

    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: const Color(0xFF16213e),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(children: [
            Icon(_envIcon(envClass), color: _envColor(envClass), size: 18),
            const SizedBox(width: 8),
            Text(
              'Ambiente: $label',
              style: TextStyle(
                color: _envColor(envClass),
                fontSize: 13,
                fontWeight: FontWeight.w600,
              ),
            ),
          ]),
          const SizedBox(height: 8),
          for (final e in sorted)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 3),
              child: Row(children: [
                SizedBox(
                  width: 14,
                  child: e.key == defaultName
                      ? const Icon(Icons.star, color: Colors.cyan, size: 14)
                      : null,
                ),
                Expanded(
                  child: Text(
                    e.key,
                    style: const TextStyle(color: Colors.white, fontSize: 12),
                  ),
                ),
                _scoreChip(e.value),
              ]),
            ),
          const SizedBox(height: 6),
          Text(
            '★ = sugerencia por defecto',
            style: const TextStyle(color: Colors.white38, fontSize: 10),
          ),
        ],
      ),
    );
  }

  Widget _scoreChip(int score) {
    final positive = score > 0;
    final neutral = score == 0;
    final color = neutral
        ? Colors.white54
        : (positive ? Colors.greenAccent : Colors.redAccent);
    final icon = neutral
        ? Icons.remove
        : (positive ? Icons.thumb_up : Icons.thumb_down);
    final sign = score > 0 ? '+' : '';
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: color.withOpacity(0.15),
        borderRadius: BorderRadius.circular(4),
        border: Border.all(color: color.withOpacity(0.4)),
      ),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        Icon(icon, color: color, size: 10),
        const SizedBox(width: 3),
        Text(
          '$sign$score',
          style: TextStyle(color: color, fontSize: 10, fontWeight: FontWeight.w600),
        ),
      ]),
    );
  }

  Widget _historyCard(List<LearningEntry> entries) {
    final lastN = entries.reversed.take(15).toList();
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: const Color(0xFF16213e),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Últimas aplicaciones',
            style: TextStyle(
              color: Color(0xFF00e5ff),
              fontSize: 12,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 8),
          if (lastN.isEmpty)
            const Text(
              'Sin actividad aún.',
              style: TextStyle(color: Colors.white54, fontSize: 11),
            )
          else
            for (final e in lastN) _entryRow(e),
        ],
      ),
    );
  }

  Widget _entryRow(LearningEntry e) {
    final fb = e.feedback;
    Color fbColor;
    IconData fbIcon;
    if (fb == null) {
      fbColor = Colors.white38;
      fbIcon = Icons.help_outline;
    } else if (fb) {
      fbColor = Colors.greenAccent;
      fbIcon = Icons.thumb_up;
    } else {
      fbColor = Colors.redAccent;
      fbIcon = Icons.thumb_down;
    }
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(children: [
        Icon(_envIcon(e.envClass), color: _envColor(e.envClass), size: 14),
        const SizedBox(width: 6),
        Expanded(
          child: Text(
            '${e.presetName}   ·   ${PresetAdvisor.labelFor(e.envClass)}',
            style: const TextStyle(color: Colors.white, fontSize: 11),
          ),
        ),
        Text(
          _shortTime(e.timestamp),
          style: const TextStyle(color: Colors.white38, fontSize: 10),
        ),
        const SizedBox(width: 6),
        Icon(fbIcon, color: fbColor, size: 12),
      ]),
    );
  }

  String _shortTime(DateTime t) {
    final now = DateTime.now();
    final diff = now.difference(t);
    if (diff.inMinutes < 1) return 'ahora';
    if (diff.inMinutes < 60) return '${diff.inMinutes} min';
    if (diff.inHours < 24) return '${diff.inHours} h';
    if (diff.inDays < 30) return '${diff.inDays} d';
    return '${(diff.inDays / 30).floor()} m';
  }

  Color _envColor(int c) {
    switch (c) {
      case 0:
        return Colors.lightGreenAccent;
      case 1:
        return Colors.cyan;
      case 2:
        return Colors.amber;
      case 3:
        return Colors.deepOrangeAccent;
      default:
        return Colors.white54;
    }
  }

  IconData _envIcon(int c) {
    switch (c) {
      case 0:
        return Icons.nights_stay;
      case 1:
        return Icons.record_voice_over;
      case 2:
        return Icons.groups;
      case 3:
        return Icons.traffic;
      default:
        return Icons.help_outline;
    }
  }
}
