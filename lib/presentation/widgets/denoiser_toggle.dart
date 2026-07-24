import 'dart:async';

import 'package:flutter/material.dart';
import '../../services/denoiser_service.dart';

/// Widget con radio buttons exclusivos para seleccionar el motor de denoising.
///
/// El motor "activo" real lo resuelve el nativo (con fallback/bypass) y puede
/// tardar uno o más callbacks de audio en estabilizarse tras un cambio, así
/// que la UI lo repolea periódicamente en vez de leerlo una sola vez.
class DenoiserToggle extends StatefulWidget {
  final DenoiserService service;
  const DenoiserToggle({super.key, required this.service});

  @override
  State<DenoiserToggle> createState() => _DenoiserToggleState();
}

class _DenoiserToggleState extends State<DenoiserToggle> {
  Timer? _pollTimer;

  @override
  void initState() {
    super.initState();
    widget.service.refreshActive().then((_) {
      if (mounted) setState(() {});
    });
    // Repolea el motor activo real: el nativo lo actualiza en el audio thread
    // en un callback posterior al select(), así que un refresco único quedaba
    // desincronizado (mostraba estado viejo).
    _pollTimer = Timer.periodic(const Duration(milliseconds: 700), (_) async {
      await widget.service.refreshActive();
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _pollTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final service = widget.service;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Motor de reducción de ruido',
            style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 8),
        ...DenoiserType.values.map((type) => RadioListTile<DenoiserType>(
              title: Text(_label(type)),
              subtitle: Text(_subtitle(type)),
              value: type,
              groupValue: service.selected,
              onChanged: (v) async {
                await service.selectDenoiser(v!);
                if (mounted) setState(() {});
              },
              secondary: service.active == type
                  ? const Icon(Icons.check_circle, color: Colors.green)
                  : null,
            )),
        if (service.isBypassed)
          Padding(
            padding: const EdgeInsets.only(top: 8, left: 16),
            child: Text(
              'Sin limpieza de ruido: ningún motor disponible '
              '(${_label(service.selected)} no cargó en este dispositivo).',
              style: TextStyle(color: Colors.red[400], fontSize: 12),
            ),
          )
        else if (service.isFallback && service.active != null)
          Padding(
            padding: const EdgeInsets.only(top: 8, left: 16),
            child: Text(
              'Fallback activo: ${_label(service.active!)} '
              '(${_label(service.selected)} no disponible)',
              style: TextStyle(color: Colors.orange[700], fontSize: 12),
            ),
          ),
      ],
    );
  }

  String _label(DenoiserType t) => switch (t) {
        DenoiserType.rnnoise => 'Estándar (RNNoise)',
        DenoiserType.dfn3 => 'Premium (DeepFilterNet3)',
        DenoiserType.gtcrn => 'Analítico (GTCRN)',
        DenoiserType.dpdfnet => 'Ultra (DPDFNet-4)',
      };

  String _subtitle(DenoiserType t) => switch (t) {
        DenoiserType.rnnoise => 'Bajo consumo, baja latencia',
        DenoiserType.dfn3 => 'Máxima calidad (OnnxRuntime)',
        DenoiserType.gtcrn => 'Modulación VAD, soporte dual-mic',
        DenoiserType.dpdfnet => 'SOTA 2025, Vorbis window, Apache 2.0',
      };
}
