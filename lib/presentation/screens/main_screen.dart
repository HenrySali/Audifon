import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import '../../data/services/preset_learning_service.dart';
import '../../domain/entities/audiogram.dart';
import '../../domain/entities/environment_profile.dart';
import '../../domain/entities/eq_preset.dart';
import '../../domain/services/preset_advisor.dart';
import '../bloc/amplification_bloc.dart';
import '../bloc/amplification_event.dart';
import '../bloc/amplification_state.dart';
import '../widgets/prescriber_mode_selector.dart';
import '../widgets/mode_toggles.dart';
import '../widgets/gain_comparison_widget.dart';
import '../widgets/gain_detail_view.dart';
import '../widgets/experience_months_picker.dart';
import '../widgets/operating_mode_banner.dart';
import '../widgets/clinical_info_chips.dart';
import '../widgets/gain_scale_slider.dart';
import '../widgets/manual_eq_overlay.dart';
import '../widgets/safety_warning_widget.dart';
import '../widgets/stale_preset_list.dart';
import '../../domain/entities/prescription_mode.dart';
import '../../data/bridges/audio_bridge.dart';
import '../../data/bridges/audio_bridge_impl.dart';
import '../../data/repositories/settings_repository_impl.dart';
import '../../domain/audiogram_driven_presets/operating_mode.dart';
import '../widgets/active_eq_visualization.dart';
import '../widgets/audio_recommendation_widget.dart';
import 'ai_chat_screen.dart';
import 'audiogram_screen.dart';
import 'diagnostic/diagnostic_flow_screen.dart';
import 'diagnostic_analyzer_screen.dart';
import 'diagnostico_dsp_screen.dart';
import 'session_log_screen.dart';
import 'adaptive_learning_screen.dart';
import 'dsp_config_detail_screen.dart';
import 'dsp_test_screen.dart';
import 'simulator_screen.dart';
import 'smart_scene_screen.dart';
import 'spectrum_analyzer_screen.dart';
import 'subsystem_diagnostics_screen.dart';
import 'preset_learning_screen.dart';
import 'technical_service_screen.dart';
import '../../feedback_checklist/screens/feedback_checklist_dialog.dart';

/// Pantalla principal de amplificación del PSK Mobile Hearing Aid.
///
/// Presenta:
/// - Botón grande de activación/desactivación (≥ 30% del área visible)
/// - Slider de volumen (-20 a +10 dB)
/// - Medidor de nivel de entrada (estilo VU, actualizado ≥ 10 Hz)
/// - Indicador de estado de conexión de auriculares (permanente)
/// - Selector de perfil (Silencioso, Conversación, Ruidoso)
/// - Wakelock mientras la amplificación está activa
///
/// Requisitos: 5.1, 5.2, 5.3, 5.4, 5.5, 5.6
/// Nombre del preset "Personal" — built-in, NO viene de los profiles del
/// `ProfileRepository` ni de los presets del bundle. Se persiste en el
/// Hive box `settings_box` con 3 valores (graves/medios/agudos) y se
/// aplica disparando `UpdateEqGains(gains, presetName: 'Personal')`.
const String _kPersonalPresetName = 'Personal';

/// Tope blando por sección 0..20 dB. Mismo valor que el paciente para
/// mantener paridad UX.
const double _kPersonalGainMaxDb = 20.0;

/// Hive keys para persistir los 3 sliders del preset Personal.
const String _kPersonalLowKey = 'personalLowGainDb';
const String _kPersonalMidKey = 'personalMidGainDb';
const String _kPersonalHighKey = 'personalHighGainDb';

/// Construye un array de 12 gains EQ a partir de las 3 ganancias del
/// preset Personal. Mapeo (mismo que el paciente, debe matchear
/// `kEqFrequencies` en `equalizer.h`):
///   - graves : bandas 0-3  (250, 500, 750, 1000 Hz)
///   - medios : bandas 4-7  (1500, 2000, 2500, 3000 Hz)
///   - agudos : bandas 8-11 (3500, 4000, 6000, 8000 Hz)
List<double> _buildPersonalGains(double low, double mid, double high) {
  final out = List<double>.filled(12, 0.0);
  for (int i = 0; i < 4; i++) {
    out[i] = low;
  }
  for (int i = 4; i < 8; i++) {
    out[i] = mid;
  }
  for (int i = 8; i < 12; i++) {
    out[i] = high;
  }
  return out;
}

/// Lee un valor de gain desde el Hive box `settings_box`, clampeado a
/// [0, kPersonalGainMaxDb]. Si la key no existe o no es numérica devuelve
/// `0.0` (default = sin amplificación).
double _readPersonalGain(Box<dynamic> box, String key) {
  final v = box.get(key);
  if (v is num) return v.toDouble().clamp(0.0, _kPersonalGainMaxDb);
  return 0.0;
}

