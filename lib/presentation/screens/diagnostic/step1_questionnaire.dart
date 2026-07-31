import 'package:flutter/material.dart';

import '../../../domain/entities/diagnostic_result.dart';

/// Paso 1: Cuestionario de Dificultad Auditiva.
///
/// 8 preguntas en español sobre situaciones cotidianas.
/// Respuestas: Nunca (0) / A veces (1) / Frecuentemente (2) / Siempre (3).
/// Score total: 0-24 puntos.
class Step1Questionnaire extends StatefulWidget {
  final void Function(List<int> answers) onComplete;

  const Step1Questionnaire({super.key, required this.onComplete});

  @override
  State<Step1Questionnaire> createState() => _Step1QuestionnaireState();
}

class _Step1QuestionnaireState extends State<Step1Questionnaire> {
  late List<int?> _answers;
  final ScrollController _scrollController = ScrollController();

  @override
  void initState() {
    super.initState();
    _answers = List.filled(
      DiagnosticResult.questionnaireQuestions.length,
      null,
    );
  }

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  bool get _allAnswered => _answers.every((a) => a != null);

  int get _currentScore =>
      _answers.where((a) => a != null).fold<int>(0, (sum, a) => sum + a!);

  void _onSubmit() {
    if (_allAnswered) {
      widget.onComplete(_answers.cast<int>());
    }
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Expanded(
          child: ListView(
            controller: _scrollController,
            padding: const EdgeInsets.all(16),
            children: [
              // Instrucciones
              Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: const Color(0xFF16213e),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(
                    color: Colors.cyan.withOpacity(0.3),
                  ),
                ),
                child: const Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Icon(Icons.info_outline, color: Colors.cyan, size: 20),
                        SizedBox(width: 8),
                        Text(
                          'Instrucciones',
                          style: TextStyle(
                            color: Colors.cyan,
                            fontSize: 15,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ],
                    ),
                    SizedBox(height: 8),
                    Text(
                      'Responda cada pregunta según su experiencia '
                      'en las últimas semanas. Sea honesto para obtener '
                      'un resultado preciso.',
                      style: TextStyle(color: Colors.white70, fontSize: 13),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 16),
              // Preguntas
              ...List.generate(
                DiagnosticResult.questionnaireQuestions.length,
                (index) => _QuestionCard(
                  index: index,
                  question: DiagnosticResult.questionnaireQuestions[index],
                  selectedAnswer: _answers[index],
                  onAnswerChanged: (value) {
                    setState(() => _answers[index] = value);
                  },
                ),
              ),
              const SizedBox(height: 16),
              // Score parcial
              if (_answers.any((a) => a != null))
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: const Color(0xFF16213e),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      const Text(
                        'Puntuación parcial: ',
                        style: TextStyle(color: Colors.white54, fontSize: 13),
                      ),
                      Text(
                        '$_currentScore / 24',
                        style: const TextStyle(
                          color: Colors.cyan,
                          fontSize: 15,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ],
                  ),
                ),
              const SizedBox(height: 80),
            ],
          ),
        ),
        // Botón siguiente
        _BottomButton(
          label: 'Siguiente',
          enabled: _allAnswered,
          onPressed: _onSubmit,
        ),
      ],
    );
  }
}

/// Card individual para cada pregunta del cuestionario.
class _QuestionCard extends StatelessWidget {
  final int index;
  final String question;
  final int? selectedAnswer;
  final ValueChanged<int> onAnswerChanged;

  const _QuestionCard({
    required this.index,
    required this.question,
    required this.selectedAnswer,
    required this.onAnswerChanged,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: const Color(0xFF16213e),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: selectedAnswer != null
              ? Colors.cyan.withOpacity(0.4)
              : Colors.white12,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Número y pregunta
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                width: 28,
                height: 28,
                decoration: BoxDecoration(
                  color: selectedAnswer != null
                      ? Colors.cyan.withOpacity(0.2)
                      : Colors.white12,
                  shape: BoxShape.circle,
                ),
                child: Center(
                  child: Text(
                    '${index + 1}',
                    style: TextStyle(
                      color: selectedAnswer != null
                          ? Colors.cyan
                          : Colors.white54,
                      fontSize: 13,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  question,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 14,
                    height: 1.4,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          // Opciones de respuesta
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: List.generate(
              DiagnosticResult.answerOptions.length,
              (optionIndex) {
                final isSelected = selectedAnswer == optionIndex;
                return GestureDetector(
                  onTap: () => onAnswerChanged(optionIndex),
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 200),
                    padding: const EdgeInsets.symmetric(
                      horizontal: 14,
                      vertical: 8,
                    ),
                    decoration: BoxDecoration(
                      color: isSelected
                          ? Colors.cyan.withOpacity(0.2)
                          : Colors.transparent,
                      borderRadius: BorderRadius.circular(20),
                      border: Border.all(
                        color: isSelected ? Colors.cyan : Colors.white24,
                        width: isSelected ? 2 : 1,
                      ),
                    ),
                    child: Text(
                      DiagnosticResult.answerOptions[optionIndex],
                      style: TextStyle(
                        color: isSelected ? Colors.cyan : Colors.white54,
                        fontSize: 12,
                        fontWeight:
                            isSelected ? FontWeight.w600 : FontWeight.normal,
                      ),
                    ),
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

/// Botón inferior fijo para navegación.
class _BottomButton extends StatelessWidget {
  final String label;
  final bool enabled;
  final VoidCallback onPressed;

  const _BottomButton({
    required this.label,
    required this.enabled,
    required this.onPressed,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: const BoxDecoration(
        color: Color(0xFF0f3460),
        border: Border(
          top: BorderSide(color: Colors.white12),
        ),
      ),
      child: SafeArea(
        top: false,
        child: SizedBox(
          width: double.infinity,
          height: 48,
          child: ElevatedButton(
            onPressed: enabled ? onPressed : null,
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.cyan,
              disabledBackgroundColor: Colors.cyan.withOpacity(0.3),
              foregroundColor: Colors.white,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
              ),
            ),
            child: Text(
              label,
              style: const TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ),
      ),
    );
  }
}
