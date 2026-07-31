import 'dart:async';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter_tts/flutter_tts.dart';

import '../../../domain/entities/diagnostic_result.dart';

/// Paso 3: Test de Reconocimiento de Palabras.
///
/// Reproduce 10 palabras bisílabas en español a nivel suave.
/// El usuario selecciona entre 4 opciones cuál escuchó.
/// Score: porcentaje de aciertos (0-100%).
class Step3WordTest extends StatefulWidget {
  final void Function(double score) onComplete;
  final VoidCallback onBack;

  const Step3WordTest({
    super.key,
    required this.onComplete,
    required this.onBack,
  });

  @override
  State<Step3WordTest> createState() => _Step3WordTestState();
}

class _Step3WordTestState extends State<Step3WordTest> {
  bool _testStarted = false;
  int _currentWordIndex = 0;
  int _correctAnswers = 0;
  bool _isPlayingWord = false;
  bool _showingResult = false;
  int? _selectedOption;
  bool? _lastAnswerCorrect;

  // TTS engine
  final FlutterTts _tts = FlutterTts();

  // Opciones mezcladas para la palabra actual
  List<String> _shuffledOptions = [];
  int _correctOptionIndex = 0;

  @override
  void initState() {
    super.initState();
    _initTts();
  }

  Future<void> _initTts() async {
    await _tts.setLanguage('es-ES');
    await _tts.setSpeechRate(0.4); // Lento para claridad
    await _tts.setVolume(0.5); // Volumen bajo (simula nivel suave)
    await _tts.setPitch(1.0);
  }

  @override
  void dispose() {
    _tts.stop();
    super.dispose();
  }

  int get _totalWords => DiagnosticResult.testWords.length;

  double get _progress => _currentWordIndex / _totalWords;

  void _startTest() {
    setState(() {
      _testStarted = true;
      _currentWordIndex = 0;
      _correctAnswers = 0;
    });
    _prepareWord();
    _playCurrentWord();
  }

  void _prepareWord() {
    // Mezclar opciones para la palabra actual
    final options =
        List<String>.from(DiagnosticResult.wordOptions[_currentWordIndex]);
    final correctWord = DiagnosticResult.testWords[_currentWordIndex];

    // Shuffle options
    final random = Random();
    options.shuffle(random);

    setState(() {
      _shuffledOptions = options;
      _correctOptionIndex = options.indexOf(correctWord);
      _selectedOption = null;
      _showingResult = false;
      _lastAnswerCorrect = null;
    });
  }

  void _playCurrentWord() {
    setState(() => _isPlayingWord = true);

    final word = DiagnosticResult.testWords[_currentWordIndex];

    // Reproducir la palabra usando TTS
    _tts.speak(word).then((_) {
      // TTS completó la reproducción
    });

    // Esperar un tiempo razonable para que termine el TTS
    Timer(const Duration(milliseconds: 1500), () {
      if (mounted) {
        setState(() => _isPlayingWord = false);
      }
    });
  }

  void _onOptionSelected(int optionIndex) {
    if (_selectedOption != null || _isPlayingWord) return;

    final isCorrect = optionIndex == _correctOptionIndex;

    setState(() {
      _selectedOption = optionIndex;
      _lastAnswerCorrect = isCorrect;
      _showingResult = true;
      if (isCorrect) _correctAnswers++;
    });

    // Avanzar después de mostrar resultado
    Timer(const Duration(milliseconds: 1200), () {
      if (mounted) {
        _advanceToNext();
      }
    });
  }

  void _advanceToNext() {
    if (_currentWordIndex < _totalWords - 1) {
      setState(() => _currentWordIndex++);
      _prepareWord();
      _playCurrentWord();
    } else {
      // Test completado
      final score = (_correctAnswers / _totalWords) * 100.0;
      widget.onComplete(score);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!_testStarted) {
      return _buildInstructions();
    }
    return _buildTestUI();
  }

