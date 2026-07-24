import 'package:flutter/material.dart';
import '../../services/denoiser_service.dart';

/// Widget con radio buttons exclusivos para seleccionar el motor de denoising.
class DenoiserToggle extends StatefulWidget {
  final DenoiserService service;
  const DenoiserToggle({super.key, required this.service});

  @override
  State<DenoiserToggle> createState() => _DenoiserToggleState();
}

class _DenoiserToggleState extends State<DenoiserToggle> {
  @override
  void initState() {
    super.initState();
    widget.service.refreshActive().then((_) => setState(() {}));
  }

  @override
  Widget build(BuildContext context) {
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
              groupValue: widget.service.selected,
              onChanged: (v) async {
                await widget.service.selectDenoiser(v!);
                setState(() {});
              },
              secondary: widget.service.active == type
                  ? const Icon(Icons.check_circle, color: Colors.green)
                  : null,
            )),
        if (widget.service.isFallback)
          Padding(
            padding: const EdgeInsets.only(top: 8, left: 16),
            child: Text(
              'Fallback activo: ${_label(widget.service.active)} '
              '(${_label(widget.service.selected)} no disponible)',
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
        DenoiserType.rnnoise => 'Bajo consumo, siempre disponible',
        DenoiserType.dfn3 => 'Máxima calidad (requiere libdfn3.so)',
        DenoiserType.gtcrn => 'Modulación VAD, soporte dual-mic',
        DenoiserType.dpdfnet => 'SOTA 2025, Vorbis window, Apache 2.0',
      };
}
