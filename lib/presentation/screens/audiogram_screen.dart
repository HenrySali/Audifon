import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:hive/hive.dart';

import '../../audiometry/screens/audiometry_screen.dart';
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

  /// Última prescripción guardada por el diagnóstico (si existe).
  /// Indexada por frecuencia EQ (Hz) → ganancia en dB.
  Map<int, double> _prescribedGains = {};
  String? _prescribedPresetName;
  DateTime? _prescribedTimestamp;

  @override
  void initState() {
    super.initState();
    _initializeThresholds();
    _loadPrescription();
  }

  /// Carga la última prescripción guardada por el diagnóstico (si existe).
  Future<void> _loadPrescription() async {
    try {
      final box = await Hive.openBox<dynamic>('last_prescription');
      final raw = box.get('prescribed_gains');
      if (raw is List) {
        // Las gains están en orden de las 12 bandas estándar.
        final gains = raw.map((e) => (e as num).toDouble()).toList();
        if (gains.length == Audiogram.standardFrequencies.length) {
          final m = <int, double>{};
          for (int i = 0; i < gains.length; i++) {
            m[Audiogram.standardFrequencies[i]] = gains[i];
          }
          _prescribedGains = m;
        }
      }
      _prescribedPresetName = box.get('preset_name') as String?;
      final ts = box.get('timestamp') as String?;
      if (ts != null) {
        _prescribedTimestamp = DateTime.tryParse(ts);
      }
      if (mounted) setState(() {});
    } catch (_) {}
  }

  /// Lanza la pantalla de audiometría del paciente. Al volver, refresca el
  /// banner de prescripción desde Hive (puede haberse actualizado si el
  /// operador aplicó el audiograma resultante al perfil).
  Future<void> _runAudiometry() async {
    await Navigator.of(context).push<dynamic>(
      MaterialPageRoute<dynamic>(
        builder: (_) => const AudiometryScreen(),
      ),
    );
    if (!mounted) return;
    await _loadPrescription();
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
            icon: const Icon(Icons.medical_services),
            tooltip: 'Hacer audiometría',
            onPressed: _runAudiometry,
          ),
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

          // Selector de presets de hipoacusia
          _buildHearingLossPresets(),

          // Banner del último diagnóstico (si existe).
          if (_prescribedGains.isNotEmpty) _buildDiagnosticBanner(),

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
    final prescribed = _prescribedGains[freq];

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 2),
      child: Column(
        children: [
          // Valor actual + ganancia prescrita
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 2, vertical: 2),
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
            ],
          ),
          // Ganancia prescrita (línea cian, si hay diagnóstico).
          if (prescribed != null)
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Text(
                '+${prescribed.round()}',
                style: const TextStyle(
                  fontSize: 9,
                  color: Color(0xFF00e5ff),
                  fontWeight: FontWeight.w600,
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

  // ─── Presets de hipoacusia (tipos clínicos estándar) ────────────────
  // Datos basados en clasificación OMS + perfiles audiométricos típicos
  // de la literatura clínica (Clark 1981, Goodman 1965, Carhart 1950).

  static const _hearingLossPresets = <_HearingLossPreset>[
    _HearingLossPreset(
      name: 'Presbiacusia',
      subtitle: 'Pérdida descendente en agudos (edad)',
      icon: Icons.trending_down,
      color: Color(0xFFFF8A65),
      // 250  500  750  1000 1500 2000 2500 3000 3500 4000 6000 8000
      thresholds: [15, 20, 25, 30, 35, 45, 50, 55, 55, 60, 65, 70],
    ),
    _HearingLossPreset(
      name: 'Conductiva',
      subtitle: 'Pérdida plana uniforme (oído medio)',
      icon: Icons.horizontal_rule,
      color: Color(0xFF4FC3F7),
      thresholds: [40, 40, 40, 40, 40, 40, 40, 40, 35, 35, 35, 35],
    ),
    _HearingLossPreset(
      name: 'Sensorioneural',
      subtitle: 'Caída abrupta desde 1 kHz (cóclea)',
      icon: Icons.signal_cellular_alt,
      color: Color(0xFFE57373),
      thresholds: [10, 15, 20, 25, 45, 55, 60, 65, 70, 75, 75, 80],
    ),
    _HearingLossPreset(
      name: 'Pendiente inversa',
      subtitle: 'Pérdida en graves, agudos normales',
      icon: Icons.trending_up,
      color: Color(0xFF81C784),
      thresholds: [55, 50, 45, 40, 30, 20, 15, 15, 10, 10, 10, 10],
    ),
    _HearingLossPreset(
      name: 'Cookie-bite',
      subtitle: 'Pérdida en medios (1-3 kHz)',
      icon: Icons.expand_more,
      color: Color(0xFFBA68C8),
      thresholds: [15, 20, 35, 50, 55, 55, 50, 45, 35, 25, 20, 15],
    ),
    _HearingLossPreset(
      name: 'Muesca de ruido',
      subtitle: 'Notch en 4 kHz (exposición a ruido)',
      icon: Icons.noise_aware,
      color: Color(0xFFFFD54F),
      thresholds: [10, 10, 15, 15, 20, 25, 35, 50, 60, 65, 45, 30],
    ),
    _HearingLossPreset(
      name: 'Plana severa',
      subtitle: 'Pérdida uniforme severa (60-80 dB)',
      icon: Icons.remove,
      color: Color(0xFFEF5350),
      thresholds: [65, 65, 65, 70, 70, 70, 70, 75, 75, 75, 80, 80],
    ),
    _HearingLossPreset(
      name: 'Leve descendente',
      subtitle: 'Pérdida leve, típica inicial',
      icon: Icons.arrow_downward,
      color: Color(0xFFA5D6A7),
      thresholds: [10, 10, 15, 20, 25, 30, 30, 35, 35, 40, 40, 45],
    ),
  ];

  /// Construye el selector horizontal de presets de hipoacusia.
  Widget _buildHearingLossPresets() {
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      padding: const EdgeInsets.symmetric(vertical: 10),
      decoration: BoxDecoration(
        color: const Color(0xFF1a1a2e),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.white10),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14),
            child: Row(
              children: [
                Icon(Icons.library_books, color: Colors.white54, size: 16),
                const SizedBox(width: 8),
                const Text(
                  'Presets de hipoacusia',
                  style: TextStyle(
                    color: Colors.white70,
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const Spacer(),
                Text(
                  'Toca para cargar',
                  style: TextStyle(color: Colors.white30, fontSize: 10),
                ),
              ],
            ),
          ),
          const SizedBox(height: 10),
          SizedBox(
            height: 72,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 12),
              itemCount: _hearingLossPresets.length,
              separatorBuilder: (_, __) => const SizedBox(width: 8),
              itemBuilder: (context, index) {
                final preset = _hearingLossPresets[index];
                return _buildPresetChip(preset);
              },
            ),
          ),
        ],
      ),
    );
  }

  /// Construye un chip/tarjeta individual para un preset de hipoacusia.
  Widget _buildPresetChip(_HearingLossPreset preset) {
    return GestureDetector(
      onTap: () => _applyPreset(preset),
      child: Container(
        width: 130,
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        decoration: BoxDecoration(
          color: preset.color.withOpacity(0.1),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: preset.color.withOpacity(0.4)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Row(
              children: [
                Icon(preset.icon, color: preset.color, size: 14),
                const SizedBox(width: 5),
                Expanded(
                  child: Text(
                    preset.name,
                    style: TextStyle(
                      color: preset.color,
                      fontSize: 11,
                      fontWeight: FontWeight.w700,
                    ),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              preset.subtitle,
              style: const TextStyle(
                color: Colors.white38,
                fontSize: 9,
              ),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
          ],
        ),
      ),
    );
  }

  /// Aplica un preset de hipoacusia a los sliders del audiograma.
  void _applyPreset(_HearingLossPreset preset) {
    setState(() {
      for (int i = 0; i < Audiogram.standardFrequencies.length; i++) {
        _thresholds[Audiogram.standardFrequencies[i]] =
            preset.thresholds[i].toDouble();
      }
      _hasChanges = true;
    });
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('Preset "${preset.name}" cargado — toca Guardar para aplicar'),
        duration: const Duration(seconds: 2),
        backgroundColor: preset.color.withOpacity(0.8),
      ),
    );
  }

  /// Banner que aparece cuando hay un diagnóstico previo guardado.
  /// Muestra la fecha, el preset recomendado y un mini gráfico de las
  /// ganancias prescritas.
  Widget _buildDiagnosticBanner() {
    final maxGain = _prescribedGains.values.isEmpty
        ? 1.0
        : _prescribedGains.values
            .reduce((a, b) => a > b ? a : b)
            .clamp(1.0, 50.0);
    final ts = _prescribedTimestamp;
    final tsStr = ts != null
        ? '${ts.day.toString().padLeft(2, "0")}/${ts.month.toString().padLeft(2, "0")}/${ts.year}'
        : '—';
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: const Color(0xFF0f3460).withOpacity(0.6),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: Colors.cyan.withOpacity(0.4)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(children: [
            const Icon(Icons.medical_information,
                color: Color(0xFF00e5ff), size: 16),
            const SizedBox(width: 6),
            const Expanded(
              child: Text(
                'Última prescripción del diagnóstico',
                style: TextStyle(
                  color: Color(0xFF00e5ff),
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            Text(
              tsStr,
              style: const TextStyle(color: Colors.white54, fontSize: 10),
            ),
          ]),
          const SizedBox(height: 6),
          if (_prescribedPresetName != null)
            Padding(
              padding: const EdgeInsets.only(bottom: 4),
              child: Text(
                'Preset: ${_prescribedPresetName!}',
                style: const TextStyle(color: Colors.white, fontSize: 11),
              ),
            ),
          // Mini-gráfico de las ganancias prescritas (overlay).
          SizedBox(
            height: 30,
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: Audiogram.standardFrequencies.map((freq) {
                final g = _prescribedGains[freq] ?? 0.0;
                final h = (g / maxGain * 26).clamp(2.0, 26.0);
                return Expanded(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 1),
                    child: Container(
                      height: h,
                      decoration: BoxDecoration(
                        color: Colors.cyan.withOpacity(g > 0 ? 0.85 : 0.2),
                        borderRadius: BorderRadius.circular(2),
                      ),
                    ),
                  ),
                );
              }).toList(),
            ),
          ),
          const SizedBox(height: 4),
          const Text(
            'Las cifras +X dB sobre cada barra muestran la ganancia prescrita por frecuencia.',
            style: TextStyle(color: Colors.white54, fontSize: 9),
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

/// Modelo de datos para un preset de hipoacusia clínico.
class _HearingLossPreset {
  final String name;
  final String subtitle;
  final IconData icon;
  final Color color;
  /// Umbrales en dB HL para las 12 frecuencias estándar (250-8000 Hz).
  final List<int> thresholds;

  const _HearingLossPreset({
    required this.name,
    required this.subtitle,
    required this.icon,
    required this.color,
    required this.thresholds,
  });
}