class MainScreen extends StatelessWidget {
  const MainScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return BlocConsumer<AmplificationBloc, AmplificationState>(
      listener: _handleStateChanges,
      builder: (context, state) {
        return SafetyWarningWidget(
          child: Scaffold(
            body: SafeArea(
              child: Column(
                children: [
                  _StatusBar(state: state),
                  Expanded(
                    child: _buildBody(context, state),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  /// Maneja efectos secundarios de cambios de estado (wakelock).
  void _handleStateChanges(BuildContext context, AmplificationState state) {
    if (state is AmplificationActive) {
      WakelockPlus.enable();
    } else {
      WakelockPlus.disable();
    }
  }

  Widget _buildBody(BuildContext context, AmplificationState state) {
    return switch (state) {
      AmplificationIdle() => _IdleView(),
      AmplificationStarting() => const _StartingView(),
      AmplificationActive() => _ActiveView(state: state),
      AmplificationPaused() => _PausedView(state: state),
      AmplificationError() => _ErrorView(state: state),
    };
  }
}

/// Widget auxiliar para mostrar una fila de información en el bottom sheet.
Widget _buildInfoRow(String label, String value) {
  return Row(
    mainAxisAlignment: MainAxisAlignment.spaceBetween,
    children: [
      Text(
        label,
        style: TextStyle(
          color: Colors.grey[400],
          fontSize: 13,
        ),
      ),
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

/// Implementación del bottom sheet del EQ activo con targets NAL-NL3 y MPO.
void _showEqDetailBottomSheetImpl(BuildContext context, AmplificationActive state) {
  final gains = state.bundle?.gainsDb;
  final targets = state.bundle?.prescribedTargetsDb;
  final mpo = state.bundle?.mpoProfileDbSpl;
  if (gains == null || gains.length != 12) return;

  // Calcular desviaciones de targets
  final deviations = targets != null && targets.length == 12
      ? List.generate(12, (i) => gains[i] - targets[i])
      : null;
  final maxDeviation = deviations?.map((d) => d.abs()).reduce((a, b) => a > b ? a : b);
  final withinTolerance = maxDeviation != null && maxDeviation <= 5.0;

  showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    backgroundColor: const Color(0xFF0f3460),
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
    ),
    builder: (context) => DraggableScrollableSheet(
      initialChildSize: 0.7,
      minChildSize: 0.5,
      maxChildSize: 0.9,
      expand: false,
      builder: (context, scrollController) => SingleChildScrollView(
        controller: scrollController,
        padding: const EdgeInsets.all(24),
        child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Handle visual
              Center(
                child: Container(
                  width: 40,
                  height: 4,
                  decoration: BoxDecoration(
                    color: Colors.white30,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
              const SizedBox(height: 20),
              
              // Header
              Row(
                children: [
                  const Icon(Icons.equalizer, color: Colors.cyan, size: 28),
                  const SizedBox(width: 12),
                  const Text(
                    'Amplificación por Frecuencia',
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 18,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Text(
                'Ambiente: ${state.activeProfile}',
                style: const TextStyle(
                  color: Colors.cyan,
                  fontSize: 14,
                ),
              ),
              
              // Badge de tolerancia AAA/ASHA
              if (deviations != null) ...[
                const SizedBox(height: 12),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                  decoration: BoxDecoration(
                    color: withinTolerance ? Colors.green.withOpacity(0.2) : Colors.orange.withOpacity(0.2),
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(
                      color: withinTolerance ? Colors.green : Colors.orange,
                    ),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        withinTolerance ? Icons.check_circle : Icons.warning,
                        color: withinTolerance ? Colors.green : Colors.orange,
                        size: 18,
                      ),
                      const SizedBox(width: 8),
                      Text(
                        withinTolerance 
                            ? 'Fitting dentro de tolerancia (±5 dB)' 
                            : 'Desviación de targets > 5 dB',
                        style: TextStyle(
                          color: withinTolerance ? Colors.green : Colors.orange,
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
              
              const SizedBox(height: 24),
              
              // Gráfico detallado con targets superpuestos
              SizedBox(
                height: 300,
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: List.generate(12, (i) {
                    final g = gains[i];
                    final t = targets != null && i < targets.length ? targets[i] : null;
                    final dev = deviations != null && i < deviations.length ? deviations[i] : null;
                    
                    // Calcular altura máxima considerando gains Y targets
                    final allValues = targets != null 
                        ? [...gains, ...targets]
                        : gains;
                    final maxGain = allValues.reduce((a, b) => a > b ? a : b).clamp(1.0, 50.0);
                    
                    final hGain = (g / maxGain * 260).clamp(10.0, 260.0);
                    final hTarget = t != null ? (t / maxGain * 260).clamp(10.0, 260.0) : null;
                    final freq = EqPreset.bandFrequencies[i];
                    
                    return Expanded(
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 2),
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.end,
                          children: [
                            // Desviación (si existe)
                            if (dev != null) ...[
                              Text(
                                '${dev >= 0 ? '+' : ''}${dev.toStringAsFixed(1)}',
                                style: TextStyle(
                                  color: dev.abs() <= 5.0 ? Colors.green : Colors.orange,
                                  fontSize: 9,
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                              const SizedBox(height: 2),
                            ],
                            // Valor de ganancia aplicada
                            Text(
                              '${g.toStringAsFixed(1)}',
                              style: const TextStyle(
                                color: Colors.cyan,
                                fontSize: 11,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                            const SizedBox(height: 4),
                            // Stack de barras: target (fondo) + gain (frente)
                            SizedBox(
                              height: 260,
                              child: Stack(
                                alignment: Alignment.bottomCenter,
                                children: [
                                  // Barra de target (transparente, outline)
                                  if (hTarget != null)
                                    Container(
                                      height: hTarget,
                                      decoration: BoxDecoration(
                                        border: Border.all(color: Colors.cyan.withOpacity(0.5), width: 2),
                                        borderRadius: BorderRadius.circular(4),
                                      ),
                                    ),
                                  // Barra de ganancia aplicada (sólida)
                                  Container(
                                    height: hGain,
                                    decoration: BoxDecoration(
                                      gradient: LinearGradient(
                                        begin: Alignment.bottomCenter,
                                        end: Alignment.topCenter,
                                        colors: [
                                          Colors.cyan,
                                          Colors.cyan.withOpacity(0.5),
                                        ],
                                      ),
                                      borderRadius: BorderRadius.circular(4),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            const SizedBox(height: 6),
                            // Frecuencia
                            Text(
                              freq >= 1000
                                  ? '${(freq / 1000).toStringAsFixed(freq % 1000 == 0 ? 0 : 1)}k'
                                  : '$freq',
                              style: TextStyle(
                                color: Colors.grey[400],
                                fontSize: 10,
                              ),
                              textAlign: TextAlign.center,
                            ),
                          ],
                        ),
                      ),
                    );
                  }).toList(),
                ),
              ),
              
              const SizedBox(height: 16),
              
              // Leyenda de barras
              if (targets != null)
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: Colors.black.withOpacity(0.2),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Container(
                            width: 24,
                            height: 12,
                            decoration: BoxDecoration(
                              gradient: LinearGradient(
                                colors: [Colors.cyan, Colors.cyan.withOpacity(0.5)],
                              ),
                              borderRadius: BorderRadius.circular(2),
                            ),
                          ),
                          const SizedBox(width: 8),
                          const Text(
                            'Ganancias aplicadas',
                            style: TextStyle(color: Colors.white, fontSize: 11),
                          ),
                        ],
                      ),
                      const SizedBox(height: 6),
                      Row(
                        children: [
                          Container(
                            width: 24,
                            height: 12,
                            decoration: BoxDecoration(
                              border: Border.all(color: Colors.cyan.withOpacity(0.5), width: 2),
                              borderRadius: BorderRadius.circular(2),
                            ),
                          ),
                          const SizedBox(width: 8),
                          const Text(
                            'Targets NAL-NL3 prescritos',
                            style: TextStyle(color: Colors.white70, fontSize: 11),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              
              const SizedBox(height: 24),
              const Divider(color: Colors.white24),
              const SizedBox(height: 16),
              
              // Información adicional
              _buildInfoRow('Prescripción', state.prescriberMode == PrescriberMode.smartNl2 ? 'NAL-NL2' : 'NAL-NL3'),
              const SizedBox(height: 8),
              if (state.lossType != null)
                _buildInfoRow('Tipo de pérdida', state.lossType!.name),
              const SizedBox(height: 8),
              _buildInfoRow('Modo de operación', state.operatingMode == OperatingMode.diagnostic ? 'Diagnóstico' : 'Amplificador'),
              
              const SizedBox(height: 24),
              
              // Nota explicativa
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: Colors.cyan.withOpacity(0.1),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: Colors.cyan.withOpacity(0.3)),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Icon(Icons.info_outline, color: Colors.cyan[300], size: 18),
                        const SizedBox(width: 8),
                        Text(
                          'Sobre estas ganancias',
                          style: TextStyle(
                            color: Colors.cyan[300],
                            fontSize: 13,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    Text(
                      'Estas ganancias se calculan automáticamente desde tu audiograma usando algoritmos clínicos (NAL-NL2/NL3). '
                      'Cada frecuencia recibe la amplificación específica que necesitas según tu pérdida auditiva.',
                      style: TextStyle(
                        color: Colors.grey[300],
                        fontSize: 12,
                        height: 1.4,
                      ),
                    ),
                  ],
                ),
              ),
              
              const SizedBox(height: 16),
              
              // Sección colapsable de configuración avanzada (MPO + WDRC)
              const Divider(color: Colors.white24),
              const SizedBox(height: 16),
              _AdvancedConfigSection(
                mpo: mpo,
                wdrcAttackMs: state.bundle?.wdrcAttackMs,
                wdrcReleaseMs: state.bundle?.wdrcReleaseMs,
                compressionRatios: state.bundle?.compressionRatios,
                compressionKnees: state.bundle?.compressionKneesDbSpl,
              ),
              const SizedBox(height: 16),
              
              // Botón de cerrar
              SizedBox(
                width: double.infinity,
                child: ElevatedButton(
                  onPressed: () => Navigator.pop(context),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.cyan,
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(8),
                    ),
                  ),
                  child: const Text(
                    'Cerrar',
                    style: TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

// =============================================================================
// MICROPHONE SELECTOR BOTTOM SHEET — Accesible en modo usuario y técnico
// =============================================================================

/// Bottom sheet para seleccionar el micrófono de entrada.
/// Se abre desde el ícono 🎙️ en la StatusBar.
void _showMicSelectorBottomSheet(BuildContext context) {
  final bloc = context.read<AmplificationBloc>();
  showModalBottomSheet<void>(
    context: context,
    backgroundColor: const Color(0xFF0f1b2d),
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
    ),
    builder: (ctx) => _MicSelectorSheet(bloc: bloc),
  );
}

/// Contenido del bottom sheet de selección de micrófono.
class _MicSelectorSheet extends StatefulWidget {
  final AmplificationBloc bloc;
  const _MicSelectorSheet({required this.bloc});

  @override
  State<_MicSelectorSheet> createState() => _MicSelectorSheetState();
}

class _MicSelectorSheetState extends State<_MicSelectorSheet> {
  List<Map<String, dynamic>> _mics = [];
  int _selectedId = -1;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final mics = await widget.bloc.audioBridge.getAvailableMicrophones();
      final box = await Hive.openBox<dynamic>('settings_box');
      final savedId = box.get('preferred_mic_id');
      if (mounted) {
        setState(() {
          _mics = mics;
          _selectedId = savedId is int ? savedId : -1;
          _loading = false;
        });
      }
    } catch (_) {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _select(int deviceId) async {
    setState(() => _selectedId = deviceId);
    try {
      final box = await Hive.openBox<dynamic>('settings_box');
      await box.put('preferred_mic_id', deviceId);
    } catch (_) {}
    try {
      await widget.bloc.audioBridge.setPreferredMicrophone(deviceId);
    } catch (_) {}
  }

  IconData _iconFor(int type) {
    switch (type) {
      case 15: return Icons.phone_android; // BUILTIN_MIC
      case 7: return Icons.bluetooth_audio; // BT_SCO
      case 8: return Icons.bluetooth_audio; // BT_A2DP
      case 22: return Icons.usb; // USB
      case 25: return Icons.bluetooth_audio; // BLE
      default: return Icons.mic;
    }
  }

  String _typeLabel(int type) {
    switch (type) {
      case 15: return 'Integrado';
      case 7: return 'Bluetooth SCO';
      case 8: return 'Bluetooth A2DP';
      case 22: return 'USB';
      case 25: return 'Bluetooth BLE';
      default: return 'Externo';
    }
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      top: false,
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // Handle.
            Container(
              width: 40, height: 4,
              decoration: BoxDecoration(
                color: Colors.white30,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            const SizedBox(height: 16),
            // Header.
            const Row(
              children: [
                Icon(Icons.mic, color: Colors.cyan, size: 22),
                SizedBox(width: 10),
                Text(
                  'Micrófono de entrada',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 16,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 4),
            const Align(
              alignment: Alignment.centerLeft,
              child: Text(
                'Seleccioná cuál micrófono usa la app para capturar audio.',
                style: TextStyle(color: Colors.white54, fontSize: 12),
              ),
            ),
            const SizedBox(height: 16),
            // Loading o lista.
            if (_loading)
              const Padding(
                padding: EdgeInsets.all(20),
                child: CircularProgressIndicator(color: Colors.cyan, strokeWidth: 2),
              )
            else ...[
              // Opción default.
              _MicTile(
                icon: Icons.auto_mode,
                name: 'Automático',
                subtitle: 'El sistema elige el mejor',
                isSelected: _selectedId == -1,
                onTap: () => _select(-1),
              ),
              // Micrófonos disponibles.
              ..._mics.map((mic) {
                final id = mic['id'] as int? ?? -1;
                final name = mic['name'] as String? ?? 'Desconocido';
                final type = mic['type'] as int? ?? -1;
                return _MicTile(
                  icon: _iconFor(type),
                  name: name,
                  subtitle: _typeLabel(type),
                  isSelected: _selectedId == id,
                  onTap: () => _select(id),
                );
              }),
            ],
          ],
        ),
      ),
    );
  }
}

/// Tile para cada opción de micrófono en el bottom sheet.
class _MicTile extends StatelessWidget {
  final IconData icon;
  final String name;
  final String subtitle;
  final bool isSelected;
  final VoidCallback onTap;

  const _MicTile({
    required this.icon,
    required this.name,
    required this.subtitle,
    required this.isSelected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(10),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
        margin: const EdgeInsets.symmetric(vertical: 3),
        decoration: BoxDecoration(
          color: isSelected ? Colors.cyan.withOpacity(0.12) : Colors.transparent,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(
            color: isSelected ? Colors.cyan.withOpacity(0.5) : Colors.white12,
          ),
        ),
        child: Row(
          children: [
            Icon(icon, color: isSelected ? Colors.cyan : Colors.white54, size: 22),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    name,
                    style: TextStyle(
                      color: isSelected ? Colors.cyan : Colors.white,
                      fontSize: 14,
                      fontWeight: isSelected ? FontWeight.w600 : FontWeight.w400,
                    ),
                    overflow: TextOverflow.ellipsis,
                  ),
                  Text(
                    subtitle,
                    style: TextStyle(
                      color: isSelected ? Colors.cyan.withOpacity(0.7) : Colors.white38,
                      fontSize: 11,
                    ),
                  ),
                ],
              ),
            ),
            if (isSelected)
              const Icon(Icons.check_circle, color: Colors.cyan, size: 20),
          ],
        ),
      ),
    );
  }
}

// =============================================================================
// STATUS BAR — Indicador de auriculares + perfil activo (siempre visible)
// =============================================================================

class _StatusBar extends StatelessWidget {
  final AmplificationState state;

  const _StatusBar({required this.state});

  @override
  Widget build(BuildContext context) {
    final bool headphonesConnected;
    final String profileName;

    if (state is AmplificationActive) {
      headphonesConnected = (state as AmplificationActive).headphonesConnected;
      profileName = (state as AmplificationActive).activeProfile;
    } else if (state is AmplificationPaused) {
      headphonesConnected =
          (state as AmplificationPaused).reason != PauseReason.btDisconnected;
      profileName = (state as AmplificationPaused).lastActiveProfile;
    } else {
      headphonesConnected = false;
      profileName = '';
    }

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(
        color: const Color(0xFF0f3460),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.3),
            blurRadius: 4,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: Row(
        children: [
          // Indicador de auriculares (Req 5.5 — permanente, visible)
          _HeadphoneIndicator(connected: headphonesConnected),
          const SizedBox(width: 8),
          // Perfil activo
          if (profileName.isNotEmpty)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
              decoration: BoxDecoration(
                color: Colors.cyan.withOpacity(0.15),
                borderRadius: BorderRadius.circular(16),
                border: Border.all(color: Colors.cyan.withOpacity(0.3)),
              ),
              child: Text(
                profileName,
                style: const TextStyle(
                  color: Colors.cyan,
                  fontSize: 12,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ),
          const SizedBox(width: 4),
          // Botones de navegación — scrollable para pantallas pequeñas
          Expanded(
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  // Botón de AI Chat
                  Builder(
                    builder: (context) => IconButton(
                      icon: const Icon(Icons.smart_toy, color: Colors.cyan, size: 21),
                      tooltip: 'AI Assistant',
                      padding: EdgeInsets.zero,
                      constraints: const BoxConstraints(minWidth: 34, minHeight: 34),
                      onPressed: () {
                        Navigator.of(context).push(
                          MaterialPageRoute(
                            builder: (_) => const AiChatScreen(),
                          ),
                        );
                      },
                    ),
                  ),
                  // Botón de diagnóstico auditivo
                  Builder(
                    builder: (context) => IconButton(
                      icon: const Icon(Icons.hearing, color: Colors.white70, size: 21),
                      tooltip: 'Diagnóstico Auditivo',
                      padding: EdgeInsets.zero,
                      constraints: const BoxConstraints(minWidth: 34, minHeight: 34),
                      onPressed: () {
                        Navigator.of(context).push(
                          MaterialPageRoute(
                            builder: (_) => BlocProvider.value(
                              value: context.read<AmplificationBloc>(),
                              child: const DiagnosticFlowScreen(),
                            ),
                          ),
                        );
                      },
                    ),
                  ),
                  // Spec in-app-diagnostic-analyzer · Task 10.3 · Req 18.1.
                  // Botón "Analizar grabación DSP" — abre el AnalyzerScreen
                  // compartido con el paciente, sin Service_Code_Gate.
                  Builder(
                    builder: (context) => IconButton(
                      icon: const Icon(Icons.analytics_outlined,
                          color: Colors.white70, size: 21),
                      tooltip: 'Analizar grabación DSP',
                      padding: EdgeInsets.zero,
                      constraints: const BoxConstraints(
                          minWidth: 34, minHeight: 34),
                      onPressed: () {
                        Navigator.of(context).push(
                          MaterialPageRoute(
                            builder: (_) => const DiagnosticAnalyzerScreen(),
                          ),
                        );
                      },
                    ),
                  ),
                  // Spec tecnico-paciente-feature-parity · Task 12.2 · Req 6.1.
                  // Botón "Diagnóstico DSP" — abre la pantalla de captura de
                  // 60 s (WAV+JSON) homóloga a la del paciente. La screen
                  // hace pre-check del motor (Req 6.11) y se autoabastece
                  // del AmplificationBloc vía context.read<>.
                  Builder(
                    builder: (context) => IconButton(
                      icon: const Icon(Icons.fiber_smart_record,
                          color: Colors.white70, size: 21),
                      tooltip: 'Diagnóstico DSP',
                      padding: EdgeInsets.zero,
                      constraints: const BoxConstraints(
                          minWidth: 34, minHeight: 34),
                      onPressed: () {
                        Navigator.of(context).push(
                          MaterialPageRoute(
                            builder: (_) => BlocProvider.value(
                              value: context.read<AmplificationBloc>(),
                              child: const DiagnosticoDspScreen(),
                            ),
                          ),
                        );
                      },
                    ),
                  ),
                  // Registro libre de eventos del bloc — sin grabar audio,
                  // captura cambios de preset/ambiente/MHL/volumen/audiograma
                  // mientras el técnico opera la app, copiable al portapapeles.
                  Builder(
                    builder: (context) => IconButton(
                      icon: const Icon(Icons.event_note,
                          color: Colors.white70, size: 21),
                      tooltip: 'Registro de sesión',
                      padding: EdgeInsets.zero,
                      constraints: const BoxConstraints(
                          minWidth: 34, minHeight: 34),
                      onPressed: () {
                        Navigator.of(context).push(
                          MaterialPageRoute(
                            builder: (_) => BlocProvider.value(
                              value: context.read<AmplificationBloc>(),
                              child: const SessionLogScreen(),
                            ),
                          ),
                        );
                      },
                    ),
                  ),
                  // Aprendizaje Adaptativo — Hermes Agent observa entornos
                  // y sugiere ajustes DSP basados en observaciones del técnico.
                  Builder(
                    builder: (context) => IconButton(
                      icon: const Icon(Icons.psychology,
                          color: Colors.amberAccent, size: 21),
                      tooltip: 'Aprendizaje Adaptativo',
                      padding: EdgeInsets.zero,
                      constraints: const BoxConstraints(
                          minWidth: 34, minHeight: 34),
                      onPressed: () {
                        Navigator.of(context).push(
                          MaterialPageRoute(
                            builder: (_) => BlocProvider.value(
                              value: context.read<AmplificationBloc>(),
                              child: const AdaptiveLearningScreen(),
                            ),
                          ),
                        );
                      },
                    ),
                  ),
                  // Botón de analizador de espectro
                  Builder(
                    builder: (context) => IconButton(
                      icon: const Icon(Icons.graphic_eq, color: Colors.white70, size: 21),
                      tooltip: 'Spectrum Analyzer',
                      padding: EdgeInsets.zero,
                      constraints: const BoxConstraints(minWidth: 34, minHeight: 34),
                      onPressed: () {
                        Navigator.of(context).push(
                          MaterialPageRoute(
                            builder: (_) => const SpectrumAnalyzerScreen(),
                          ),
                        );
                      },
                    ),
                  ),
                  // Botón de diagnóstico de subsistemas
                  Builder(
                    builder: (context) => IconButton(
                      icon: const Icon(Icons.developer_board, color: Colors.white70, size: 21),
                      tooltip: 'Diagnóstico Subsistemas',
                      padding: EdgeInsets.zero,
                      constraints: const BoxConstraints(minWidth: 34, minHeight: 34),
                      onPressed: () {
                        Navigator.of(context).push(
                          MaterialPageRoute(
                            builder: (_) => const SubsystemDiagnosticsScreen(),
                          ),
                        );
                      },
                    ),
                  ),
                  // Botón de test del pipeline DSP
                  Builder(
                    builder: (context) => IconButton(
                      icon: const Icon(Icons.bug_report, color: Colors.white70, size: 21),
                      tooltip: 'DSP Pipeline Test',
                      padding: EdgeInsets.zero,
                      constraints: const BoxConstraints(minWidth: 34, minHeight: 34),
                      onPressed: () {
                        Navigator.of(context).push(
                          MaterialPageRoute(
                            builder: (_) => BlocProvider.value(
                              value: context.read<AmplificationBloc>(),
                              child: const DspTestScreen(),
                            ),
                          ),
                        );
                      },
                    ),
                  ),
                  // Botón de selector de micrófono — accesible en modo
                  // usuario y técnico. Abre bottom sheet con lista de mics.
                  Builder(
                    builder: (context) => IconButton(
                      icon: const Icon(Icons.mic, color: Colors.white70, size: 21),
                      tooltip: 'Micrófono',
                      padding: EdgeInsets.zero,
                      constraints: const BoxConstraints(minWidth: 34, minHeight: 34),
                      onPressed: () => _showMicSelectorBottomSheet(context),
                    ),
                  ),
                  // Botón de Servicio Técnico (calibración, info del sistema)
                  Builder(
                    builder: (context) => IconButton(
                      icon: const Icon(Icons.build_circle, color: Colors.white70, size: 21),
                      tooltip: 'Servicio Técnico',
                      padding: EdgeInsets.zero,
                      constraints: const BoxConstraints(minWidth: 34, minHeight: 34),
                      onPressed: () {
                        Navigator.of(context).push(
                          MaterialPageRoute(
                            builder: (_) => BlocProvider.value(
                              value: context.read<AmplificationBloc>(),
                              child: const TechnicalServiceScreen(),
                            ),
                          ),
                        );
                      },
                    ),
                  ),
                  // Botón de simulador avanzado
                  Builder(
                    builder: (context) => IconButton(
                      icon: const Icon(Icons.tune, color: Colors.white70, size: 21),
                      tooltip: 'Configuración Avanzada',
                      padding: EdgeInsets.zero,
                      constraints: const BoxConstraints(minWidth: 34, minHeight: 34),
                      onPressed: () {
                        Navigator.of(context).push(
                          MaterialPageRoute(
                            builder: (_) => BlocProvider.value(
                              value: context.read<AmplificationBloc>(),
                              child: const SimulatorScreen(),
                            ),
                          ),
                        );
                      },
                    ),
                  ),
                  // Botón de EQ manual (sliders por banda + reset) — hallazgo A-9.
                  // Solo disponible mientras la amplificación está activa para que
                  // exista un bundle vivo sobre el cual aplicar el delta.
                  if (state is AmplificationActive)
                    Builder(
                      builder: (context) => IconButton(
                        icon: const Icon(Icons.equalizer, color: Colors.white70, size: 21),
                        tooltip: 'EQ manual',
                        padding: EdgeInsets.zero,
                        constraints: const BoxConstraints(minWidth: 34, minHeight: 34),
                        onPressed: () {
                          final bloc = context.read<AmplificationBloc>();
                          showModalBottomSheet<void>(
                            context: context,
                            isScrollControlled: true,
                            backgroundColor: const Color(0xFF1a2332),
                            shape: const RoundedRectangleBorder(
                              borderRadius: BorderRadius.vertical(
                                top: Radius.circular(16),
                              ),
                            ),
                            builder: (_) => BlocProvider.value(
                              value: bloc,
                              child: const SafeArea(
                                top: false,
                                child: SingleChildScrollView(
                                  child: ManualEqOverlay(),
                                ),
                              ),
                            ),
                          );
                        },
                      ),
                    ),
                  // Botón de configuración de audiograma (Req 4.1, 4.3)
                  Builder(
                    builder: (context) => IconButton(
                      icon: const Icon(Icons.settings, color: Colors.white70, size: 21),
                      tooltip: 'Configurar Audiograma',
                      padding: EdgeInsets.zero,
                      constraints: const BoxConstraints(minWidth: 34, minHeight: 34),
                      onPressed: () async {
                        final bloc = context.read<AmplificationBloc>();
                        final savedAudiogram =
                            await bloc.audiogramRepository.getAudiogram();
                        if (!context.mounted) return;
                        Navigator.of(context).push(
                          MaterialPageRoute(
                            builder: (_) => BlocProvider.value(
                              value: bloc,
                              child: AudiogramScreen(
                                currentAudiogram: savedAudiogram,
                              ),
                            ),
                          ),
                        );
                      },
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Indicador de conexión de auriculares — siempre visible (Req 5.5).
class _HeadphoneIndicator extends StatelessWidget {
  final bool connected;

  const _HeadphoneIndicator({required this.connected});

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(
          connected ? Icons.headphones : Icons.headphones_outlined,
          color: connected ? Colors.green : Colors.red.shade300,
          size: 20,
        ),
        const SizedBox(width: 6),
        Text(
          connected ? 'Conectado' : 'Desconectado',
          style: TextStyle(
            color: connected ? Colors.green : Colors.red.shade300,
            fontSize: 13,
            fontWeight: FontWeight.w500,
          ),
        ),
      ],
    );
  }
}

// =============================================================================
// IDLE VIEW — Botón grande de activación
// =============================================================================

class _IdleView extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        children: [
          const Spacer(flex: 1),
          // Botón grande de activación (≥ 30% del área visible) — Req 5.1
          _ActivationButton(
            active: false,
            onPressed: () {
              context.read<AmplificationBloc>().add(const StartAmplification());
            },
          ),
          const Spacer(flex: 1),
          // Pre-selección en IDLE (aún no hay amplificación activa → no hay
          // `activeProfile` real). El chip activo REAL se muestra en la vista
          // activa (`_ActiveView` → `_ProfileSelector(state.activeProfile)`),
          // que el clasificador automático actualiza vía `ChangeProfile`.
          // PENDIENTE (no invasivo): reflejar aquí el último perfil persistido
          // (SettingsRepository.lastProfile) requiere carga async en idle.
          const _ProfileSelector(activeProfile: 'Conversación'),
          const SizedBox(height: 24),
        ],
      ),
    );
  }
}

// =============================================================================
// STARTING VIEW — Indicador de carga
// =============================================================================

class _StartingView extends StatelessWidget {
  const _StartingView();

  @override
  Widget build(BuildContext context) {
    return const Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          SizedBox(
            width: 64,
            height: 64,
            child: CircularProgressIndicator(
              strokeWidth: 4,
              color: Colors.cyan,
            ),
          ),
          SizedBox(height: 24),
          Text(
            'Iniciando amplificación...',
            style: TextStyle(
              fontSize: 16,
              color: Colors.white70,
            ),
          ),
        ],
      ),
    );
  }
}

// =============================================================================
// ACTIVE VIEW — Controles completos de amplificación
// =============================================================================

class _ActiveView extends StatelessWidget {
  final AmplificationActive state;

  const _ActiveView({required this.state});

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
      child: Column(
        children: [
          // Banner de Modo Amplificador (Req 13.10, 5.6)
          const OperatingModeBanner(),
          // Chips clínicos: LossType + PrescriptionMode (visibles en Modo
          // Diagnóstico con bundle activo). El widget se auto-suscribe al
          // AmplificationBloc con buildWhen filtrando por bundle, lossType
          // y prescriptionMode (hallazgo A-9).
          const ClinicalInfoChips(),
          // Recomendaciones contextuales de audio: eco, voz baja,
          // saturación EQ, sugerencias de ambiente. Aparecen como
          // banners animados descartables con cooldown de 30s.
          const AudioRecommendationWidget(),
          // Banner de presets personalizados obsoletos (audiograma cambió
          // tras crear el preset). Permite regenerarlos in-situ. Si no hay
          // presets stale, se renderiza como SizedBox.shrink (hallazgo A-9).
          const StalePresetList(),
          const SizedBox(height: 8),
          // Botón grande de desactivación (≥ 30% del área visible) — Req 5.1
          _ActivationButton(
            active: true,
            onPressed: () {
              context.read<AmplificationBloc>().add(const StopAmplification());
            },
          ),
          const SizedBox(height: 16),
          // Selector de motor de realce de voz (Dual-DNN / MVDR / Bypass)
          // — spec gtcrn-dual-channel, tareas 5.1–5.3
          const _EnhancementEngineSelectorCard(),
          const SizedBox(height: 20),
          // Selector de modo de prescriptor (Smart-NL2 / Smart-NL3) — Req 5.1–5.5
          PrescriberModeSelector(
            currentMode: state.prescriberMode,
            onModeChanged: (mode) {
              context
                  .read<AmplificationBloc>()
                  .add(ChangePrescriberMode(mode: mode));
            },
          ),
          // Selector de experiencia previa con audífonos — sólo aplica al
          // prescriptor NL3 (define la corrección de aclimatización -3 dB).
          if (state.prescriberMode == PrescriberMode.smartNl3) ...[
            const SizedBox(height: 12),
            ExperienceMonthsPicker(
              currentMonths: state.experienceMonths,
              onChanged: (months) {
                context
                    .read<AmplificationBloc>()
                    .add(SetExperienceMonths(months));
              },
            ),
          ],
          const SizedBox(height: 12),
          // tecnico-paciente-feature-parity — task 9.3 (Req 1.1, 1.2, 1.3, 1.4):
          // Reemplazo del toggle monolítico legacy `MhlModeToggle` por
          // `ModeToggles`, que renderiza dos toggles independientes ("MHL
          // Prescripción" + "Modo Música") y delega la regla de mutex al
          // `AmplificationBloc` (handlers `_onToggleMhlPrescription` y
          // `_onToggleMusicMode`). El widget legacy `MhlModeToggle` se
          // conserva en `lib/presentation/widgets/mhl_mode_toggle.dart` como
          // wrapper backward-compatible que delega en `ModeToggles` con
          // `showMusic: false` (Req 1.12), pero la pantalla principal usa
          // ahora la versión nueva directamente.
          ModeToggles(
            mhlPrescription: state.mhlActive,
            musicMode: state.musicModeActive,
            onMhlChanged: (activate) {
              context
                  .read<AmplificationBloc>()
                  .add(ToggleMhlPrescription(activate: activate));
            },
            onMusicChanged: (activate) {
              context
                  .read<AmplificationBloc>()
                  .add(ToggleMusicMode(activate: activate));
            },
          ),
          const SizedBox(height: 12),
          // Comparación visual NL2 vs NL3 (solo cuando hay datos NL3 y el
          // modo activo es Smart-NL3). Tap → bottom sheet con detalle por banda.
          if (state.prescriberMode == PrescriberMode.smartNl3 &&
              state.nl2Gains.length == 12 &&
              state.nl3Gains.length == 12 &&
              state.lossType != null) ...[
            const SizedBox(height: 12),
            GainComparisonWidget(
              nl2Gains: state.nl2Gains,
              nl3Gains: state.nl3Gains,
              cinGains: state.prescriptionMode == PrescriptionMode.comfortInNoise
                  ? state.cinGains
                  : null,
              lossType: state.lossType!,
              onTap: () => showGainDetailBottomSheet(
                context: context,
                nl2Gains: state.nl2Gains,
                nl3Gains: state.nl3Gains,
                cinGains: state.cinGains,
              ),
            ),
          ],
          const SizedBox(height: 16),
          // Slider de volumen (-20 a +10 dB) — Req 5.3
          _VolumeSlider(volumeDb: state.volumeDb),
          const SizedBox(height: 8),
          // Slider de intensidad de amplificación (gainScale) — Req 13.5, 13.6, 13.11
          // Visible sólo en Modo Amplificador (el widget se auto-oculta en
          // Modo Diagnóstico vía BlocBuilder + operatingMode interno).
          const GainScaleSlider(),
          const SizedBox(height: 16),
          // Medidor de nivel de entrada (estilo VU) — Req 5.4
          _InputLevelMeter(levelDb: state.inputLevelDb),
          const SizedBox(height: 16),
          // Indicador de preset EQ activo
          _EqPresetIndicator(presetName: state.activeEqPreset, nrLevel: state.activeNrLevel),
          const SizedBox(height: 16),
          // Mini panel de visualización del preset EQ activo con gráfico de barras
          _EqPresetDetailPanel(state: state),
          const SizedBox(height: 16),
          // Reporte de procesamiento en tiempo real
          _ProcessingReport(state: state),
          const SizedBox(height: 16),
          // smart-continuo-dnn-modulado: toggle Smart continuo + chip de
          // escena en vivo. Toggle controla [_smartEnabled] vía
          // ToggleSmart event. Chip lee `bloc.lastEnvClass` con un
          // `Timer.periodic` interno (1 Hz) para reflejar la escena real.
          const _SmartSceneToggleCard(),
          const SizedBox(height: 16),
          // modo-conversacion-sco: toggle Modo Conversación (SCO baja latencia)
          // Solo visible cuando hay Bluetooth conectado (recomendación bioingeniero)
          if (state.headphonesConnected) ...[
            const _ConversationModeToggleCard(),
            const SizedBox(height: 16),
          ],
          // Selector de perfil — Req 8.1
          _ProfileSelector(activeProfile: state.activeProfile),
          const SizedBox(height: 16),
          // Limpiador de ruido DNN (IA) — anti "tktktkt"
          const _DnnNoiseCleanerCard(),
          const SizedBox(height: 16),
          // Visualización del EQ activo (ganancias realmente aplicadas al DSP).
          // Prioriza `activeEqGains` (preset aplicado, ej: Smart Scene) sobre
          // `bundle.gainsDb` (prescripción base sin personalizar).
          if (state.activeEqGains != null || state.bundle?.gainsDb != null)
            ActiveEqVisualization(
              gains: state.activeEqGains ?? state.bundle!.gainsDb,
              environmentName: state.activeProfile,
              onTap: () => _showEqDetailBottomSheetImpl(context, state),
            ),
          if (state.activeEqPreset == _kPersonalPresetName) ...[
            const SizedBox(height: 16),
            const _PersonalGainsCard(),
          ],
          const SizedBox(height: 24),
        ],
      ),
    );
  }

}

// =============================================================================
// PAUSED VIEW — Razón de pausa y botón de reanudar
// =============================================================================

class _PausedView extends StatelessWidget {
  final AmplificationPaused state;

  const _PausedView({required this.state});

  @override
  Widget build(BuildContext context) {
    final (icon, message) = switch (state.reason) {
      PauseReason.btDisconnected => (
          Icons.bluetooth_disabled,
          'Auriculares desconectados'
        ),
      PauseReason.audioFocusLost => (
          Icons.volume_off,
          'Otra app está usando el audio'
        ),
      PauseReason.userPaused => (Icons.pause_circle, 'Amplificación pausada'),
    };

    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(icon, size: 64, color: Colors.orange.shade300),
            const SizedBox(height: 24),
            Text(
              message,
              style: const TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.w500,
                color: Colors.white,
              ),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 12),
            Text(
              'Perfil: ${state.lastActiveProfile} · Volumen: ${state.lastVolumeDb.toStringAsFixed(0)} dB',
              style: const TextStyle(fontSize: 14, color: Colors.white54),
            ),
            const SizedBox(height: 32),
            ElevatedButton.icon(
              onPressed: () {
                context
                    .read<AmplificationBloc>()
                    .add(const ResumeAmplification());
              },
              icon: const Icon(Icons.play_arrow),
              label: const Text('Reanudar'),
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.cyan,
                foregroundColor: Colors.white,
                padding:
                    const EdgeInsets.symmetric(horizontal: 32, vertical: 16),
                textStyle: const TextStyle(fontSize: 16),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// =============================================================================
// ADVANCED CONFIG SECTION — MPO + WDRC colapsable en bottom sheet
// =============================================================================

/// Sección colapsable de configuración avanzada (MPO, WDRC, compresión).
class _AdvancedConfigSection extends StatefulWidget {
  final List<double>? mpo;
  final double? wdrcAttackMs;
  final double? wdrcReleaseMs;
  final List<double>? compressionRatios;
  final List<double>? compressionKnees;

  const _AdvancedConfigSection({
    this.mpo,
    this.wdrcAttackMs,
    this.wdrcReleaseMs,
    this.compressionRatios,
    this.compressionKnees,
  });

  @override
  State<_AdvancedConfigSection> createState() => _AdvancedConfigSectionState();
}

class _AdvancedConfigSectionState extends State<_AdvancedConfigSection> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Header colapsable
        InkWell(
          onTap: () => setState(() => _expanded = !_expanded),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: Row(
              children: [
                Icon(
                  _expanded ? Icons.expand_less : Icons.expand_more,
                  color: Colors.white70,
                ),
                const SizedBox(width: 8),
                const Text(
                  'Configuración Avanzada (MPO + WDRC)',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 15,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
          ),
        ),

        // Contenido colapsable
        if (_expanded) ...[
          const SizedBox(height: 12),
          
          // --- MPO por banda ---
          if (widget.mpo != null && widget.mpo!.length == 12) ...[
            const Text(
              'MPO (Maximum Power Output) por banda',
              style: TextStyle(
                color: Colors.cyan,
                fontSize: 13,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 8),
            
            // Verificar si algún valor excede 105 dB SPL
            if (widget.mpo!.any((m) => m > 105.0))
              Container(
                margin: const EdgeInsets.only(bottom: 12),
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: Colors.orange.withOpacity(0.15),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: Colors.orange.withOpacity(0.5)),
                ),
                child: Row(
                  children: [
                    const Icon(Icons.warning, color: Colors.orange, size: 18),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        'Advertencia: Algunos valores de MPO exceden 105 dB SPL (límite pediátrico). Verificar UCL del paciente.',
                        style: TextStyle(
                          color: Colors.orange[200],
                          fontSize: 11,
                          height: 1.3,
                        ),
                      ),
                    ),
                  ],
                ),
              ),

            // Gráfico de MPO
            SizedBox(
              height: 180,
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: List.generate(12, (i) {
                  final mpo = widget.mpo![i];
                  final freq = EqPreset.bandFrequencies[i];
                  final exceedsLimit = mpo > 105.0;
                  
                  final h = ((mpo - 80.0) / (132.0 - 80.0) * 160).clamp(5.0, 160.0);
                  final limitLineHeight = ((105.0 - 80.0) / (132.0 - 80.0) * 160);
                  
                  return Expanded(
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 1.5),
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.end,
                        children: [
                          Text(
                            '${mpo.round()}',
                            style: TextStyle(
                              color: exceedsLimit ? Colors.orange : Colors.white70,
                              fontSize: 9,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                          const SizedBox(height: 3),
                          SizedBox(
                            height: 160,
                            child: Stack(
                              alignment: Alignment.bottomCenter,
                              children: [
                                Positioned(
                                  bottom: limitLineHeight,
                                  left: 0,
                                  right: 0,
                                  child: Container(
                                    height: 1,
                                    color: Colors.red.withOpacity(0.5),
                                  ),
                                ),
                                Container(
                                  height: h,
                                  decoration: BoxDecoration(
                                    color: exceedsLimit 
                                        ? Colors.orange.withOpacity(0.7)
                                        : Colors.white70.withOpacity(0.6),
                                    borderRadius: BorderRadius.circular(2),
                                  ),
                                ),
                              ],
                            ),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            freq >= 1000
                                ? '${(freq / 1000).toStringAsFixed(freq % 1000 == 0 ? 0 : 1)}k'
                                : '$freq',
                            style: TextStyle(
                              color: Colors.grey[500],
                              fontSize: 8,
                            ),
                            textAlign: TextAlign.center,
                          ),
                        ],
                      ),
                    ),
                  );
                }).toList(),
              ),
            ),
            
            const SizedBox(height: 8),
            Row(
              children: [
                Container(width: 3, height: 12, color: Colors.red.withOpacity(0.5)),
                const SizedBox(width: 6),
                Text(
                  'Límite pediátrico: 105 dB SPL',
                  style: TextStyle(color: Colors.grey[400], fontSize: 10),
                ),
              ],
            ),
            const SizedBox(height: 20),
          ],

          // --- Parámetros WDRC ---
          if (widget.wdrcAttackMs != null && widget.wdrcReleaseMs != null) ...[
            const Text(
              'Parámetros WDRC (Wide Dynamic Range Compression)',
              style: TextStyle(
                color: Colors.cyan,
                fontSize: 13,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 8),
            Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: Colors.black.withOpacity(0.2),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Column(
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text('Attack time', style: TextStyle(color: Colors.grey[400], fontSize: 12)),
                      Text(
                        '${widget.wdrcAttackMs!.toStringAsFixed(1)} ms',
                        style: const TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.w600),
                      ),
                    ],
                  ),
                  const SizedBox(height: 6),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text('Release time', style: TextStyle(color: Colors.grey[400], fontSize: 12)),
                      Text(
                        '${widget.wdrcReleaseMs!.toStringAsFixed(0)} ms',
                        style: const TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.w600),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ],
      ],
    );
  }
}

// =============================================================================
// ERROR VIEW — Mensaje de error y botón de reintentar
// =============================================================================

class _ErrorView extends StatelessWidget {
  final AmplificationError state;

  const _ErrorView({required this.state});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(Icons.error_outline, size: 64, color: Colors.redAccent),
            const SizedBox(height: 24),
            const Text(
              'Error',
              style: TextStyle(
                fontSize: 20,
                fontWeight: FontWeight.bold,
                color: Colors.redAccent,
              ),
            ),
            const SizedBox(height: 12),
            Text(
              state.message,
              style: const TextStyle(fontSize: 14, color: Colors.white70),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 32),
            ElevatedButton.icon(
              onPressed: () {
                context
                    .read<AmplificationBloc>()
                    .add(const StartAmplification());
              },
              icon: const Icon(Icons.refresh),
              label: const Text('Reintentar'),
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.cyan,
                foregroundColor: Colors.white,
                padding:
                    const EdgeInsets.symmetric(horizontal: 32, vertical: 16),
                textStyle: const TextStyle(fontSize: 16),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// =============================================================================
// SHARED WIDGETS
// =============================================================================

/// Botón grande de activación/desactivación (≥ 30% del área visible).
///
/// Requisito 5.1: Ocupa al menos el 30% del área visible.
/// Estado claro: verde = activar, rojo = desactivar.
class _ActivationButton extends StatelessWidget {
  final bool active;
  final VoidCallback onPressed;

  const _ActivationButton({
    required this.active,
    required this.onPressed,
  });

  @override
  Widget build(BuildContext context) {
    // LayoutBuilder para garantizar ≥ 30% del área visible
    return LayoutBuilder(
      builder: (context, constraints) {
        // Calcular tamaño mínimo para cumplir 30% del área visible
        final screenHeight = MediaQuery.of(context).size.height;
        final minHeight = screenHeight * 0.30;
        final buttonSize = minHeight.clamp(140.0, 240.0);

        return SizedBox(
          width: buttonSize,
          height: buttonSize,
          child: Material(
            elevation: 8,
            shape: const CircleBorder(),
            color: active ? Colors.red.shade700 : Colors.green.shade700,
            child: InkWell(
              onTap: onPressed,
              customBorder: const CircleBorder(),
              splashColor: Colors.white24,
              child: Center(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(
                      active ? Icons.stop : Icons.mic,
                      size: buttonSize * 0.3,
                      color: Colors.white,
                    ),
                    const SizedBox(height: 8),
                    Text(
                      active ? 'DESACTIVAR' : 'ACTIVAR',
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: buttonSize * 0.09,
                        fontWeight: FontWeight.bold,
                        letterSpacing: 1.2,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

/// Slider de volumen maestro (-20 a +10 dB).
///
/// Requisito 5.3: Ajustable con respuesta < 50 ms.
class _VolumeSlider extends StatelessWidget {
  final double volumeDb;

  const _VolumeSlider({required this.volumeDb});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(
        color: const Color(0xFF16213e),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.volume_up, color: Colors.cyan, size: 20),
              const SizedBox(width: 8),
              const Text(
                'Volumen',
                style: TextStyle(
                  color: Colors.white70,
                  fontSize: 13,
                  fontWeight: FontWeight.w500,
                ),
              ),
              const Spacer(),
              Text(
                '${volumeDb.toStringAsFixed(0)} dB',
                style: const TextStyle(
                  color: Colors.cyan,
                  fontSize: 14,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          SliderTheme(
            data: SliderTheme.of(context).copyWith(
              activeTrackColor: Colors.cyan,
              inactiveTrackColor: Colors.cyan.withOpacity(0.2),
              thumbColor: Colors.cyan,
              overlayColor: Colors.cyan.withOpacity(0.1),
              trackHeight: 6,
            ),
            child: Slider(
              value: volumeDb,
              min: -20,
              max: 10,
              divisions: 30,
              label: '${volumeDb.toStringAsFixed(0)} dB',
              onChanged: (value) {
                context
                    .read<AmplificationBloc>()
                    .add(ChangeVolume(volumeDb: value));
              },
            ),
          ),
          const Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text('-20 dB', style: TextStyle(fontSize: 11, color: Colors.white38)),
              Text('+10 dB', style: TextStyle(fontSize: 11, color: Colors.white38)),
            ],
          ),
        ],
      ),
    );
  }
}

/// Medidor de nivel de entrada estilo VU (actualizado ≥ 10 Hz).
///
/// Requisito 5.4: Indicador visual del nivel de entrada del micrófono.
class _InputLevelMeter extends StatelessWidget {
  final double levelDb;

  const _InputLevelMeter({required this.levelDb});

  @override
  Widget build(BuildContext context) {
    // Normalizar nivel a rango visual [0, 1]
    // Rango típico de entrada: 20 dB SPL (silencio) a 100 dB SPL (fuerte)
    final normalizedLevel = ((levelDb - 20) / 80).clamp(0.0, 1.0);

    // Color del indicador según nivel
    final Color barColor;
    if (normalizedLevel > 0.85) {
      barColor = Colors.red;
    } else if (normalizedLevel > 0.65) {
      barColor = Colors.orange;
    } else {
      barColor = Colors.green;
    }

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(
        color: const Color(0xFF16213e),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.graphic_eq, color: Colors.cyan, size: 20),
              const SizedBox(width: 8),
              const Text(
                'Nivel',
                style: TextStyle(
                  color: Colors.white70,
                  fontSize: 13,
                  fontWeight: FontWeight.w500,
                ),
              ),
              const Spacer(),
              Text(
                '${levelDb.toStringAsFixed(0)} dB SPL',
                style: const TextStyle(
                  color: Colors.cyan,
                  fontSize: 14,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          // Barra de nivel estilo VU
          ClipRRect(
            borderRadius: BorderRadius.circular(4),
            child: SizedBox(
              height: 12,
              child: LinearProgressIndicator(
                value: normalizedLevel,
                backgroundColor: Colors.grey.shade800,
                color: barColor,
              ),
            ),
          ),
          const SizedBox(height: 4),
          const Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text('20', style: TextStyle(fontSize: 10, color: Colors.white38)),
              Text('40', style: TextStyle(fontSize: 10, color: Colors.white38)),
              Text('60', style: TextStyle(fontSize: 10, color: Colors.white38)),
              Text('80', style: TextStyle(fontSize: 10, color: Colors.white38)),
              Text('100', style: TextStyle(fontSize: 10, color: Colors.white38)),
            ],
          ),
        ],
      ),
    );
  }
}

/// Selector de perfil de entorno (predefinidos + personalizados).
///
/// Requisito 8.1: Silencioso, Conversación, Ruidoso + custom presets.
/// Carga todos los perfiles desde ProfileRepository.
/// Long-press en perfiles personalizados muestra diálogo de eliminación.
class _ProfileSelector extends StatefulWidget {
  final String activeProfile;

  const _ProfileSelector({required this.activeProfile});

  @override
  State<_ProfileSelector> createState() => _ProfileSelectorState();
}

class _ProfileSelectorState extends State<_ProfileSelector> {
  List<EnvironmentProfile> _allProfiles = [];
  bool _loaded = false;

  @override
  void initState() {
    super.initState();
    _loadProfiles();
  }

  @override
  void didUpdateWidget(covariant _ProfileSelector oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Reload profiles when the widget updates (e.g., after delete)
    _loadProfiles();
  }

  Future<void> _loadProfiles() async {
    final bloc = context.read<AmplificationBloc>();
    final profiles = await bloc.profileRepository.getAllProfiles();
    if (mounted) {
      setState(() {
        _allProfiles = profiles;
        _loaded = true;
      });
    }
  }

  Future<void> _confirmDelete(BuildContext context, EnvironmentProfile profile) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF1a2332),
        title: const Text(
          'Eliminar preset',
          style: TextStyle(color: Colors.white),
        ),
        content: Text(
          '¿Eliminar el preset "${profile.name}"?',
          style: const TextStyle(color: Colors.white70),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancelar'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text(
              'Eliminar',
              style: TextStyle(color: Colors.red),
            ),
          ),
        ],
      ),
    );

    if (confirmed == true && mounted) {
      context
          .read<AmplificationBloc>()
          .add(DeleteCustomPreset(name: profile.name));
      // Refresh the list after deletion
      await Future.delayed(const Duration(milliseconds: 100));
      _loadProfiles();
    }
  }

  @override
  Widget build(BuildContext context) {
    // Show predefined profiles while loading
    final profiles = _loaded
        ? _allProfiles
        : EnvironmentProfile.predefinedProfiles;

    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: const Color(0xFF16213e),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Wrap(
        alignment: WrapAlignment.center,
        spacing: 8,
        runSpacing: 8,
        children: [
          ...profiles.map((profile) {
            final isActive = profile.name == widget.activeProfile;
            final isPredefined = EnvironmentProfile.predefinedProfiles
                .any((p) => p.name == profile.name);
            return _ProfileChip(
              profile: profile,
              isActive: isActive,
              onTap: () {
                context
                    .read<AmplificationBloc>()
                    .add(ChangeProfile(profile: profile.name));
              },
              onLongPress: isPredefined
                  ? null
                  : () => _confirmDelete(context, profile),
            );
          }),
          // Chip "Personal" — built-in, dispatcheado fuera del flujo de
          // ChangeProfile (no busca en ProfileRepository). Despacha
          // UpdateEqGains directamente con los gains construidos desde
          // los 3 valores persistidos en Hive box `settings_box`.
          _PersonalProfileChip(
            isActive: _isPersonalActive(context),
            onTap: () => _activatePersonal(context),
          ),
        ],
      ),
    );
  }

  /// Lee `state.activeEqPreset` del bloc actual para saber si el preset
  /// Personal está activo. Se usa para resaltar el chip y para mostrar
  /// el `_PersonalGainsCard` en `main_screen`.
  bool _isPersonalActive(BuildContext context) {
    final state = context.read<AmplificationBloc>().state;
    if (state is AmplificationActive) {
      return state.activeEqPreset == _kPersonalPresetName;
    }
    return false;
  }

  /// Activa el preset Personal: lee los 3 sliders persistidos, construye
  /// los 12 gains y despacha `UpdateEqGains(gains, presetName: 'Personal')`.
  /// Si el box todavía no se abrió o no hay valores guardados, los 3
  /// arrancan en 0 dB (preset bypass).
  Future<void> _activatePersonal(BuildContext context) async {
    // Capturamos el bloc ANTES del await para evitar el lint
    // `use_build_context_synchronously`. El bloc es el mismo aunque el
    // widget se desmonte después del await; despachar al bloc es seguro.
    final bloc = context.read<AmplificationBloc>();
    final box = await Hive.openBox<dynamic>('settings_box');
    final low = _readPersonalGain(box, _kPersonalLowKey);
    final mid = _readPersonalGain(box, _kPersonalMidKey);
    final high = _readPersonalGain(box, _kPersonalHighKey);
    final gains = _buildPersonalGains(low, mid, high);
    bloc.add(
      UpdateEqGains(gains: gains, presetName: _kPersonalPresetName),
    );
  }
}

/// Chip individual de perfil.
class _ProfileChip extends StatelessWidget {
  final EnvironmentProfile profile;
  final bool isActive;
  final VoidCallback onTap;
  final VoidCallback? onLongPress;

  const _ProfileChip({
    required this.profile,
    required this.isActive,
    required this.onTap,
    this.onLongPress,
  });

  IconData get _icon => switch (profile.name) {
        'Silencioso' => Icons.nights_stay,
        'Conversación' => Icons.people,
        'Ruidoso' => Icons.volume_up,
        _ => Icons.tune,
      };

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      onLongPress: onLongPress,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        decoration: BoxDecoration(
          color: isActive ? Colors.cyan.withOpacity(0.2) : Colors.transparent,
          borderRadius: BorderRadius.circular(20),
          border: Border.all(
            color: isActive ? Colors.cyan : Colors.white24,
            width: isActive ? 2 : 1,
          ),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              _icon,
              color: isActive ? Colors.cyan : Colors.white54,
              size: 22,
            ),
            const SizedBox(height: 4),
            Text(
              profile.name,
              style: TextStyle(
                color: isActive ? Colors.cyan : Colors.white54,
                fontSize: 11,
                fontWeight: isActive ? FontWeight.bold : FontWeight.normal,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Chip "Personal" — built-in, no persiste en `ProfileRepository`. Su
/// `onTap` despacha `UpdateEqGains(presetName: 'Personal')` directamente,
/// usando los 3 sliders persistidos en Hive box `settings_box`.
///
/// Visualmente es similar al `_ProfileChip` pero con icono distinto
/// (`Icons.equalizer`) y sin long-press (no se borra como un custom
/// preset).
class _PersonalProfileChip extends StatelessWidget {
  final bool isActive;
  final VoidCallback onTap;

  const _PersonalProfileChip({
    required this.isActive,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        decoration: BoxDecoration(
          color: isActive ? Colors.cyan.withOpacity(0.2) : Colors.transparent,
          borderRadius: BorderRadius.circular(20),
          border: Border.all(
            color: isActive ? Colors.cyan : Colors.white24,
            width: isActive ? 2 : 1,
          ),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.equalizer,
              color: isActive ? Colors.cyan : Colors.white54,
              size: 22,
            ),
            const SizedBox(height: 4),
            Text(
              'Personal',
              style: TextStyle(
                color: isActive ? Colors.cyan : Colors.white54,
                fontSize: 11,
                fontWeight: isActive ? FontWeight.bold : FontWeight.normal,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Card con 3 sliders graves/medios/agudos para el preset Personal del
/// técnico. Solo se renderiza cuando `state.activeEqPreset == 'Personal'`.
///
/// Carga los 3 valores desde Hive box `settings_box` en `initState`. Al
/// mover un slider, persiste el valor y despacha
/// `UpdateEqGains(gains: built, presetName: 'Personal')` para que el
/// motor reciba los nuevos gains. El bloc preserva el `activeEqPreset`
/// para que el card siga visible.
class _PersonalGainsCard extends StatefulWidget {
  const _PersonalGainsCard();

  @override
  State<_PersonalGainsCard> createState() => _PersonalGainsCardState();
}

class _PersonalGainsCardState extends State<_PersonalGainsCard> {
  double _low = 0.0;
  double _mid = 0.0;
  double _high = 0.0;
  Box<dynamic>? _box;
  bool _loaded = false;

  @override
  void initState() {
    super.initState();
    _loadFromHive();
  }

  Future<void> _loadFromHive() async {
    try {
      final box = await Hive.openBox<dynamic>('settings_box');
      if (!mounted) return;
      setState(() {
        _box = box;
        _low = _readPersonalGain(box, _kPersonalLowKey);
        _mid = _readPersonalGain(box, _kPersonalMidKey);
        _high = _readPersonalGain(box, _kPersonalHighKey);
        _loaded = true;
      });
    } catch (_) {
      if (mounted) setState(() => _loaded = true);
    }
  }

  Future<void> _onChanged(String key, double v, void Function(double) updater) async {
    setState(() => updater(v));
    final box = _box;
    if (box != null) {
      try {
        await box.put(key, v);
      } catch (_) {/* best effort */}
    }
    if (!mounted) return;
    final gains = _buildPersonalGains(_low, _mid, _high);
    context.read<AmplificationBloc>().add(
          UpdateEqGains(gains: gains, presetName: _kPersonalPresetName),
        );
  }

  @override
  Widget build(BuildContext context) {
    if (!_loaded) {
      return const SizedBox.shrink();
    }
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
            'Mi mezcla — ajustá a gusto',
            style: TextStyle(
              color: Colors.cyan,
              fontSize: 14,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 4),
          const Text(
            'El motor protege contra saturación: nunca daña el oído.',
            style: TextStyle(color: Colors.white54, fontSize: 11),
          ),
          const SizedBox(height: 12),
          _PersonalSlider(
            label: 'Graves',
            sublabel: '250 a 1000 Hz',
            value: _low,
            onChanged: (v) => _onChanged(_kPersonalLowKey, v, (x) => _low = x),
          ),
          _PersonalSlider(
            label: 'Medios',
            sublabel: '1500 a 3000 Hz',
            value: _mid,
            onChanged: (v) => _onChanged(_kPersonalMidKey, v, (x) => _mid = x),
          ),
          _PersonalSlider(
            label: 'Agudos',
            sublabel: '3500 a 8000 Hz',
            value: _high,
            onChanged: (v) => _onChanged(_kPersonalHighKey, v, (x) => _high = x),
          ),
        ],
      ),
    );
  }
}

class _PersonalSlider extends StatelessWidget {
  final String label;
  final String sublabel;
  final double value;
  final ValueChanged<double> onChanged;

  const _PersonalSlider({
    required this.label,
    required this.sublabel,
    required this.value,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  label,
                  style: const TextStyle(color: Colors.white, fontSize: 13),
                ),
              ),
              Text(
                '${value.toStringAsFixed(1)} dB',
                style: const TextStyle(color: Colors.cyan, fontSize: 13),
              ),
            ],
          ),
          Text(
            sublabel,
            style: const TextStyle(color: Colors.white54, fontSize: 10),
          ),
          Slider(
            value: value.clamp(0.0, _kPersonalGainMaxDb),
            min: 0.0,
            max: _kPersonalGainMaxDb,
            divisions: 40,
            activeColor: Colors.cyan,
            onChanged: onChanged,
          ),
        ],
      ),
    );
  }
}

// =============================================================================
// PROCESSING REPORT — Reporte de procesamiento en tiempo real
// =============================================================================

/// Panel de reporte de procesamiento DSP en tiempo real.
/// Muestra: entrada, salida, ganancia, WDRC, MPO, NR, latencia.
/// Incluye botón para copiar el reporte al portapapeles.
class _ProcessingReport extends StatelessWidget {
  final AmplificationActive state;

  const _ProcessingReport({required this.state});

  @override
  Widget build(BuildContext context) {
    // Calcular valores derivados
    final inputSpl = state.inputLevelDb;
    final volumeDb = state.volumeDb;
    final profile = state.activeProfile;

    // Estimar ganancia basada en perfil
    final double estimatedGain;
    final double compressionRatio;
    final int nrLevel;
    switch (profile) {
      case 'Silencioso':
        estimatedGain = 15.0;
        compressionRatio = 1.5;
        nrLevel = 1;
      case 'Conversación':
        estimatedGain = 20.0;
        compressionRatio = 2.0;
        nrLevel = 2;
      case 'Ruidoso':
        estimatedGain = 10.0;
        compressionRatio = 3.0;
        nrLevel = 3;
      default:
        estimatedGain = 15.0;
        compressionRatio = 2.0;
        nrLevel = 1;
    }

    // Estado WDRC
    const expansionKnee = 35.0;
    const compressionKnee = 55.0;
    final String wdrcState;
    if (inputSpl < expansionKnee) {
      wdrcState = 'Expansión ↓';
    } else if (inputSpl > compressionKnee) {
      wdrcState = 'Compresión (${compressionRatio.toStringAsFixed(1)}:1)';
    } else {
      wdrcState = 'Lineal';
    }

    // Salida estimada
    final outputSpl = inputSpl + estimatedGain + volumeDb;

    // MPO
    const mpoThreshold = 100.0;
    final mpoActive = outputSpl > mpoThreshold - 3;

    // NR labels
    const nrLabels = ['Off', 'Mild', 'Moderate', 'Strong'];

    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: const Color(0xFF16213e),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: const Color(0xFF2a3a4a)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Header con título y botón copiar
          Row(
            children: [
              const Icon(Icons.analytics, color: Colors.cyan, size: 18),
              const SizedBox(width: 6),
              const Text(
                'Procesamiento',
                style: TextStyle(
                  color: Colors.cyan,
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(width: 8),
              // Botones de acción — scroll horizontal si no caben
              Expanded(
                child: SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  reverse: true, // mostrar el final primero (más cerca al usuario)
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
              // Debug button oculto en producción
              // GestureDetector(
              //   onTap: () => _showDebugInfo(context),
              //   child: Container(
              //     padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              //     decoration: BoxDecoration(
              //       color: Colors.orange.withOpacity(0.15),
              //       borderRadius: BorderRadius.circular(6),
              //     ),
              //     child: const Row(
              //       mainAxisSize: MainAxisSize.min,
              //       children: [
              //         Icon(Icons.bug_report, color: Colors.orange, size: 14),
              //         SizedBox(width: 4),
              //         Text('Debug', style: TextStyle(color: Colors.orange, fontSize: 11)),
              //       ],
              //     ),
              //   ),
              // ),
              // const SizedBox(width: 6),
              // Botón DSP Pipeline Test
              GestureDetector(
                onTap: () {
                  Navigator.of(context).push(
                    MaterialPageRoute(
                      builder: (_) => BlocProvider.value(
                        value: context.read<AmplificationBloc>(),
                        child: const DspTestScreen(),
                      ),
                    ),
                  );
                },
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                  decoration: BoxDecoration(
                    color: Colors.cyan.withOpacity(0.15),
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: const Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.science, color: Colors.cyan, size: 14),
                      SizedBox(width: 4),
                      Text('DSP Test', style: TextStyle(color: Colors.cyan, fontSize: 11)),
                    ],
                  ),
                ),
              ),
              const SizedBox(width: 6),
              // Botón TNR (Transient Noise Reducer) — toggle on/off
              _TnrToggleButton(),
              const SizedBox(width: 6),
              // Botón Auto Suggest — sugiere preset según ambiente
              _AutoSuggestButton(),
              const SizedBox(width: 6),
              // Botón Smart Scene (Fase 1) — pantalla de diagnóstico del analyzer
              _SmartSceneButton(),
              const SizedBox(width: 6),
              GestureDetector(
                onTap: () => _copyReport(context, inputSpl, outputSpl,
                    estimatedGain, volumeDb, wdrcState, mpoActive, nrLevel, nrLabels),
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                  decoration: BoxDecoration(
                    color: Colors.cyan.withOpacity(0.15),
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: const Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.copy, color: Colors.cyan, size: 14),
                      SizedBox(width: 4),
                      Text('Copiar', style: TextStyle(color: Colors.cyan, fontSize: 11)),
                    ],
                  ),
                ),
              ),
                    ],
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          // Grid de métricas
          Wrap(
            spacing: 12,
            runSpacing: 8,
            children: [
              _ReportMetric(
                icon: '📥',
                label: 'Entrada',
                value: '${inputSpl.toStringAsFixed(1)} dB SPL',
              ),
              _ReportMetric(
                icon: '📤',
                label: 'Salida',
                value: '${outputSpl.toStringAsFixed(1)} dB SPL',
              ),
              _ReportMetric(
                icon: '📈',
                label: 'Ganancia',
                value: '+${(estimatedGain + volumeDb).toStringAsFixed(1)} dB',
              ),
              _ReportMetric(
                icon: '🔊',
                label: 'Volumen',
                value: '${volumeDb >= 0 ? '+' : ''}${volumeDb.toStringAsFixed(0)} dB',
              ),
              _ReportMetric(
                icon: '🎚️',
                label: 'WDRC',
                value: wdrcState,
              ),
              _ReportMetric(
                icon: '🛡️',
                label: 'MPO',
                value: mpoActive ? '⚠️ LIMITANDO' : 'Inactivo',
                valueColor: mpoActive ? Colors.red : null,
              ),
              _ReportMetric(
                icon: '🔇',
                label: 'NR',
                value: nrLabels[nrLevel.clamp(0, 3)],
              ),
              _ReportMetric(
                icon: '⏱️',
                label: 'Latencia',
                value: '~5.8 ms',
              ),
            ],
          ),
        ],
      ),
    );
  }

  void _showDebugInfo(BuildContext context) async {
    try {
      const channel = MethodChannel('com.psk.hearing_aid/audio');
      final info = await channel.invokeMethod<String>('getDebugInfo');
      if (context.mounted) {
        showDialog(
          context: context,
          builder: (ctx) => AlertDialog(
            backgroundColor: const Color(0xFF1a2332),
            title: const Text('Debug Info', style: TextStyle(color: Colors.orange)),
            content: SingleChildScrollView(
              child: Text(
                info ?? 'No info',
                style: const TextStyle(
                  color: Colors.white70,
                  fontFamily: 'monospace',
                  fontSize: 12,
                ),
              ),
            ),
            actions: [
              TextButton(
                onPressed: () {
                  Clipboard.setData(ClipboardData(text: info ?? ''));
                  Navigator.pop(ctx);
                },
                child: const Text('Copiar y cerrar'),
              ),
            ],
          ),
        );
      }
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error: $e'), backgroundColor: Colors.red),
        );
      }
    }
  }

  void _copyReport(
    BuildContext context,
    double inputSpl,
    double outputSpl,
    double gain,
    double volume,
    String wdrcState,
    bool mpoActive,
    int nrLevel,
    List<String> nrLabels,
  ) {
    final report = '''
=== Reporte de Procesamiento DSP ===
Perfil: ${state.activeProfile}
Entrada: ${inputSpl.toStringAsFixed(1)} dB SPL
Salida: ${outputSpl.toStringAsFixed(1)} dB SPL
Ganancia: +${(gain + volume).toStringAsFixed(1)} dB
Volumen: ${volume >= 0 ? '+' : ''}${volume.toStringAsFixed(0)} dB
WDRC: $wdrcState
MPO: ${mpoActive ? 'LIMITANDO' : 'Inactivo'}
NR: ${nrLabels[nrLevel.clamp(0, 3)]}
Latencia: ~5.8 ms
Auriculares: ${state.headphonesConnected ? 'Conectados' : 'Desconectados'}
================================
''';

    Clipboard.setData(ClipboardData(text: report));
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('Reporte copiado al portapapeles'),
        duration: Duration(seconds: 2),
        backgroundColor: Color(0xFF0f3460),
      ),
    );
  }
}

