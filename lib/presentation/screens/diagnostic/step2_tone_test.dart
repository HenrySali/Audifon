import 'dart:async';

import 'package:flutter/material.dart';

import '../../../domain/entities/diagnostic_result.dart';

/// Paso 2: Test de Tonos Puros.
///
/// Reproduce tonos puros a 6 frecuencias: 500, 1000, 2000, 3000, 4000, 8000 Hz.
/// Método descendente: empieza a 70 dB, baja de 10 en 10 hasta que no escuche,
/// luego sube de 5 en 5 hasta que escuche de nuevo.
/// Evalúa cada oído por separado.
class Step2ToneTest extends StatefulWidget {
  final void Function(
    Map<int, double> leftThresholds,
    Map<int, double> rightThresholds,
  ) onComplete;
  final VoidCallback onBack;

  const Step2ToneTest({
    super.key,
    required this.onComplete,
    required this.onBack,
  });

  @override
  State<Step2ToneTest> createState() => _Step2ToneTestState();
}

class _Step2ToneTestState extends State<Step2ToneTest> {
  // Estado del test
  bool _testStarted = false;
  bool _isPlayingTone = false;
  bool _waitingForResponse = false;

  // Oído actual: 0 = derecho, 1 = izquierdo
  int _currentEarIndex = 0;
  static const List<String> _earLabels = ['Derecho', 'Izquierdo'];

  // Frecuencia actual
  int _currentFreqIndex = 0;

  // Nivel actual en dB HL
  double _currentLevel = 70.0;

  // Fase del método: 'descending' o 'ascending'
  String _phase = 'descending';

  // Nivel donde dejó de escuchar (para fase ascendente)
  double _lastNotHeardLevel = 70.0;

  // Resultados
  final Map<int, double> _leftThresholds = {};
  final Map<int, double> _rightThresholds = {};

  // Timer para reproducción de tono
  Timer? _toneTimer;
  Timer? _responseTimer;

  // Constantes del test
  static const double _startLevel = 70.0;
  static const double _descendStep = 10.0;
  static const double _ascendStep = 5.0;
  static const double _minLevel = 0.0;
  static const double _maxLevel = 80.0;
  static const Duration _toneDuration = Duration(milliseconds: 1500);
  static const Duration _responseTimeout = Duration(seconds: 4);

  @override
  void dispose() {
    _toneTimer?.cancel();
    _responseTimer?.cancel();
    super.dispose();
  }

  List<int> get _frequencies => DiagnosticResult.testFrequencies;

  String get _currentEarLabel => _earLabels[_currentEarIndex];

  int get _currentFrequency => _frequencies[_currentFreqIndex];

  int get _totalTests => _frequencies.length * 2; // 2 oídos

  int get _completedTests =>
      _currentEarIndex * _frequencies.length + _currentFreqIndex;

  double get _progress => _completedTests / _totalTests;

  void _startTest() {
    setState(() {
      _testStarted = true;
      _currentEarIndex = 0;
      _currentFreqIndex = 0;
      _currentLevel = _startLevel;
      _phase = 'descending';
    });
    _playTone();
  }

  void _playTone() {
    setState(() {
      _isPlayingTone = true;
      _waitingForResponse = false;
    });

    // TODO: implement tone generation
    // Aquí se generaría un tono sinusoidal puro a _currentFrequency Hz
    // con nivel _currentLevel dB HL, en el oído _currentEarLabel.
    // Duración: 1.5 segundos.

    _toneTimer = Timer(_toneDuration, () {
      if (mounted) {
        setState(() {
          _isPlayingTone = false;
          _waitingForResponse = true;
        });
        // Iniciar timeout de respuesta
        _responseTimer = Timer(_responseTimeout, () {
          if (mounted) {
            _onNotHeard();
          }
        });
      }
    });
  }

