import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:hive/hive.dart';

import '../../../domain/entities/diagnostic_result.dart';
import '../../../domain/entities/eq_preset.dart';
import '../../bloc/amplification_bloc.dart';
import '../../bloc/amplification_event.dart' show UpdateEqGains;

/// Paso 5: Recomendación basada en los resultados del diagnóstico.
///
/// Muestra:
/// - Preset EQ sugerido (Normal/Mild/Moderate/Severe/Profound)
/// - Advertencia si debe visitar un audiólogo
/// - Botón "Aplicar preset recomendado"
/// - Botón "Guardar resultado" para historial
class Step5Recommendation extends StatefulWidget {
  final DiagnosticResult? result;
  final VoidCallback onBack;

  const Step5Recommendation({
    super.key,
    required this.result,
    required this.onBack,
  });

  @override
  State<Step5Recommendation> createState() => _Step5RecommendationState();
}

class _Step5RecommendationState extends State<Step5Recommendation> {
  bool _presetApplied = false;
  bool _resultSaved = false;

  DiagnosticResult? get _result => widget.result;

  void _applyPreset() {
    if (_result == null) return;

    final preset = EqPreset.findByName(_result!.recommendedPreset);
    if (preset != null) {
      context.read<AmplificationBloc>().add(
            UpdateEqGains(gains: preset.gains, presetName: preset.name),
          );
      setState(() => _presetApplied = true);

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'Preset "${preset.name}" aplicado correctamente',
          ),
          backgroundColor: Colors.green.shade700,
          duration: const Duration(seconds: 2),
        ),
      );
    }
  }

  Future<void> _saveResult() async {
    if (_result == null) return;

    try {
      // Guardar en Hive
      final box = await Hive.openBox<Map>('diagnostic_results');
      await box.add(_result!.toJson().cast<dynamic, dynamic>());
      await box.close();

      setState(() => _resultSaved = true);

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: const Text('Resultado guardado en historial'),
            backgroundColor: Colors.cyan.shade700,
            duration: const Duration(seconds: 2),
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Error al guardar: $e'),
            backgroundColor: Colors.red.shade700,
          ),
        );
      }
    }
  }

  void _finishDiagnostic() {
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    if (_result == null) {
      return const Center(
        child: CircularProgressIndicator(color: Colors.cyan),
      );
    }

    return Column(
      children: [
        Expanded(
          child: ListView(
            padding: const EdgeInsets.all(16),
            children: [
              const SizedBox(height: 8),
              // Icono y título
              const Center(
                child: Icon(
                  Icons.recommend,
                  size: 56,
                  color: Colors.cyan,
                ),
              ),
              const SizedBox(height: 12),
              const Center(
                child: Text(
                  'Recomendación',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 22,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
              const SizedBox(height: 24),
              // Preset recomendado
              _RecommendedPresetCard(
                presetName: _result!.recommendedPreset,
                applied: _presetApplied,
              ),
              const SizedBox(height: 16),
              // Advertencia de audiólogo
              if (_result!.shouldVisitAudiologist)
                _AudiologistWarning(),
              if (_result!.shouldVisitAudiologist) const SizedBox(height: 16),
              // Score del cuestionario
              _ScoreCard(
                title: 'Cuestionario de Dificultad',
                value: '${_result!.questionnaireScore}/24',
                description: _getQuestionnaireInterpretation(
                  _result!.questionnaireScore,
                ),
                icon: Icons.quiz,
              ),
              const SizedBox(height: 12),
              // Score de palabras
              _ScoreCard(
                title: 'Reconocimiento de Palabras',
                value: '${_result!.wordRecognitionScore.toStringAsFixed(0)}%',
                description: _getWordScoreInterpretation(
                  _result!.wordRecognitionScore,
                ),
                icon: Icons.record_voice_over,
              ),
              const SizedBox(height: 24),
              // Botones de acción
              _ActionButton(
                icon: Icons.tune,
                label: 'Aplicar Preset Recomendado',
                sublabel: _presetApplied
                    ? 'Preset aplicado ✓'
                    : 'Configura el audífono automáticamente',
                color: Colors.cyan,
                enabled: !_presetApplied,
                onPressed: _applyPreset,
              ),
              const SizedBox(height: 12),
              _ActionButton(
                icon: Icons.save,
                label: 'Guardar Resultado',
                sublabel: _resultSaved
                    ? 'Guardado en historial ✓'
                    : 'Guarda para comparar en el futuro',
                color: Colors.tealAccent,
                enabled: !_resultSaved,
                onPressed: _saveResult,
              ),
              const SizedBox(height: 80),
            ],
          ),
        ),
        // Botones de navegación
        Container(
          padding: const EdgeInsets.all(16),
          decoration: const BoxDecoration(
            color: Color(0xFF0f3460),
            border: Border(top: BorderSide(color: Colors.white12)),
          ),
          child: SafeArea(
            top: false,
            child: Row(
              children: [
                TextButton(
                  onPressed: widget.onBack,
                  child: const Text(
                    'Atrás',
                    style: TextStyle(color: Colors.white54),
                  ),
                ),
                const Spacer(),
                ElevatedButton.icon(
                  onPressed: _finishDiagnostic,
                  icon: const Icon(Icons.check),
                  label: const Text('Finalizar'),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.cyan,
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(
                      horizontal: 24,
                      vertical: 12,
                    ),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  String _getQuestionnaireInterpretation(int score) {
    if (score <= 4) return 'Sin dificultad significativa';
    if (score <= 8) return 'Dificultad leve';
    if (score <= 14) return 'Dificultad moderada';
    if (score <= 19) return 'Dificultad considerable';
    return 'Dificultad severa';
  }

  String _getWordScoreInterpretation(double score) {
    if (score >= 90) return 'Excelente discriminación';
    if (score >= 80) return 'Buena discriminación';
    if (score >= 60) return 'Discriminación moderada';
    if (score >= 40) return 'Discriminación pobre';
    return 'Discriminación muy pobre';
  }
}

/// Card del preset recomendado.
class _RecommendedPresetCard extends StatelessWidget {
  final String presetName;
  final bool applied;

  const _RecommendedPresetCard({
    required this.presetName,
    required this.applied,
  });

  @override
  Widget build(BuildContext context) {
    final preset = EqPreset.findByName(presetName);

    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: const Color(0xFF16213e),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: applied
              ? Colors.green.withOpacity(0.5)
              : Colors.cyan.withOpacity(0.4),
          width: 2,
        ),
      ),
      child: Column(
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(
                applied ? Icons.check_circle : Icons.auto_fix_high,
                color: applied ? Colors.green : Colors.cyan,
                size: 28,
              ),
              const SizedBox(width: 12),
              Text(
                'Preset Recomendado',
                style: TextStyle(
                  color: applied ? Colors.green : Colors.cyan,
                  fontSize: 16,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          Text(
            presetName,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 28,
              fontWeight: FontWeight.bold,
            ),
          ),
          if (preset != null) ...[
            const SizedBox(height: 4),
            Text(
              preset.description,
              style: const TextStyle(
                color: Colors.white54,
                fontSize: 13,
              ),
            ),
          ],
          if (applied) ...[
            const SizedBox(height: 8),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
              decoration: BoxDecoration(
                color: Colors.green.withOpacity(0.15),
                borderRadius: BorderRadius.circular(12),
              ),
              child: const Text(
                'Aplicado',
                style: TextStyle(
                  color: Colors.green,
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// Advertencia de visitar audiólogo.
class _AudiologistWarning extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.orange.withOpacity(0.1),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: Colors.orange.withOpacity(0.4),
        ),
      ),
      child: const Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.medical_services, color: Colors.orange, size: 24),
          SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Recomendamos visitar un audiólogo',
                  style: TextStyle(
                    color: Colors.orange,
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                SizedBox(height: 4),
                Text(
                  'Se detectó pérdida auditiva superior a 40 dB en alguna '
                  'frecuencia. Un profesional puede realizar un diagnóstico '
                  'completo y recomendar el tratamiento adecuado.',
                  style: TextStyle(
                    color: Colors.white70,
                    fontSize: 12,
                    height: 1.4,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Card de score individual.
class _ScoreCard extends StatelessWidget {
  final String title;
  final String value;
  final String description;
  final IconData icon;

  const _ScoreCard({
    required this.title,
    required this.value,
    required this.description,
    required this.icon,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: const Color(0xFF16213e),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        children: [
          Icon(icon, color: Colors.cyan.withOpacity(0.7), size: 20),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 13,
                    fontWeight: FontWeight.w500,
                  ),
                ),
                Text(
                  description,
                  style: const TextStyle(
                    color: Colors.white38,
                    fontSize: 11,
                  ),
                ),
              ],
            ),
          ),
          Text(
            value,
            style: const TextStyle(
              color: Colors.cyan,
              fontSize: 18,
              fontWeight: FontWeight.bold,
            ),
          ),
        ],
      ),
    );
  }
}

/// Botón de acción con icono y sublabel.
class _ActionButton extends StatelessWidget {
  final IconData icon;
  final String label;
  final String sublabel;
  final Color color;
  final bool enabled;
  final VoidCallback onPressed;

  const _ActionButton({
    required this.icon,
    required this.label,
    required this.sublabel,
    required this.color,
    required this.enabled,
    required this.onPressed,
  });

  @override
  Widget build(BuildContext context) {
    return Material(
      color: enabled ? color.withOpacity(0.1) : Colors.white.withOpacity(0.05),
      borderRadius: BorderRadius.circular(12),
      child: InkWell(
        onTap: enabled ? onPressed : null,
        borderRadius: BorderRadius.circular(12),
        child: Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
              color: enabled ? color.withOpacity(0.4) : Colors.white12,
            ),
          ),
          child: Row(
            children: [
              Icon(
                icon,
                color: enabled ? color : Colors.white24,
                size: 24,
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      label,
                      style: TextStyle(
                        color: enabled ? Colors.white : Colors.white38,
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    Text(
                      sublabel,
                      style: TextStyle(
                        color: enabled ? Colors.white54 : Colors.white24,
                        fontSize: 11,
                      ),
                    ),
                  ],
                ),
              ),
              Icon(
                enabled ? Icons.arrow_forward_ios : Icons.check,
                color: enabled ? color.withOpacity(0.5) : Colors.green,
                size: 16,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