/// Métrica individual del reporte de procesamiento.
class _ReportMetric extends StatelessWidget {
  final String icon;
  final String label;
  final String value;
  final Color? valueColor;

  const _ReportMetric({
    required this.icon,
    required this.label,
    required this.value,
    this.valueColor,
  });

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 145,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(icon, style: const TextStyle(fontSize: 12)),
          const SizedBox(width: 4),
          Text(
            '$label: ',
            style: const TextStyle(
              color: Colors.white54,
              fontSize: 11,
              fontWeight: FontWeight.w500,
            ),
          ),
          Flexible(
            child: Text(
              value,
              style: TextStyle(
                color: valueColor ?? Colors.white,
                fontSize: 11,
                fontWeight: FontWeight.w600,
              ),
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    );
  }
}

// =============================================================================
// EQ PRESET DETAIL PANEL — Mini gráfico de barras + WDRC params
// =============================================================================

/// Panel compacto (≤80px) que muestra:
/// - Nombre del preset EQ activo
/// - Mini gráfico de barras con las 12 ganancias reales por banda
/// - Parámetros WDRC: CR y Compression Knee del perfil activo
/// Al tocarlo navega a SimulatorScreen (configuración avanzada).
class _EqPresetDetailPanel extends StatefulWidget {
  final AmplificationActive state;

