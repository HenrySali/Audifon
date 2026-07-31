import 'package:flutter/material.dart';
import '../../services/denoiser_service.dart';

/// Widget con radio buttons exclusivos para seleccionar el motor de denoising.
///
/// Muestra exactamente 3 opciones visibles al usuario:
///   - Estándar (RNNoise)
///   - Ultra (DPDFNet-4)
///   - Inteligente (DPDFNet-2 48k)
///
/// Las opciones DFN3 y GTCRN están retiradas y NO se muestran en la UI.
class DenoiserToggle extends StatefulWidget {
  final DenoiserService service;
  const DenoiserToggle({super.key, required this.service});

  @override
  State<DenoiserToggle> createState() => _DenoiserToggleState();
}

class _DenoiserToggleState extends State<DenoiserToggle> {
  /// Los 3 motores visibles en la UI (DFN3 y GTCRN están retirados/ocultos).
  static const _visibleTypes = [
    DenoiserType.rnnoise,
    DenoiserType.dpdfnet,
    DenoiserType.dpdfnet2,
  ];

  @override
  void initState() {
    super.initState();
    widget.service.addListener(_onServiceChanged);
    widget.service.refreshActive().then((_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    widget.service.removeListener(_onServiceChanged);
    super.dispose();
  }

  void _onServiceChanged() {
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Motor de reducción de ruido',
            style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 8),
        ..._visibleTypes.map((type) => RadioListTile<DenoiserType>(
              title: Text(_label(type)),
              subtitle: Text(_subtitle(type)),
              value: type,
              groupValue: widget.service.selected,
              onChanged: (v) async {
                await widget.service.selectDenoiser(v!);
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
        DenoiserType.dpdfnet2 => 'Inteligente (DPDFNet-2 48k)',
      };

  String _subtitle(DenoiserType t) => switch (t) {
        DenoiserType.rnnoise => 'Bajo consumo, siempre disponible',
        DenoiserType.dfn3 => 'Máxima calidad (retirado)',
        DenoiserType.gtcrn => 'Modulación VAD (retirado)',
        DenoiserType.dpdfnet => 'SOTA 2025, Deep Filtering causal',
        DenoiserType.dpdfnet2 => '48 kHz nativo, 20 ms latencia, sin artefactos',
      };
}
