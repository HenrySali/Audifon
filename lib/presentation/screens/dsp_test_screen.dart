import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../domain/entities/eq_preset.dart';
import '../../domain/services/preset_advisor.dart';
import '../bloc/amplification_bloc.dart';
import '../bloc/amplification_event.dart' show ChangeVolume, UpdateEqGains;
import '../bloc/amplification_state.dart';

/// Pantalla de diagnóstico del pipeline DSP — muestra métricas en tiempo real
/// de cada etapa para cada preset EQ.
///
/// Funciones:
///  1. Métricas en vivo Input → NR → EQ → WDRC → Volume → Output.
///  2. Banner con sugerencia de preset según ambiente detectado por el
///     clasificador C++ (QUIET / SPEECH / SPEECH_IN_NOISE / NOISE).
///  3. Loudness compensation entre presets durante "Run All Tests" — ajusta
///     master volume para que la comparación sea por timbre y no por volumen.
///  4. Tope de volumen del test (cap) — protege al usuario de presets que
///     suben mucho.
///  5. Export JSON del log.
class DspTestScreen extends StatefulWidget {
  const DspTestScreen({super.key});

  @override
  State<DspTestScreen> createState() => _DspTestScreenState();
}

class _DspTestScreenState extends State<DspTestScreen> {
  static const _channel = MethodChannel('com.psk.hearing_aid/audio');

  // ─── Estado de polling de métricas ────────────────────────────────────
  Timer? _pollTimer;
  Timer? _ambientPollTimer;
  Map<String, dynamic>? _metrics;

  // ─── Estado del test seleccionado ──────────────────────────────────────
  int? _activePresetIndex;

  // ─── Run All ──────────────────────────────────────────────────────────
  bool _runningAll = false;
  int _runAllIndex = 0;
  final List<Map<String, dynamic>> _testLog = [];

  // ─── Volumen guardado del usuario (antes del test) ────────────────────
  double? _savedVolumeDb;

  // ─── Tope de volumen durante el test (relativo al volumen guardado) ───
  double _testCeilingDeltaDb = -3.0; // -3 dB por defecto

  // ─── Loudness compensation ────────────────────────────────────────────
  bool _loudnessCompensation = true;

  // ─── Ambiente detectado más reciente ──────────────────────────────────
  int _envClass = -1; // -1 = aún sin dato

  // ─── Saturación del limitador MPO (spec audifono-v3 T10.2 / R9.2) ─────
  // Métricas expuestas por el motor en `getDspStageMetrics()`:
  //   - `mpoLimitingFraction` (double 0..1): fracción de muestras del
  //     último bloque en que el MPO recortó.
  //   - `mpoLimitingSustained` (bool): true si la limitación fue sostenida
  //     (~≥200 ms). Señal del aviso visible al técnico.
  // Tolerantes a `.so` viejos que no exponen estas claves → 0.0 / false.
  double _mpoFraction = 0.0;
  bool _mpoSustained = false;

  /// Umbral de `mpoLimitingFraction` por encima del cual se considera que
  /// el limitador está actuando de forma notable aunque no sea sostenida.
  static const double _satFractionThreshold = 0.2;

  @override
  void initState() {
    super.initState();
    // Asegurar que el clasificador esté activo para leer environmentClass.
    _channel.invokeMethod('updateAutoClassify', {'enabled': true})
        .catchError((_) => null);
    // Polling permanente de ambiente (más lento que el del preset activo).
    _ambientPollTimer = Timer.periodic(
      const Duration(milliseconds: 500),
      (_) => _fetchAmbientOnly(),
    );
  }

  Future<void> _fetchAmbientOnly() async {
    // Si ya hay polling completo activo, no duplicar.
    if (_pollTimer?.isActive == true) return;
    try {
      final r = await _channel.invokeMethod<Map>('getDspStageMetrics');
      if (mounted && r != null) {
        final m = Map<String, dynamic>.from(r);
        final ec = m['environmentClass'];
        final newEnv = (ec is int && ec >= 0) ? ec : _envClass;
        final frac = _satFraction(m['mpoLimitingFraction']);
        final sust = _satSustained(m['mpoLimitingSustained']);
        if (newEnv != _envClass ||
            frac != _mpoFraction ||
            sust != _mpoSustained) {
          setState(() {
            _envClass = newEnv;
            _mpoFraction = frac;
            _mpoSustained = sust;
          });
        }
      }
    } catch (_) {}
  }