  const _EqPresetDetailPanel({required this.state});

  @override
  State<_EqPresetDetailPanel> createState() => _EqPresetDetailPanelState();
}

class _EqPresetDetailPanelState extends State<_EqPresetDetailPanel> {
  List<double> _gains = List.filled(12, 0.0);
  String _presetName = '';
  bool _loaded = false;

  @override
  void initState() {
    super.initState();
    _loadEqData();
  }

  @override
  void didUpdateWidget(covariant _EqPresetDetailPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.state.activeEqPreset != widget.state.activeEqPreset) {
      _loadEqData();
    }
  }

  Future<void> _loadEqData() async {
    final bloc = context.read<AmplificationBloc>();
    try {
      final savedPreset = await bloc.settingsRepository.getLastEqPreset();
      if (savedPreset != null) {
        final gains = (savedPreset['gains'] as List<dynamic>?)
            ?.map((e) => (e as num).toDouble())
            .toList();
        if (gains != null && gains.length == 12) {
          _gains = gains;
        }
        _presetName = savedPreset['name'] as String? ?? widget.state.activeEqPreset;
      } else {
        _presetName = widget.state.activeEqPreset;
      }
    } catch (_) {
      _presetName = widget.state.activeEqPreset;
    }
    if (mounted) setState(() => _loaded = true);
  }

  /// Obtiene los parámetros WDRC del perfil activo.
  ({double cr, double knee}) _getWdrcParams() {
    final profileName = widget.state.activeProfile;
    final profile = EnvironmentProfile.predefinedProfiles.cast<EnvironmentProfile?>().firstWhere(
      (p) => p!.name == profileName,
      orElse: () => null,
    );
    if (profile != null) {
      return (cr: profile.compressionRatio, knee: profile.compressionKnee);
    }
    // Fallback para perfiles custom — usar valores por defecto
    return (cr: 2.0, knee: 50.0);
  }

  @override
  Widget build(BuildContext context) {
    final wdrc = _getWdrcParams();

    return GestureDetector(
      onTap: () {
        Navigator.of(context).push(
          MaterialPageRoute(
            builder: (_) => BlocProvider.value(
              value: context.read<AmplificationBloc>(),
              child: const SimulatorScreen(),
            ),
          ),
        );
      },
      child: Container(
        height: 80,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: const Color(0xFF16213e),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: Colors.cyan.withOpacity(0.2)),
        ),
        child: Row(
          children: [
            // Left: Preset name + WDRC params
            SizedBox(
              width: 90,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Text(
                    _loaded ? _presetName : '...',
                    style: const TextStyle(
                      color: Colors.cyan,
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                    ),
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: 4),
                  Text(
                    'CR ${wdrc.cr.toStringAsFixed(1)}:1',
                    style: const TextStyle(
                      color: Colors.white54,
                      fontSize: 10,
                    ),
                  ),
                  Text(
                    'Knee ${wdrc.knee.toStringAsFixed(0)} dB',
                    style: const TextStyle(
                      color: Colors.white54,
                      fontSize: 10,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            // Center: Mini bar chart of 12 bands
            Expanded(
              child: _loaded
                  ? _MiniEqBarChart(gains: _gains)
                  : const Center(
                      child: SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: Colors.cyan,
                        ),
                      ),
                    ),
            ),
            const SizedBox(width: 8),
            // Right: chevron
            const Icon(Icons.chevron_right, color: Colors.white38, size: 18),
          ],
        ),
      ),
    );
  }
}

