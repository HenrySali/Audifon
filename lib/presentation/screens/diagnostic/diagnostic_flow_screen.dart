import 'package:flutter/material.dart';

import '../../../data/services/headphone_calibrator.dart';
import '../../../domain/entities/diagnostic_result.dart';
import 'calibration_step.dart';
import 'step1_questionnaire.dart';
import 'step2_tone_test.dart';
import 'step3_word_test.dart';
import 'step4_results.dart';
import 'step5_recommendation.dart';

/// Pantalla principal del flujo de diagnóstico auditivo.
///
/// Flujo: Cuestionario → Calibración (si necesario) → Tonos → Palabras → Resultados → Recomendación
///
/// Si el auricular ya está calibrado, salta automáticamente la calibración.
class DiagnosticFlowScreen extends StatefulWidget {
  const DiagnosticFlowScreen({super.key});

  @override
  State<DiagnosticFlowScreen> createState() => _DiagnosticFlowScreenState();
}

class _DiagnosticFlowScreenState extends State<DiagnosticFlowScreen> {
  final PageController _pageController = PageController();
  int _currentStep = 0;

  // El flujo tiene 6 pasos posibles, pero calibración puede saltarse
  // Pasos: 0=Cuestionario, 1=Calibración, 2=Tonos, 3=Palabras, 4=Resultados, 5=Recomendación
  static const int _totalSteps = 6;

  // Si ya está calibrado, se salta el paso de calibración
  bool _skipCalibration = false;
  bool _calibrationChecked = false;

  // Datos recopilados durante el flujo
  List<int> _questionnaireAnswers = [];
  Map<int, double> _leftEarThresholds = {};
  Map<int, double> _rightEarThresholds = {};
  double _wordRecognitionScore = 0;

  @override
  void initState() {
    super.initState();
    _checkCalibrationStatus();
  }

  @override
  void dispose() {
    _pageController.dispose();
    super.dispose();
  }

  Future<void> _checkCalibrationStatus() async {
    final calibrator = HeadphoneCalibrator();
    final isCalibrated = await calibrator.isCalibrated();
    await calibrator.dispose();
    if (mounted) {
      setState(() {
        _skipCalibration = isCalibrated;
        _calibrationChecked = true;
      });
    }
  }

  /// Número de pasos visibles (sin calibración si ya está calibrado).
  int get _visibleSteps => _skipCalibration ? 5 : 6;

  /// Índice visual del paso actual (ajustado si se salta calibración).
  int get _displayStep {
    if (_skipCalibration && _currentStep > 0) {
      return _currentStep - 1; // Salta el paso de calibración visualmente
    }
    return _currentStep;
  }

  void _goToStep(int step) {
    setState(() => _currentStep = step);
    _pageController.animateToPage(
      step,
      duration: const Duration(milliseconds: 300),
      curve: Curves.easeInOut,
    );
  }

  void _goToNextStep() {
    if (_currentStep < _totalSteps - 1) {
      _goToStep(_currentStep + 1);
    }
  }

  void _goToPreviousStep() {
    if (_currentStep > 0) {
      // Si estamos en tonos y calibración se saltó, volver al cuestionario
      if (_skipCalibration && _currentStep == 2) {
        _goToStep(0);
      } else {
        _goToStep(_currentStep - 1);
      }
    }
  }

  void _onQuestionnaireComplete(List<int> answers) {
    _questionnaireAnswers = answers;
    if (_skipCalibration) {
      // Saltar calibración, ir directo a tonos
      _goToStep(2);
    } else {
      _goToNextStep(); // Ir a calibración
    }
  }

  void _onCalibrationComplete() {
    // Después de calibrar, ir al test de tonos
    _goToStep(2);
  }

  void _onToneTestComplete(
    Map<int, double> leftThresholds,
    Map<int, double> rightThresholds,
  ) {
    _leftEarThresholds = leftThresholds;
    _rightEarThresholds = rightThresholds;
    _goToStep(3);
  }

  void _onWordTestComplete(double score) {
    _wordRecognitionScore = score;
    _goToStep(4);
  }

  void _onResultsReviewed() {
    _goToStep(5);
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
            currentStep: _displayStep,
            totalSteps: _visibleSteps,
            skipCalibration: _skipCalibration,
          ),
          // Contenido del paso actual
          Expanded(
            child: PageView(
              controller: _pageController,
              physics: const NeverScrollableScrollPhysics(),
              children: [
                // Paso 0: Cuestionario
                Step1Questionnaire(
                  onComplete: _onQuestionnaireComplete,
                ),
                // Paso 1: Calibración
                CalibrationStep(
                  onComplete: _onCalibrationComplete,
                  onBack: _goToPreviousStep,
                ),
                // Paso 2: Test de tonos
                Step2ToneTest(
                  onComplete: _onToneTestComplete,
                  onBack: _goToPreviousStep,
                ),
                // Paso 3: Test de palabras
                Step3WordTest(
                  onComplete: _onWordTestComplete,
                  onBack: _goToPreviousStep,
                ),
                // Paso 4: Resultados
                Step4Results(
                  leftEarThresholds: _leftEarThresholds,
                  rightEarThresholds: _rightEarThresholds,
                  wordRecognitionScore: _wordRecognitionScore,
                  onContinue: _onResultsReviewed,
                  onBack: _goToPreviousStep,
                ),
                // Paso 5: Recomendación
                Step5Recommendation(
                  result: _currentStep >= 5 ? _buildResult() : null,
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

/// Indicador de progreso visual para los pasos del diagnóstico.
class _ProgressIndicator extends StatelessWidget {
  final int currentStep;
  final int totalSteps;
  final bool skipCalibration;

  const _ProgressIndicator({
    required this.currentStep,
    required this.totalSteps,
    required this.skipCalibration,
  });

  List<String> get _stepLabels => skipCalibration
      ? const [
          'Cuestionario',
          'Tonos',
          'Palabras',
          'Resultados',
          'Recomendación',
        ]
      : const [
          'Cuestionario',
          'Calibración',
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
          if (currentStep < _stepLabels.length)
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
