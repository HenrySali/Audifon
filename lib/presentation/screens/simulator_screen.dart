import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../domain/entities/eq_preset.dart';
import '../bloc/amplification_bloc.dart';
import '../bloc/amplification_event.dart';
import '../bloc/amplification_state.dart';

/// Pantalla de configuración avanzada del audífono.
///
/// Presenta:
/// - Selector de presets de EQ (Normal, Mild, Moderate, Severe, Profound, Custom)
/// - Control manual de las 12 bandas de EQ (sliders individuales)
/// - Visualización del espectro de frecuencias (barras)
/// - Información de dispositivos de audio (micrófono, auricular BT)
/// - Controles de NR y WDRC
class SimulatorScreen extends StatefulWidget {
  const SimulatorScreen({super.key});

  @override
  State<SimulatorScreen> createState() => _SimulatorScreenState();
}

class _SimulatorScreenState extends State<SimulatorScreen> {
  /// Ganancias actuales de las 12 bandas.
  List<double> _currentGains = List.filled(12, 0.0);

  /// Preset activo (null si es custom).
  EqPreset? _activePreset = EqPreset.normal;

  /// Información de dispositivos.
  Map<String, dynamic> _deviceInfo = {};

  /// Timer para polling de device info.
  Timer? _deviceInfoTimer;

  @override
  void initState() {
    super.initState();
    _loadDeviceInfo();
    _deviceInfoTimer = Timer.periodic(
      const Duration(seconds: 3),
      (_) => _loadDeviceInfo(),
    );
  }

  @override
  void dispose() {
    _deviceInfoTimer?.cancel();
    super.dispose();
  }

  Future<void> _loadDeviceInfo() async {
    try {
      const channel = MethodChannel('com.psk.hearing_aid/audio');
      final info = await channel.invokeMapMethod<String, dynamic>('getDeviceInfo');
      if (info != null && mounted) {
        setState(() => _deviceInfo = info);
      }
    } catch (_) {
      // Device info not available (engine not running)
    }
  }

  void _applyPreset(EqPreset preset) {
    setState(() {
      _currentGains = List.from(preset.gains);
      _activePreset = preset;
    });
    _applyGains(presetName: preset.name);
  }

  void _updateBand(int index, double value) {
    setState(() {
      _currentGains[index] = value;
      _activePreset = null; // Switch to custom mode
    });
    _applyGains();
  }

  void _applyGains({String? presetName}) {
    try {
      context.read<AmplificationBloc>().add(
        UpdateEqGains(gains: List.from(_currentGains), presetName: presetName),
      );
    } catch (_) {
      // Bloc not available (not in active state)
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF0a1628),
      appBar: AppBar(
        title: const Text('Configuración Avanzada'),
        backgroundColor: const Color(0xFF0f3460),
        foregroundColor: Colors.white,
        elevation: 0,
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // ─── Device Info Panel ─────────────────────────────────────
            _DeviceInfoPanel(deviceInfo: _deviceInfo),
            const SizedBox(height: 16),

            // ─── EQ Presets ────────────────────────────────────────────
            _PresetSelector(
              activePreset: _activePreset,
              onPresetSelected: _applyPreset,
            ),
            const SizedBox(height: 16),

            // ─── Spectrum Visualization ────────────────────────────────
            _SpectrumVisualization(gains: _currentGains),
            const SizedBox(height: 16),

            // ─── Manual EQ Bands ───────────────────────────────────────
            _ManualEqControl(
              gains: _currentGains,
              onBandChanged: _updateBand,
            ),
            const SizedBox(height: 16),

            // ─── NR Control ────────────────────────────────────────────
            _NrControl(),
            const SizedBox(height: 24),
          ],
        ),
      ),
    );
  }
}

// =============================================================================
// DEVICE INFO PANEL
// =============================================================================

class _DeviceInfoPanel extends StatelessWidget {
  final Map<String, dynamic> deviceInfo;

  const _DeviceInfoPanel({required this.deviceInfo});