/// Mini gráfico de barras compacto para las 12 ganancias EQ.
class _MiniEqBarChart extends StatelessWidget {
  final List<double> gains;

  const _MiniEqBarChart({required this.gains});

  @override
  Widget build(BuildContext context) {
    // Calcular rango para normalización
    final maxGain = gains.reduce((a, b) => a > b ? a : b).clamp(1.0, 50.0);

    return Row(
      crossAxisAlignment: CrossAxisAlignment.end,
      children: List.generate(12, (i) {
        final normalized = (gains[i] / maxGain).clamp(0.0, 1.0);
        return Expanded(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 1),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                Expanded(
                  child: Align(
                    alignment: Alignment.bottomCenter,
                    child: FractionallySizedBox(
                      heightFactor: normalized.clamp(0.05, 1.0),
                      child: Container(
                        decoration: BoxDecoration(
                          color: _barColor(gains[i]),
                          borderRadius: BorderRadius.circular(2),
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        );
      }),
    );
  }

  Color _barColor(double gain) {
    if (gain >= 25) return Colors.orange;
    if (gain >= 15) return Colors.cyan;
    if (gain >= 5) return Colors.cyan.withOpacity(0.7);
    return Colors.cyan.withOpacity(0.4);
  }
}

// =============================================================================
// EQ PRESET INDICATOR — Muestra el preset activo en la pantalla principal
// =============================================================================

/// Indicador compacto del preset de EQ y NR activos.
/// Al tocarlo abre la pantalla de detalle completo de configuración DSP.
/// Anima un destello cyan cuando cambia el preset (visualmente confirma
/// que la sugerencia "Auto" se aplicó).
class _EqPresetIndicator extends StatefulWidget {
  final String presetName;
  final int nrLevel;

  const _EqPresetIndicator({required this.presetName, required this.nrLevel});

  @override
  State<_EqPresetIndicator> createState() => _EqPresetIndicatorState();
}

class _EqPresetIndicatorState extends State<_EqPresetIndicator>
    with SingleTickerProviderStateMixin {
  late final AnimationController _flashController;

  @override
  void initState() {
    super.initState();
    _flashController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1200),
    );
  }

  @override
  void didUpdateWidget(covariant _EqPresetIndicator oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.presetName != widget.presetName) {
      _flashController.forward(from: 0.0);
    }
  }

  @override
  void dispose() {
    _flashController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    const nrLabels = ['Off', 'Bajo', 'Medio', 'Alto'];

    return GestureDetector(
      onTap: () {
        Navigator.of(context).push(
          MaterialPageRoute(
            builder: (_) => BlocProvider.value(
              value: context.read<AmplificationBloc>(),
              child: const DspConfigDetailScreen(),
            ),
          ),
        );
      },
      child: AnimatedBuilder(
        animation: _flashController,
        builder: (context, child) {
          // Pulso de luz: 0 → 1 → 0 en 1.2 s.
          final t = _flashController.value;
          final pulse = (t < 0.5 ? t * 2 : (1 - t) * 2).clamp(0.0, 1.0);
          final borderColor = Color.lerp(
            Colors.transparent,
            Colors.cyan,
            pulse,
          )!;
          final bg = Color.lerp(
            const Color(0xFF16213e),
            Colors.cyan.withOpacity(0.20),
            pulse * 0.6,
          )!;
          return Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
            decoration: BoxDecoration(
              color: bg,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: borderColor, width: 2 * pulse),
              boxShadow: pulse > 0
                  ? [
                      BoxShadow(
                        color: Colors.cyan.withOpacity(0.3 * pulse),
                        blurRadius: 8 * pulse,
                      ),
                    ]
                  : null,
            ),
            child: child,
          );
        },
        child: Row(
          children: [
            const Icon(Icons.equalizer, color: Colors.cyan, size: 18),
            const SizedBox(width: 8),
            Expanded(
              child: AnimatedSwitcher(
                duration: const Duration(milliseconds: 300),
                child: Text(
                  'EQ: ${widget.presetName}',
                  key: ValueKey(widget.presetName),
                  style: const TextStyle(
                    color: Colors.cyan,
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ),
            const Icon(Icons.noise_aware, color: Colors.white54, size: 16),
            const SizedBox(width: 4),
            Text(
              'NR: ${nrLabels[widget.nrLevel.clamp(0, 3)]}',
              style: const TextStyle(
                color: Colors.white54,
                fontSize: 12,
              ),
            ),
            const SizedBox(width: 8),
            const Icon(Icons.chevron_right, color: Colors.white38, size: 18),
          ],
        ),
      ),
    );
  }
}


/// Botón toggle para activar/desactivar el Transient Noise Reducer (TNR).
///
/// El TNR atenúa automáticamente impulsos abruptos como timbre del subte,
/// puertas, bocinas, sin afectar la voz normal.
class _TnrToggleButton extends StatefulWidget {
  @override
  State<_TnrToggleButton> createState() => _TnrToggleButtonState();
}

class _TnrToggleButtonState extends State<_TnrToggleButton> {
  bool _enabled = true; // Activado por default

  @override
  void initState() {
    super.initState();
    // Asegurar que el estado nativo coincida con el inicial
    _applyToNative(_enabled);
  }

  Future<void> _applyToNative(bool enabled) async {
    try {
      const channel = MethodChannel('com.psk.hearing_aid/audio');
      await channel.invokeMethod('updateTnrEnabled', {'enabled': enabled});
    } catch (_) {
      // Ignorar errores si el engine no está activo
    }
  }

  void _toggle() {
    setState(() => _enabled = !_enabled);
    _applyToNative(_enabled);
    final msg = _enabled
        ? '🛡️ TNR activado — atenúa impulsos (timbre, puertas)'
        : '🔊 TNR desactivado — escucha sin filtrar';
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(msg),
        duration: const Duration(seconds: 2),
        backgroundColor: _enabled ? Colors.cyan.shade900 : Colors.grey.shade800,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final color = _enabled ? Colors.cyan : Colors.white38;
    final bgColor = _enabled
        ? Colors.cyan.withOpacity(0.15)
        : Colors.white.withOpacity(0.05);
    return GestureDetector(
      onTap: _toggle,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        decoration: BoxDecoration(
          color: bgColor,
          borderRadius: BorderRadius.circular(6),
          border: _enabled
              ? Border.all(color: Colors.cyan.withOpacity(0.4), width: 0.5)
              : null,
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              _enabled ? Icons.shield : Icons.shield_outlined,
              color: color,
              size: 14,
            ),
            const SizedBox(width: 4),
            Text(
              _enabled ? 'TNR ON' : 'TNR OFF',
              style: TextStyle(color: color, fontSize: 11),
            ),
          ],
        ),
      ),
    );
  }
}


