// Pantalla "Tope de ganancia" — slider para fijar el cap manual por banda.
//
// Cuando el usuario fija un valor, el bloc lo aplica como cap por banda
// en lugar del default automático según severidad del audiograma. Es la
// forma de que el técnico/paciente suba o baje la amplificación máxima
// sin tocar el código.

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../bloc/amplification_bloc.dart';
import '../bloc/amplification_event.dart';
import '../bloc/amplification_state.dart';

class GainCapScreen extends StatefulWidget {
  const GainCapScreen({super.key});

  @override
  State<GainCapScreen> createState() => _GainCapScreenState();
}

class _GainCapScreenState extends State<GainCapScreen> {
  static const double _kMin = 4.0;
  static const double _kMax = 24.0;

  double? _value;
  bool _autoMode = true;

  @override
  void initState() {
    super.initState();
    final bloc = context.read<AmplificationBloc>();
    final stored = bloc.settingsRepository.gainCapManualDb;
    if (stored != null) {
      _value = stored.clamp(_kMin, _kMax);
      _autoMode = false;
    } else {
      _autoMode = true;
      _value = 10.0; // valor inicial visible si el usuario activa manual
    }
  }

  Future<void> _save() async {
    final bloc = context.read<AmplificationBloc>();
    await bloc.settingsRepository
        .setGainCapManualDb(_autoMode ? null : _value);

    final bundle = bloc.lastBundle;
    final isMotorActive = bloc.state is AmplificationActive;

    if (bundle != null && isMotorActive) {
      bloc.add(ApplyAudiogramDrivenBundle(bundle: bundle));
    }

    if (!mounted) return;

    final appliedNow = bundle != null && isMotorActive;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(_autoMode
            ? 'Tope automático restaurado${appliedNow ? '' : ' (se aplicará al iniciar)'}'
            : 'Tope fijado en ${_value!.toStringAsFixed(1)} dB${appliedNow ? '' : ' (se aplicará al iniciar)'}'),
        backgroundColor:
            appliedNow ? Colors.green.shade700 : Colors.orange.shade700,
        duration: const Duration(seconds: 2),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF1a1a2e),
      appBar: AppBar(
        backgroundColor: const Color(0xFF0f3460),
        title: const Text('Tope de ganancia'),
        foregroundColor: Colors.white,
      ),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
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
                        Icon(Icons.info_outline, color: Colors.amber, size: 22),
                        SizedBox(width: 8),
                        Text(
                          '¿Qué hace este tope?',
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
                      'El sistema amplifica según tu audiograma (graves bajos, '
                      'agudos altos). Este tope limita el máximo en cualquier '
                      'banda para evitar saturación. Si saturás, bajalo. Si '
                      'querés más volumen y no satura, subilo.\n\n'
                      'Defaults automáticos:\n'
                      '• Audiograma severo (PTA > 35) → 8 dB\n'
                      '• Audiograma leve (PTA 20-35) → 14 dB\n'
                      '• Sin audiograma o normal → sin tope',
                      style: TextStyle(color: Colors.white70, fontSize: 12),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 24),

              // Toggle auto / manual.
              Row(
                children: [
                  Expanded(
                    child: ChoiceChip(
                      label: const Text('Automático'),
                      selected: _autoMode,
                      onSelected: (v) {
                        if (v) setState(() => _autoMode = true);
                      },
                      selectedColor: Colors.cyan,
                      labelStyle: TextStyle(
                        color: _autoMode ? Colors.black : Colors.white70,
                        fontWeight: FontWeight.w600,
                      ),
                      backgroundColor: const Color(0xFF16213e),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: ChoiceChip(
                      label: const Text('Manual'),
                      selected: !_autoMode,
                      onSelected: (v) {
                        if (v) setState(() => _autoMode = false);
                      },
                      selectedColor: Colors.orangeAccent,
                      labelStyle: TextStyle(
                        color: !_autoMode ? Colors.black : Colors.white70,
                        fontWeight: FontWeight.w600,
                      ),
                      backgroundColor: const Color(0xFF16213e),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 30),

              // Slider (solo visible / activo en modo manual).
              Opacity(
                opacity: _autoMode ? 0.4 : 1.0,
                child: AbsorbPointer(
                  absorbing: _autoMode,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Text(
                        'Tope: ${(_value ?? 10.0).toStringAsFixed(1)} dB',
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 24,
                          fontWeight: FontWeight.w700,
                        ),
                        textAlign: TextAlign.center,
                      ),
                      const SizedBox(height: 12),
                      SliderTheme(
                        data: SliderThemeData(
                          activeTrackColor:
                              (_value ?? 10.0) > 18 ? Colors.red : Colors.cyan,
                          inactiveTrackColor: Colors.white24,
                          thumbColor: Colors.white,
                          overlayColor: Colors.cyan.withOpacity(0.2),
                          valueIndicatorColor: const Color(0xFF0f3460),
                        ),
                        child: Slider(
                          value: (_value ?? 10.0).clamp(_kMin, _kMax),
                          min: _kMin,
                          max: _kMax,
                          divisions: 40,
                          label: '${(_value ?? 10.0).toStringAsFixed(1)} dB',
                          onChanged: (v) => setState(() => _value = v),
                        ),
                      ),
                      const Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Text('4 dB',
                              style: TextStyle(
                                  color: Colors.white38, fontSize: 11)),
                          Text('14 dB',
                              style: TextStyle(
                                  color: Colors.white38, fontSize: 11)),
                          Text('24 dB',
                              style: TextStyle(
                                  color: Colors.white38, fontSize: 11)),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
              const Spacer(),

              ElevatedButton.icon(
                onPressed: _save,
                icon: const Icon(Icons.check),
                label: const Text('Guardar'),
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
            ],
          ),
        ),
      ),
    );
  }
}
