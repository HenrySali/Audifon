import 'dart:async';

import 'package:flutter/material.dart';
import '../../services/denoiser_service.dart';

/// Widget con radio buttons exclusivos para seleccionar el motor de denoising.
///
/// Coherencia visual (fix): antes se mostraban 3 indicadores para 3 estados
/// distintos (radio azul = seleccionado, check verde = activo, banner naranja
/// = fallback). Cuando la selección del usuario no estaba disponible los tres
/// se contradecían visualmente. Ahora hay UNA sola fuente de verdad:
///
///   - **Radio azul** = lo que suena AHORA (motor activo real).
///   - **Banner naranja** (opcional) = "querías X pero cayó a Y por fallback",
///     sin ningún indicador redundante en el otro motor.
///
/// Adicionalmente, se hace polling suave del estado activo cada 1 s para
/// detectar cambios dinámicos (p.ej. si un motor primario se recupera tras
/// arranque tardío, el radio se sincroniza solo).
class DenoiserToggle extends StatefulWidget {
  final DenoiserService service;
  const DenoiserToggle({super.key, required this.service});

  @override
  State<DenoiserToggle> createState() => _DenoiserToggleState();
}

class _DenoiserToggleState extends State<DenoiserToggle> {
  Timer? _refreshTimer;

  @override
  void initState() {
    super.initState();
    // Refresh inicial + polling cada 1 s mientras el widget está montado.
    // Esto sincroniza la UI si el motor activo cambia detrás de escena
    // (p.ej. tras que un fallback se resuelve).
    widget.service.refreshActive().then((_) {
      if (mounted) setState(() {});
    });
    _refreshTimer = Timer.periodic(const Duration(seconds: 1), (_) async {
      await widget.service.refreshActive();
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _refreshTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // El groupValue del RadioListTile es el motor ACTIVO real (lo que suena),
    // NO la última elección del usuario. De esta forma no hay contradicción
    // visual entre el radio y ningún otro indicador.
    final DenoiserType activeGroup = widget.service.active;

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
              // Radio se marca en el motor ACTIVO (no en el que el usuario
              // "eligió" internamente). Cuando el usuario hace click, la
              // selección se envía al nativo y en el siguiente refresh
              // active reflejará el cambio (o el fallback si no está listo).
              groupValue: activeGroup,
              onChanged: (v) async {
                if (v == null) return;
                await widget.service.selectDenoiser(v);
                if (mounted) setState(() {});
              },
              // Sin `secondary` — antes había un Icon(check_circle) verde
              // que duplicaba la información del radio azul y generaba
              // contradicción cuando el fallback estaba activo.
            )),
        if (widget.service.isFallback)
          Padding(
            padding: const EdgeInsets.only(top: 8, left: 16, right: 16),
            child: Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: Colors.orange.withOpacity(0.12),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: Colors.orange.withOpacity(0.5)),
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(Icons.info_outline,
                      color: Colors.orange[700], size: 18),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      'Elegiste ${_label(widget.service.selected)} '
                      'pero no está disponible ahora mismo. '
                      'Suena ${_label(widget.service.active)} '
                      'como reemplazo automático.',
                      style: TextStyle(
                          color: Colors.orange[700], fontSize: 12),
                    ),
                  ),
                ],
              ),
            ),
          ),
      ],
    );
  }

  String _label(DenoiserType t) => switch (t) {
        DenoiserType.rnnoise => 'Estándar (RNNoise)',
        DenoiserType.dfn3 => 'Premium (DeepFilterNet3)',
        DenoiserType.gtcrn => 'Analítico (GTCRN)',
      };

  String _subtitle(DenoiserType t) => switch (t) {
        DenoiserType.rnnoise => 'Bajo consumo, siempre disponible',
        DenoiserType.dfn3 => 'Máxima calidad (requiere libdfn3.so)',
        DenoiserType.gtcrn => 'Modulación VAD, soporte dual-mic',
      };
}