/// Botón "Auto" — clasifica el ambiente acústico actual y aplica el preset
/// EQ recomendado, ajustando además el master volume con un delta sugerido.
///
/// Funciona consultando `getDspStageMetrics` cada 100 ms durante 1 segundo,
/// promediando la clase de ambiente devuelta por el clasificador C++. Luego
/// usa [PresetAdvisor.suggestForUser] para mapear ambiente → preset
/// (consultando aprendizaje local primero) y aplica vía bloc.
///
/// Después de aplicar muestra una barra flotante con 👍 / 👎 para que el
/// usuario califique el resultado. La calificación se guarda en
/// [PresetLearningService] y permite que la app aprenda preferencias.
class _AutoSuggestButton extends StatefulWidget {
  @override
  State<_AutoSuggestButton> createState() => _AutoSuggestButtonState();
}

class _AutoSuggestButtonState extends State<_AutoSuggestButton> {
  bool _busy = false;
  static const _channel = MethodChannel('com.psk.hearing_aid/audio');
  final _learning = PresetLearningService();

  Future<void> _measureAndApply() async {
    if (_busy) return;
    setState(() => _busy = true);

    final bloc = context.read<AmplificationBloc>();
    final isActive = bloc.state is AmplificationActive;

    if (!isActive) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Activá el audífono primero para detectar el ambiente.'),
          duration: Duration(seconds: 2),
        ),
      );
      setState(() => _busy = false);
      return;
    }

    // Asegurar que el clasificador esté activo
    try {
      await _channel.invokeMethod('updateAutoClassify', {'enabled': true});
    } catch (_) {}

    // Esperar 500 ms a que el clasificador estabilice tras un cambio
    await Future.delayed(const Duration(milliseconds: 500));

    // Medir 1 segundo, tomar la clase de ambiente más frecuente.
    final classCounts = <int, int>{};
    for (int i = 0; i < 10; i++) {
      try {
        final r = await _channel.invokeMethod<Map>('getDspStageMetrics');
        if (r != null) {
          final ec = r['environmentClass'];
          if (ec is int && ec >= 0) {
            classCounts[ec] = (classCounts[ec] ?? 0) + 1;
          }
        }
      } catch (_) {}
      await Future.delayed(const Duration(milliseconds: 100));
    }

    // Modo normal del Técnico = manual: el clasificador solo se prende
    // para esta medición de 1 s y se vuelve a apagar al terminar, para no
    // dejarlo persistente pisando el WDRC cada bloque. La sugerencia de
    // preset/volumen se aplica igual debajo con la clase ya medida.
    try {
      await _channel.invokeMethod('updateAutoClassify', {'enabled': false});
    } catch (_) {}

    if (!mounted) return;

    if (classCounts.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('No se pudo leer el ambiente. Revisá permisos del micrófono.'),
          duration: Duration(seconds: 2),
        ),
      );
      setState(() => _busy = false);
      return;
    }

    final dominant = classCounts.entries
        .reduce((a, b) => a.value >= b.value ? a : b)
        .key;

    // Cargar aprendizaje local y consultar.
    await _learning.load();
    final result = PresetAdvisor.suggestForUser(
      envClass: dominant,
      learning: _learning,
    );
    final preset = result.preset;
    final fromLearning = result.fromLearning;
    final volDelta = PresetAdvisor.volumeDeltaFor(dominant);

    // Aplicar preset
    bloc.add(UpdateEqGains(gains: preset.gains, presetName: preset.name));

    // Aplicar delta de volumen sobre el actual si hay estado activo
    final st = bloc.state;
    if (st is AmplificationActive && volDelta != 0) {
      final newVol = (st.volumeDb + volDelta).clamp(-20.0, 10.0);
      bloc.add(ChangeVolume(volumeDb: newVol));
    }

    // Registrar la aplicación para que el usuario pueda calificarla.
    final entryId = await _learning.recordApplication(
      envClass: dominant,
      presetName: preset.name,
      source: 'auto',
    );

    if (!mounted) return;

    final label = PresetAdvisor.labelFor(dominant);

    // Mostrar la barra de feedback con 👍 / 👎.
    _showFeedbackBar(
      context: context,
      message: '🎯 $label → ${preset.name}'
          '${volDelta != 0 ? '   ·   Vol ${volDelta.toStringAsFixed(0)} dB' : ''}'
          '${fromLearning ? '   ·   📚 Aprendido' : ''}',
      entryId: entryId,
      presetName: preset.name,
      gains: preset.gains,
      sceneClass: PresetAdvisor.labelFor(dominant),
    );

    setState(() => _busy = false);
  }

  /// Muestra una `MaterialBanner` con botones 👍 / 👎 que persisten hasta
  /// que el usuario responda o pasen 12 segundos.
  void _showFeedbackBar({
    required BuildContext context,
    required String message,
    required int entryId,
    required String presetName,
    required List<double> gains,
    required String sceneClass,
  }) {
    final messenger = ScaffoldMessenger.of(context);
    messenger.clearMaterialBanners();
    final controller = messenger.showMaterialBanner(
      MaterialBanner(
        backgroundColor: const Color(0xFF0f3460),
        leading: const Icon(Icons.auto_awesome, color: Colors.amberAccent),
        content: Text(
          '$message\n¿Quedó bien?',
          style: const TextStyle(color: Colors.white, fontSize: 13),
        ),
        actions: [
          TextButton.icon(
            onPressed: () async {
              await _learning.recordFeedback(
                entryId: entryId,
                positive: false,
              );
              messenger.hideCurrentMaterialBanner();
              messenger.showSnackBar(
                const SnackBar(
                  content: Text('Anotado: 👎 — la app va a evitar este preset'),
                  duration: Duration(seconds: 2),
                ),
              );
              if (mounted) {
                await showFeedbackChecklistDialog(
                  context,
                  sceneClass: sceneClass,
                  presetName: presetName,
                  gains: gains,
                  thumbsUp: false,
                );
              }
            },
            icon: const Icon(Icons.thumb_down, color: Colors.redAccent, size: 18),
            label: const Text(
              'No',
              style: TextStyle(color: Colors.redAccent),
            ),
          ),
          TextButton.icon(
            onPressed: () async {
              await _learning.recordFeedback(
                entryId: entryId,
                positive: true,
              );
              messenger.hideCurrentMaterialBanner();
              messenger.showSnackBar(
                const SnackBar(
                  content: Text('Anotado: 👍 — la app va a preferirlo aquí'),
                  duration: Duration(seconds: 2),
                ),
              );
              if (mounted) {
                await showFeedbackChecklistDialog(
                  context,
                  sceneClass: sceneClass,
                  presetName: presetName,
                  gains: gains,
                  thumbsUp: true,
                );
              }
            },
            icon: const Icon(Icons.thumb_up, color: Colors.greenAccent, size: 18),
            label: const Text(
              'Sí',
              style: TextStyle(color: Colors.greenAccent),
            ),
          ),
        ],
      ),
    );

    // Auto-dismiss tras 12 s sin respuesta.
    Future.delayed(const Duration(seconds: 12), () {
      try {
        controller.close();
      } catch (_) {}
    });
  }

  @override
  Widget build(BuildContext context) {
    final color = _busy ? Colors.white38 : Colors.amberAccent;
    final bgColor = _busy
        ? Colors.white.withOpacity(0.05)
        : Colors.amber.withOpacity(0.12);
    return GestureDetector(
      onTap: _measureAndApply,
      onLongPress: () {
        Navigator.of(context).push(
          MaterialPageRoute(
            builder: (_) => const PresetLearningScreen(),
          ),
        );
      },
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        decoration: BoxDecoration(
          color: bgColor,
          borderRadius: BorderRadius.circular(6),
          border: _busy
              ? null
              : Border.all(color: Colors.amber.withOpacity(0.4), width: 0.5),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            _busy
                ? const SizedBox(
                    width: 12,
                    height: 12,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: Colors.white38,
                    ),
                  )
                : Icon(Icons.auto_awesome, color: color, size: 14),
            const SizedBox(width: 4),
            Text(
              _busy ? 'Midiendo…' : 'Auto',
              style: TextStyle(color: color, fontSize: 11),
            ),
          ],
        ),
      ),
    );
  }
}