  /// Parser tolerante de `mpoLimitingFraction`: acepta cualquier `num`,
  /// recorta a `[0,1]`. `.so` viejos que no exponen la clave → 0.0.
  double _satFraction(dynamic v) =>
      v is num ? v.toDouble().clamp(0.0, 1.0).toDouble() : 0.0;

  /// Parser tolerante de `mpoLimitingSustained`: acepta `bool` o `num`
  /// (1.0f → true). Clave ausente → false.
  bool _satSustained(dynamic v) =>
      v is bool ? v : (v is num ? v != 0 : false);

  @override
  void dispose() {
    _pollTimer?.cancel();
    _ambientPollTimer?.cancel();
    // Si quedó algo activo, restaurar volumen
    _restoreVolume();
    super.dispose();
  }

  // ────────────────────────────────────────────────────────────────────────
  // Volume management
  // ────────────────────────────────────────────────────────────────────────

  Future<void> _saveCurrentVolumeIfNeeded() async {
    if (_savedVolumeDb != null) return;
    // No tenemos getter directo, asumimos 0 dB si no se conoce.
    // El test ajustará el volumen relativo a este valor.
    _savedVolumeDb = 0.0;
  }

  Future<void> _setEngineVolume(double db) async {
    try {
      await _channel.invokeMethod('updateVolume', {'volumeDb': db});
    } catch (_) {}
  }

  Future<void> _restoreVolume() async {
    if (_savedVolumeDb != null) {
      await _setEngineVolume(_savedVolumeDb!);
      _savedVolumeDb = null;
    }
  }

  /// Aplica el volumen efectivo durante el test:
  ///   volumen efectivo = saved + ceiling - loudnessOffset(preset)
  /// donde loudnessOffset reduce el volumen para presets con mayor ganancia
  /// promedio en banda de habla.
  Future<void> _applyTestVolume(EqPreset preset) async {
    await _saveCurrentVolumeIfNeeded();
    final base = (_savedVolumeDb ?? 0.0) + _testCeilingDeltaDb;
    final compensation = _loudnessCompensation
        ? PresetAdvisor.loudnessNormalizationOffsetDb(preset)
        : 0.0;
    final effective = (base + compensation).clamp(-20.0, 10.0);
    await _setEngineVolume(effective);
  }

  // ────────────────────────────────────────────────────────────────────────
  // Test single preset
  // ────────────────────────────────────────────────────────────────────────

  Future<void> _startTest(int idx) async {
    setState(() {
      _activePresetIndex = idx;
      _metrics = null;
    });
    final preset = EqPreset.allPresets[idx];
    try {
      await _channel.invokeMethod('updateEqGains', {'gains': preset.gains});
    } catch (_) {}
    // Aplicar volumen del test (cap + loudness comp)
    await _applyTestVolume(preset);

    _pollTimer?.cancel();
    _pollTimer = Timer.periodic(const Duration(milliseconds: 100), (_) => _fetch());
  }

  Future<void> _stopTest() async {
    _pollTimer?.cancel();
    await _restoreVolume();
    setState(() {
      _activePresetIndex = null;
      _metrics = null;
    });
  }

  Future<void> _fetch() async {
    try {
      final r = await _channel.invokeMethod<Map>('getDspStageMetrics');
      if (mounted && r != null) {
        final m = Map<String, dynamic>.from(r);
        final ec = m['environmentClass'];
        if (ec is int) _envClass = ec;
        _mpoFraction = _satFraction(m['mpoLimitingFraction']);
        _mpoSustained = _satSustained(m['mpoLimitingSustained']);
        setState(() => _metrics = m);
      }
    } on MissingPluginException {
      if (mounted) setState(() => _metrics = null);
    } catch (_) {}
  }

  // ────────────────────────────────────────────────────────────────────────
  // Run all tests
  // ────────────────────────────────────────────────────────────────────────

