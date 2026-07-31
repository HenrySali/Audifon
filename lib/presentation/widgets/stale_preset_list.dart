import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../domain/audiogram_driven_presets/custom_preset_record.dart';
import '../../domain/entities/audiogram.dart';
import '../../domain/entities/prescription_mode.dart';
import '../../domain/repositories/profile_repository.dart';
import '../bloc/amplification_bloc.dart';
import '../bloc/amplification_state.dart';
import 'stale_preset_indicator.dart';

/// Lista de presets personalizados obsoletos con acción de regeneración.
///
/// Carga los presets personalizados desde [ProfileRepository] y renderiza
/// un [StalePresetIndicator] por cada preset cuyo flag `stale == true`.
/// Cuando no hay presets obsoletos, el widget no muestra nada.
///
/// La regeneración se ejecuta directamente contra
/// [ProfileRepository.regenerateCustomPreset] usando el audiograma actual
/// del paciente (obtenido del [AmplificationBloc.audiogramRepository]).
///
/// El widget es reactivo: se reconstruye cuando `customPresetsStale`
/// cambia en el estado del bloc (por ejemplo, tras regenerar todos los
/// presets o tras un nuevo cambio de audiograma).
///
/// Requisitos: 9.4
class StalePresetList extends StatefulWidget {
  const StalePresetList({super.key});

  @override
  State<StalePresetList> createState() => _StalePresetListState();
}

class _StalePresetListState extends State<StalePresetList> {
  List<CustomPresetRecord> _stalePresets = [];
  final Set<String> _regenerating = {};
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _loadStalePresets();
  }

  Future<void> _loadStalePresets() async {
    final bloc = context.read<AmplificationBloc>();
    try {
      final presets = await bloc.profileRepository.getCustomPresets();
      if (!mounted) return;
      setState(() {
        _stalePresets = presets.where((p) => p.stale).toList();
        _loading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() => _loading = false);
    }
  }

  Future<void> _regeneratePreset(CustomPresetRecord preset) async {
    setState(() => _regenerating.add(preset.name));

    final bloc = context.read<AmplificationBloc>();
    try {
      final audiogram = await bloc.audiogramRepository.getAudiogram();
      if (!mounted) return;
      if (audiogram == null || audiogram == Audiogram.defaultAudiogram()) {
        _showError('No hay audiograma medido para regenerar.');
        setState(() => _regenerating.remove(preset.name));
        return;
      }

      // Use the current operating mode's prescription mode from the state.
      final state = bloc.state;
      final mode = state is AmplificationActive
          ? state.prescriptionMode
          : PrescriptionMode.quiet;

      await bloc.profileRepository.regenerateCustomPreset(
        preset.name,
        audiogram: audiogram,
        mode: mode,
      );

      if (!mounted) return;
      // Reload list after regeneration.
      setState(() => _regenerating.remove(preset.name));
      await _loadStalePresets();
    } catch (e) {
      if (!mounted) return;
      _showError('Error al regenerar "${preset.name}": $e');
      setState(() => _regenerating.remove(preset.name));
    }
  }

  void _showError(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: Colors.red.shade700,
        behavior: SnackBarBehavior.floating,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return BlocListener<AmplificationBloc, AmplificationState>(
      listenWhen: (previous, current) {
        if (current is! AmplificationActive) return false;
        if (previous is! AmplificationActive) return true;
        return previous.customPresetsStale != current.customPresetsStale;
      },
      listener: (context, state) {
        // Reload stale presets when the flag changes.
        _loadStalePresets();
      },
      child: _buildContent(),
    );
  }

  Widget _buildContent() {
    if (_loading) return const SizedBox.shrink();
    if (_stalePresets.isEmpty) return const SizedBox.shrink();

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          for (final preset in _stalePresets)
            StalePresetIndicator(
              key: ValueKey('stale_${preset.name}'),
              presetName: preset.name,
              isStale: true,
              isRegenerating: _regenerating.contains(preset.name),
              onRegenerate: _regenerating.contains(preset.name)
                  ? null
                  : () => _regeneratePreset(preset),
            ),
        ],
      ),
    );
  }
}