// =============================================================================
// SMART SCENE BUTTON — Smart Scene Engine (Fase 1)
// =============================================================================

/// Botón compacto que abre la pantalla de diagnóstico del Smart Scene Engine.
///
/// Fase 1 muestra los números crudos del clasificador C++ a 10 Hz.
/// Las decisiones automáticas y el preset adaptativo llegan en fases siguientes.
class _SmartSceneButton extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: () {
        Navigator.of(context).push(
          MaterialPageRoute(
            builder: (_) => const SmartSceneScreen(),
          ),
        );
      },
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        decoration: BoxDecoration(
          color: const Color(0xFF8E24AA).withOpacity(0.18),
          borderRadius: BorderRadius.circular(6),
          border: Border.all(
            color: const Color(0xFF00E5FF).withOpacity(0.5),
            width: 0.5,
          ),
        ),
        child: const Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.insights, color: Color(0xFF00E5FF), size: 14),
            SizedBox(width: 4),
            Text(
              'Smart',
              style: TextStyle(color: Color(0xFF00E5FF), fontSize: 11),
            ),
          ],
        ),
      ),
    );
  }
}


// =============================================================================
// MODO CONVERSACIÓN — toggle local (no pasa por el AmplificationBloc)
// =============================================================================

/// Toggle "Modo Conversación" — rutea audio por SCO Bluetooth (o builtin si
/// no hay BT) con `MODE_IN_COMMUNICATION` y baja el sample rate del pipeline
/// a 16 kHz / 64 frames. Latencia BT cae de ~200 ms a ~25 ms.
///
/// Despacha el evento [ToggleConversationMode] al [AmplificationBloc]. El
/// handler `_onToggleConversationMode` delega en `audioBridge.setConversationMode`,
/// persiste en Hive (`conversationMode`) y emite el state con `conversationMode`.
///
/// Muestra un chip con el modo actual: "🎵 A2DP (Normal)" o "🎧 SCO (Baja Latencia)"
/// y un warning badge "⚠️ Calidad reducida (16 kHz)" cuando está activo.
class _ConversationModeToggleCard extends StatefulWidget {
  const _ConversationModeToggleCard();

  @override
  State<_ConversationModeToggleCard> createState() => _ConversationModeToggleCardState();
}

class _ConversationModeToggleCardState extends State<_ConversationModeToggleCard> {
  bool _isChanging = false;
  bool? _expectedMode; // null = no hay cambio en progreso

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AmplificationBloc>().state;
    final isActive = state is AmplificationActive && state.conversationMode;

    return BlocListener<AmplificationBloc, AmplificationState>(
      listenWhen: (prev, curr) {
        // Solo escuchar si hay un cambio en progreso Y conversationMode cambió
        if (_expectedMode == null) return false;
        if (curr is! AmplificationActive) return false;
        final prevMode = prev is AmplificationActive ? prev.conversationMode : false;
        return curr.conversationMode != prevMode;
      },
      listener: (context, state) {
        if (state is AmplificationActive && state.conversationMode == _expectedMode) {
          // El cambio esperado terminó
          if (mounted) {
            setState(() {
              _isChanging = false;
              _expectedMode = null;
            });
          }
        }
      },
      child: LayoutBuilder(
      builder: (context, constraints) {
        final isCompact = constraints.maxWidth < 360;
        return Container(
          padding: EdgeInsets.all(isCompact ? 8 : 14),
          decoration: BoxDecoration(
            color: const Color(0xFF16213e),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
              color: isActive ? Colors.cyan.withOpacity(0.6) : Colors.white12,
            ),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Icon(
                    Icons.phone_bluetooth_speaker,
                    color: isActive ? Colors.cyanAccent : Colors.white60,
                    size: isCompact ? 16 : 20,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Modo Conversación',
                          style: TextStyle(
                            color: Colors.white,
                            fontSize: isCompact ? 12 : 14,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          'BT baja latencia (~10ms). Voz 16 kHz.',
                          style: TextStyle(
                            color: Colors.white60,
                            fontSize: isCompact ? 10 : 11,
                          ),
                        ),
                        if (!isCompact) ...[
                          const SizedBox(height: 2),
                          const Text(
                            '⚠️ Amplificación 6-8 kHz desactivada (consonantes /s/, /f/)',
                            style: TextStyle(
                              color: Colors.orangeAccent,
                              fontSize: 10,
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                  // Mostrar loading spinner si está cambiando, sino el Switch
                  if (_isChanging)
                    const SizedBox(
                      width: 24,
                      height: 24,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        valueColor: AlwaysStoppedAnimation<Color>(Colors.cyanAccent),
                      ),
                    )
                  else
                    Switch(
                      value: isActive,
                      onChanged: _isChanging ? null : (v) {
                        final currentMode = (state is AmplificationActive) ? state.conversationMode : false;
                        print('🔍 TOGGLE: isActive=$isActive, v=$v, currentMode=$currentMode');
                        setState(() {
                          _isChanging = true;
                          _expectedMode = v;
                        });
                        context
                            .read<AmplificationBloc>()
                            .add(ToggleConversationMode(activate: v));
                        
                        // Timeout de respaldo (por si el BLoC no emite state en tiempo razonable)
                        Future.delayed(const Duration(seconds: 5), () {
                          if (mounted && _isChanging && _expectedMode == v) {
                            setState(() {
                              _isChanging = false;
                              _expectedMode = null;
                            });
                          }
                        });
                      },
                      activeColor: Colors.cyanAccent,
                    ),
                ],
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  // Chip de modo actual
                  Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                    decoration: BoxDecoration(
                      color: isActive
                          ? Colors.cyan.withOpacity(0.15)
                          : Colors.white.withOpacity(0.05),
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(
                        color:
                            isActive ? Colors.cyan.withOpacity(0.4) : Colors.white24,
                      ),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          isActive ? Icons.headset_mic : Icons.headphones,
                          color: isActive ? Colors.cyanAccent : Colors.white38,
                          size: 14,
                        ),
                        const SizedBox(width: 4),
                        Text(
                          isActive ? 'SCO (Baja Latencia)' : 'A2DP (Normal)',
                          style: TextStyle(
                            color: isActive ? Colors.cyanAccent : Colors.white60,
                            fontSize: 11,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ],
                    ),
                  ),
                  // Warning badge cuando está activo
                  if (isActive) ...[
                    const SizedBox(width: 8),
                    Container(
                      padding:
                          const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                      decoration: BoxDecoration(
                        color: Colors.orange.withOpacity(0.15),
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(color: Colors.orange.withOpacity(0.4)),
                      ),
                      child: const Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(Icons.warning_amber_rounded,
                              color: Colors.orangeAccent, size: 14),
                          SizedBox(width: 4),
                          Text(
                            'Solo para llamadas',
                            style: TextStyle(
                              color: Colors.orangeAccent,
                              fontSize: 11,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ],
              ),
              // Nota informativa de uso clínico — solo en pantallas no compactas
              if (isActive && !isCompact) ...[
                const SizedBox(height: 8),
                Container(
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: Colors.blue.withOpacity(0.1),
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: Colors.blue.withOpacity(0.3)),
                  ),
                  child: const Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Icon(Icons.info_outline, color: Colors.blueAccent, size: 16),
                      SizedBox(width: 6),
                      Expanded(
                        child: Text(
                          'Usar solo para llamadas/videollamadas. '
                          'NO usar para ambiente cotidiano, música o aprendizaje de lenguaje.',
                          style: TextStyle(
                            color: Colors.blueAccent,
                            fontSize: 10,
                            height: 1.3,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
            ],
            ],
          ),
        );
      },
    ),
    ); // Cierre del BlocListener
  }
}


// ─────────────────────────────────────────────────────────────────────────────
// smart-continuo-dnn-modulado: Smart Scene continuo + chip de escena en vivo
// ─────────────────────────────────────────────────────────────────────────────

/// Card con el toggle del Smart Scene Engine continuo + chip de escena.
///
/// El toggle controla `_smartEnabled` del bloc vía evento `ToggleSmart`.
/// El chip se actualiza a 1 Hz vía Timer interno leyendo
/// `bloc.lastEnvClass`. Cuando Smart está OFF, el chip se oculta y solo
/// queda el toggle apagado.
///
/// Visibilidad: solo se muestra en `AmplificationActive` (motor corriendo).
/// La pre-selección en IDLE NO incluye este card — el clasificador
/// necesita el motor activo para emitir clases.
class _SmartSceneToggleCard extends StatefulWidget {
  const _SmartSceneToggleCard();

  @override
  State<_SmartSceneToggleCard> createState() => _SmartSceneToggleCardState();
}

class _SmartSceneToggleCardState extends State<_SmartSceneToggleCard> {
  Timer? _refresh;
  bool _smart = false;
  int? _envClass;

  @override
  void initState() {
    super.initState();
    final bloc = context.read<AmplificationBloc>();
    _smart = bloc.isSmartEnabled;
    _envClass = bloc.lastEnvClass;
    _refresh = Timer.periodic(const Duration(seconds: 1), (_) => _tick());
  }

  @override
  void dispose() {
    _refresh?.cancel();
    super.dispose();
  }

  void _tick() {
    if (!mounted) return;
    final bloc = context.read<AmplificationBloc>();
    final newSmart = bloc.isSmartEnabled;
    final newCls = bloc.lastEnvClass;
    if (newSmart != _smart || newCls != _envClass) {
      setState(() {
        _smart = newSmart;
        _envClass = newCls;
      });
    }
  }

  Future<void> _onToggle(bool v) async {
    final bloc = context.read<AmplificationBloc>();
    bloc.add(ToggleSmart(activate: v));
    setState(() => _smart = v);
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: const Color(0xFF1a1a2e),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.white.withOpacity(0.08)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              const Icon(Icons.auto_awesome, color: Color(0xFF00e5ff), size: 20),
              const SizedBox(width: 8),
              const Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Smart (ambiente automático)',
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    SizedBox(height: 2),
                    Text(
                      'Clasifica el entorno en vivo y elige el perfil.',
                      style: TextStyle(color: Colors.white60, fontSize: 11),
                    ),
                  ],
                ),
              ),
              Switch(
                value: _smart,
                onChanged: _onToggle,
                activeColor: const Color(0xFF00e5ff),
              ),
            ],
          ),
          if (_smart) ...[
            const SizedBox(height: 10),
            _SceneChip(envClass: _envClass),
          ],
        ],
      ),
    );
  }
}

/// Chip que muestra la clase de entorno detectada por el
/// `EnvironmentClassifier` C++ (4 clases reales).
///
/// Mapeo:
///   - 0 QUIET            → 🟢 Silencio
///   - 1 SPEECH           → 🟡 Voz
///   - 2 SPEECH_IN_NOISE  → 🟠 Voz + ruido
///   - 3 NOISE            → 🔴 Ruidoso
///   - null/otro          → ⏳ Detectando…
class _SceneChip extends StatelessWidget {
  final int? envClass;
  const _SceneChip({required this.envClass});