  Future<void> _runAll() async {
    setState(() {
      _runningAll = true;
      _runAllIndex = 0;
      _testLog.clear();
    });
    for (int i = 0; i < EqPreset.allPresets.length; i++) {
      if (!mounted || !_runningAll) break;
      setState(() => _runAllIndex = i);
      await _startTest(i);
      // Esperar 1.2 s para que el engine se estabilice con el nuevo preset
      await Future.delayed(const Duration(milliseconds: 1200));
      // Tomar 5 muestras durante 2 s y guardar la última
      final samples = <Map<String, dynamic>>[];
      for (int s = 0; s < 5; s++) {
        await Future.delayed(const Duration(milliseconds: 400));
        if (_metrics != null) samples.add(Map<String, dynamic>.from(_metrics!));
      }
      _testLog.add({
        'preset': EqPreset.allPresets[i].name,
        'gains': EqPreset.allPresets[i].gains,
        'volumeOffset':
            _loudnessCompensation
                ? PresetAdvisor.loudnessNormalizationOffsetDb(
                    EqPreset.allPresets[i])
                : 0.0,
        'ts': DateTime.now().toIso8601String(),
        'metrics': samples.isNotEmpty ? samples.last : {'status': 'no_data'},
        'sampleCount': samples.length,
      });
    }
    await _stopTest();
    // Restaurar preset Normal al finalizar
    try {
      await _channel.invokeMethod(
        'updateEqGains',
        {'gains': EqPreset.allPresets[0].gains},
      );
    } catch (_) {}
    if (mounted) setState(() => _runningAll = false);
  }

  // ────────────────────────────────────────────────────────────────────────
  // Apply suggested preset
  // ────────────────────────────────────────────────────────────────────────

