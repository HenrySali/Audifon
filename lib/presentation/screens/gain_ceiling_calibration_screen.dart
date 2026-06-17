import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../domain/entities/audiogram.dart';
import '../bloc/amplification_bloc.dart';
import '../bloc/amplification_event.dart';
import '../bloc/amplification_state.dart';

/// Pantalla de calibración de ganancia máxima del hardware (Gain Ceiling)
/// **por banda** — flujo secuencial de 12 pasos.
///
/// Para cada una de las 12 bandas (alineadas con
/// [Audiogram.standardFrequencies]), el técnico:
///
/// 1. Mueve un slider 0..50 dB (paso 0.5 dB).
/// 2. Mientras lo mueve, el motor recibe un array de 12 ganancias donde
///    **todas las bandas están en 0 dB excepto la banda actual**, que
///    queda al valor del slider. Esto aísla acústicamente esa banda
///    (la única amplificación es la de esa frecuencia).
/// 3. Al detectar distorsión, pulsa "Marcar límite": el valor se
///    guarda como techo de la banda actual y avanza a la siguiente.
///
/// Tras las 12 bandas, se muestra el resumen y el botón
/// "Finalizar calibración" (que persiste el array completo en
/// [SettingsRepository.setHardwareGainCeilingPerBandDb]).
///
/// El botón "Reset" reinicia el array a `[50.0]*12` (sin restricción)
/// y vuelve al paso 1.
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
  /// Frecuencias de las 12 bandas, en Hz, alineadas con el EQ del motor
  /// y con [Audiogram.standardFrequencies].
  static const List<int> _kBandFrequenciesHz = Audiogram.standardFrequencies;

  /// Cantidad de bandas. Debe ser 12 para mantener consistencia con el
  /// resto del pipeline DSP.
  static const int _kBandCount = 12;

  /// Techo "sin restricción" — coincide con `AudiogramDrivenBundle.gainMaxDb`.
  static const double _kCeilingMaxDb = 50.0;

  /// Valores guardados por banda (longitud 12). Inicia con los persistidos
  /// y se actualiza con cada "Marcar límite".
  late List<double> _bandCeilings;

  /// Banda actualmente en calibración. `_kBandCount` indica que ya se
  /// completaron las 12 (pantalla de resumen).
  int _currentBandIndex = 0;

  /// Valor actual del slider (0..50 dB, paso 0.5 dB).
  double _sliderValue = 0.0;

  /// `true` mientras se está enviando ganancia aislada en vivo al motor
  /// (al menos una vez se movió el slider en la banda actual).
  bool _isLive = false;

  @override
  void initState() {
    super.initState();
    final bloc = context.read<AmplificationBloc>();
    final stored = bloc.settingsRepository.hardwareGainCeilingPerBandDb;
    _bandCeilings = List<double>.from(stored);
    if (_bandCeilings.length != _kBandCount) {
      _bandCeilings = List<double>.filled(_kBandCount, _kCeilingMaxDb);
    }
    // Para la banda inicial: si ya tiene un valor calibrado (< 50),
    // arrancar el slider ahí; si no, en 0.
    _sliderValue = _bandCeilings[0] < _kCeilingMaxDb ? _bandCeilings[0] : 0.0;
  }

  /// Envía al motor un array de 12 ganancias con todas las bandas en 0
  /// excepto [bandIndex] que recibe [gainDb]. Aísla acústicamente la
  /// banda en calibración.
  void _sendIsolatedGain(int bandIndex, double gainDb) {
    final bloc = context.read<AmplificationBloc>();
    if (bloc.state is! AmplificationActive) return;

    final gains = List<double>.filled(_kBandCount, 0.0);
    if (bandIndex >= 0 && bandIndex < _kBandCount) {
      gains[bandIndex] = gainDb;
    }
    bloc.add(UpdateEqGains(
      gains: gains,
      presetName: '_GainCeilingCalibration',
    ));
    if (!_isLive) {
      setState(() => _isLive = true);
    }
  }

  /// Marca el valor actual del slider como techo de la banda actual y
  /// avanza a la siguiente. Tras la última banda, salta al resumen.
  void _markLimitAndAdvance() {
    setState(() {
      _bandCeilings[_currentBandIndex] = _sliderValue;
      _currentBandIndex += 1;
      if (_currentBandIndex < _kBandCount) {
        // Para la siguiente banda: arrancar en el valor previamente
        // guardado si existe (< 50), si no en 0.
        final next = _bandCeilings[_currentBandIndex];
        _sliderValue = next < _kCeilingMaxDb ? next : 0.0;
      }
      _isLive = false;
    });

    // Restaurar preset activo entre bandas para no dejar al técnico
    // con la ganancia aislada de la banda anterior cargada.
    _restoreActivePreset();
  }

  /// Resetea los 12 valores a 50 dB (sin restricción) y vuelve a la banda 0.
  Future<void> _resetAll() async {
    setState(() {
      _bandCeilings = List<double>.filled(_kBandCount, _kCeilingMaxDb);
      _currentBandIndex = 0;
      _sliderValue = 0.0;
      _isLive = false;
    });

    // Persistir el reset inmediatamente: deja el motor en "sin restricción"
    // aunque el técnico cierre la pantalla sin completar las 12 bandas.
    final bloc = context.read<AmplificationBloc>();
    await bloc.settingsRepository.setHardwareGainCeilingPerBandDb(_bandCeilings);

    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Calibración reseteada (sin restricción)'),
          backgroundColor: Colors.orange,
          duration: Duration(seconds: 2),
        ),
      );
    }
    _restoreActivePreset();
  }

  /// Persiste el array completo de 12 techos en SettingsRepository.
  Future<void> _finalizeCalibration() async {
    final bloc = context.read<AmplificationBloc>();
    await bloc.settingsRepository
        .setHardwareGainCeilingPerBandDb(_bandCeilings);

    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'Calibración finalizada — ${_calibratedCount()}/12 bandas calibradas',
          ),
          backgroundColor: Colors.green.shade700,
          duration: const Duration(seconds: 2),
        ),
      );
    }
    _restoreActivePreset();
    if (mounted) {
      Navigator.of(context).pop();
    }
  }

  /// Cuenta cuántas bandas tienen un techo < 50 (calibradas).
  int _calibratedCount() => _bandCeilings.where((v) => v < _kCeilingMaxDb).length;

  /// Vuelve a aplicar el preset activo al motor (descarta la ganancia
  /// aislada de calibración). Best-effort: el bloc maneja el caso donde
  /// no hay preset persistido.
  void _restoreActivePreset() async {
    final bloc = context.read<AmplificationBloc>();
    final preset = await bloc.settingsRepository.getLastEqPreset();
    if (preset != null && preset['gains'] != null) {
      final gains = (preset['gains'] as List)
          .cast<num>()
          .map((e) => e.toDouble())
          .toList();
      final name = preset['name'] as String? ?? 'Custom';
      bloc.add(UpdateEqGains(gains: gains, presetName: name));
    }
    if (mounted) {
      setState(() => _isLive = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final isSummary = _currentBandIndex >= _kBandCount;

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
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: isSummary ? _buildSummary() : _buildBandStep(),
        ),
      ),
    );
  }

  // ─── Step UI ──────────────────────────────────────────────────────────────

  Widget _buildBandStep() {
    final freqHz = _kBandFrequenciesHz[_currentBandIndex];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _buildInstructions(),
        const SizedBox(height: 20),

        // Indicador del paso actual.
        Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: const Color(0xFF16213e),
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: Colors.cyanAccent.withOpacity(0.4)),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Banda ${_currentBandIndex + 1} de $_kBandCount',
                style: const TextStyle(
                  color: Colors.cyanAccent,
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  letterSpacing: 0.4,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                'Frecuencia ${_formatFrequency(freqHz)}',
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 22,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 8),
              _buildProgressBar(),
            ],
          ),
        ),
        const SizedBox(height: 24),

        // Valor del slider.
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
              _sendIsolatedGain(_currentBandIndex, value);
            },
          ),
        ),
        const SizedBox(height: 4),
        const Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text('0 dB',
                style: TextStyle(color: Colors.white38, fontSize: 11)),
            Text('25 dB',
                style: TextStyle(color: Colors.white38, fontSize: 11)),
            Text('50 dB',
                style: TextStyle(color: Colors.white38, fontSize: 11)),
          ],
        ),
        const SizedBox(height: 28),

        // Botón "Marcar límite" (avanza automáticamente).
        ElevatedButton.icon(
          onPressed: _markLimitAndAdvance,
          icon: const Icon(Icons.flag),
          label: Text(
            _currentBandIndex == _kBandCount - 1
                ? 'Marcar límite y ver resumen'
                : 'Marcar límite y siguiente',
          ),
          style: ElevatedButton.styleFrom(
            backgroundColor: Colors.green.shade700,
            foregroundColor: Colors.white,
            padding: const EdgeInsets.symmetric(vertical: 14),
            textStyle: const TextStyle(
              fontSize: 15,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
        const SizedBox(height: 12),

        OutlinedButton.icon(
          onPressed: _resetAll,
          icon: const Icon(Icons.restart_alt),
          label: const Text('Reset (sin restricción)'),
          style: OutlinedButton.styleFrom(
            foregroundColor: Colors.orange,
            side: const BorderSide(color: Colors.orange),
            padding: const EdgeInsets.symmetric(vertical: 14),
            textStyle: const TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.w500,
            ),
          ),
        ),

        const Spacer(),

        if (_isLive) _buildLiveBanner(),
      ],
    );
  }

  // ─── Summary UI ───────────────────────────────────────────────────────────

  Widget _buildSummary() {
    final calibrated = _calibratedCount();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: const Color(0xFF16213e),
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: Colors.greenAccent.withOpacity(0.4)),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'Resumen de calibración',
                style: TextStyle(
                  color: Colors.greenAccent,
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 6),
              Text(
                '$calibrated de $_kBandCount bandas con techo calibrado.',
                style: const TextStyle(color: Colors.white70, fontSize: 12),
              ),
            ],
          ),
        ),
        const SizedBox(height: 16),

        Expanded(
          child: ListView.builder(
            itemCount: _kBandCount,
            itemBuilder: (context, i) {
              final freq = _kBandFrequenciesHz[i];
              final v = _bandCeilings[i];
              final isCalibrated = v < _kCeilingMaxDb;
              return Container(
                margin: const EdgeInsets.symmetric(vertical: 3),
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 10,
                ),
                decoration: BoxDecoration(
                  color: const Color(0xFF16213e),
                  borderRadius: BorderRadius.circular(6),
                  border: Border.all(
                    color: isCalibrated
                        ? Colors.orangeAccent.withOpacity(0.45)
                        : Colors.white12,
                  ),
                ),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(
                      'Banda ${i + 1} · ${_formatFrequency(freq)}',
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 13,
                      ),
                    ),
                    Text(
                      isCalibrated
                          ? '${v.toStringAsFixed(1)} dB'
                          : 'sin límite',
                      style: TextStyle(
                        color: isCalibrated
                            ? Colors.orangeAccent
                            : Colors.white54,
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ),
              );
            },
          ),
        ),
        const SizedBox(height: 12),

        ElevatedButton.icon(
          onPressed: _finalizeCalibration,
          icon: const Icon(Icons.check),
          label: const Text('Finalizar calibración'),
          style: ElevatedButton.styleFrom(
            backgroundColor: Colors.green.shade700,
            foregroundColor: Colors.white,
            padding: const EdgeInsets.symmetric(vertical: 14),
            textStyle: const TextStyle(
              fontSize: 15,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
        const SizedBox(height: 8),
        OutlinedButton.icon(
          onPressed: _resetAll,
          icon: const Icon(Icons.restart_alt),
          label: const Text('Reset (sin restricción)'),
          style: OutlinedButton.styleFrom(
            foregroundColor: Colors.orange,
            side: const BorderSide(color: Colors.orange),
            padding: const EdgeInsets.symmetric(vertical: 12),
            textStyle: const TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.w500,
            ),
          ),
        ),
      ],
    );
  }

  // ─── Helpers de UI ────────────────────────────────────────────────────────

  Widget _buildInstructions() {
    return Container(
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
            'Conectá el auricular al dispositivo. Para cada banda subí la '
            'ganancia hasta escuchar distorsión y pulsá "Marcar límite". '
            'El motor amplifica solo la frecuencia de la banda actual: '
            'el resto queda en 0 dB.',
            style: TextStyle(color: Colors.white70, fontSize: 12),
          ),
        ],
      ),
    );
  }

  Widget _buildProgressBar() {
    final progress = (_currentBandIndex + 1) / _kBandCount;
    return ClipRRect(
      borderRadius: BorderRadius.circular(4),
      child: LinearProgressIndicator(
        value: progress,
        minHeight: 5,
        backgroundColor: Colors.white12,
        valueColor:
            const AlwaysStoppedAnimation<Color>(Colors.cyanAccent),
      ),
    );
  }

  Widget _buildLiveBanner() {
    return Container(
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
              'Ganancia aislada en vivo. Al avanzar o salir se restaura '
              'el preset activo.',
              style: TextStyle(color: Colors.cyan, fontSize: 11),
            ),
          ),
        ],
      ),
    );
  }

  String _formatFrequency(int hz) {
    if (hz >= 1000) {
      final khz = hz / 1000.0;
      // 1000 -> "1 kHz", 1500 -> "1.5 kHz", 2000 -> "2 kHz".
      final isInteger = (hz % 1000) == 0;
      return isInteger
          ? '${khz.toStringAsFixed(0)} kHz'
          : '${khz.toStringAsFixed(1)} kHz';
    }
    return '$hz Hz';
  }

  @override
  void dispose() {
    if (_isLive) {
      _restoreActivePreset();
    }
    super.dispose();
  }
}