  @override
  Widget build(BuildContext context) {
    final String emoji;
    final String label;
    final Color color;
    switch (envClass) {
      case 0:
        emoji = '🟢';
        label = 'Silencio';
        color = const Color(0xFF4CAF50);
        break;
      case 1:
        emoji = '🟡';
        label = 'Voz';
        color = const Color(0xFFFFC107);
        break;
      case 2:
        emoji = '🟠';
        label = 'Voz + ruido';
        color = const Color(0xFFFF9800);
        break;
      case 3:
        emoji = '🔴';
        label = 'Ruidoso';
        color = const Color(0xFFF44336);
        break;
      default:
        emoji = '⏳';
        label = 'Detectando…';
        color = const Color(0xFF9E9E9E);
    }
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: color.withOpacity(0.15),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: color.withOpacity(0.5)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(emoji, style: const TextStyle(fontSize: 14)),
          const SizedBox(width: 6),
          Text(
            'Ambiente: $label',
            style: TextStyle(
              color: color,
              fontSize: 13,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }
}


// =============================================================================
// LIMPIADOR DE RUIDO (DNN) — Toggle + Slider en la pantalla principal
// =============================================================================

/// Control del filtro de ruido IA (DNN GTCRN) accesible directamente desde la
/// pantalla principal. Toggle on/off + slider de intensidad. Autocontenido:
/// maneja su estado interno y se comunica directo con el MethodChannel sin
/// pasar por el AmplificationBloc (mismo patrón que _ConversationModeToggleCard).
class _DnnNoiseCleanerCard extends StatefulWidget {
  const _DnnNoiseCleanerCard();

  @override
  State<_DnnNoiseCleanerCard> createState() => _DnnNoiseCleanerCardState();
}

class _DnnNoiseCleanerCardState extends State<_DnnNoiseCleanerCard> {
  static const _channel = MethodChannel('com.psk.hearing_aid/audio');

  bool _enabled = true;
  double _intensity = 0.6;

  @override
  void initState() {
    super.initState();
    // Leer el estado inicial del DNN desde el motor (best-effort).
    _loadState();
  }

  Future<void> _loadState() async {
    try {
      final active = await _channel.invokeMethod<bool>('getDnnIsActive');
      if (mounted && active != null) {
        setState(() => _enabled = active);
      }
    } catch (_) {}
    // Leer intensidad desde settings si está disponible.
    try {
      final bloc = context.read<AmplificationBloc>();
      final intensity = bloc.settingsRepository.dnnIntensity;
      if (mounted) setState(() => _intensity = intensity);
    } catch (_) {}
  }

  Future<void> _setEnabled(bool enabled) async {
    setState(() => _enabled = enabled);
    try {
      await _channel.invokeMethod<void>('setDnnEnabled', {'enabled': enabled});
    } catch (_) {}
  }

  Future<void> _setIntensity(double value) async {
    setState(() => _intensity = value);
    try {
      await _channel.invokeMethod<void>(
        'setDnnIntensity',
        {'intensity': value},
      );
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    final intensityPct = (_intensity * 100).round();
    return Card(
      color: const Color(0xFF16213e),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // ─── Fila: Título + Toggle ─────────────────────────────────
            Row(
              children: [
                const Icon(Icons.psychology, color: Colors.cyanAccent, size: 20),
                const SizedBox(width: 8),
                const Expanded(
                  child: Text(
                    'Limpiador de ruido (IA)',
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                Switch(
                  value: _enabled,
                  onChanged: _setEnabled,
                  activeColor: Colors.cyanAccent,
                  inactiveThumbColor: Colors.white60,
                  inactiveTrackColor: Colors.white12,
                ),
              ],
            ),
            // ─── Slider de intensidad ─────────────────────────────────
            Opacity(
              opacity: _enabled ? 1.0 : 0.4,
              child: AbsorbPointer(
                absorbing: !_enabled,
                child: Row(
                  children: [
                    const Icon(Icons.tune, color: Colors.white60, size: 16),
                    const SizedBox(width: 4),
                    const Text(
                      'Fuerza',
                      style: TextStyle(color: Colors.white70, fontSize: 12),
                    ),
                    Expanded(
                      child: Slider(
                        value: _intensity,
                        min: 0.0,
             max: 1.0,
                        divisions: 20,
                        label: '$intensityPct%',
                        activeColor: Colors.cyanAccent,
                        inactiveColor: Colors.white24,
                        onChanged: (v) => setState(() => _intensity = v),
                        onChangeEnd: _setIntensity,
                      ),
                    ),
                    Text(
                      '$intensityPct%',
                      style: const TextStyle(
                        color: Colors.white70,
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// =============================================================================
// SELECTOR DE MOTOR DE REALCE — spec gtcrn-dual-channel (tareas 5.1–5.3)
// =============================================================================

/// Hive key para persistir el motor de realce seleccionado (índice nativo).
///
/// Reemplaza a la vieja key binaria `beamformingEnabled`. Guarda el
/// [EnhancementEngineMode.nativeValue] (0=Bypass, 1=DualChannelDnn,
/// 2=MvdrBackup).
const String _kEnhancementEngineModeKey = 'enhancementEngineMode';

/// Hive key para persistir el tamaño de bloque / latencia del DNN (EXTRA).
const String _kDnnBlockSizeKey = 'dnnBlockSize';

/// Tamaño de bloque DNN por defecto óptimo (muestras por canal @ 16 kHz).
///
/// 160 muestras = 10 ms de hop, coherente con el pipeline GTCRN dual
/// (ver `dnn_denoiser` tarea 2). Es el valor recomendado; el slider
/// permite explorar el trade-off latencia/estabilidad.
const int _kDnnBlockSizeDefault = 160;
const int _kDnnBlockSizeMin = 80;
const int _kDnnBlockSizeMax = 480;

/// Selector de 3 opciones del motor de realce de voz (Dual-DNN / MVDR /
/// Bypass) que reemplaza al viejo toggle binario de beamforming.
///
/// - **5.1**: `SegmentedButton` de 3 opciones en la pantalla técnico. Al
///   seleccionar, llama a `AudioBridgeImpl().setEnhancementEngineMode(mode)`
///   y persiste el índice en Hive. El estado inicial se carga con
///   `getEnhancementEngineMode()` (con fallback a Hive si el motor está idle).
/// - **5.3**: indicador visual del estado real, consultando
///   `getDnnIsActive()` / `getBeamformingActive()` para distinguir "activo"
///   de "en bypass por fallo".
/// - **EXTRA**: slider de ajuste fino de latencia / tamaño de bloque, con
///   default óptimo, cableado a `setDnnBlockSize` (el backend lo implementa
///   en la tarea 7; hoy es no-op tolerante a MissingPluginException).
class _EnhancementEngineSelectorCard extends StatefulWidget {
  const _EnhancementEngineSelectorCard();

  @override
  State<_EnhancementEngineSelectorCard> createState() =>
      _EnhancementEngineSelectorCardState();
}

class _EnhancementEngineSelectorCardState
    extends State<_EnhancementEngineSelectorCard> {
  EnhancementEngineMode _mode = EnhancementEngineMode.bypass;
  bool _loaded = false;

  /// Estado real reportado por el motor nativo (5.3).
  bool _dnnActive = false;
  bool _beamformingActive = false;

  /// Tamaño de bloque actual (EXTRA slider).
  double _blockSize = _kDnnBlockSizeDefault.toDouble();

  Timer? _statusTimer;

  @override
  void initState() {
    super.initState();
    _loadInitialState();
    // Refresca el indicador de estado real periódicamente mientras la
    // tarjeta está visible.
    _statusTimer = Timer.periodic(
      const Duration(seconds: 2),
      (_) => _refreshRealStatus(),
    );
  }

  @override
  void dispose() {
    _statusTimer?.cancel();
    super.dispose();
  }

  Future<void> _loadInitialState() async {
    final bridge = AudioBridgeImpl();

    // 1) Motor seleccionado: preferir el estado nativo; si el motor está
    //    idle (retorna Bypass), caer al valor persistido en Hive.
    EnhancementEngineMode mode = EnhancementEngineMode.bypass;
    try {
      mode = await bridge.getEnhancementEngineMode();
    } catch (_) {/* fail-safe: bypass */}

    int? persisted;
    double blockSize = _kDnnBlockSizeDefault.toDouble();
    try {
      final box = await Hive.openBox<dynamic>('settings_box');
      final v = box.get(_kEnhancementEngineModeKey);
      if (v is int) persisted = v;
      final bs = box.get(_kDnnBlockSizeKey);
      if (bs is int) {
        blockSize = bs.toDouble().clamp(
              _kDnnBlockSizeMin.toDouble(),
              _kDnnBlockSizeMax.toDouble(),
            );
      }
    } catch (_) {/* best effort */}

    if (mode == EnhancementEngineMode.bypass && persisted != null) {
      mode = EnhancementEngineMode.fromNative(persisted);
    }

    if (mounted) {
      setState(() {
        _mode = mode;
        _blockSize = blockSize;
        _loaded = true;
      });
    }
    await _refreshRealStatus();
  }

  Future<void> _refreshRealStatus() async {
    final bridge = AudioBridgeImpl();
    bool dnn = false;
    bool bf = false;
    try {
      dnn = await bridge.getDnnIsActive();
    } catch (_) {/* tolera handler ausente */}
    try {
      bf = await bridge.getBeamformingActive();
    } catch (_) {/* tolera handler ausente */}
    if (mounted) {
      setState(() {
        _dnnActive = dnn;
        _beamformingActive = bf;
      });
    }
  }

  Future<void> _onModeSelected(EnhancementEngineMode mode) async {
    setState(() => _mode = mode);

    // Persistir el índice nativo en Hive.
    try {
      final box = await Hive.openBox<dynamic>('settings_box');
      await box.put(_kEnhancementEngineModeKey, mode.nativeValue);
    } catch (_) {/* best effort */}

    // Comunicar al motor nativo.
    try {
      await AudioBridgeImpl().setEnhancementEngineMode(mode);
    } catch (_) {/* tolera MissingPluginException si el motor no está activo */}

    // Refrescar el indicador de estado real tras el cambio.
    await _refreshRealStatus();
  }

  Future<void> _onBlockSizeChanged(double value) async {
    setState(() => _blockSize = value);
  }

  Future<void> _onBlockSizeCommitted(double value) async {
    final blockSize = value.round();
    try {
      final box = await Hive.openBox<dynamic>('settings_box');
      await box.put(_kDnnBlockSizeKey, blockSize);
    } catch (_) {/* best effort */}
    try {
      await AudioBridgeImpl().setDnnBlockSize(blockSize);
    } catch (_) {/* backend lo implementa en tarea 7 (no-op por ahora) */}
  }

  @override
  Widget build(BuildContext context) {
    if (!_loaded) return const SizedBox.shrink();

    return Card(
      color: const Color(0xFF16213e),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Encabezado
            Row(
              children: [
                Icon(
                  Icons.spatial_audio,
                  color: _mode == EnhancementEngineMode.bypass
                      ? Colors.white60
                      : Colors.cyanAccent,
                  size: 24,
                ),
                const SizedBox(width: 12),
                const Expanded(
                  child: Text(
                    'Motor de realce de voz',
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 4),
            const Text(
              'Elegí el algoritmo que procesa la voz frente al ruido',
              style: TextStyle(color: Colors.white60, fontSize: 11),
            ),
            const SizedBox(height: 12),

            // 5.1 — Selector de 3 opciones
            _buildModeSelector(),
            const SizedBox(height: 12),

            // 5.3 — Indicador de estado real
            _buildRealStatusIndicator(),
            const SizedBox(height: 16),

            // EXTRA — Slider de ajuste fino de latencia / tamaño de bloque
            _buildBlockSizeSlider(),
          ],
        ),
      ),
    );
  }

  Widget _buildModeSelector() {
    return SizedBox(
      width: double.infinity,
      child: SegmentedButton<EnhancementEngineMode>(
        segments: const <ButtonSegment<EnhancementEngineMode>>[
          ButtonSegment<EnhancementEngineMode>(
            value: EnhancementEngineMode.dualChannelDnn,
            label: Text('Dual-DNN', style: TextStyle(fontSize: 11)),
            icon: Icon(Icons.auto_awesome, size: 16),
            tooltip: 'Realce DNN dual-channel (recomendado)',
          ),
          ButtonSegment<EnhancementEngineMode>(
            value: EnhancementEngineMode.mvdrBackup,
            label: Text('MVDR', style: TextStyle(fontSize: 11)),
            icon: Icon(Icons.hearing, size: 16),
            tooltip: 'Beamformer MVDR clásico (respaldo)',
          ),
          ButtonSegment<EnhancementEngineMode>(
            value: EnhancementEngineMode.bypass,
            label: Text('Bypass', style: TextStyle(fontSize: 11)),
            icon: Icon(Icons.block, size: 16),
            tooltip: 'Sin realce',
          ),
        ],
        selected: <EnhancementEngineMode>{_mode},
        onSelectionChanged: (selection) {
          if (selection.isNotEmpty) _onModeSelected(selection.first);
        },
        showSelectedIcon: false,
        style: ButtonStyle(
          visualDensity: VisualDensity.compact,
          foregroundColor: MaterialStateProperty.resolveWith<Color>((states) {
            if (states.contains(MaterialState.selected)) {
              return const Color(0xFF16213e);
            }
            return Colors.white70;
          }),
          backgroundColor: MaterialStateProperty.resolveWith<Color>((states) {
            if (states.contains(MaterialState.selected)) {
              return Colors.cyanAccent;
            }
            return Colors.transparent;
          }),
        ),
      ),
    );
  }

  /// Etiqueta descriptiva del modo seleccionado + estado real (5.3).
  Widget _buildRealStatusIndicator() {
    // Determina si el motor seleccionado está realmente activo en nativo
    // o si cayó a bypass por fallo (p. ej. `.pt` inválido).
    final bool degraded;
    final String statusText;
    final Color statusColor;
    final IconData statusIcon;

    switch (_mode) {
      case EnhancementEngineMode.dualChannelDnn:
        degraded = !_dnnActive;
        if (_dnnActive) {
          statusText = 'Dual-DNN activo y procesando';
          statusColor = Colors.greenAccent;
          statusIcon = Icons.check_circle;
        } else {
          statusText = 'Seleccionado Dual-DNN, pero en bypass '
              '(motor inactivo o modelo no cargado)';
          statusColor = Colors.orangeAccent;
          statusIcon = Icons.warning_amber_rounded;
        }
        break;
      case EnhancementEngineMode.mvdrBackup:
        degraded = !_beamformingActive;
        if (_beamformingActive) {
          statusText = 'MVDR activo (captura estéreo 2-mic)';
          statusColor = Colors.greenAccent;
          statusIcon = Icons.check_circle;
        } else {
          statusText = 'Seleccionado MVDR, pero en bypass '
              '(motor inactivo o sin captura estéreo)';
          statusColor = Colors.orangeAccent;
          statusIcon = Icons.warning_amber_rounded;
        }
        break;
      case EnhancementEngineMode.bypass:
        degraded = false;
        statusText = 'Sin realce (passthrough)';
        statusColor = Colors.white60;
        statusIcon = Icons.info_outline;
        break;
    }

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: degraded
            ? Colors.orange.withOpacity(0.12)
            : Colors.white.withOpacity(0.04),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        children: [
          Icon(statusIcon, color: statusColor, size: 16),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              statusText,
              style: TextStyle(color: statusColor, fontSize: 11),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildBlockSizeSlider() {
    final int blockSamples = _blockSize.round();
    // 16 kHz → ms = muestras / 16
    final double latencyMs = blockSamples / 16.0;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            const Icon(Icons.tune, color: Colors.white60, size: 16),
            const SizedBox(width: 8),
            const Expanded(
              child: Text(
                'Ajuste fino de latencia (tamaño de bloque)',
                style: TextStyle(
                  color: Colors.white70,
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            Text(
              '$blockSamples muestras · ${latencyMs.toStringAsFixed(1)} ms',
              style: const TextStyle(color: Colors.cyanAccent, fontSize: 11),
            ),
          ],
        ),
        Slider(
          value: _blockSize,
          min: _kDnnBlockSizeMin.toDouble(),
          max: _kDnnBlockSizeMax.toDouble(),
          divisions: (_kDnnBlockSizeMax - _kDnnBlockSizeMin) ~/ 10,
          label: '$blockSamples',
          activeColor: Colors.cyanAccent,
          inactiveColor: Colors.white24,
          onChanged: _onBlockSizeChanged,
          onChangeEnd: _onBlockSizeCommitted,
        ),
        const Text(
          'Default óptimo: 160 muestras (10 ms). El backend aplicará este '
          'ajuste en la tarea 7; por ahora se persiste localmente.',
          style: TextStyle(color: Colors.white38, fontSize: 10),
        ),
      ],
    );
  }
}
