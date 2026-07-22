import 'dart:async';
import 'package:flutter/material.dart';
import '../../data/bridges/audio_bridge.dart';
import '../../domain/entities/calibration_data.dart';
import '../../domain/repositories/settings_repository.dart';

/// Frecuencias del sweep de calibración de auriculares (Hz).
const List<int> kCalibrationFrequencies = [
  250, 500, 750, 1000, 1500, 2000,
  2500, 3000, 3500, 4000, 6000, 8000,
];

/// Método de calibración del micrófono.
enum MicCalibrationMethod {
  externalRef,
  phoneModel,
  selfTest,
}

/// Fase del flujo de calibración.
enum _CalibrationPhase {
  /// Pantalla principal: muestra estado y opciones de calibración.
  home,

  /// Wizard de calibración del micrófono.
  micCalibration,

  /// Wizard de calibración de auriculares.
  headphoneCalibration,
}

/// Pantalla principal del flujo de calibración.
///
/// Implementa un wizard de calibración con dos etapas:
/// 1. Calibración del micrófono (3 métodos: referencia externa, BD modelo, auto-test)
/// 2. Calibración de auriculares (sweep loopback 250-8000 Hz)
///
/// Almacena calibración por dispositivo (MAC BT o "wired_default").
/// Ofrece recalibración cuando se detectan nuevos auriculares.
///
/// Requisitos: Calibración del Sistema (micrófono + auriculares)
class CalibrationScreen extends StatefulWidget {
  final AudioBridge audioBridge;
  final SettingsRepository settingsRepository;

  /// ID del auricular actualmente conectado (MAC BT o null para cable).
  final String? connectedHeadphoneId;

  /// Nombre del auricular conectado.
  final String? connectedHeadphoneName;

  /// Si es Bluetooth.
  final bool isBluetoothConnected;

  const CalibrationScreen({
    super.key,
    required this.audioBridge,
    required this.settingsRepository,
    this.connectedHeadphoneId,
    this.connectedHeadphoneName,
    this.isBluetoothConnected = false,
  });

  @override
  State<CalibrationScreen> createState() => _CalibrationScreenState();
}

class _CalibrationScreenState extends State<CalibrationScreen> {
  _CalibrationPhase _phase = _CalibrationPhase.home;
  CalibrationData? _calibrationData;
  bool _loading = true;

  // Mic calibration state
  MicCalibrationMethod? _selectedMicMethod;
  int _micStep = 0; // 0=method select, 1=instructions, 2=measuring, 3=result
  MicCalibrationResult? _micResult;
  String? _micError;
  bool _micMeasuring = false;

  // Headphone calibration state
  int _hpStep = 0; // 0=instructions, 1=sweep in progress, 2=result
  HeadphoneCalibrationResult? _hpResult;
  String? _hpError;
  bool _hpMeasuring = false;
  int _sweepProgress = 0; // 0-12 frequencies completed

  // Recalibration detection
  bool _newHeadphoneDetected = false;

  @override
  void initState() {
    super.initState();
    _loadCalibrationData();
  }

  Future<void> _loadCalibrationData() async {
    setState(() => _loading = true);
    try {
      _calibrationData = await widget.settingsRepository.getCalibrationData();
      // Check if current headphone needs calibration
      if (_calibrationData != null) {
        final hpCal = _calibrationData!
            .getActiveHeadphoneCalibration(widget.connectedHeadphoneId);
        if (hpCal == null && _effectiveHeadphoneId.isNotEmpty) {
          _newHeadphoneDetected = true;
        }
      }
    } catch (_) {
      _calibrationData = null;
    }
    setState(() => _loading = false);
  }

  String get _effectiveHeadphoneId =>
      widget.connectedHeadphoneId ?? 'wired_default';

