import 'package:flutter/material.dart';

import '../../../domain/entities/diagnostic_result.dart';
import 'step1_questionnaire.dart';
import 'step2_tone_test.dart';
import 'step3_word_test.dart';
import 'step4_results.dart';
import 'step5_recommendation.dart';

/// Pantalla principal del flujo de diagnóstico auditivo de 5 pasos.
///
/// Usa un PageView controlado con indicador de progreso.
/// Cada paso valida antes de permitir avanzar al siguiente.
class DiagnosticFlowScreen extends StatefulWidget {
  const DiagnosticFlowScreen({super.key});

  @override
  State<DiagnosticFlowScreen> createState() => _DiagnosticFlowScreenState();
}

class _DiagnosticFlowScreenState extends State<DiagnosticFlowScreen> {
  final PageController _pageController = PageController();
  int _currentStep = 0;
  static const int _totalSteps = 5;

  // Datos recopilados durante el flujo
  List<int> _questionnaireAnswers = [];
  Map<int, double> _leftEarThresholds = {};
  Map<int, double> _rightEarThresholds = {};
  double _wordRecognitionScore = 0;

  @override
  void dispose() {
    _pageController.dispose();
    super.dispose();
  }

  void _goToNextStep() {
    if (_currentStep < _totalSteps - 1) {
      setState(() => _currentStep++);
      _pageController.animateToPage(
        _currentStep,
        duration: const Duration(milliseconds: 300),
        curve: Curves.easeInOut,
      );
    }
  }

  void _goToPreviousStep() {
    if (_currentStep > 0) {
      setState(() => _currentStep--);
      _pageController.animateToPage(
        _currentStep,
        duration: const Duration(milliseconds: 300),
        curve: Curves.easeInOut,
      );
    }
  }

  void _onQuestionnaireComplete(List<int> answers) {
    _questionnaireAnswers = answers;
    _goToNextStep();
  }

  void _onToneTestComplete(
    Map<int, double> leftThresholds,
    Map<int, double> rightThresholds,
  ) {
    _leftEarThresholds = leftThresholds;
    _rightEarThresholds = rightThresholds;
    _goToNextStep();
  }

  void _onWordTestComplete(double score) {
    _wordRecognitionScore = score;
    _goToNextStep();
  }

  void _onResultsReviewed() {
    _goToNextStep();
  }

  DiagnosticResult _buildResult() {
    final score = _questionnaireAnswers.fold<int>(0, (sum, a) => sum + a);
    final preset = DiagnosticResult.getRecommendedPreset(
      _leftEarThresholds,
      _rightEarThresholds,
    );
    final shouldVisit = DiagnosticResult.checkShouldVisitAudiologist(
      _leftEarThresholds,
      _rightEarThresholds,
    );
    final summary = DiagnosticResult.generateSummary(
      _leftEarThresholds,
      _rightEarThresholds,
      _wordRecognitionScore,
    );

    return DiagnosticResult(
      timestamp: DateTime.now(),
      questionnaireAnswers: _questionnaireAnswers,
      questionnaireScore: score,
      leftEarThresholds: _leftEarThresholds,
      rightEarThresholds: _rightEarThresholds,
      wordRecognitionScore: _wordRecognitionScore,
      recommendedPreset: preset,
      shouldVisitAudiologist: shouldVisit,
      summary: summary,
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF1a1a2e),
      appBar: AppBar(
        backgroundColor: const Color(0xFF0f3460),
        title: const Text(
          'Diagnóstico Auditivo',
          style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
        ),
        leading: IconButton(
          icon: const Icon(Icons.close),
          onPressed: () => _showExitConfirmation(context),
        ),
      ),
      body: Column(
        children: [
          // Indicador de progreso
          _ProgressIndicator(
            currentStep: _currentStep,
            totalSteps: _totalSteps,
          ),
          // Contenido del paso actual
          Expanded(
            child: PageView(
              controller: _pageController,
              physics: const NeverScrollableScrollPhysics(),
              children: [
                Step1Questionnaire(
                  onComplete: _onQuestionnaireComplete,
                ),
                Step2ToneTest(
                  onComplete: _onToneTestComplete,
                  onBack: _goToPreviousStep,
                ),
                Step3WordTest(
                  onComplete: _onWordTestComplete,
                  onBack: _goToPreviousStep,
                ),
                Step4Results(
                  leftEarThresholds: _leftEarThresholds,
                  rightEarThresholds: _rightEarThresholds,
                  wordRecognitionScore: _wordRecognitionScore,
                  onContinue: _onResultsReviewed,
                  onBack: _goToPreviousStep,
                ),
                Step5Recommendation(
                  result: _currentStep >= 4 ? _buildResult() : null,
                  onBack: _goToPreviousStep,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _showExitConfirmation(BuildContext context) async {
    final shouldExit = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF1a2332),
        title: const Text(
          '¿Salir del diagnóstico?',
          style: TextStyle(color: Colors.white),
        ),
        content: const Text(
          'Se perderá el progreso actual.',
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
              'Salir',
              style: TextStyle(color: Colors.red),
            ),
          ),
        ],
      ),
    );

    if (shouldExit == true && context.mounted) {
      Navigator.of(context).pop();
    }
  }
}

/// Indicador de progreso visual para los 5 pasos.
class _ProgressIndicator extends StatelessWidget {
  final int currentStep;
  final int totalSteps;

  const _ProgressIndicator({
    required this.currentStep,
    required this.totalSteps,
  });

  static const List<String> _stepLabels = [
    'Cuestionario',
    'Tonos',
    'Palabras',
    'Resultados',
    'Recomendación',
  ];

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: const BoxDecoration(
        color: Color(0xFF0f3460),
        border: Border(
          bottom: BorderSide(color: Colors.cyan, width: 0.5),
        ),
      ),
      child: Column(
        children: [
          // Step counter
          Text(
            'Paso ${currentStep + 1} de $totalSteps',
            style: const TextStyle(
              color: Colors.white70,
              fontSize: 13,
            ),
          ),
          const SizedBox(height: 8),
          // Progress bar
          Row(
            children: List.generate(totalSteps, (index) {
              final isCompleted = index < currentStep;
              final isCurrent = index == currentStep;
              return Expanded(
                child: Container(
                  margin: EdgeInsets.only(
                    right: index < totalSteps - 1 ? 4 : 0,
                  ),
                  height: 4,
                  decoration: BoxDecoration(
                    color: isCompleted
                        ? Colors.cyan
                        : isCurrent
                            ? Colors.cyan.withOpacity(0.5)
                            : Colors.white12,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              );
            }),
          ),
          const SizedBox(height: 6),
          // Step label
          Text(
            _stepLabels[currentStep],
            style: const TextStyle(
              color: Colors.cyan,
              fontSize: 12,
              fontWeight: FontWeight.w500,
            ),
          ),
        ],
      ),
    );
  }
}