  @override
  Widget build(BuildContext context) {
    final inputName = deviceInfo['inputDeviceName'] as String? ?? 'No detectado';
    final outputName = deviceInfo['outputDeviceName'] as String? ?? 'No detectado';
    final btConnected = deviceInfo['bluetoothConnected'] as bool? ?? false;
    final btName = deviceInfo['bluetoothName'] as String? ?? '';
    final btIsA2dp = deviceInfo['bluetoothIsA2dp'] as bool? ?? false;

    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: const Color(0xFF16213e),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: btConnected ? Colors.green.withOpacity(0.3) : Colors.orange.withOpacity(0.3),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                btConnected ? Icons.bluetooth_connected : Icons.bluetooth_disabled,
                color: btConnected ? Colors.green : Colors.orange,
                size: 18,
              ),
              const SizedBox(width: 8),
              const Text(
                'Dispositivos de Audio',
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          // Input device
          _DeviceRow(
            icon: Icons.mic,
            label: 'Micrófono',
            value: inputName,
            color: Colors.cyan,
          ),
          const SizedBox(height: 8),
          // Output device
          _DeviceRow(
            icon: Icons.headphones,
            label: 'Salida',
            value: btConnected ? '$btName ${btIsA2dp ? "(A2DP)" : "(SCO)"}' : outputName,
            color: btConnected ? Colors.green : Colors.orange,
          ),
          if (!btConnected) ...[
            const SizedBox(height: 8),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
              decoration: BoxDecoration(
                color: Colors.orange.withOpacity(0.1),
                borderRadius: BorderRadius.circular(8),
              ),
              child: const Row(
                children: [
                  Icon(Icons.warning_amber, color: Colors.orange, size: 16),
                  SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      'Conecta un auricular Bluetooth para usar el audífono',
                      style: TextStyle(color: Colors.orange, fontSize: 11),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _DeviceRow extends StatelessWidget {
  final IconData icon;
  final String label;
  final String value;
  final Color color;

  const _DeviceRow({
    required this.icon,
    required this.label,
    required this.value,
    required this.color,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Icon(icon, color: color, size: 16),
        const SizedBox(width: 8),
        Text(
          '$label: ',
          style: const TextStyle(color: Colors.white54, fontSize: 12),
        ),
        Expanded(
          child: Text(
            value,
            style: TextStyle(color: color, fontSize: 12, fontWeight: FontWeight.w500),
            overflow: TextOverflow.ellipsis,
          ),
        ),
      ],
    );
  }
}

// =============================================================================
// PRESET SELECTOR
// =============================================================================

class _PresetSelector extends StatelessWidget {
  final EqPreset? activePreset;
  final ValueChanged<EqPreset> onPresetSelected;

  const _PresetSelector({
    required this.activePreset,
    required this.onPresetSelected,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: const Color(0xFF16213e),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Row(
            children: [
              Icon(Icons.equalizer, color: Colors.cyan, size: 18),
              SizedBox(width: 8),
              Text(
                'Presets de Ecualización',
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              ...EqPreset.allPresets.map((preset) => _PresetChip(
                preset: preset,
                isActive: activePreset?.name == preset.name,
                onTap: () => onPresetSelected(preset),
              )),
              _PresetChip(
                preset: EqPreset.custom(),
                isActive: activePreset == null,
                onTap: () {}, // Custom is selected by modifying bands
                isCustom: true,
              ),
            ],
          ),
          if (activePreset != null) ...[
            const SizedBox(height: 8),
            Text(
              activePreset!.description,
              style: const TextStyle(color: Colors.white38, fontSize: 11),
            ),
          ],
        ],
      ),
    );
  }
}

class _PresetChip extends StatelessWidget {
  final EqPreset preset;
  final bool isActive;
  final VoidCallback onTap;
  final bool isCustom;

  const _PresetChip({
    required this.preset,
    required this.isActive,
    required this.onTap,
    this.isCustom = false,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: isActive ? Colors.cyan.withOpacity(0.2) : Colors.transparent,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(
            color: isActive ? Colors.cyan : Colors.white24,
            width: isActive ? 2 : 1,
          ),
        ),
        child: Text(
          preset.name,
          style: TextStyle(
            color: isActive ? Colors.cyan : Colors.white54,
            fontSize: 12,
            fontWeight: isActive ? FontWeight.bold : FontWeight.normal,
          ),
        ),
      ),
    );
  }
}

// =============================================================================
// SPECTRUM VISUALIZATION
// =============================================================================

class _SpectrumVisualization extends StatelessWidget {
  final List<double> gains;