  /// El usuario indica que escuchó el tono.
  void _onHeard() {
    _responseTimer?.cancel();

    if (_phase == 'descending') {
      // En fase descendente: bajar nivel
      if (_currentLevel - _descendStep >= _minLevel) {
        setState(() => _currentLevel -= _descendStep);
        _playTone();
      } else {
        // Llegamos al mínimo sin dejar de escuchar
        _recordThreshold(_currentLevel);
      }
    } else {
      // En fase ascendente: el umbral es este nivel
      _recordThreshold(_currentLevel);
    }
  }

  /// El usuario indica que NO escuchó el tono (o timeout).
  void _onNotHeard() {
    _responseTimer?.cancel();

    if (_phase == 'descending') {
      // Cambiar a fase ascendente
      setState(() {
        _lastNotHeardLevel = _currentLevel;
        _phase = 'ascending';
        _currentLevel += _ascendStep;
      });
      if (_currentLevel <= _maxLevel) {
        _playTone();
      } else {
        _recordThreshold(_maxLevel);
      }
    } else {
      // En fase ascendente: subir nivel
      if (_currentLevel + _ascendStep <= _maxLevel) {
        setState(() => _currentLevel += _ascendStep);
        _playTone();
      } else {
        // No escucha ni al máximo
        _recordThreshold(_maxLevel);
      }
    }
  }

  void _recordThreshold(double threshold) {
    final freq = _currentFrequency;

    setState(() {
      if (_currentEarIndex == 0) {
        _rightThresholds[freq] = threshold;
      } else {
        _leftThresholds[freq] = threshold;
      }
    });

    // Avanzar a siguiente frecuencia u oído
    _advanceToNext();
  }

  void _advanceToNext() {
    if (_currentFreqIndex < _frequencies.length - 1) {
      // Siguiente frecuencia
      setState(() {
        _currentFreqIndex++;
        _currentLevel = _startLevel;
        _phase = 'descending';
      });
      // Pequeña pausa entre frecuencias
      Future.delayed(const Duration(milliseconds: 800), () {
        if (mounted) _playTone();
      });
    } else if (_currentEarIndex == 0) {
      // Cambiar al oído izquierdo
      setState(() {
        _currentEarIndex = 1;
        _currentFreqIndex = 0;
        _currentLevel = _startLevel;
        _phase = 'descending';
      });
      Future.delayed(const Duration(milliseconds: 1000), () {
        if (mounted) _playTone();
      });
    } else {
      // Test completado
      _finishTest();
    }
  }

