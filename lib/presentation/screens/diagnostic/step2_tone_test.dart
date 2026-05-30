import 'dart:async';
import 'dart:math';

import 'package:flutter/material.dart';

import '../../../data/services/headphone_calibrator.dart';
import '../../../data/services/tone_generator.dart';
import '../../../domain/entities/diagnostic_result.dart';

/// Paso 2: Test de Tonos Puros — Audiometría Calibrada (ISO 8253-1).
///
/// Usa la tabla de calibración del auricular para emitir niveles reales
/// en dB SPL. Método ASCENDENTE: empieza en 10 dB SPL, sube de 5 en 5.
/// Umbral = nivel más bajo donde el usuario responde 2 de 3 veces.
///
/// Frecuencias: 500, 1000, 2000, 3000, 4000, 8000 Hz.
/// Evalúa cada oído por separado.
///
/// Máximos por frecuencia:
///  - Frecuencias bajas (< 1 kHz, p.ej. 500 Hz): hasta 50 dB SPL.
///  - Frecuencias medias y altas (≥ 1 kHz): hasta 70 dB SPL — permite
///    detectar pérdidas en agudos sin saturar el auricular.
/// Si no detecta al máximo, marca "no detectado".
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
  final ToneGenerator _toneGenerator = ToneGenerator();
  final HeadphoneCalibrator _calibrator = HeadphoneCalibrator();

  // Estado del test
  _TestState _testState = _TestState.loading;
  bool _isCalibrated = false;

  // Parámetros del método ascendente ISO 8253-1
  static const double _startLevelDbSpl = 10.0;
  static const double _stepSizeDb = 5.0;
  // Máximo por frecuencia: bajas (< 1 kHz) hasta 50 dB SPL,
  // medias y altas (≥ 1 kHz) hasta 70 dB SPL.
  // Esto refleja la práctica clínica donde las pérdidas en frecuencias
  // medias/altas requieren mayor margen para detectar el umbral.
  static const double _maxLevelLowFreqDbSpl = 50.0;
  static const double _maxLevelHighFreqDbSpl = 70.0;
  static const int _highFreqThresholdHz = 1000;
  static const int _requiredResponses = 2; // de 3 presentaciones
  static const int _presentationsPerLevel = 3;

  /// Máximo nivel testeable para la frecuencia actual.
  double get _currentMaxLevelDbSpl => _currentFrequency >= _highFreqThresholdHz
      ? _maxLevelHighFreqDbSpl
      : _maxLevelLowFreqDbSpl;

  // Estado de la prueba actual
  int _currentEarIndex = 0; // 0 = derecho, 1 = izquierdo
  int _currentFreqIndex = 0;
  double _currentLevelDbSpl = _startLevelDbSpl;
  int _responsesAtCurrentLevel = 0;
  int _presentationsAtCurrentLevel = 0;

  bool _isPlayingTone = false;
  bool _waitingForResponse = false;

  Timer? _toneTimer;
  Timer? _responseTimer;

  // Resultados
  final Map<int, double> _rightEarThresholds = {};
  final Map<int, double> _leftEarThresholds = {};

  // Constantes de timing
  static const Duration _toneDuration = Duration(milliseconds: 1500);
  static const Duration _responseTimeout = Duration(seconds: 4);
  static const Duration _interToneDelay = Duration(milliseconds: 800);

  static const List<String> _earLabels = ['Derecho', 'Izquierdo'];

  @override
  void initState() {
    super.initState();
    _initializeCalibration();
  }

  @override
  void dispose() {
    _toneTimer?.cancel();
    _responseTimer?.cancel();
    _toneGenerator.dispose();
    _calibrator.dispose();
    super.dispose();
  }

  List<int> get _frequencies => DiagnosticResult.testFrequencies;
  String get _currentEarLabel => _earLabels[_currentEarIndex];
  int get _currentFrequency => _frequencies[_currentFreqIndex];
  int get _totalTests => _frequencies.length * 2;
  int get _completedTests =>
      _currentEarIndex * _frequencies.length + _currentFreqIndex;
  double get _progress => _completedTests / _totalTests;

  Future<void> _initializeCalibration() async {
    final calibrated = await _calibrator.isCalibrated();
    if (calibrated) {
      await _calibrator.loadCalibration();
    }
    if (mounted) {
      setState(() {
        _isCalibrated = calibrated;
        _testState = _TestState.ready;
      });
    }
  }

  void _startTest() {
    setState(() {
      _testState = _TestState.testing;
      _currentEarIndex = 0;
      _currentFreqIndex = 0;
      _currentLevelDbSpl = _startLevelDbSpl;
      _responsesAtCurrentLevel = 0;
      _presentationsAtCurrentLevel = 0;
      _rightEarThresholds.clear();
      _leftEarThresholds.clear();
    });
    _playCurrentTone();
  }

  void _playCurrentTone() {
    setState(() {
      _isPlayingTone = true;
      _waitingForResponse = false;
    });

    // Obtener amplitud calibrada para el nivel actual en dB SPL
    final amplitude = _isCalibrated
        ? _calibrator.getAmplitudeForLevel(
            _currentFrequency, _currentLevelDbSpl)
        : _estimateAmplitudeUncalibrated(_currentLevelDbSpl);

    // Convertir amplitud lineal al levelDb que espera ToneGenerator
    final levelDb = _amplitudeToToneGeneratorLevel(amplitude);

    final ear = _currentEarIndex == 0 ? 'right' : 'left';
    _toneGenerator.playTone(
      frequencyHz: _currentFrequency,
      levelDb: levelDb,
      ear: ear,
    );

    _toneTimer = Timer(_toneDuration, () {
      if (mounted) {
        _toneGenerator.stop();
        setState(() {
          _isPlayingTone = false;
          _waitingForResponse = true;
        });
        // Timeout: si no responde, cuenta como "no escuchó"
        _responseTimer = Timer(_responseTimeout, () {
          if (mounted) _onNotHeard();
        });
      }
    });
  }

  /// El usuario indica que escuchó el tono.
  void _onHeard() {
    _responseTimer?.cancel();
    setState(() {
      _responsesAtCurrentLevel++;
      _presentationsAtCurrentLevel++;
    });

    _evaluateLevel();
  }

  /// El usuario no respondió (timeout) o indica que no escuchó.
  void _onNotHeard() {
    _responseTimer?.cancel();
    setState(() {
      _presentationsAtCurrentLevel++;
    });

    _evaluateLevel();
  }

  /// Evalúa si se alcanzó el criterio de umbral en el nivel actual.
  void _evaluateLevel() {
    // Optimización: si ya tiene 2 respuestas, umbral encontrado
    if (_responsesAtCurrentLevel >= _requiredResponses) {
      _recordThreshold(_currentLevelDbSpl);
      return;
    }

    // ¿Ya se completaron las presentaciones para este nivel?
    if (_presentationsAtCurrentLevel >= _presentationsPerLevel) {
      // No alcanzó el criterio → subir nivel
      _ascendLevel();
      return;
    }

    // Optimización: si ya es imposible alcanzar 2 respuestas
    final remaining =
        _presentationsPerLevel - _presentationsAtCurrentLevel;
    if (_responsesAtCurrentLevel + remaining < _requiredResponses) {
      _ascendLevel();
      return;
    }

    // Continuar presentando al mismo nivel
    Future.delayed(_interToneDelay, () {
      if (mounted && _testState == _TestState.testing) {
        _playCurrentTone();
      }
    });
  }

  /// Sube el nivel 5 dB SPL.
  void _ascendLevel() {
    final nextLevel = _currentLevelDbSpl + _stepSizeDb;
    final maxLevel = _currentMaxLevelDbSpl;

    if (nextLevel > maxLevel) {
      // No detectado al máximo nivel para esta frecuencia
      _recordThreshold(-1); // -1 indica "no detectado"
      return;
    }

    setState(() {
      _currentLevelDbSpl = nextLevel;
      _responsesAtCurrentLevel = 0;
      _presentationsAtCurrentLevel = 0;
    });

    Future.delayed(_interToneDelay, () {
      if (mounted && _testState == _TestState.testing) {
        _playCurrentTone();
      }
    });
  }

  /// Registra el umbral para la frecuencia y oído actual.
  void _recordThreshold(double thresholdDbSpl) {
    final freq = _currentFrequency;
    // Si es -1 (no detectado), usar el máximo testeado + 5 dB como marcador
    // de "peor que el límite" para esa frecuencia.
    final value = thresholdDbSpl < 0
        ? _currentMaxLevelDbSpl + 5.0
        : thresholdDbSpl;

    setState(() {
      if (_currentEarIndex == 0) {
        _rightEarThresholds[freq] = value;
      } else {
        _leftEarThresholds[freq] = value;
      }
    });

    _advanceToNext();
  }

  /// Avanza a la siguiente frecuencia u oído.
  void _advanceToNext() {
    if (_currentFreqIndex < _frequencies.length - 1) {
      // Siguiente frecuencia
      setState(() {
        _currentFreqIndex++;
        _currentLevelDbSpl = _startLevelDbSpl;
        _responsesAtCurrentLevel = 0;
        _presentationsAtCurrentLevel = 0;
      });
      Future.delayed(const Duration(milliseconds: 1000), () {
        if (mounted && _testState == _TestState.testing) {
          _playCurrentTone();
        }
      });
    } else if (_currentEarIndex == 0) {
      // Cambiar al oído izquierdo
      setState(() {
        _currentEarIndex = 1;
        _currentFreqIndex = 0;
        _currentLevelDbSpl = _startLevelDbSpl;
        _responsesAtCurrentLevel = 0;
        _presentationsAtCurrentLevel = 0;
      });
      Future.delayed(const Duration(seconds: 2), () {
        if (mounted && _testState == _TestState.testing) {
          _playCurrentTone();
        }
      });
    } else {
      // Test completo
      _finishTest();
    }
  }

  void _finishTest() {
    setState(() => _testState = _TestState.completed);
    widget.onComplete(_leftEarThresholds, _rightEarThresholds);
  }

  /// Estimación de amplitud sin calibración (fallback).
  /// Asume que amplitud 0.5 produce ~70 dB SPL en un auricular típico.
  double _estimateAmplitudeUncalibrated(double targetDbSpl) {
    // dB SPL ≈ 20*log10(amplitude) + 94
    // amplitude = 10^((targetDbSpl - 94) / 20)
    final amplitude = pow(10, (targetDbSpl - 94) / 20).toDouble();
    return amplitude.clamp(0.001, 0.9);
  }

  /// Convierte amplitud lineal (0-1) al levelDb (0-80) del ToneGenerator.
  ///
  /// Inversa de ToneGenerator._dbToAmplitude:
  ///   amplitude = 0.9 * pow(10, (normalized - 1) * 2)
  ///   donde normalized = levelDb / 80
  double _amplitudeToToneGeneratorLevel(double amplitude) {
    if (amplitude <= 0) return 0;
    final ratio = amplitude / 0.9;
    if (ratio <= 0) return 0;
    final log10Ratio = log(ratio) / ln10;
    final normalized = log10Ratio / 2 + 1;
    return (normalized * 80).clamp(0.0, 80.0);
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      color: const Color(0xFF1a1a2e),
      child: SafeArea(
        child: switch (_testState) {
          _TestState.loading => _buildLoading(),
          _TestState.ready => _buildReady(),
          _TestState.testing => _buildTesting(),
          _TestState.completed => _buildCompleted(),
        },
      ),
    );
  }

  Widget _buildLoading() {
    return const Center(
      child: CircularProgressIndicator(color: Colors.cyan),
    );
  }

  Widget _buildReady() {
    return Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        children: [
          const Spacer(),
          if (!_isCalibrated) ...[
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: Colors.orange.withOpacity(0.1),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: Colors.orange.withOpacity(0.4)),
              ),
              child: const Row(
                children: [
                  Icon(Icons.warning_amber, color: Colors.orange, size: 28),
                  SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Sin calibración',
                          style: TextStyle(
                            color: Colors.orange,
                            fontSize: 15,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        SizedBox(height: 4),
                        Text(
                          'Los resultados serán aproximados. '
                          'Se recomienda calibrar el auricular primero.',
                          style: TextStyle(
                            color: Colors.orange,
                            fontSize: 13,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 24),
          ],
          Container(
            padding: const EdgeInsets.all(24),
            decoration: BoxDecoration(
              color: const Color(0xFF16213e),
              borderRadius: BorderRadius.circular(16),
            ),
            child: Column(
              children: [
                const Icon(
                  Icons.hearing,
                  color: Colors.cyan,
                  size: 48,
                ),
                const SizedBox(height: 16),
                const Text(
                  'Test de Tonos Puros',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 20,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const SizedBox(height: 12),
                Text(
                  'Se evaluará cada oído por separado.\n'
                  'Escuchará tonos a diferentes frecuencias.\n'
                  'Presione "Escucho" cada vez que oiga un tono.\n\n'
                  'Método: ascendente (ISO 8253-1)\n'
                  'Rango: 10–50 dB SPL en bajas / 10–70 dB SPL en ≥1 kHz'
                  '${_isCalibrated ? ' (calibrado)' : ''}',
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    color: Colors.white70,
                    fontSize: 14,
                    height: 1.5,
                  ),
                ),
              ],
            ),
          ),
          const Spacer(),
          Row(
            children: [
              IconButton(
                onPressed: widget.onBack,
                icon: const Icon(Icons.arrow_back, color: Colors.white70),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: ElevatedButton.icon(
                  onPressed: _startTest,
                  icon: const Icon(Icons.play_arrow, size: 20),
                  label: const Text('Iniciar test'),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.cyan,
                    foregroundColor: Colors.black,
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildTesting() {
    return Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        children: [
          // Progreso
          _buildProgressHeader(),
          const SizedBox(height: 24),
          // Info del tono actual
          Container(
            padding: const EdgeInsets.all(20),
            decoration: BoxDecoration(
              color: const Color(0xFF16213e),
              borderRadius: BorderRadius.circular(16),
            ),
            child: Column(
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                  children: [
                    _buildMetric(
                      'Oído',
                      _currentEarLabel,
                      Icons.hearing,
                    ),
                    _buildMetric(
                      'Frecuencia',
                      '${_currentFrequency} Hz',
                      Icons.graphic_eq,
                    ),
                    _buildMetric(
                      'Nivel',
                      '${_currentLevelDbSpl.toInt()} dB SPL',
                      Icons.volume_up,
                    ),
                  ],
                ),
                const SizedBox(height: 16),
                // Indicador visual del tono
                AnimatedContainer(
                  duration: const Duration(milliseconds: 200),
                  height: 60,
                  decoration: BoxDecoration(
                    color: _isPlayingTone
                        ? Colors.cyan.withOpacity(0.2)
                        : Colors.transparent,
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(
                      color: _isPlayingTone
                          ? Colors.cyan
                          : Colors.white12,
                      width: _isPlayingTone ? 2 : 1,
                    ),
                  ),
                  child: Center(
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          _isPlayingTone
                              ? Icons.music_note
                              : Icons.music_off,
                          color: _isPlayingTone
                              ? Colors.cyan
                              : Colors.white24,
                          size: 24,
                        ),
                        const SizedBox(width: 8),
                        Text(
                          _isPlayingTone
                              ? '♪ Tono sonando...'
                              : _waitingForResponse
                                  ? '¿Lo escuchó?'
                                  : 'Preparando...',
                          style: TextStyle(
                            color: _isPlayingTone
                                ? Colors.cyan
                                : Colors.white54,
                            fontSize: 15,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
          const Spacer(),
          // Botón de respuesta
          SizedBox(
            width: double.infinity,
            height: 80,
            child: ElevatedButton.icon(
              onPressed:
                  (_isPlayingTone || _waitingForResponse) ? _onHeard : null,
              icon: const Icon(Icons.hearing, size: 28),
              label: const Text(
                '¡Escucho!',
                style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
              ),
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.cyan,
                foregroundColor: Colors.black,
                disabledBackgroundColor: Colors.white12,
                disabledForegroundColor: Colors.white24,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(16),
                ),
              ),
            ),
          ),
          const SizedBox(height: 12),
          Text(
            'Presentación ${_presentationsAtCurrentLevel + 1}/$_presentationsPerLevel '
            '• Respuestas: $_responsesAtCurrentLevel/$_requiredResponses',
            style: const TextStyle(color: Colors.white38, fontSize: 12),
          ),
        ],
      ),
    );
  }

  Widget _buildCompleted() {
    return const Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.check_circle, color: Colors.greenAccent, size: 48),
          SizedBox(height: 12),
          Text(
            'Test de tonos completado',
            style: TextStyle(color: Colors.white, fontSize: 18),
          ),
        ],
      ),
    );
  }

  Widget _buildProgressHeader() {
    return Column(
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(
              'Oído $_currentEarLabel',
              style: const TextStyle(
                color: Colors.white,
                fontSize: 16,
                fontWeight: FontWeight.w600,
              ),
            ),
            Text(
              '${_completedTests + 1} / $_totalTests',
              style: const TextStyle(color: Colors.white54, fontSize: 14),
            ),
          ],
        ),
        const SizedBox(height: 8),
        ClipRRect(
          borderRadius: BorderRadius.circular(4),
          child: LinearProgressIndicator(
            value: _progress,
            minHeight: 6,
            backgroundColor: Colors.white12,
            valueColor: const AlwaysStoppedAnimation<Color>(Colors.cyan),
          ),
        ),
      ],
    );
  }

  Widget _buildMetric(String label, String value, IconData icon) {
    return Column(
      children: [
        Icon(icon, color: Colors.white38, size: 20),
        const SizedBox(height: 4),
        Text(
          label,
          style: const TextStyle(color: Colors.white38, fontSize: 11),
        ),
        const SizedBox(height: 2),
        Text(
          value,
          style: const TextStyle(
            color: Colors.white,
            fontSize: 13,
            fontWeight: FontWeight.w600,
          ),
        ),
      ],
    );
  }
}

enum _TestState {
  loading,
  ready,
  testing,
  completed,
}
