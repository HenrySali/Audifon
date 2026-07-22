import 'dart:async';

import 'package:flutter/material.dart';

import '../../../data/services/headphone_calibrator.dart';

/// Paso de calibración de auriculares.
///
/// Guía al usuario para apoyar el auricular sobre el micrófono del celular,
/// ejecuta la calibración automática, y muestra el progreso y resultados.
class CalibrationStep extends StatefulWidget {
  /// Callback cuando la calibración está completa y se puede continuar.
  final VoidCallback onComplete;

  /// Callback para volver al paso anterior.
  final VoidCallback onBack;

  const CalibrationStep({
    super.key,
    required this.onComplete,
    required this.onBack,
  });

  @override
  State<CalibrationStep> createState() => _CalibrationStepState();
}

class _CalibrationStepState extends State<CalibrationStep> {
  final HeadphoneCalibrator _calibrator = HeadphoneCalibrator();

  _CalibrationState _state = _CalibrationState.checking;
  double _progress = 0;
  int _currentFreq = 0;
  double _currentAmplitude = 0;
  bool _isStable = true;
  String? _errorMessage;

  // Resumen de calibración
  Map<int, Map<double, double>>? _calibrationResults;
  DateTime? _calibrationTime;

  @override
  void initState() {
    super.initState();
    _checkExistingCalibration();
  }

  @override
  void dispose() {
    _calibrator.dispose();
    super.dispose();
  }

  Future<void> _checkExistingCalibration() async {
    final calibrated = await _calibrator.isCalibrated();
    if (calibrated) {
      await _calibrator.loadCalibration();
      if (mounted) {
        setState(() {
          _calibrationResults = _calibrator.calibrationTable;
          _calibrationTime = _calibrator.calibrationTimestamp;
          _state = _CalibrationState.alreadyCalibrated;
        });
      }
    } else {
      if (mounted) {
        setState(() => _state = _CalibrationState.instructions);
      }
    }
  }