  const _SpectrumVisualization({required this.gains});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: const Color(0xFF16213e),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Row(
            children: [
              Icon(Icons.bar_chart, color: Colors.cyan, size: 18),
              SizedBox(width: 8),
              Text(
                'Espectro de Ganancia',
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          SizedBox(
            height: 120,
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: List.generate(12, (i) {
                final normalizedGain = (gains[i] / 50.0).clamp(0.0, 1.0);
                final barColor = _getBarColor(gains[i]);
                return Expanded(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 2),
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.end,
                      children: [
                        Text(
                          '${gains[i].toInt()}',
                          style: TextStyle(
                            color: barColor,
                            fontSize: 9,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Expanded(
                          child: Align(
                            alignment: Alignment.bottomCenter,
                            child: FractionallySizedBox(
                              heightFactor: normalizedGain.clamp(0.02, 1.0),
                              child: Container(
                                decoration: BoxDecoration(
                                  color: barColor,
                                  borderRadius: const BorderRadius.vertical(
                                    top: Radius.circular(3),
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          EqPreset.bandLabels[i],
                          style: const TextStyle(
                            color: Colors.white38,
                            fontSize: 8,
                          ),
                        ),
                      ],
                    ),
                  ),
                );
              }),
            ),
          ),
        ],
      ),
    );
  }

  Color _getBarColor(double gain) {
    if (gain > 30) return Colors.red.shade400;
    if (gain > 20) return Colors.orange;
    if (gain > 10) return Colors.yellow.shade600;
    if (gain > 0) return Colors.cyan;
    return Colors.grey;
  }
}

// =============================================================================
// MANUAL EQ CONTROL — 12 Band Sliders
// =============================================================================

class _ManualEqControl extends StatelessWidget {
  final List<double> gains;
  final void Function(int index, double value) onBandChanged;

  const _ManualEqControl({
    required this.gains,
    required this.onBandChanged,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: const Color(0xFF16213e),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Row(
            children: [
              Icon(Icons.tune, color: Colors.cyan, size: 18),
              SizedBox(width: 8),
              Text(
                'Control Manual de Bandas',
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          const Text(
            'Desliza cada banda para ajustar la ganancia (0-50 dB)',
            style: TextStyle(color: Colors.white38, fontSize: 11),
          ),
          const SizedBox(height: 12),
          // Sliders in a grid (2 columns for better mobile UX)
          ...List.generate(6, (row) {
            final i1 = row * 2;
            final i2 = row * 2 + 1;
            return Padding(
              padding: const EdgeInsets.only(bottom: 4),
              child: Row(
                children: [
                  Expanded(child: _BandSlider(
                    index: i1,
                    gain: gains[i1],
                    onChanged: (v) => onBandChanged(i1, v),
                  )),
                  const SizedBox(width: 8),
                  Expanded(child: _BandSlider(
                    index: i2,
                    gain: gains[i2],
                    onChanged: (v) => onBandChanged(i2, v),
                  )),
                ],
              ),
            );
          }),
        ],
      ),
    );
  }
}

class _BandSlider extends StatelessWidget {
  final int index;
  final double gain;
  final ValueChanged<double> onChanged;

  const _BandSlider({
    required this.index,
    required this.gain,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(
              '${EqPreset.bandLabels[index]} Hz',
              style: const TextStyle(color: Colors.white54, fontSize: 11),
            ),
            Text(
              '${gain.toInt()} dB',
              style: const TextStyle(
                color: Colors.cyan,
                fontSize: 11,
                fontWeight: FontWeight.bold,
              ),
            ),
          ],
        ),
        SliderTheme(
          data: SliderTheme.of(context).copyWith(
            activeTrackColor: Colors.cyan,
            inactiveTrackColor: Colors.cyan.withOpacity(0.15),
            thumbColor: Colors.cyan,
            overlayColor: Colors.cyan.withOpacity(0.1),
            trackHeight: 4,
            thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6),
          ),
          child: Slider(
            value: gain,
            min: 0,
            max: 50,
            divisions: 50,
            onChanged: onChanged,
          ),
        ),
      ],
    );
  }
}

// =============================================================================
// NR CONTROL
// =============================================================================

class _NrControl extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: const Color(0xFF16213e),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Row(
            children: [
              Icon(Icons.noise_aware, color: Colors.cyan, size: 18),
              SizedBox(width: 8),
              Text(
                'Reducción de Ruido',
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
            children: [
              _NrChip(label: 'Off', level: 0),
              _NrChip(label: 'Bajo', level: 1),
              _NrChip(label: 'Medio', level: 2),
              _NrChip(label: 'Alto', level: 3),
            ],
          ),
        ],
      ),
    );
  }
}

class _NrChip extends StatelessWidget {
  final String label;
  final int level;

  const _NrChip({
    required this.label,
    required this.level,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: () {
        try {
          context.read<AmplificationBloc>().add(UpdateNrLevel(level: level));
        } catch (_) {
          // Bloc not available
        }
      },
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: Colors.cyan.withOpacity(0.5)),
          color: Colors.cyan.withOpacity(0.1),
        ),
        child: Text(
          label,
          style: const TextStyle(color: Colors.cyan, fontSize: 12),
        ),
      ),
    );
  }
}
