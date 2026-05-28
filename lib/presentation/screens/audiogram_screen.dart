import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../domain/entities/audiogram.dart';
import '../bloc/amplification_bloc.dart';
import '../bloc/amplification_event.dart';

/// Pantalla de configuración de audiograma con editor de 12 frecuencias.
///
/// Muestra sliders verticales para cada frecuencia audiométrica (250-8000 Hz)
/// con rango de 0-120 dB HL. Pre-poblada con el audiograma por defecto
/// (0 dB HL en bajas, 40-75 dB HL en altas).
///
/// Al guardar, despacha [UpdateAudiogram] al BLoC para recalcular la
/// prescripción NAL-NL2 y aplicarla al DSP sin reiniciar la sesión de audio.
///
/// Requisitos: 4.1, 4.3, 4.4
class AudiogramScreen extends StatefulWidget {
  /// Audiograma actual para pre-poblar el editor.
  /// Si es null, se usa el audiograma por defecto.
  final Audiogram? currentAudiogram;

  const AudiogramScreen({super.key, this.currentAudiogram});

  @override
  State<AudiogramScreen> createState() => _AudiogramScreenState();
}

class _AudiogramScreenState extends State<AudiogramScreen> {
  /// Umbrales editables por frecuencia (Hz → dB HL).
  late Map<int, double> _thresholds;

  /// Indica si hubo cambios sin guardar.
  bool _hasChanges = false;

  @override
  void initState() {
    super.initState();
    _initializeThresholds();
  }

  /// Inicializa los umbrales desde el audiograma actual o los valores por defecto.
  void _initializeThresholds() {
    final source = widget.currentAudiogram?.thresholds ??
        Audiogram.defaultThresholds;
    // Crear copia mutable con todas las 12 frecuencias
    _thresholds = {};
    for (final freq in Audiogram.standardFrequencies) {
      _thresholds[freq] = source[freq] ?? 0.0;
    }
  }

  /// Restaura los valores predeterminados del audiograma.
  void _restoreDefaults() {
    setState(() {
      for (final freq in Audiogram.standardFrequencies) {
        _thresholds[freq] = Audiogram.defaultThresholds[freq] ?? 0.0;
      }
      _hasChanges = true;
    });
  }