  String get _effectiveHeadphoneName =>
      widget.connectedHeadphoneName ??
      (widget.isBluetoothConnected ? 'Bluetooth' : 'Auriculares con cable');

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Calibración del Sistema'),
        backgroundColor: const Color(0xFF0f3460),
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: () {
            if (_phase != _CalibrationPhase.home) {
              setState(() {
                _phase = _CalibrationPhase.home;
                _resetMicState();
                _resetHpState();
              });
            } else {
              Navigator.of(context).pop();
            }
          },
        ),
      ),
      backgroundColor: const Color(0xFF1a1a2e),
      body: _loading
          ? const Center(child: CircularProgressIndicator(color: Colors.cyan))
          : _buildPhaseContent(),
    );
  }

  void _resetMicState() {
    _selectedMicMethod = null;
    _micStep = 0;
    _micResult = null;
    _micError = null;
    _micMeasuring = false;
  }

  void _resetHpState() {
    _hpStep = 0;
    _hpResult = null;
    _hpError = null;
    _hpMeasuring = false;
    _sweepProgress = 0;
  }

  Widget _buildPhaseContent() {
    switch (_phase) {
      case _CalibrationPhase.home:
        return _buildHome();
      case _CalibrationPhase.micCalibration:
        return _buildMicCalibration();
      case _CalibrationPhase.headphoneCalibration:
        return _buildHeadphoneCalibration();
    }
  }

  // ═══════════════════════════════════════════════════════════════════════════
  // HOME — Calibration status and options
  // ═══════════════════════════════════════════════════════════════════════════

  Widget _buildHome() {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // New headphone detected banner
          if (_newHeadphoneDetected) _buildNewHeadphoneBanner(),

          // Current calibration status
          _buildCalibrationStatus(),

          const SizedBox(height: 24),

          // Calibrate Microphone button
          _buildCalibrationOption(
            icon: Icons.mic,
            title: 'Calibrar Micrófono',
            subtitle: _micStatusText,
            onTap: () {
              setState(() {
                _phase = _CalibrationPhase.micCalibration;
                _resetMicState();
              });
            },
          ),

          const SizedBox(height: 16),

          // Calibrate Headphones button
          _buildCalibrationOption(
            icon: Icons.headphones,
            title: 'Calibrar Auriculares',
            subtitle: _hpStatusText,
            onTap: () {
              setState(() {
                _phase = _CalibrationPhase.headphoneCalibration;
                _resetHpState();
              });
            },
          ),
        ],
      ),
    );
  }

  String get _micStatusText {
    final mic = _calibrationData?.micCalibration;
    if (mic == null) return 'No calibrado';
    final date = _formatDate(mic.calibratedAt);
    final method = _methodLabel(mic.method);
    return 'Calibrado: $date ($method)';
  }

  String get _hpStatusText {
    final hpCal = _calibrationData
        ?.getActiveHeadphoneCalibration(widget.connectedHeadphoneId);
    if (hpCal == null) return 'No calibrado para $_effectiveHeadphoneName';
    final date = _formatDate(hpCal.calibratedAt);
    return 'Calibrado: $date (${hpCal.headphoneName})';
  }

  String _formatDate(DateTime dt) =>
      '${dt.day}/${dt.month}/${dt.year} ${dt.hour}:${dt.minute.toString().padLeft(2, '0')}';

  String _methodLabel(String method) {
    switch (method) {
      case 'external_ref':
        return 'Referencia externa';
      case 'phone_model':
        return 'Modelo de teléfono';
      case 'self_test':
        return 'Auto-test';
      default:
        return method;
    }
  }

  Widget _buildNewHeadphoneBanner() {
    return Container(
      margin: const EdgeInsets.only(bottom: 20),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.orange.withOpacity(0.15),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.orange.withOpacity(0.5)),
      ),
      child: Row(
        children: [
          const Icon(Icons.info_outline, color: Colors.orange, size: 24),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              'Nuevos auriculares detectados: $_effectiveHeadphoneName.\n'
              'Se recomienda recalibrar.',
              style: const TextStyle(color: Colors.orange, fontSize: 13),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildCalibrationStatus() {
    final hasMic = _calibrationData?.micCalibration != null;
    final hasHp = _calibrationData
            ?.getActiveHeadphoneCalibration(widget.connectedHeadphoneId) !=
        null;

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: const Color(0xFF16213e),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Estado de Calibración',
            style: TextStyle(
              color: Colors.white,
              fontSize: 16,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 12),
          _buildStatusRow(
            'Micrófono',
            hasMic,
            hasMic ? _micStatusText : 'Pendiente',
          ),
          const SizedBox(height: 8),
          _buildStatusRow(
            'Auriculares',
            hasHp,
            hasHp ? _hpStatusText : 'Pendiente',
          ),
        ],
      ),
    );
  }

  Widget _buildStatusRow(String label, bool calibrated, String detail) {
    return Row(
      children: [
        Icon(
          calibrated ? Icons.check_circle : Icons.radio_button_unchecked,
          color: calibrated ? Colors.green : Colors.white38,
          size: 18,
        ),
        const SizedBox(width: 8),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                label,
                style: const TextStyle(
                  color: Colors.white70,
                  fontSize: 14,
                  fontWeight: FontWeight.w500,
                ),
              ),
              Text(
                detail,
                style: TextStyle(
                  color: calibrated ? Colors.white54 : Colors.white38,
                  fontSize: 12,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildCalibrationOption({
    required IconData icon,
    required String title,
    required String subtitle,
    required VoidCallback onTap,
  }) {
    return Material(
      color: const Color(0xFF16213e),
      borderRadius: BorderRadius.circular(12),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(12),
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Row(
            children: [
              Container(
                width: 48,
                height: 48,
                decoration: BoxDecoration(
                  color: Colors.cyan.withOpacity(0.15),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Icon(icon, color: Colors.cyan, size: 24),
              ),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 16,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      subtitle,
                      style: const TextStyle(
                        color: Colors.white54,
                        fontSize: 12,
                      ),
                    ),
                  ],
                ),
              ),
              const Icon(Icons.chevron_right, color: Colors.white38),
            ],
          ),
        ),
      ),
    );
  }

  // ═══════════════════════════════════════════════════════════════════════════
  // MIC CALIBRATION WIZARD
  // ═══════════════════════════════════════════════════════════════════════════

  Widget _buildMicCalibration() {
    switch (_micStep) {
      case 0:
        return _buildMicMethodSelection();
      case 1:
        return _buildMicInstructions();
      case 2:
        return _buildMicMeasuring();
      case 3:
        return _buildMicResult();
      default:
        return _buildMicMethodSelection();
    }
  }

  /// Step 0: Choose calibration method
  Widget _buildMicMethodSelection() {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Icon(Icons.mic, size: 48, color: Colors.cyan),
          const SizedBox(height: 16),
          const Text(
            'Calibración del Micrófono',
            style: TextStyle(
              color: Colors.white,
              fontSize: 20,
              fontWeight: FontWeight.bold,
            ),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 8),
          const Text(
            'Seleccione el método de calibración:',
            style: TextStyle(color: Colors.white70, fontSize: 14),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 24),

          // Method 1: External Reference (recommended)
          _buildMethodCard(
            method: MicCalibrationMethod.externalRef,
            title: 'Referencia Externa',
            description:
                'Use un sonómetro o fuente de sonido calibrada como referencia. '
                'Método más preciso.',
            icon: Icons.speaker,
            recommended: true,
          ),
          const SizedBox(height: 12),

          // Method 2: Phone Model DB
          _buildMethodCard(
            method: MicCalibrationMethod.phoneModel,
            title: 'Modelo de Teléfono',
            description:
                'Usa valores pre-calibrados para su modelo de teléfono. '
                'Rápido pero menos preciso.',
            icon: Icons.phone_android,
            recommended: false,
          ),
          const SizedBox(height: 12),

          // Method 3: Self-Test
          _buildMethodCard(
            method: MicCalibrationMethod.selfTest,
            title: 'Auto-Test',
            description:
                'Reproduce un tono por el parlante del teléfono y mide con el micrófono. '
                'Precisión limitada.',
            icon: Icons.autorenew,
            recommended: false,
          ),
        ],
      ),
    );
  }

  Widget _buildMethodCard({
    required MicCalibrationMethod method,
    required String title,
    required String description,
    required IconData icon,
    required bool recommended,
  }) {
    final isSelected = _selectedMicMethod == method;

    return GestureDetector(
      onTap: () {
        setState(() {
          _selectedMicMethod = method;
          _micStep = 1;
        });
      },
      child: Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: isSelected
              ? Colors.cyan.withOpacity(0.15)
              : const Color(0xFF16213e),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: isSelected ? Colors.cyan : Colors.white12,
            width: isSelected ? 2 : 1,
          ),
        ),
        child: Row(
          children: [
            Container(
              width: 40,
              height: 40,
              decoration: BoxDecoration(
                color: Colors.cyan.withOpacity(0.1),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Icon(icon, color: Colors.cyan, size: 20),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Text(
                        title,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 15,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      if (recommended) ...[
                        const SizedBox(width: 8),
                        Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 6, vertical: 2),
                          decoration: BoxDecoration(
                            color: Colors.green.withOpacity(0.2),
                            borderRadius: BorderRadius.circular(4),
                          ),
                          child: const Text(
                            'Recomendado',
                            style: TextStyle(
                              color: Colors.green,
                              fontSize: 10,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ),
                      ],
                    ],
                  ),
                  const SizedBox(height: 4),
                  Text(
                    description,
                    style: const TextStyle(color: Colors.white54, fontSize: 12),
                  ),
                ],
              ),
            ),
            const Icon(Icons.chevron_right, color: Colors.white38, size: 20),
          ],
        ),
      ),
    );
  }

  /// Step 1: Instructions for selected method
  Widget _buildMicInstructions() {
    final (title, instructions) = _getMicInstructions();

    return SingleChildScrollView(
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Icon(Icons.info_outline, size: 48, color: Colors.cyan),
          const SizedBox(height: 16),
          Text(
            title,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 18,
              fontWeight: FontWeight.bold,
            ),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 24),
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: const Color(0xFF16213e),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: instructions
                  .asMap()
                  .entries
                  .map((entry) => Padding(
                        padding: const EdgeInsets.only(bottom: 12),
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Container(
                              width: 24,
                              height: 24,
                              decoration: BoxDecoration(
                                color: Colors.cyan.withOpacity(0.2),
                                shape: BoxShape.circle,
                              ),
                              child: Center(
                                child: Text(
                                  '${entry.key + 1}',
                                  style: const TextStyle(
                                    color: Colors.cyan,
                                    fontSize: 12,
                                    fontWeight: FontWeight.bold,
                                  ),
                                ),
                              ),
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              child: Text(
                                entry.value,
                                style: const TextStyle(
                                  color: Colors.white70,
                                  fontSize: 14,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ))
                  .toList(),
            ),
          ),
          const SizedBox(height: 32),
          ElevatedButton(
            onPressed: _startMicCalibration,
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.cyan,
              foregroundColor: Colors.white,
              padding: const EdgeInsets.symmetric(vertical: 16),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
              ),
            ),
            child: const Text(
              'Iniciar Calibración',
              style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
            ),
          ),
        ],
      ),
    );
  }

  (String, List<String>) _getMicInstructions() {
    switch (_selectedMicMethod!) {
      case MicCalibrationMethod.externalRef:
        return (
          'Referencia Externa',
          [
            'Coloque el teléfono a 30 cm de una fuente de sonido calibrada.',
            'La fuente debe reproducir un tono de 1 kHz a un nivel conocido (ej: 94 dB SPL).',
            'Asegúrese de que el entorno esté silencioso (< 40 dB SPL de ruido de fondo).',
            'Presione "Iniciar Calibración" cuando esté listo.',
          ],
        );
      case MicCalibrationMethod.phoneModel:
        return (
          'Modelo de Teléfono',
          [
            'Se consultará la base de datos de sensibilidades de micrófono por modelo.',
            'Si su modelo está registrado, se usará el offset pre-calibrado.',
            'Si no, se usará el valor por defecto (120 dB).',
            'Presione "Iniciar Calibración" para continuar.',
          ],
        );
      case MicCalibrationMethod.selfTest:
        return (
          'Auto-Test',
          [
            'Se reproducirá un tono de 1 kHz por el parlante del teléfono.',
            'Simultáneamente se capturará con el micrófono.',
            'Coloque el teléfono en una superficie plana, sin obstrucciones.',
            'Asegúrese de que el entorno esté silencioso.',
            'Presione "Iniciar Calibración" cuando esté listo.',
          ],
        );
    }
  }

  Future<void> _startMicCalibration() async {
    setState(() {
      _micStep = 2;
      _micMeasuring = true;
      _micError = null;
    });

    try {
      // Determine reference level based on method
      final double refLevel;
      switch (_selectedMicMethod!) {
        case MicCalibrationMethod.externalRef:
          refLevel = 94.0; // Standard calibration level
        case MicCalibrationMethod.phoneModel:
          refLevel = 94.0; // Will use phone model DB internally
        case MicCalibrationMethod.selfTest:
          refLevel = 70.0; // Approximate level from phone speaker
      }

      final result = await widget.audioBridge.calibrateMicrophone(
        referenceSplLevel: refLevel,
      );

      setState(() {
        _micResult = result;
        _micMeasuring = false;
        _micStep = 3;
      });
    } catch (e) {
      setState(() {
        _micError = e.toString();
        _micMeasuring = false;
        _micStep = 3;
      });
    }
  }

  /// Step 2: Measuring in progress
  Widget _buildMicMeasuring() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const SizedBox(
              width: 80,
              height: 80,
              child: CircularProgressIndicator(
                strokeWidth: 4,
                color: Colors.cyan,
              ),
            ),
            const SizedBox(height: 32),
            const Text(
              'Midiendo...',
              style: TextStyle(
                color: Colors.white,
                fontSize: 20,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 12),
            const Text(
              'Mantenga el teléfono estable.\nNo hable ni haga ruido.',
              style: TextStyle(color: Colors.white54, fontSize: 14),
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }

  /// Step 3: Result display
  Widget _buildMicResult() {
    if (_micError != null) {
      return _buildErrorResult(
        title: 'Error en Calibración',
        message: _micError!,
        onRetry: () {
          setState(() {
            _micStep = 1;
            _micError = null;
          });
        },
      );
    }

    final result = _micResult!;
    return SingleChildScrollView(
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Icon(Icons.check_circle, size: 64, color: Colors.green),
          const SizedBox(height: 16),
          const Text(
            'Calibración Completada',
            style: TextStyle(
              color: Colors.white,
              fontSize: 20,
              fontWeight: FontWeight.bold,
            ),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 24),

          // Results card
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: const Color(0xFF16213e),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Column(
              children: [
                _buildResultRow(
                  'Offset SPL',
                  '${result.splOffset.toStringAsFixed(1)} dB',
                ),
                const Divider(color: Colors.white12, height: 20),
                _buildResultRow(
                  'Confianza',
                  '${(result.confidenceLevel * 100).toStringAsFixed(0)}%',
                ),
                const Divider(color: Colors.white12, height: 20),
                _buildResultRow(
                  'Método',
                  _methodLabel(result.method),
                ),
              ],
            ),
          ),
          const SizedBox(height: 32),

          // Save / Retry buttons
          Row(
            children: [
              Expanded(
                child: OutlinedButton(
                  onPressed: () {
                    setState(() {
                      _micStep = 0;
                      _micResult = null;
                    });
                  },
                  style: OutlinedButton.styleFrom(
                    foregroundColor: Colors.white70,
                    side: const BorderSide(color: Colors.white38),
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                  ),
                  child: const Text('Reintentar'),
                ),
              ),
              const SizedBox(width: 16),
              Expanded(
                child: ElevatedButton(
                  onPressed: _saveMicCalibration,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.cyan,
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                  ),
                  child: const Text('Guardar'),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Future<void> _saveMicCalibration() async {
    final updatedData = CalibrationData(
      micCalibration: _micResult,
      headphoneCalibrations:
          _calibrationData?.headphoneCalibrations ?? const {},
    );

    await widget.settingsRepository.setCalibrationData(updatedData);
    await widget.audioBridge.applyCalibration(updatedData);

    setState(() {
      _calibrationData = updatedData;
      _phase = _CalibrationPhase.home;
      _resetMicState();
    });

    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Calibración del micrófono guardada'),
          backgroundColor: Colors.green,
        ),
      );
    }
  }

  // ═══════════════════════════════════════════════════════════════════════════
  // HEADPHONE CALIBRATION WIZARD
  // ═══════════════════════════════════════════════════════════════════════════

  Widget _buildHeadphoneCalibration() {
    switch (_hpStep) {
      case 0:
        return _buildHpInstructions();
      case 1:
        return _buildHpSweep();
      case 2:
        return _buildHpResult();
      default:
        return _buildHpInstructions();
    }
  }

  /// Step 0: Instructions
  Widget _buildHpInstructions() {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Icon(Icons.headphones, size: 48, color: Colors.cyan),
          const SizedBox(height: 16),
          const Text(
            'Calibración de Auriculares',
            style: TextStyle(
              color: Colors.white,
              fontSize: 20,
              fontWeight: FontWeight.bold,
            ),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 8),
          Text(
            'Dispositivo: $_effectiveHeadphoneName',
            style: const TextStyle(color: Colors.cyan, fontSize: 14),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 24),

          // Instructions
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: const Color(0xFF16213e),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _buildInstructionStep(
                  1,
                  'Presione el auricular contra el micrófono del teléfono '
                      'formando un sello acústico (acoplador improvisado).',
                ),
                const SizedBox(height: 12),
                _buildInstructionStep(
                  2,
                  'Se reproducirá un sweep de frecuencias (250 → 8000 Hz) '
                      'por el auricular.',
                ),
                const SizedBox(height: 12),
                _buildInstructionStep(
                  3,
                  'El micrófono medirá la respuesta en frecuencia del auricular.',
                ),
                const SizedBox(height: 12),
                _buildInstructionStep(
                  4,
                  'Mantenga el sello estable durante todo el proceso (~15 segundos).',
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),

          // Visual guide
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: Colors.cyan.withOpacity(0.08),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: Colors.cyan.withOpacity(0.3)),
            ),
            child: const Row(
              children: [
                Icon(Icons.lightbulb_outline, color: Colors.cyan, size: 20),
                SizedBox(width: 12),
                Expanded(
                  child: Text(
                    'Consejo: Presione firmemente el auricular contra el '
                    'micrófono para obtener mejores resultados.',
                    style: TextStyle(color: Colors.cyan, fontSize: 12),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 32),

          ElevatedButton(
            onPressed: _startHeadphoneCalibration,
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.cyan,
              foregroundColor: Colors.white,
              padding: const EdgeInsets.symmetric(vertical: 16),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
              ),
            ),
            child: const Text(
              'Iniciar Sweep',
              style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildInstructionStep(int number, String text) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          width: 24,
          height: 24,
          decoration: BoxDecoration(
            color: Colors.cyan.withOpacity(0.2),
            shape: BoxShape.circle,
          ),
          child: Center(
            child: Text(
              '$number',
              style: const TextStyle(
                color: Colors.cyan,
                fontSize: 12,
                fontWeight: FontWeight.bold,
              ),
            ),
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Text(
            text,
            style: const TextStyle(color: Colors.white70, fontSize: 14),
          ),
        ),
      ],
    );
  }

  Future<void> _startHeadphoneCalibration() async {
    setState(() {
      _hpStep = 1;
      _hpMeasuring = true;
      _hpError = null;
      _sweepProgress = 0;
    });

    // Simulate sweep progress updates
    final progressTimer = Timer.periodic(
      const Duration(milliseconds: 1200),
      (timer) {
        if (!mounted || !_hpMeasuring) {
          timer.cancel();
          return;
        }
        setState(() {
          _sweepProgress = (_sweepProgress + 1)
              .clamp(0, kCalibrationFrequencies.length);
        });
        if (_sweepProgress >= kCalibrationFrequencies.length) {
          timer.cancel();
        }
      },
    );

    try {
      final result = await widget.audioBridge.calibrateHeadphones(
        headphoneId: _effectiveHeadphoneId,
      );

      progressTimer.cancel();

      setState(() {
        _hpResult = result;
        _hpMeasuring = false;
        _sweepProgress = kCalibrationFrequencies.length;
        _hpStep = 2;
      });
    } catch (e) {
      progressTimer.cancel();
      setState(() {
        _hpError = e.toString();
        _hpMeasuring = false;
        _hpStep = 2;
      });
    }
  }

  /// Step 1: Sweep in progress
  Widget _buildHpSweep() {
    final progress = _sweepProgress / kCalibrationFrequencies.length;
    final currentFreq = _sweepProgress < kCalibrationFrequencies.length
        ? kCalibrationFrequencies[_sweepProgress]
        : kCalibrationFrequencies.last;

    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(Icons.graphic_eq, size: 48, color: Colors.cyan),
            const SizedBox(height: 24),
            const Text(
              'Sweep en Progreso',
              style: TextStyle(
                color: Colors.white,
                fontSize: 20,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              'Frecuencia: $currentFreq Hz',
              style: const TextStyle(color: Colors.cyan, fontSize: 16),
            ),
            const SizedBox(height: 32),

            // Progress bar
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: const Color(0xFF16213e),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Column(
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      const Text(
                        '250 Hz',
                        style: TextStyle(color: Colors.white54, fontSize: 12),
                      ),
                      Text(
                        '${(_sweepProgress)}/${kCalibrationFrequencies.length}',
                        style: const TextStyle(
                          color: Colors.cyan,
                          fontSize: 14,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      const Text(
                        '8000 Hz',
                        style: TextStyle(color: Colors.white54, fontSize: 12),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  ClipRRect(
                    borderRadius: BorderRadius.circular(6),
                    child: LinearProgressIndicator(
                      value: progress,
                      minHeight: 12,
                      backgroundColor: Colors.grey.shade800,
                      color: Colors.cyan,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 24),
            const Text(
              'Mantenga el auricular presionado\ncontra el micrófono.',
              style: TextStyle(color: Colors.white54, fontSize: 14),
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }

  /// Step 2: Result display
  Widget _buildHpResult() {
    if (_hpError != null) {
      return _buildErrorResult(
        title: 'Error en Calibración',
        message: _hpError!,
        onRetry: () {
          setState(() {
            _hpStep = 0;
            _hpError = null;
          });
        },
      );
    }

    final result = _hpResult!;
    return SingleChildScrollView(
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Icon(Icons.check_circle, size: 64, color: Colors.green),
          const SizedBox(height: 16),
          const Text(
            'Calibración Completada',
            style: TextStyle(
              color: Colors.white,
              fontSize: 20,
              fontWeight: FontWeight.bold,
            ),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 8),
          Text(
            result.headphoneName,
            style: const TextStyle(color: Colors.cyan, fontSize: 14),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 24),

          // Frequency response chart (simple bar chart)
          _buildFrequencyResponseChart(result.frequencyResponse),

          const SizedBox(height: 24),

          // Compensation values
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: const Color(0xFF16213e),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Compensación EQ aplicada:',
                  style: TextStyle(
                    color: Colors.white70,
                    fontSize: 13,
                    fontWeight: FontWeight.w500,
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  _formatCompensation(result.compensation),
                  style: const TextStyle(
                    color: Colors.white54,
                    fontSize: 11,
                    fontFamily: 'monospace',
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 32),

          // Save / Retry buttons
          Row(
            children: [
              Expanded(
                child: OutlinedButton(
                  onPressed: () {
                    setState(() {
                      _hpStep = 0;
                      _hpResult = null;
                    });
                  },
                  style: OutlinedButton.styleFrom(
                    foregroundColor: Colors.white70,
                    side: const BorderSide(color: Colors.white38),
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                  ),
                  child: const Text('Reintentar'),
                ),
              ),
              const SizedBox(width: 16),
              Expanded(
                child: ElevatedButton(
                  onPressed: _saveHeadphoneCalibration,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.cyan,
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                  ),
                  child: const Text('Guardar'),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  /// Simple bar chart showing dB per frequency.
  Widget _buildFrequencyResponseChart(Map<int, double> response) {
    if (response.isEmpty) {
      return const SizedBox.shrink();
    }

    // Find max absolute value for scaling
    final maxAbs = response.values
        .map((v) => v.abs())
        .reduce((a, b) => a > b ? a : b)
        .clamp(1.0, 30.0);

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: const Color(0xFF16213e),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Respuesta en Frecuencia (dB relativo a 1 kHz)',
            style: TextStyle(
              color: Colors.white70,
              fontSize: 13,
              fontWeight: FontWeight.w500,
            ),
          ),
          const SizedBox(height: 16),
          SizedBox(
            height: 120,
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: kCalibrationFrequencies.map((freq) {
                final value = response[freq] ?? 0.0;
                final normalizedHeight =
                    (value.abs() / maxAbs * 50).clamp(2.0, 50.0);
                final isPositive = value >= 0;

                return Expanded(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 1),
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.end,
                      children: [
                        // Value label
                        Text(
                          '${value >= 0 ? '+' : ''}${value.toStringAsFixed(0)}',
                          style: TextStyle(
                            color: isPositive
                                ? Colors.green.shade300
                                : Colors.red.shade300,
                            fontSize: 8,
                          ),
                        ),
                        const SizedBox(height: 2),
                        // Bar
                        Container(
                          height: normalizedHeight,
                          decoration: BoxDecoration(
                            color: isPositive
                                ? Colors.green.withOpacity(0.7)
                                : Colors.red.withOpacity(0.7),
                            borderRadius: BorderRadius.circular(2),
                          ),
                        ),
                        const SizedBox(height: 4),
                        // Frequency label
                        Text(
                          _shortFreqLabel(freq),
                          style: const TextStyle(
                            color: Colors.white38,
                            fontSize: 7,
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

  String _shortFreqLabel(int freq) {
    if (freq >= 1000) {
      return '${(freq / 1000).toStringAsFixed(freq % 1000 == 0 ? 0 : 1)}k';
    }
    return '$freq';
  }

  String _formatCompensation(Map<int, double> compensation) {
    final buffer = StringBuffer();
    for (final freq in kCalibrationFrequencies) {
      final value = compensation[freq] ?? 0.0;
      final sign = value >= 0 ? '+' : '';
      buffer.writeln(
          '${_shortFreqLabel(freq).padRight(5)} $sign${value.toStringAsFixed(1)} dB');
    }
    return buffer.toString().trimRight();
  }

  Future<void> _saveHeadphoneCalibration() async {
    final existingHpCals =
        Map<String, HeadphoneCalibrationResult>.from(
            _calibrationData?.headphoneCalibrations ?? {});
    existingHpCals[_effectiveHeadphoneId] = _hpResult!;

    final updatedData = CalibrationData(
      micCalibration: _calibrationData?.micCalibration,
      headphoneCalibrations: existingHpCals,
    );

    await widget.settingsRepository.setCalibrationData(updatedData);
    await widget.audioBridge.applyCalibration(updatedData);

    setState(() {
      _calibrationData = updatedData;
      _newHeadphoneDetected = false;
      _phase = _CalibrationPhase.home;
      _resetHpState();
    });

    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Calibración de auriculares guardada'),
          backgroundColor: Colors.green,
        ),
      );
    }
  }

  // ═══════════════════════════════════════════════════════════════════════════
  // SHARED WIDGETS
  // ═══════════════════════════════════════════════════════════════════════════

  Widget _buildResultRow(String label, String value) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Text(
          label,
          style: const TextStyle(color: Colors.white54, fontSize: 14),
        ),
        Text(
          value,
          style: const TextStyle(
            color: Colors.cyan,
            fontSize: 14,
            fontWeight: FontWeight.w600,
          ),
        ),
      ],
    );
  }

  Widget _buildErrorResult({
    required String title,
    required String message,
    required VoidCallback onRetry,
  }) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(Icons.error_outline, size: 64, color: Colors.redAccent),
            const SizedBox(height: 24),
            Text(
              title,
              style: const TextStyle(
                color: Colors.redAccent,
                fontSize: 20,
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 12),
            Text(
              message,
              style: const TextStyle(color: Colors.white54, fontSize: 14),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 32),
            ElevatedButton.icon(
              onPressed: onRetry,
              icon: const Icon(Icons.refresh),
              label: const Text('Reintentar'),
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.cyan,
                foregroundColor: Colors.white,
                padding:
                    const EdgeInsets.symmetric(horizontal: 32, vertical: 14),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
