import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../bloc/amplification_bloc.dart';
import '../bloc/amplification_event.dart';
import '../bloc/amplification_state.dart';

/// Pantalla de calibración de ganancia máxima del hardware (Gain Ceiling).
///
/// El técnico sube un slider de 0 a 50 dB (envía ganancia plana en vivo
/// a las 12 bandas) hasta escuchar distorsión en el auricular conectado.
/// Al pulsar "Marcar límite", el valor se persiste como techo absoluto
/// de ganancia que ninguna banda puede superar en ningún contexto.
///
/// Requiere que el [AmplificationBloc] esté provisto en el árbol.
class GainCeilingCalibrationScreen extends StatefulWidget {
  const GainCeilingCalibrationScreen({super.key});

  @override
  State<GainCeilingCalibrationScreen> createState() =>
      _GainCeilingCalibrationScreenState();
}

class _GainCeilingCalibrationScreenState
    extends State<GainCeilingCalibrationScreen> {
  double _sliderValue = 0.0;
  double _currentCeiling = 50.0;
  bool _isLive = false;

  @override
  void initState() {
    super.initState();
    _loadCurrentCeiling();
  }

  void _loadCurrentCeiling() {
    final bloc = context.read<AmplificationBloc>();
    final ceiling = bloc.settingsRepository.hardwareGainCeilingDb;
    setState(() {
      _currentCeiling = ceiling;
      _sliderValue = 0.0;
    });
  }

  /// Envía ganancia plana (las 12 bandas al mismo valor) al motor.
  void _sendFlatGain(double gainDb) {
    final bloc = context.read<AmplificationBloc>();
    final state = bloc.state;
    if (state is! AmplificationActive) return;

    // 12 bandas, todas al mismo valor.
    final flatGains = List<double>.filled(12, gainDb);
    bloc.add(UpdateEqGains(
      gains: flatGains,
      presetName: '_GainCeilingCalibration',
    ));
    if (!_isLive) {
      setState(() => _isLive = true);
    }
  }

  /// Marca el límite actual del slider como ceiling y persiste.
  Future<void> _markCeiling() async {
    final bloc = context.read<AmplificationBloc>();
    await bloc.settingsRepository.setHardwareGainCeilingDb(_sliderValue);
    setState(() {
      _currentCeiling = _sliderValue;
    });

    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'Límite fijado en ${_sliderValue.toStringAsFixed(1)} dB',
          ),
          backgroundColor: Colors.green.shade700,
          duration: const Duration(seconds: 2),
        ),
      );
    }

    // Restaurar gains del preset activo (ahora acotados por el nuevo ceiling).
    _restoreActivePreset();
  }

  /// Resetea el ceiling a 50 dB (sin restricción).
  Future<void> _resetCeiling() async {
    final bloc = context.read<AmplificationBloc>();
    await bloc.settingsRepository.setHardwareGainCeilingDb(50.0);
    setState(() {
      _currentCeiling = 50.0;
    });

    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Límite reseteado a 50 dB (sin restricción)'),
          backgroundColor: Colors.orange,
          duration: Duration(seconds: 2),
        ),
      );
    }

    // Restaurar gains del preset activo (ya sin techo restrictivo).
    _restoreActivePreset();
  }

  /// Restaura las gains del preset activo mandando un evento al bloc.
  /// Al despachar UpdateEqGains con las gains persistidas, el bloc
  /// re-aplica todos los clamps (incluyendo el nuevo ceiling).
  void _restoreActivePreset() async {
    final bloc = context.read<AmplificationBloc>();
    final preset = await bloc.settingsRepository.getLastEqPreset();
    if (preset != null && preset['gains'] != null) {
      final gains = (preset['gains'] as List).cast<num>().map((e) => e.toDouble()).toList();
      final name = preset['name'] as String? ?? 'Custom';
      bloc.add(UpdateEqGains(gains: gains, presetName: name));
    }
    if (mounted) {
      setState(() => _isLive = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF1a1a2e),
      appBar: AppBar(
        backgroundColor: const Color(0xFF0f3460),
        title: const Text(
          'Calibración de Ganancia Máxima',
          style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
        ),
        iconTheme: const IconThemeData(color: Colors.white),
      ),
      body: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // Instrucción
            Container(
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: const Color(0xFF16213e),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: Colors.amber.withOpacity(0.4)),
              ),
              child: const Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Icon(Icons.warning_amber_rounded,
                          color: Colors.amber, size: 22),
                      SizedBox(width: 8),
                      Text(
                        'Instrucciones',
                        style: TextStyle(
                          color: Colors.amber,
                          fontSize: 14,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ],
                  ),
                  SizedBox(height: 8),
                  Text(
                    'Conectá el auricular al dispositivo. Subí la ganancia '
                    'lentamente hasta escuchar distorsión (crackle, clip). '
                    'Luego pulsá "Marcar límite". Eso fija el techo de '
                    'ganancia que NINGUNA configuración va a superar.',
                    style: TextStyle(color: Colors.white70, fontSize: 12),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 24),

            // Valor actual del ceiling
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
              decoration: BoxDecoration(
                color: const Color(0xFF16213e),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  const Text(
                    'Ceiling actual:',
                    style: TextStyle(color: Colors.white70, fontSize: 13),
                  ),
                  Text(
                    _currentCeiling >= 50.0
                        ? '50.0 dB (sin límite)'
                        : '${_currentCeiling.toStringAsFixed(1)} dB',
                    style: TextStyle(
                      color: _currentCeiling >= 50.0
                          ? Colors.white
                          : Colors.orangeAccent,
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 24),

            // Slider de ganancia
            Text(
              'Ganancia de prueba: ${_sliderValue.toStringAsFixed(1)} dB',
              style: const TextStyle(
                color: Colors.white,
                fontSize: 15,
                fontWeight: FontWeight.w600,
              ),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 8),
            SliderTheme(
              data: SliderThemeData(
                activeTrackColor: _sliderValue > 40
                    ? Colors.red
                    : _sliderValue > 25
                        ? Colors.orange
                        : Colors.cyan,
                inactiveTrackColor: Colors.white24,
                thumbColor: Colors.white,
                overlayColor: Colors.cyan.withOpacity(0.2),
                valueIndicatorColor: const Color(0xFF0f3460),
                valueIndicatorTextStyle: const TextStyle(
                  color: Colors.white,
                  fontSize: 12,
                ),
              ),
              child: Slider(
                value: _sliderValue,
                min: 0.0,
                max: 50.0,
                divisions: 100, // step 0.5 dB
                label: '${_sliderValue.toStringAsFixed(1)} dB',
                onChanged: (value) {
                  setState(() => _sliderValue = value);
                  _sendFlatGain(value);
                },
              ),
            ),
            const SizedBox(height: 8),
            // Indicador visual de rango
            const Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text('0 dB', style: TextStyle(color: Colors.white38, fontSize: 11)),
                Text('25 dB', style: TextStyle(color: Colors.white38, fontSize: 11)),
                Text('50 dB', style: TextStyle(color: Colors.white38, fontSize: 11)),
              ],
            ),
            const SizedBox(height: 32),

            // Botón Marcar límite
            ElevatedButton.icon(
              onPressed: _sliderValue > 0 ? _markCeiling : null,
              icon: const Icon(Icons.flag),
              label: const Text('Marcar límite'),
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.green.shade700,
                foregroundColor: Colors.white,
                disabledBackgroundColor: Colors.grey.shade800,
                padding: const EdgeInsets.symmetric(vertical: 14),
                textStyle: const TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            const SizedBox(height: 12),

            // Botón Reset
            OutlinedButton.icon(
              onPressed: _currentCeiling < 50.0 ? _resetCeiling : null,
              icon: const Icon(Icons.restart_alt),
              label: const Text('Reset (sin límite)'),
              style: OutlinedButton.styleFrom(
                foregroundColor: Colors.orange,
                side: BorderSide(
                  color: _currentCeiling < 50.0
                      ? Colors.orange
                      : Colors.grey.shade700,
                ),
                padding: const EdgeInsets.symmetric(vertical: 14),
                textStyle: const TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ),

            const Spacer(),

            // Nota de estado
            if (_isLive)
              Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: Colors.cyan.withOpacity(0.1),
                  borderRadius: BorderRadius.circular(6),
                  border: Border.all(color: Colors.cyan.withOpacity(0.3)),
                ),
                child: const Row(
                  children: [
                    Icon(Icons.volume_up, color: Colors.cyan, size: 18),
                    SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        'Escuchando ganancia plana en vivo. '
                        'Al marcar o salir se restaura el preset activo.',
                        style: TextStyle(color: Colors.cyan, fontSize: 11),
                      ),
                    ),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }

  @override
  void dispose() {
    // Si el usuario sale sin marcar, restaurar el preset activo.
    // Fire-and-forget: el bloc y el bridge siguen vivos post-dispose.
    if (_isLive) {
      _restoreActivePreset();
    }
    super.dispose();
  }
}