  /// Guarda el audiograma y despacha UpdateAudiogram al BLoC.
  ///
  /// Recalcula la prescripción NAL-NL2 y la aplica al DSP
  /// sin reiniciar la sesión de audio (Req 4.3).
  void _saveAudiogram() {
    final points = _thresholds.entries
        .map((e) => AudiogramPoint(frequencyHz: e.key, thresholdHL: e.value))
        .toList()
      ..sort((a, b) => a.frequencyHz.compareTo(b.frequencyHz));

    context.read<AmplificationBloc>().add(UpdateAudiogram(audiogram: points));

    setState(() {
      _hasChanges = false;
    });

    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('Audiograma guardado. Prescripción NAL-NL2 actualizada.'),
        duration: Duration(seconds: 2),
      ),
    );

    Navigator.of(context).pop();
  }

  /// Muestra diálogo para guardar el audiograma actual como un preset con nombre.
  void _saveAsPreset() {
    final controller = TextEditingController();
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Guardar como Preset'),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(
            hintText: 'Nombre del preset (ej: Mesa de trabajo)',
            border: OutlineInputBorder(),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancelar'),
          ),
          ElevatedButton(
            onPressed: () {
              final name = controller.text.trim();
              if (name.isEmpty) return;
              // Dispatch save preset event
              final points = _thresholds.entries
                  .map((e) => AudiogramPoint(frequencyHz: e.key, thresholdHL: e.value))
                  .toList()
                ..sort((a, b) => a.frequencyHz.compareTo(b.frequencyHz));
              context.read<AmplificationBloc>().add(
                SaveCustomPreset(name: name, audiogram: points),
              );
              Navigator.pop(ctx);
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(
                  content: Text('Preset "$name" guardado'),
                  duration: const Duration(seconds: 2),
                ),
              );
            },
            child: const Text('Guardar'),
          ),
        ],
      ),
    );
  }

  /// Formatea la frecuencia para mostrar en la UI.
  String _formatFrequency(int freq) {
    if (freq >= 1000) {
      final kHz = freq / 1000;
      if (kHz == kHz.roundToDouble()) {
        return '${kHz.round()}k';
      }
      return '${kHz.toStringAsFixed(1)}k';
    }
    return '$freq';
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Configurar Audiograma'),
        actions: [
          IconButton(
            icon: const Icon(Icons.bookmark_add),
            tooltip: 'Guardar como Preset',
            onPressed: _saveAsPreset,
          ),
          IconButton(
            icon: const Icon(Icons.restore),
            tooltip: 'Restaurar valores predeterminados',
            onPressed: _restoreDefaults,
          ),
        ],
      ),
      body: Column(
        children: [
          // Header con instrucciones
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
            child: Text(
              'Ajuste los umbrales auditivos (dB HL) para cada frecuencia. '
              'Valores más altos indican mayor pérdida auditiva.',
              style: TextStyle(
                color: Colors.grey[400],
                fontSize: 13,
              ),
            ),
          ),

          // Audiogram editor con sliders verticales
          Expanded(
            child: _buildAudiogramEditor(),
          ),

          // Botones de acción
          _buildActionButtons(),
        ],
      ),
    );
  }

  /// Construye el editor de audiograma con 12 sliders verticales.
  Widget _buildAudiogramEditor() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8),
      child: Column(
        children: [
          // Escala dB HL (eje Y)
          Padding(
            padding: const EdgeInsets.only(left: 4, right: 4, top: 8),
            child: Row(
              children: [
                const SizedBox(width: 28),
                Expanded(
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: const [
                      Text('0', style: TextStyle(fontSize: 10, color: Colors.grey)),
                      Text('dB HL', style: TextStyle(fontSize: 10, color: Colors.grey)),
                      Text('120', style: TextStyle(fontSize: 10, color: Colors.grey)),
                    ],
                  ),
                ),
              ],
            ),
          ),

          // Sliders verticales
          Expanded(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: Audiogram.standardFrequencies.map((freq) {
                return Expanded(
                  child: _buildFrequencySlider(freq),
                );
              }).toList(),
            ),
          ),
        ],
      ),
    );
  }

  /// Construye un slider vertical para una frecuencia específica.
  Widget _buildFrequencySlider(int freq) {
    final threshold = _thresholds[freq] ?? 0.0;
    // Color basado en severidad de la pérdida
    final color = _getThresholdColor(threshold);

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 2),
      child: Column(
        children: [
          // Valor actual
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 2),
            decoration: BoxDecoration(
              color: color.withOpacity(0.2),
              borderRadius: BorderRadius.circular(4),
            ),
            child: Text(
              '${threshold.round()}',
              style: TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.bold,
                color: color,
              ),
            ),
          ),

          const SizedBox(height: 4),

          // Slider vertical (rotado)
          Expanded(
            child: RotatedBox(
              quarterTurns: 3,
              child: SliderTheme(
                data: SliderTheme.of(context).copyWith(
                  activeTrackColor: color,
                  inactiveTrackColor: color.withOpacity(0.2),
                  thumbColor: color,
                  overlayColor: color.withOpacity(0.1),
                  trackHeight: 4,
                  thumbShape: const RoundSliderThumbShape(
                    enabledThumbRadius: 7,
                  ),
                ),
                child: Slider(
                  value: threshold,
                  min: 0,
                  max: 120,
                  divisions: 24,
                  onChanged: (value) {
                    setState(() {
                      _thresholds[freq] = value;
                      _hasChanges = true;
                    });
                  },
                ),
              ),
            ),
          ),

          const SizedBox(height: 4),

          // Etiqueta de frecuencia
          Text(
            _formatFrequency(freq),
            style: const TextStyle(
              fontSize: 9,
              color: Colors.grey,
            ),
          ),
          Text(
            'Hz',
            style: TextStyle(
              fontSize: 8,
              color: Colors.grey[600],
            ),
          ),
        ],
      ),
    );
  }

  /// Retorna un color basado en la severidad de la pérdida auditiva.
  Color _getThresholdColor(double threshold) {
    if (threshold <= 20) return Colors.green;
    if (threshold <= 40) return Colors.yellow;
    if (threshold <= 55) return Colors.orange;
    if (threshold <= 70) return Colors.deepOrange;
    return Colors.red;
  }

  /// Construye los botones de acción (restaurar y guardar).
  Widget _buildActionButtons() {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Theme.of(context).appBarTheme.backgroundColor,
        border: Border(
          top: BorderSide(color: Colors.grey[800]!, width: 0.5),
        ),
      ),
      child: SafeArea(
        top: false,
        child: Row(
          children: [
            // Botón restaurar valores predeterminados
            Expanded(
              child: OutlinedButton.icon(
                onPressed: _restoreDefaults,
                icon: const Icon(Icons.restore, size: 18),
                label: const Text(
                  'Restaurar predeterminados',
                  style: TextStyle(fontSize: 12),
                ),
                style: OutlinedButton.styleFrom(
                  padding: const EdgeInsets.symmetric(vertical: 12),
                ),
              ),
            ),

            const SizedBox(width: 12),

            // Botón guardar
            Expanded(
              child: FilledButton.icon(
                onPressed: _hasChanges ? _saveAudiogram : null,
                icon: const Icon(Icons.save, size: 18),
                label: const Text('Guardar'),
                style: FilledButton.styleFrom(
                  padding: const EdgeInsets.symmetric(vertical: 12),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
