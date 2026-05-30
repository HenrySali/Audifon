import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:hive/hive.dart';

import '../../../domain/entities/audiogram.dart';
import '../../../domain/entities/diagnostic_result.dart';
import '../../../domain/entities/eq_preset.dart';
import '../../../domain/gain_prescriber.dart';
import '../../bloc/amplification_bloc.dart';
import '../../bloc/amplification_event.dart'
    show ChangeVolume, UpdateAudiogram, UpdateEqGains;
import '../../bloc/amplification_state.dart';

/// Paso 5: Recomendación basada en los resultados del diagnóstico.
///
/// Muestra:
/// - Preset EQ sugerido refinado (10 presets disponibles)
/// - Audiograma reconstruido + ganancias NAL-NL2 prescritas
/// - Volumen inicial sugerido según severidad
/// - Advertencia si debe visitar un audiólogo
/// - Botón "Aplicar todo" que: guarda audiograma, aplica preset, ajusta volumen
/// - Botón "Guardar resultado" para historial de diagnósticos
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
  bool _appliedAll = false;
  bool _resultSaved = false;

  /// Hive box donde se guarda la última prescripción NAL-NL2 calculada para
  /// que la pantalla de audiograma pueda dibujarla como overlay.
  static const String _prescriptionBoxName = 'last_prescription';

  DiagnosticResult? get _result => widget.result;

  /// Construye el audiograma completo (12 freqs) a partir de los thresholds
  /// medidos en el diagnóstico (6 freqs).
  Audiogram _buildAudiogram() {
    final thresholds = DiagnosticResult.buildAudiogramThresholds(
      _result!.leftEarThresholds,
      _result!.rightEarThresholds,
    );
    return Audiogram(thresholds: thresholds);
  }

  /// Calcula las ganancias prescritas para mostrar.
  List<double> _prescribedGains() {
    return GainPrescriber().prescribeFromAudiogram(_buildAudiogram());
  }

  /// Aplica TODO de un toque: audiograma, preset EQ, volumen sugerido.
  Future<void> _applyEverything() async {
    if (_result == null) return;

    final audiogram = _buildAudiogram();
    final preset = EqPreset.findByName(_result!.recommendedPreset);
    final volumeDb = DiagnosticResult.suggestInitialVolumeDb(
      _result!.leftEarThresholds,
      _result!.rightEarThresholds,
    );
    final gains = _prescribedGains();

    final bloc = context.read<AmplificationBloc>();

    // 1. Guardar el audiograma + recalcular NAL-NL2 + aplicar al engine.
    final points = audiogram.thresholds.entries
        .map((e) => AudiogramPoint(
              frequencyHz: e.key,
              thresholdHL: e.value,
            ))
        .toList()
      ..sort((a, b) => a.frequencyHz.compareTo(b.frequencyHz));
    bloc.add(UpdateAudiogram(audiogram: points));

    // 2. Aplicar preset EQ refinado (sobreescribe la prescripción NAL pura).
    if (preset != null) {
      bloc.add(UpdateEqGains(gains: preset.gains, presetName: preset.name));
    }

    // 3. Ajustar volumen inicial sugerido (sumar al actual).
    final state = bloc.state;
    if (state is AmplificationActive) {
      final newVol = (state.volumeDb + volumeDb).clamp(-20.0, 10.0);
      bloc.add(ChangeVolume(volumeDb: newVol));
    } else {
      // Si está inactivo, persistir el volumen para usar al encender.
      try {
        await bloc.settingsRepository.setLastVolume(volumeDb);
      } catch (_) {}
    }

    // 4. Persistir la prescripción para overlay en pantalla de audiograma.
    try {
      final box = await Hive.openBox<dynamic>(_prescriptionBoxName);
      await box.put('prescribed_gains', gains);
      await box.put('preset_name', preset?.name ?? _result!.recommendedPreset);
      await box.put('volume_db_suggested', volumeDb);
      await box.put('timestamp', DateTime.now().toIso8601String());
      await box.put(
        'thresholds',
        audiogram.thresholds.map((k, v) => MapEntry(k.toString(), v)),
      );
    } catch (_) {}

    if (!mounted) return;

    setState(() => _appliedAll = true);

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          'Configuración aplicada · Preset ${preset?.name ?? "—"} · Vol ${volumeDb >= 0 ? "+" : ""}${volumeDb.toStringAsFixed(0)} dB',
        ),
        backgroundColor: Colors.green.shade700,
        duration: const Duration(seconds: 3),
      ),
    );
  }

  Future<void> _saveResult() async {
    if (_result == null) return;
    try {
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

    final volSugerido = DiagnosticResult.suggestInitialVolumeDb(
      _result!.leftEarThresholds,
      _result!.rightEarThresholds,
    );

    return Column(
      children: [
        Expanded(
          child: ListView(
            padding: const EdgeInsets.all(16),
            children: [
              const SizedBox(height: 8),
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
              _RecommendedPresetCard(
                presetName: _result!.recommendedPreset,
                applied: _appliedAll,
              ),
              const SizedBox(height: 12),
              _SuggestedSettingsCard(
                presetName: _result!.recommendedPreset,
                volumeDeltaDb: volSugerido,
                gains: _prescribedGains(),
              ),
              const SizedBox(height: 16),
              if (_result!.shouldVisitAudiologist) _AudiologistWarning(),
              if (_result!.shouldVisitAudiologist) const SizedBox(height: 16),
              _ScoreCard(
                title: 'Cuestionario de Dificultad',
                value: '${_result!.questionnaireScore}/24',
                description: _getQuestionnaireInterpretation(
                  _result!.questionnaireScore,
                ),
                icon: Icons.quiz,
              ),
              const SizedBox(height: 12),
              _ScoreCard(
                title: 'Reconocimiento de Palabras',
                value:
                    '${_result!.wordRecognitionScore.toStringAsFixed(0)}%',
                description: _getWordScoreInterpretation(
                  _result!.wordRecognitionScore,
                ),
                icon: Icons.record_voice_over,
              ),
              const SizedBox(height: 24),
              _ActionButton(
                icon: Icons.auto_fix_high,
                label: 'Aplicar Configuración Recomendada',
                sublabel: _appliedAll
                    ? 'Audiograma, preset y volumen aplicados ✓'
                    : 'Audiograma + Preset + Volumen en un toque',
                color: Colors.cyan,
                enabled: !_appliedAll,
                onPressed: _applyEverything,
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

/// Tarjeta del preset recomendado.
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
      child: Column(children: [
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
            style: const TextStyle(color: Colors.white54, fontSize: 13),
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
      ]),
    );
  }
}

/// Tarjeta con el detalle de la configuración sugerida (volumen, ganancias).
class _SuggestedSettingsCard extends StatelessWidget {
  final String presetName;
  final double volumeDeltaDb;
  final List<double> gains;

  const _SuggestedSettingsCard({
    required this.presetName,
    required this.volumeDeltaDb,
    required this.gains,
  });

  @override
  Widget build(BuildContext context) {
    final maxGain = gains.isEmpty
        ? 1.0
        : gains.reduce((a, b) => a > b ? a : b).clamp(1.0, 50.0);
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: const Color(0xFF0f1f3a),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.cyan.withOpacity(0.2)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.equalizer, color: Color(0xFF00e5ff), size: 18),
              const SizedBox(width: 8),
              const Text(
                'Ajustes sugeridos',
                style: TextStyle(
                  color: Color(0xFF00e5ff),
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const Spacer(),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                decoration: BoxDecoration(
                  color: Colors.cyan.withOpacity(0.15),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Text(
                  'Vol ${volumeDeltaDb >= 0 ? "+" : ""}${volumeDeltaDb.toStringAsFixed(0)} dB',
                  style: const TextStyle(
                    color: Color(0xFF00e5ff),
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          // Mini gráfico de las 12 ganancias prescritas.
          SizedBox(
            height: 40,
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: List.generate(12, (i) {
                final g = i < gains.length ? gains[i] : 0.0;
                final h = (g / maxGain * 36).clamp(2.0, 36.0);
                return Expanded(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 1),
                    child: Container(
                      height: h,
                      decoration: BoxDecoration(
                        color: Colors.cyan.withOpacity(g > 0 ? 0.85 : 0.2),
                        borderRadius: BorderRadius.circular(2),
                      ),
                    ),
                  ),
                );
              }),
            ),
          ),
          const SizedBox(height: 4),
          Row(
            children: List.generate(
              12,
              (i) => Expanded(
                child: Text(
                  EqPreset.bandLabels[i],
                  style: const TextStyle(color: Colors.white38, fontSize: 7),
                  textAlign: TextAlign.center,
                ),
              ),
            ),
          ),
          const SizedBox(height: 8),
          Text(
            'Ganancias prescritas (NAL-NL2). Visibles también en la pantalla del audiograma como línea cian.',
            style: const TextStyle(color: Colors.white54, fontSize: 10),
          ),
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
        border: Border.all(color: Colors.orange.withOpacity(0.4)),
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

/// Tarjeta de score individual.
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
      child: Row(children: [
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
                style: const TextStyle(color: Colors.white38, fontSize: 11),
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
      ]),
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
          child: Row(children: [
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
          ]),
        ),
      ),
    );
  }
}