  void _finishTest() {
    widget.onComplete(_leftThresholds, _rightThresholds);
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
                  Icons.headphones,
                  size: 64,
                  color: Colors.cyan,
                ),
                const SizedBox(height: 24),
                const Text(
                  'Test de Tonos Puros',
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
                      _InstructionItem(
                        number: '1',
                        text: 'Colóquese los auriculares en un lugar silencioso.',
                      ),
                      _InstructionItem(
                        number: '2',
                        text: 'Escuchará tonos a diferentes frecuencias y volúmenes.',
                      ),
                      _InstructionItem(
                        number: '3',
                        text:
                            'Presione "Escucho" cada vez que oiga un tono, por débil que sea.',
                      ),
                      _InstructionItem(
                        number: '4',
                        text:
                            'Si no escucha nada, presione "No escucho" o espere 4 segundos.',
                      ),
                      _InstructionItem(
                        number: '5',
                        text: 'Se evaluará cada oído por separado.',
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 16),
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: Colors.orange.withOpacity(0.1),
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(
                      color: Colors.orange.withOpacity(0.3),
                    ),
                  ),
                  child: const Row(
                    children: [
                      Icon(Icons.warning_amber, color: Colors.orange, size: 20),
                      SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          'Use auriculares para resultados precisos. '
                          'Asegúrese de estar en un ambiente silencioso.',
                          style: TextStyle(
                            color: Colors.orange,
                            fontSize: 12,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
        // Botones
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
    return Column(
      children: [
        Expanded(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              children: [
                // Progreso del test
                LinearProgressIndicator(
                  value: _progress,
                  backgroundColor: Colors.white12,
                  color: Colors.cyan,
                  minHeight: 6,
                ),
                const SizedBox(height: 16),
                // Info del oído actual
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(
                      _currentEarIndex == 0
                          ? Icons.hearing
                          : Icons.hearing,
                      color: _currentEarIndex == 0
                          ? Colors.red.shade300
                          : Colors.blue.shade300,
                      size: 24,
                    ),
                    const SizedBox(width: 8),
                    Text(
                      'Oído $_currentEarLabel',
                      style: TextStyle(
                        color: _currentEarIndex == 0
                            ? Colors.red.shade300
                            : Colors.blue.shade300,
                        fontSize: 18,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 24),
                // Frecuencia actual
                Container(
                  padding: const EdgeInsets.all(20),
                  decoration: BoxDecoration(
                    color: const Color(0xFF16213e),
                    borderRadius: BorderRadius.circular(16),
                    border: Border.all(
                      color: Colors.cyan.withOpacity(0.3),
                    ),
                  ),
                  child: Column(
                    children: [
                      Text(
                        '${_currentFrequency} Hz',
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 32,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        'Nivel: ${_currentLevel.toStringAsFixed(0)} dB',
                        style: const TextStyle(
                          color: Colors.white54,
                          fontSize: 16,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        'Fase: ${_phase == 'descending' ? 'Descendente' : 'Ascendente'}',
                        style: TextStyle(
                          color: Colors.cyan.withOpacity(0.7),
                          fontSize: 13,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 32),
                // Indicador de estado
                if (_isPlayingTone)
                  _TonePlayingIndicator()
                else if (_waitingForResponse)
                  const Text(
                    '¿Escuchó el tono?',
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 18,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                const Spacer(),
                // Botones de respuesta
                Row(
                  children: [
                    Expanded(
                      child: SizedBox(
                        height: 64,
                        child: ElevatedButton.icon(
                          onPressed:
                              (_waitingForResponse || _isPlayingTone)
                                  ? _onHeard
                                  : null,
                          icon: const Icon(Icons.check, size: 28),
                          label: const Text(
                            'Escucho',
                            style: TextStyle(fontSize: 16),
                          ),
                          style: ElevatedButton.styleFrom(
                            backgroundColor: Colors.green.shade700,
                            disabledBackgroundColor:
                                Colors.green.withOpacity(0.2),
                            foregroundColor: Colors.white,
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(16),
                            ),
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(width: 16),
                    Expanded(
                      child: SizedBox(
                        height: 64,
                        child: ElevatedButton.icon(
                          onPressed: _waitingForResponse ? _onNotHeard : null,
                          icon: const Icon(Icons.close, size: 28),
                          label: const Text(
                            'No escucho',
                            style: TextStyle(fontSize: 16),
                          ),
                          style: ElevatedButton.styleFrom(
                            backgroundColor: Colors.red.shade700,
                            disabledBackgroundColor:
                                Colors.red.withOpacity(0.2),
                            foregroundColor: Colors.white,
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(16),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

/// Indicador visual de que se está reproduciendo un tono.
class _TonePlayingIndicator extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        const SizedBox(
          width: 48,
          height: 48,
          child: CircularProgressIndicator(
            strokeWidth: 3,
            color: Colors.cyan,
          ),
        ),
        const SizedBox(height: 12),
        Text(
          'Reproduciendo tono...',
          style: TextStyle(
            color: Colors.cyan.withOpacity(0.8),
            fontSize: 15,
          ),
        ),
      ],
    );
  }
}

/// Item de instrucción numerado.
class _InstructionItem extends StatelessWidget {
  final String number;
  final String text;

  const _InstructionItem({required this.number, required this.text});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 22,
            height: 22,
            decoration: BoxDecoration(
              color: Colors.cyan.withOpacity(0.2),
              shape: BoxShape.circle,
            ),
            child: Center(
              child: Text(
                number,
                style: const TextStyle(
                  color: Colors.cyan,
                  fontSize: 12,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              text,
              style: const TextStyle(color: Colors.white70, fontSize: 13),
            ),
          ),
        ],
      ),
    );
  }
}