  Future<void> _startCalibration() async {
    setState(() {
      _state = _CalibrationState.calibrating;
      _progress = 0;
      _errorMessage = null;
    });

    _calibrator.onProgressUpdate = (freq, amplitude, progress) {
      if (mounted) {
        setState(() {
          _currentFreq = freq;
          _currentAmplitude = amplitude;
          _progress = progress;
        });
      }
    };

    _calibrator.onStabilityUpdate = (isStable) {
      if (mounted) {
        setState(() => _isStable = isStable);
      }
    };

    try {
      final success = await _calibrator.calibrate();
      if (mounted) {
        if (success) {
          setState(() {
            _state = _CalibrationState.completed;
            _calibrationResults = _calibrator.calibrationTable;
            _calibrationTime = DateTime.now();
          });
        } else {
          setState(() {
            _state = _CalibrationState.instructions;
            _errorMessage = 'La calibración falló. Intente de nuevo.';
          });
        }
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _state = _CalibrationState.instructions;
          _errorMessage = 'Error: ${e.toString()}';
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      color: const Color(0xFF1a1a2e),
      child: SafeArea(
        child: switch (_state) {
          _CalibrationState.checking => _buildChecking(),
          _CalibrationState.alreadyCalibrated => _buildAlreadyCalibrated(),
          _CalibrationState.instructions => _buildInstructions(),
          _CalibrationState.calibrating => _buildCalibrating(),
          _CalibrationState.completed => _buildCompleted(),
        },
      ),
    );
  }

  Widget _buildChecking() {
    return const Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          CircularProgressIndicator(color: Colors.cyan),
          SizedBox(height: 16),
          Text(
            'Verificando calibración...',
            style: TextStyle(color: Colors.white70, fontSize: 16),
          ),
        ],
      ),
    );
  }

  Widget _buildAlreadyCalibrated() {
    return Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        children: [
          const Spacer(),
          Container(
            padding: const EdgeInsets.all(20),
            decoration: BoxDecoration(
              color: const Color(0xFF16213e),
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: Colors.cyan.withOpacity(0.3)),
            ),
            child: Column(
              children: [
                const Icon(
                  Icons.check_circle,
                  color: Colors.cyan,
                  size: 64,
                ),
                const SizedBox(height: 16),
                const Text(
                  'Auricular ya calibrado',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 20,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const SizedBox(height: 8),
                if (_calibrationTime != null)
                  Text(
                    'Última calibración: ${_formatDate(_calibrationTime!)}',
                    style: const TextStyle(
                      color: Colors.white54,
                      fontSize: 14,
                    ),
                  ),
                const SizedBox(height: 16),
                _buildCalibrationSummary(),
              ],
            ),
          ),
          const Spacer(),
          Row(
            children: [
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: () {
                    setState(() => _state = _CalibrationState.instructions);
                  },
                  icon: const Icon(Icons.refresh, size: 18),
                  label: const Text('Recalibrar'),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: Colors.cyan,
                    side: const BorderSide(color: Colors.cyan),
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                flex: 2,
                child: ElevatedButton.icon(
                  onPressed: widget.onComplete,
                  icon: const Icon(Icons.arrow_forward, size: 18),
                  label: const Text('Continuar al test'),
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

  Widget _buildInstructions() {
    return Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        children: [
          const Spacer(),
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
                  Icons.headphones,
                  color: Colors.cyan,
                  size: 56,
                ),
                const SizedBox(height: 8),
                const Icon(
                  Icons.arrow_downward,
                  color: Colors.cyan,
                  size: 24,
                ),
                const SizedBox(height: 4),
                const Icon(
                  Icons.mic,
                  color: Colors.cyan,
                  size: 40,
                ),
                const SizedBox(height: 20),
                const Text(
                  'Calibración del auricular',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 20,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const SizedBox(height: 12),
                const Text(
                  'Apoye el auricular sobre el micrófono del celular.\n\n'
                  'El sistema emitirá tonos a diferentes volúmenes y '
                  'frecuencias para medir la respuesta real del auricular.',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: Colors.white70,
                    fontSize: 15,
                    height: 1.4,
                  ),
                ),
                const SizedBox(height: 16),
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: Colors.amber.withOpacity(0.1),
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(
                      color: Colors.amber.withOpacity(0.3),
                    ),
                  ),
                  child: const Row(
                    children: [
                      Icon(Icons.info_outline, color: Colors.amber, size: 20),
                      SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          'Asegúrese de estar en un ambiente silencioso.',
                          style: TextStyle(
                            color: Colors.amber,
                            fontSize: 13,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          if (_errorMessage != null) ...[
            const SizedBox(height: 12),
            Text(
              _errorMessage!,
              style: const TextStyle(color: Colors.redAccent, fontSize: 13),
            ),
          ],
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
                  onPressed: _startCalibration,
                  icon: const Icon(Icons.play_arrow, size: 20),
                  label: const Text('Iniciar calibración'),
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

  Widget _buildCalibrating() {
    return Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        children: [
          const Spacer(),
          Container(
            padding: const EdgeInsets.all(24),
            decoration: BoxDecoration(
              color: const Color(0xFF16213e),
              borderRadius: BorderRadius.circular(16),
            ),
            child: Column(
              children: [
                const Text(
                  'Calibrando...',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 20,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const SizedBox(height: 24),
                // Barra de progreso
                ClipRRect(
                  borderRadius: BorderRadius.circular(8),
                  child: LinearProgressIndicator(
                    value: _progress,
                    minHeight: 10,
                    backgroundColor: Colors.white12,
                    valueColor:
                        const AlwaysStoppedAnimation<Color>(Colors.cyan),
                  ),
                ),
                const SizedBox(height: 12),
                Text(
                  '${(_progress * 100).toInt()}%',
                  style: const TextStyle(
                    color: Colors.cyan,
                    fontSize: 16,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 20),
                // Info de frecuencia y amplitud actual
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                  children: [
                    _buildInfoChip(
                      'Frecuencia',
                      '${_currentFreq} Hz',
                      Icons.graphic_eq,
                    ),
                    _buildInfoChip(
                      'Amplitud',
                      _currentAmplitude.toStringAsFixed(2),
                      Icons.volume_up,
                    ),
                  ],
                ),
                const SizedBox(height: 16),
                // Indicador de estabilidad
                AnimatedContainer(
                  duration: const Duration(milliseconds: 300),
                  padding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 8,
                  ),
                  decoration: BoxDecoration(
                    color: _isStable
                        ? Colors.green.withOpacity(0.15)
                        : Colors.orange.withOpacity(0.15),
                    borderRadius: BorderRadius.circular(20),
                    border: Border.all(
                      color: _isStable
                          ? Colors.green.withOpacity(0.5)
                          : Colors.orange.withOpacity(0.5),
                    ),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        _isStable ? Icons.check_circle : Icons.warning,
                        color: _isStable ? Colors.green : Colors.orange,
                        size: 18,
                      ),
                      const SizedBox(width: 8),
                      Text(
                        _isStable
                            ? 'Medición estable'
                            : 'Acerque más el auricular',
                        style: TextStyle(
                          color: _isStable ? Colors.green : Colors.orange,
                          fontSize: 13,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          const Spacer(),
          const Text(
            'No mueva el auricular durante la calibración',
            style: TextStyle(color: Colors.white38, fontSize: 13),
          ),
        ],
      ),
    );
  }

  Widget _buildCompleted() {
    return Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        children: [
          const Spacer(),
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
                  Icons.check_circle,
                  color: Colors.greenAccent,
                  size: 64,
                ),
                const SizedBox(height: 16),
                const Text(
                  'Calibración completada ✓',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 20,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const SizedBox(height: 16),
                _buildCalibrationSummary(),
              ],
            ),
          ),
          const Spacer(),
          SizedBox(
            width: double.infinity,
            child: ElevatedButton.icon(
              onPressed: widget.onComplete,
              icon: const Icon(Icons.arrow_forward, size: 18),
              label: const Text('Continuar al test'),
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
    );
  }

  Widget _buildCalibrationSummary() {
    if (_calibrationResults == null) return const SizedBox.shrink();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          'Niveles medidos (dB SPL @ amplitud 0.3):',
          style: TextStyle(color: Colors.white54, fontSize: 12),
        ),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          runSpacing: 6,
          children: _calibrationResults!.entries.map((entry) {
            final spl = entry.value[0.3];
            final splText =
                spl != null ? '${spl.toStringAsFixed(0)} dB' : '—';
            return Container(
              padding: const EdgeInsets.symmetric(
                horizontal: 10,
                vertical: 4,
              ),
              decoration: BoxDecoration(
                color: Colors.cyan.withOpacity(0.1),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: Colors.cyan.withOpacity(0.3)),
              ),
              child: Text(
                '${entry.key} Hz: $splText',
                style: const TextStyle(
                  color: Colors.cyan,
                  fontSize: 12,
                  fontWeight: FontWeight.w500,
                ),
              ),
            );
          }).toList(),
        ),
      ],
    );
  }

  Widget _buildInfoChip(String label, String value, IconData icon) {
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
            fontSize: 15,
            fontWeight: FontWeight.w600,
          ),
        ),
      ],
    );
  }

  String _formatDate(DateTime date) {
    return '${date.day}/${date.month}/${date.year} '
        '${date.hour.toString().padLeft(2, '0')}:'
        '${date.minute.toString().padLeft(2, '0')}';
  }
}

enum _CalibrationState {
  checking,
  alreadyCalibrated,
  instructions,
  calibrating,
  completed,
}