  /// Aplica el preset sugerido al **sistema completo** (no solo al engine
  /// como hace [_startTest]). Despacha por [AmplificationBloc] igual que el
  /// botón Auto Suggest de la pantalla principal: persiste el preset,
  /// actualiza el estado/UI globales y aplica el volumen efectivo de la
  /// prueba como nuevo volumen del usuario.
  ///
  /// Volumen aplicado:
  ///   nuevoVolumen = volumenActualUsuario
  ///                  + tope del test (`_testCeilingDeltaDb`)
  ///                  + compensación de loudness del preset (si está ON)
  ///
  /// El valor se clamp-ea solo a los límites físicos [-20, +10] dB pero **no
  /// se impone como techo permanente**: el usuario puede subirlo o bajarlo
  /// libremente después desde el slider de volumen.
  Future<void> _applySuggested() async {
    if (_envClass < 0) return;
    final suggested = PresetAdvisor.suggestFor(_envClass);

    final bloc = context.read<AmplificationBloc>();

    // Detener el polling de métricas y descartar el "savedVolume" del modo
    // test: ya no vamos a restaurar nada en dispose, vamos a comprometernos
    // con el volumen del test como volumen real.
    _pollTimer?.cancel();
    _savedVolumeDb = null;
    if (mounted) {
      setState(() {
        _activePresetIndex = null;
        _metrics = null;
      });
    }

    // 1. Aplicar preset EQ por el bloc (persiste + actualiza estado +
    //    llama al engine si está activo).
    bloc.add(UpdateEqGains(
      gains: suggested.gains,
      presetName: suggested.name,
    ));

    // 2. Calcular el volumen efectivo del test para el preset sugerido y
    //    aplicarlo al sistema (sin imponer un cap, solo el rango físico).
    final st = bloc.state;
    final compensation = _loudnessCompensation
        ? PresetAdvisor.loudnessNormalizationOffsetDb(suggested)
        : 0.0;
    if (st is AmplificationActive) {
      final base = st.volumeDb; // volumen real actual del usuario
      final newVolume =
          (base + _testCeilingDeltaDb + compensation).clamp(-20.0, 10.0);
      bloc.add(ChangeVolume(volumeDb: newVolume));
    }

    if (!mounted) return;
    final label = PresetAdvisor.labelFor(_envClass);
    final parts = <String>[
      '🎯 $label → ${suggested.name}',
      'Tope ${_testCeilingDeltaDb.toStringAsFixed(0)} dB',
    ];
    if (compensation != 0) {
      parts.add('LC ${compensation.toStringAsFixed(1)} dB');
    }
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(parts.join('   ·   ')),
        duration: const Duration(seconds: 3),
      ),
    );
  }

  // ────────────────────────────────────────────────────────────────────────
  // Export
  // ────────────────────────────────────────────────────────────────────────

  void _exportLog() {
    if (_testLog.isEmpty) return;
    final json = const JsonEncoder.withIndent('  ').convert({
      'date': DateTime.now().toIso8601String(),
      'loudnessCompensation': _loudnessCompensation,
      'testCeilingDeltaDb': _testCeilingDeltaDb,
      'results': _testLog,
    });
    Clipboard.setData(ClipboardData(text: json));
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('📋 Log copiado (${_testLog.length} presets)')),
    );
  }

  // ────────────────────────────────────────────────────────────────────────
  // UI helpers
  // ────────────────────────────────────────────────────────────────────────

  Color _lvlColor(double? v) {
    if (v == null) return Colors.white38;
    if (v > 0.95) return Colors.red;
    if (v > 0.8) return Colors.orange;
    return Colors.green;
  }

  // ────────────────────────────────────────────────────────────────────────
  // Build
  // ────────────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF0a0e21),
      appBar: AppBar(
        title: const Text('DSP Pipeline Test'),
        backgroundColor: const Color(0xFF0f3460),
        foregroundColor: Colors.white,
        actions: [
          if (_testLog.isNotEmpty)
            IconButton(
              icon: const Icon(Icons.copy),
              tooltip: 'Export JSON',
              onPressed: _exportLog,
            ),
        ],
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _buildEnvBanner(),
            const SizedBox(height: 8),
            _buildSaturationIndicator(),
            const SizedBox(height: 8),
            _buildRunAllAndOptions(),
            const SizedBox(height: 10),
            if (_activePresetIndex != null) ...[
              _buildMetrics(),
              const SizedBox(height: 8),
              _buildEqBars(),
              const SizedBox(height: 8),
              _buildWdrc(),
              const SizedBox(height: 12),
            ],
            _buildPresets(),
          ],
        ),
      ),
    );
  }

  // ────────────────────────────────────────────────────────────────────────
  // Indicador de saturación del limitador (MPO) — R9.2 audifono-v3
  // ────────────────────────────────────────────────────────────────────────
  //
  // Se alimenta del MISMO polling de métricas ya existente:
  //   - `_fetchAmbientOnly` (500 ms, siempre activo cuando no hay test)
  //   - `_fetch` (100 ms, durante un test de preset)
  // Muestra en vivo si el limitador clínico está recortando la salida:
  //   - VERDE  "Sin saturación"  → no limita.
  //   - NARANJA "Limitando"       → fracción > umbral (recorte puntual).
  //   - ROJO    "SATURACIÓN sostenida" → `mpoLimitingSustained == true`
  //     (≥ ~200 ms cuasi-continuos: la salida está pegada al techo).
  // El valor cuantitativo (% de muestras recortadas) acompaña al estado.
  Widget _buildSaturationIndicator() {
    final bool limiting = _mpoFraction > _satFractionThreshold;
    final bool alert = _mpoSustained || limiting;
    final String pct = (_mpoFraction * 100).toStringAsFixed(0);

    final Color color = _mpoSustained
        ? Colors.red
        : (limiting ? Colors.orange : Colors.green);
    final String state = _mpoSustained
        ? 'SATURACIÓN sostenida'
        : (limiting ? 'Limitando' : 'Sin saturación');
    final IconData icon =
        alert ? Icons.warning_amber_rounded : Icons.check_circle_outline;

    return Semantics(
      container: true,
      label: 'Indicador de saturación del limitador MPO. '
          'Estado: $state. Recorte del $pct por ciento de las muestras '
          'del último bloque.',
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: BoxDecoration(
          color: color.withOpacity(0.12),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: color.withOpacity(0.5)),
        ),
        child: Row(children: [
          Icon(icon, color: color, size: 18),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Limitador (MPO): $state',
                  style: TextStyle(
                    color: color,
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                Text(
                  'Recorte: $pct % de las muestras del último bloque',
                  style: const TextStyle(color: Colors.white70, fontSize: 10),
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          // Barra cuantitativa (0..1) con el color del estado actual.
          SizedBox(
            width: 64,
            child: ClipRRect(
              borderRadius: BorderRadius.circular(3),
              child: SizedBox(
                height: 8,
                child: LinearProgressIndicator(
                  value: _mpoFraction.clamp(0.0, 1.0),
                  backgroundColor: Colors.white.withOpacity(0.08),
                  color: color,
                ),
              ),
            ),
          ),
        ]),
      ),
    );
  }

  // ────────────────────────────────────────────────────────────────────────
  // Banner de ambiente + sugerencia
  // ────────────────────────────────────────────────────────────────────────

  Widget _buildEnvBanner() {
    // Si todavía no hay datos de ambiente, mostrar pista breve.
    if (_envClass < 0) {
      return Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: BoxDecoration(
          color: const Color(0xFF16213e),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: Colors.white12),
        ),
        child: const Row(children: [
          Icon(Icons.eco, color: Colors.white38, size: 16),
          SizedBox(width: 8),
          Expanded(
            child: Text(
              'Esperando lectura del clasificador de ambiente…',
              style: TextStyle(color: Colors.white54, fontSize: 11),
            ),
          ),
        ]),
      );
    }

    final label = PresetAdvisor.labelFor(_envClass);
    final suggested = PresetAdvisor.suggestFor(_envClass);
    final volDelta = PresetAdvisor.volumeDeltaFor(_envClass);
    final color = _envColor(_envClass);

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: color.withOpacity(0.10),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: color.withOpacity(0.4)),
      ),
      child: Row(children: [
        Icon(_envIcon(_envClass), color: color, size: 18),
        const SizedBox(width: 8),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Ambiente: $label',
                style: TextStyle(
                  color: color,
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                ),
              ),
              Text(
                'Sugerido: ${suggested.name}'
                '${volDelta != 0 ? '   ·   Vol ${volDelta.toStringAsFixed(0)} dB' : ''}',
                style: const TextStyle(color: Colors.white70, fontSize: 10),
              ),
            ],
          ),
        ),
        SizedBox(
          height: 28,
          child: ElevatedButton(
            onPressed: _runningAll ? null : _applySuggested,
            style: ElevatedButton.styleFrom(
              backgroundColor: color.withOpacity(0.20),
              foregroundColor: color,
              side: BorderSide(color: color),
              padding: const EdgeInsets.symmetric(horizontal: 10),
              textStyle: const TextStyle(fontSize: 10),
            ),
            child: const Text('Aplicar'),
          ),
        ),
      ]),
    );
  }

  Color _envColor(int c) {
    switch (c) {
      case 0:
        return Colors.lightGreenAccent;
      case 1:
        return Colors.cyan;
      case 2:
        return Colors.amber;
      case 3:
        return Colors.deepOrangeAccent;
      default:
        return Colors.white54;
    }
  }

  IconData _envIcon(int c) {
    switch (c) {
      case 0:
        return Icons.nights_stay;
      case 1:
        return Icons.record_voice_over;
      case 2:
        return Icons.groups;
      case 3:
        return Icons.traffic;
      default:
        return Icons.help_outline;
    }
  }

  // ────────────────────────────────────────────────────────────────────────
  // Run All + Opciones (loudness comp + ceiling)
  // ────────────────────────────────────────────────────────────────────────

  Widget _buildRunAllAndOptions() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        ElevatedButton.icon(
          onPressed: _runningAll
              ? () => setState(() => _runningAll = false)
              : _runAll,
          icon: Icon(_runningAll ? Icons.stop : Icons.play_arrow, size: 18),
          label: Text(
            _runningAll
                ? 'Stop (${_runAllIndex + 1}/${EqPreset.allPresets.length})'
                : 'Run All Tests',
          ),
          style: ElevatedButton.styleFrom(
            backgroundColor: _runningAll
                ? Colors.red.withOpacity(0.2)
                : Colors.cyan.withOpacity(0.15),
            foregroundColor: _runningAll ? Colors.red : Colors.cyan,
            side: BorderSide(color: _runningAll ? Colors.red : Colors.cyan),
            padding: const EdgeInsets.symmetric(vertical: 12),
          ),
        ),
        const SizedBox(height: 8),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
          decoration: BoxDecoration(
            color: const Color(0xFF16213e),
            borderRadius: BorderRadius.circular(8),
          ),
          child: Column(
            children: [
              // Loudness compensation toggle
              Row(children: [
                const Icon(Icons.volume_up, color: Color(0xFF00e5ff), size: 14),
                const SizedBox(width: 6),
                const Expanded(
                  child: Text(
                    'Compensación de volumen entre presets',
                    style: TextStyle(color: Colors.white, fontSize: 11),
                  ),
                ),
                Switch(
                  value: _loudnessCompensation,
                  onChanged: _runningAll
                      ? null
                      : (v) {
                          setState(() => _loudnessCompensation = v);
                          if (_activePresetIndex != null) {
                            _applyTestVolume(
                              EqPreset.allPresets[_activePresetIndex!],
                            );
                          }
                        },
                  activeColor: Colors.cyan,
                ),
              ]),
              // Test ceiling slider
              Row(children: [
                const Icon(Icons.tune, color: Color(0xFF00e5ff), size: 14),
                const SizedBox(width: 6),
                const Text(
                  'Tope de volumen del test',
                  style: TextStyle(color: Colors.white, fontSize: 11),
                ),
                const Spacer(),
                Text(
                  '${_testCeilingDeltaDb.toStringAsFixed(0)} dB',
                  style: const TextStyle(
                    color: Colors.cyan,
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ]),
              SliderTheme(
                data: SliderTheme.of(context).copyWith(
                  trackHeight: 2.5,
                  thumbShape: const RoundSliderThumbShape(
                    enabledThumbRadius: 6,
                  ),
                ),
                child: Slider(
                  value: _testCeilingDeltaDb,
                  min: -10,
                  max: 0,
                  divisions: 10,
                  activeColor: Colors.cyan,
                  inactiveColor: Colors.white12,
                  onChanged: _runningAll
                      ? null
                      : (v) {
                          setState(() => _testCeilingDeltaDb = v);
                          if (_activePresetIndex != null) {
                            _applyTestVolume(
                              EqPreset.allPresets[_activePresetIndex!],
                            );
                          }
                        },
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  // ────────────────────────────────────────────────────────────────────────
  // Métricas
  // ────────────────────────────────────────────────────────────────────────

  Widget _buildMetrics() {
    final preset = EqPreset.allPresets[_activePresetIndex!];
    final m = _metrics;
    final compensation = _loudnessCompensation
        ? PresetAdvisor.loudnessNormalizationOffsetDb(preset)
        : 0.0;
    return Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: const Color(0xFF16213e),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: Colors.cyan.withOpacity(0.3)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(children: [
            const Icon(Icons.analytics, color: Color(0xFF00e5ff), size: 16),
            const SizedBox(width: 6),
            Text(
              'Testing: ${preset.name}',
              style: const TextStyle(
                color: Color(0xFF00e5ff),
                fontSize: 13,
                fontWeight: FontWeight.w600,
              ),
            ),
            const Spacer(),
            if (compensation != 0)
              Padding(
                padding: const EdgeInsets.only(right: 6),
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                  decoration: BoxDecoration(
                    color: Colors.purple.withOpacity(0.2),
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: Text(
                    'Vol ${compensation.toStringAsFixed(1)} dB',
                    style: const TextStyle(color: Colors.purpleAccent, fontSize: 9),
                  ),
                ),
              ),
            if (m == null)
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                decoration: BoxDecoration(
                  color: Colors.orange.withOpacity(0.2),
                  borderRadius: BorderRadius.circular(4),
                ),
                child: const Text(
                  'Native N/A',
                  style: TextStyle(color: Colors.orange, fontSize: 9),
                ),
              ),
          ]),
          const SizedBox(height: 8),
          _mRow('Input', m?['inputLevel']),
          _mRow('Post-NR', m?['postNrLevel']),
          _mRow('Post-EQ', m?['postEqLevel']),
          _mRow('Post-WDRC', m?['postWdrcLevel']),
          _mRow('Post-Vol', m?['postVolumeLevel']),
          _mRow('Output', m?['outputLevel']),
          const Divider(color: Colors.white12, height: 12),
          _peakClipRow(m),
        ],
      ),
    );
  }

  Widget _mRow(String label, dynamic val) {
    final double? v = val is num ? val.toDouble() : null;
    final norm = v != null ? (v / 120.0).clamp(0.0, 1.0) : null;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 1.5),
      child: Row(children: [
        SizedBox(
          width: 70,
          child: Text(
            label,
            style: const TextStyle(color: Color(0xFF00e5ff), fontSize: 11),
          ),
        ),
        Expanded(
          child: ClipRRect(
            borderRadius: BorderRadius.circular(2),
            child: SizedBox(
              height: 6,
              child: LinearProgressIndicator(
                value: norm ?? 0,
                backgroundColor: Colors.white.withOpacity(0.05),
                color: _lvlColor(norm),
              ),
            ),
          ),
        ),
        const SizedBox(width: 6),
        SizedBox(
          width: 60,
          child: Text(
            v != null ? '${v.toStringAsFixed(1)} dB' : 'N/A',
            style: TextStyle(
              color: v != null ? Colors.white : Colors.white38,
              fontSize: 10,
            ),
            textAlign: TextAlign.right,
          ),
        ),
      ]),
    );
  }

  Widget _peakClipRow(Map<String, dynamic>? m) {
    final peak = m?['peakSample'] is num
        ? (m!['peakSample'] as num).toDouble()
        : null;
    final clips =
        m?['clipCount'] is num ? (m!['clipCount'] as num).toInt() : null;
    final peakC = peak != null && peak >= 0.95
        ? Colors.red
        : (peak != null && peak >= 0.8 ? Colors.orange : Colors.green);
    final clipC = clips != null && clips > 0 ? Colors.red : Colors.green;
    return Row(children: [
      Icon(
        peak != null && peak >= 0.95
            ? Icons.warning_amber
            : Icons.check_circle_outline,
        color: peakC,
        size: 13,
      ),
      const SizedBox(width: 4),
      Text(
        'Peak: ${peak?.toStringAsFixed(3) ?? "N/A"}',
        style: TextStyle(color: peakC, fontSize: 11),
      ),
      const SizedBox(width: 16),
      Icon(
        clips != null && clips > 0 ? Icons.error : Icons.check_circle_outline,
        color: clipC,
        size: 13,
      ),
      const SizedBox(width: 4),
      Text(
        'Clips: ${clips ?? "N/A"}',
        style: TextStyle(color: clipC, fontSize: 11),
      ),
    ]);
  }

  // ────────────────────────────────────────────────────────────────────────
  // EQ bars
  // ────────────────────────────────────────────────────────────────────────

  Widget _buildEqBars() {
    final preset = EqPreset.allPresets[_activePresetIndex!];
    final maxG = preset.gains.reduce((a, b) => a > b ? a : b);
    return Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: const Color(0xFF16213e),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(children: [
            const Icon(Icons.equalizer, color: Color(0xFF00e5ff), size: 14),
            const SizedBox(width: 4),
            const Text(
              'EQ Gains',
              style: TextStyle(color: Color(0xFF00e5ff), fontSize: 11),
            ),
            const Spacer(),
            Text(
              'Max: ${maxG.toInt()} dB',
              style: TextStyle(
                color: maxG > 14 ? Colors.orange : Colors.white54,
                fontSize: 10,
              ),
            ),
          ]),
          const SizedBox(height: 6),
          SizedBox(
            height: 50,
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: List.generate(12, (i) {
                final g = preset.gains[i];
                final c = g > 14
                    ? Colors.orange
                    : Colors.cyan.withOpacity(g > 8 ? 1.0 : 0.6);
                return Expanded(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 1),
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.end,
                      children: [
                        Text(
                          '${g.toInt()}',
                          style: TextStyle(color: c, fontSize: 7),
                        ),
                        const SizedBox(height: 1),
                        Container(
                          height: (g / 50.0 * 40).clamp(2.0, 40.0),
                          decoration: BoxDecoration(
                            color: c,
                            borderRadius: BorderRadius.circular(2),
                          ),
                        ),
                      ],
                    ),
                  ),
                );
              }),
            ),
          ),
          const SizedBox(height: 3),
          Row(
            children: List.generate(
              12,
              (i) => Expanded(
                child: Text(
                  EqPreset.bandLabels[i],
                  style: const TextStyle(color: Colors.white38, fontSize: 7),
                  textAlign: TextAlign.center,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  // ────────────────────────────────────────────────────────────────────────
  // WDRC info
  // ────────────────────────────────────────────────────────────────────────

  Widget _buildWdrc() {
    final m = _metrics;
    final gf = m?['wdrcGainFactor'];
    final region = m?['wdrcRegion'] as String?;
    Color rc(String? r) => switch (r) {
          'expansion' => Colors.blue,
          'linear' => Colors.green,
          'compression' => Colors.orange,
          _ => Colors.white38,
        };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: const Color(0xFF16213e),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(children: [
        const Icon(Icons.compress, color: Color(0xFF00e5ff), size: 14),
        const SizedBox(width: 6),
        const Text('WDRC', style: TextStyle(color: Color(0xFF00e5ff), fontSize: 11)),
        const SizedBox(width: 12),
        Text(
          'Gain: ${gf is num ? gf.toStringAsFixed(3) : "N/A"}',
          style: const TextStyle(color: Colors.white, fontSize: 11),
        ),
        const SizedBox(width: 12),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
          decoration: BoxDecoration(
            color: rc(region).withOpacity(0.2),
            borderRadius: BorderRadius.circular(4),
            border: Border.all(color: rc(region).withOpacity(0.5)),
          ),
          child: Text(
            region ?? 'N/A',
            style: TextStyle(
              color: rc(region),
              fontSize: 10,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
      ]),
    );
  }

  // ────────────────────────────────────────────────────────────────────────
  // Lista de presets
  // ────────────────────────────────────────────────────────────────────────

  Widget _buildPresets() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Padding(
          padding: EdgeInsets.only(left: 4, bottom: 6),
          child: Text(
            'EQ Presets',
            style: TextStyle(
              color: Color(0xFF00e5ff),
              fontSize: 12,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
        ...List.generate(EqPreset.allPresets.length, (i) {
          final p = EqPreset.allPresets[i];
          final active = _activePresetIndex == i;
          final maxG = p.gains.reduce((a, b) => a > b ? a : b);
          final loudOffset =
              PresetAdvisor.loudnessNormalizationOffsetDb(p);
          return Container(
            margin: const EdgeInsets.only(bottom: 5),
            padding:
                const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
            decoration: BoxDecoration(
              color: active
                  ? Colors.cyan.withOpacity(0.08)
                  : const Color(0xFF16213e),
              borderRadius: BorderRadius.circular(7),
              border: active
                  ? Border.all(color: Colors.cyan.withOpacity(0.4))
                  : null,
            ),
            child: Row(children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      p.name,
                      style: TextStyle(
                        color: active ? Colors.cyan : Colors.white,
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    Text(
                      '${p.description} · Max ${maxG.toInt()} dB · CR ${p.compressionRatio}:1'
                      '${loudOffset != 0 ? ' · Vol ${loudOffset.toStringAsFixed(1)} dB' : ''}',
                      style: const TextStyle(color: Colors.white38, fontSize: 9),
                    ),
                  ],
                ),
              ),
              SizedBox(
                height: 28,
                child: ElevatedButton(
                  onPressed: _runningAll
                      ? null
                      : () => active ? _stopTest() : _startTest(i),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: active
                        ? Colors.red.withOpacity(0.2)
                        : Colors.cyan.withOpacity(0.12),
                    foregroundColor: active ? Colors.red : Colors.cyan,
                    side: BorderSide(
                      color: active ? Colors.red : Colors.cyan,
                      width: 0.5,
                    ),
                    padding: const EdgeInsets.symmetric(horizontal: 10),
                    textStyle: const TextStyle(fontSize: 10),
                  ),
                  child: Text(active ? 'Stop' : 'Test'),
                ),
              ),
            ]),
          );
        }),
      ],
    );
  }
}