  Widget _buildInstructions() {
    return Column(
      children: [
        Expanded(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                const Icon(
                  Icons.record_voice_over,
                  size: 64,
                  color: Colors.cyan,
                ),
                const SizedBox(height: 24),
                const Text(
                  'Test de Palabras',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 22,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const SizedBox(height: 16),
                Container(
                  padding: const EdgeInsets.all(20),
                  decoration: BoxDecoration(
                    color: const Color(0xFF16213e),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: const Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Instrucciones:',
                        style: TextStyle(
                          color: Colors.cyan,
                          fontSize: 15,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      SizedBox(height: 12),
                      Text(
                        '• Escuchará 10 palabras, una a la vez.\n'
                        '• Cada palabra se reproduce a un volumen suave.\n'
                        '• Seleccione entre las 4 opciones la palabra que escuchó.\n'
                        '• Si no está seguro, elija la que más se parezca.',
                        style: TextStyle(
                          color: Colors.white70,
                          fontSize: 13,
                          height: 1.6,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
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
                  onPressed: _startTest,
                  icon: const Icon(Icons.play_arrow),
                  label: const Text('Iniciar Test'),
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

  Widget _buildTestUI() {
    return Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        children: [
          // Progreso
          Row(
            children: [
              Text(
                'Palabra ${_currentWordIndex + 1} de $_totalWords',
                style: const TextStyle(color: Colors.white54, fontSize: 13),
              ),
              const Spacer(),
              Text(
                'Aciertos: $_correctAnswers',
                style: const TextStyle(
                  color: Colors.cyan,
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          LinearProgressIndicator(
            value: _progress,
            backgroundColor: Colors.white12,
            color: Colors.cyan,
            minHeight: 6,
          ),
          const SizedBox(height: 32),
          // Indicador de reproducción
          if (_isPlayingWord)
            Container(
              padding: const EdgeInsets.all(24),
              decoration: BoxDecoration(
                color: const Color(0xFF16213e),
                borderRadius: BorderRadius.circular(16),
                border: Border.all(color: Colors.cyan.withOpacity(0.3)),
              ),
              child: Column(
                children: [
                  const Icon(
                    Icons.volume_up,
                    color: Colors.cyan,
                    size: 48,
                  ),
                  const SizedBox(height: 12),
                  Text(
                    'Escuche atentamente...',
                    style: TextStyle(
                      color: Colors.cyan.withOpacity(0.8),
                      fontSize: 16,
                    ),
                  ),
                ],
              ),
            )
          else ...[
            const Text(
              '¿Qué palabra escuchó?',
              style: TextStyle(
                color: Colors.white,
                fontSize: 18,
                fontWeight: FontWeight.w500,
              ),
            ),
            const SizedBox(height: 8),
            // Botón para repetir
            TextButton.icon(
              onPressed: _isPlayingWord ? null : _playCurrentWord,
              icon: const Icon(Icons.replay, size: 18),
              label: const Text('Repetir palabra'),
              style: TextButton.styleFrom(
                foregroundColor: Colors.cyan.withOpacity(0.7),
              ),
            ),
          ],
          const SizedBox(height: 24),
          // Opciones
          if (!_isPlayingWord)
            Expanded(
              child: GridView.count(
                crossAxisCount: 2,
                mainAxisSpacing: 12,
                crossAxisSpacing: 12,
                childAspectRatio: 2.5,
                children: List.generate(_shuffledOptions.length, (index) {
                  final isSelected = _selectedOption == index;
                  final isCorrect =
                      _showingResult && index == _correctOptionIndex;
                  final isWrong = _showingResult &&
                      isSelected &&
                      index != _correctOptionIndex;

                  Color bgColor;
                  Color borderColor;
                  Color textColor;

                  if (isCorrect) {
                    bgColor = Colors.green.withOpacity(0.2);
                    borderColor = Colors.green;
                    textColor = Colors.green;
                  } else if (isWrong) {
                    bgColor = Colors.red.withOpacity(0.2);
                    borderColor = Colors.red;
                    textColor = Colors.red;
                  } else if (isSelected) {
                    bgColor = Colors.cyan.withOpacity(0.2);
                    borderColor = Colors.cyan;
                    textColor = Colors.cyan;
                  } else {
                    bgColor = const Color(0xFF16213e);
                    borderColor = Colors.white24;
                    textColor = Colors.white;
                  }

                  return GestureDetector(
                    onTap: () => _onOptionSelected(index),
                    child: AnimatedContainer(
                      duration: const Duration(milliseconds: 200),
                      decoration: BoxDecoration(
                        color: bgColor,
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(color: borderColor, width: 2),
                      ),
                      child: Center(
                        child: Text(
                          _shuffledOptions[index],
                          style: TextStyle(
                            color: textColor,
                            fontSize: 18,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                    ),
                  );
                }),
              ),
            )
          else
            const Spacer(),
          // Feedback de respuesta
          if (_showingResult && _lastAnswerCorrect != null)
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: _lastAnswerCorrect!
                    ? Colors.green.withOpacity(0.1)
                    : Colors.red.withOpacity(0.1),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(
                    _lastAnswerCorrect! ? Icons.check_circle : Icons.cancel,
                    color:
                        _lastAnswerCorrect! ? Colors.green : Colors.red,
                    size: 20,
                  ),
                  const SizedBox(width: 8),
                  Text(
                    _lastAnswerCorrect! ? '¡Correcto!' : 'Incorrecto',
                    style: TextStyle(
                      color: _lastAnswerCorrect!
                          ? Colors.green
                          : Colors.red,
                      fontSize: 15,
                      fontWeight: FontWeight.w600,
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
