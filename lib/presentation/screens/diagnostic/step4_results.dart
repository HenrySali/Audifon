import 'package:flutter/material.dart';

import '../../../domain/entities/diagnostic_result.dart';

/// Paso 4: Resultado Visual del Diagnóstico.
///
/// Muestra:
/// - Audiograma simplificado con colores por grado de pérdida
/// - Gráfico de barras por frecuencia para cada oído
/// - Resumen en texto simple
class Step4Results extends StatelessWidget {
  final Map<int, double> leftEarThresholds;
  final Map<int, double> rightEarThresholds;
  final double wordRecognitionScore;
  final VoidCallback onContinue;
  final VoidCallback onBack;

  const Step4Results({
    super.key,
    required this.leftEarThresholds,
    required this.rightEarThresholds,
    required this.wordRecognitionScore,
    required this.onContinue,
    required this.onBack,
  });

  @override
  Widget build(BuildContext context) {
    final summary = DiagnosticResult.generateSummary(
      leftEarThresholds,
      rightEarThresholds,
      wordRecognitionScore,
    );

    return Column(
      children: [
        Expanded(
          child: ListView(
            padding: const EdgeInsets.all(16),
            children: [
              // Título
              const Center(
                child: Text(
                  'Resultados del Diagnóstico',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 20,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
              const SizedBox(height: 20),
              // Audiograma oído derecho
              _AudiogramCard(
                title: 'Oído Derecho',
                thresholds: rightEarThresholds,
                earColor: Colors.red.shade300,
                icon: Icons.hearing,
              ),
              const SizedBox(height: 16),
              // Audiograma oído izquierdo
              _AudiogramCard(
                title: 'Oído Izquierdo',
                thresholds: leftEarThresholds,
                earColor: Colors.blue.shade300,
                icon: Icons.hearing,
              ),
              const SizedBox(height: 16),
              // Reconocimiento de palabras
              _WordScoreCard(score: wordRecognitionScore),
              const SizedBox(height: 16),
              // Leyenda de colores
              const _ColorLegend(),
              const SizedBox(height: 16),
              // Resumen textual
              if (summary.isNotEmpty)
                Container(
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    color: const Color(0xFF16213e),
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(
                      color: Colors.cyan.withOpacity(0.3),
                    ),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Row(
                        children: [
                          Icon(Icons.summarize, color: Colors.cyan, size: 20),
                          SizedBox(width: 8),
                          Text(
                            'Resumen',
                            style: TextStyle(
                              color: Colors.cyan,
                              fontSize: 15,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 12),
                      Text(
                        summary,
                        style: const TextStyle(
                          color: Colors.white70,
                          fontSize: 14,
                          height: 1.5,
                        ),
                      ),
                    ],
                  ),
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
                  onPressed: onBack,
                  child: const Text(
                    'Atrás',
                    style: TextStyle(color: Colors.white54),
                  ),
                ),
                const Spacer(),
                ElevatedButton(
                  onPressed: onContinue,
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
                  child: const Text(
                    'Ver Recomendación',
                    style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

/// Card con audiograma simplificado (barras por frecuencia).
class _AudiogramCard extends StatelessWidget {
  final String title;
  final Map<int, double> thresholds;
  final Color earColor;
  final IconData icon;

  const _AudiogramCard({
    required this.title,
    required this.thresholds,
    required this.earColor,
    required this.icon,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: const Color(0xFF16213e),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon, color: earColor, size: 20),
              const SizedBox(width: 8),
              Text(
                title,
                style: TextStyle(
                  color: earColor,
                  fontSize: 15,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          // Gráfico de barras
          SizedBox(
            height: 140,
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: DiagnosticResult.testFrequencies.map((freq) {
                final threshold = thresholds[freq] ?? 0;
                // Normalizar: 0 dB = barra vacía, 80 dB = barra llena
                final normalizedHeight = (threshold / 80.0).clamp(0.0, 1.0);
                final color = _getColorForThreshold(threshold);

                return Expanded(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 3),
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.end,
                      children: [
                        // Valor en dB
                        Text(
                          '${threshold.toStringAsFixed(0)}',
                          style: TextStyle(
                            color: color,
                            fontSize: 10,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        const SizedBox(height: 4),
                        // Barra
                        Expanded(
                          child: Align(
                            alignment: Alignment.bottomCenter,
                            child: FractionallySizedBox(
                              heightFactor: normalizedHeight.clamp(0.05, 1.0),
                              child: Container(
                                decoration: BoxDecoration(
                                  color: color,
                                  borderRadius: BorderRadius.circular(4),
                                ),
                              ),
                            ),
                          ),
                        ),
                        const SizedBox(height: 4),
                        // Etiqueta de frecuencia
                        Text(
                          _freqLabel(freq),
                          style: const TextStyle(
                            color: Colors.white38,
                            fontSize: 9,
                          ),
                        ),
                      ],
                    ),
                  ),
                );
              }).toList(),
            ),
          ),
        ],
      ),
    );
  }

  String _freqLabel(int freq) {
    if (freq >= 1000) {
      return '${freq ~/ 1000}k';
    }
    return '$freq';
  }

  Color _getColorForThreshold(double threshold) {
    if (threshold <= 25) return Colors.green;
    if (threshold <= 40) return Colors.yellow.shade600;
    if (threshold <= 55) return Colors.orange;
    return Colors.red;
  }
}

/// Card con score de reconocimiento de palabras.
class _WordScoreCard extends StatelessWidget {
  final double score;

  const _WordScoreCard({required this.score});

  @override
  Widget build(BuildContext context) {
    final Color scoreColor;
    final String scoreLabel;

    if (score >= 80) {
      scoreColor = Colors.green;
      scoreLabel = 'Bueno';
    } else if (score >= 60) {
      scoreColor = Colors.yellow.shade600;
      scoreLabel = 'Moderado';
    } else {
      scoreColor = Colors.red;
      scoreLabel = 'Bajo';
    }

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: const Color(0xFF16213e),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        children: [
          const Icon(Icons.record_voice_over, color: Colors.cyan, size: 20),
          const SizedBox(width: 12),
          const Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Reconocimiento de Palabras',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 14,
                    fontWeight: FontWeight.w500,
                  ),
                ),
                SizedBox(height: 2),
                Text(
                  'Porcentaje de palabras identificadas correctamente',
                  style: TextStyle(color: Colors.white38, fontSize: 11),
                ),
              ],
            ),
          ),
          Column(
            children: [
              Text(
                '${score.toStringAsFixed(0)}%',
                style: TextStyle(
                  color: scoreColor,
                  fontSize: 24,
                  fontWeight: FontWeight.bold,
                ),
              ),
              Text(
                scoreLabel,
                style: TextStyle(
                  color: scoreColor,
                  fontSize: 11,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// Leyenda de colores para el audiograma.
class _ColorLegend extends StatelessWidget {
  const _ColorLegend();

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: const Color(0xFF16213e),
        borderRadius: BorderRadius.circular(8),
      ),
      child: const Row(
        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
        children: [
          _LegendItem(color: Colors.green, label: 'Normal\n0-25 dB'),
          _LegendItem(color: Colors.yellow, label: 'Leve\n26-40 dB'),
          _LegendItem(color: Colors.orange, label: 'Moderada\n41-55 dB'),
          _LegendItem(color: Colors.red, label: 'Severa\n56+ dB'),
        ],
      ),
    );
  }
}

class _LegendItem extends StatelessWidget {
  final Color color;
  final String label;

  const _LegendItem({required this.color, required this.label});

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Container(
          width: 16,
          height: 16,
          decoration: BoxDecoration(
            color: color,
            borderRadius: BorderRadius.circular(4),
          ),
        ),
        const SizedBox(height: 4),
        Text(
          label,
          textAlign: TextAlign.center,
          style: const TextStyle(
            color: Colors.white54,
            fontSize: 10,
          ),
        ),
      ],
    );
  }
}
