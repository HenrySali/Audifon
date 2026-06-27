import 'package:flutter/material.dart';

import '../../domain/entities/eq_preset.dart';

/// Visualización compacta del ecualizador activo.
///
/// Muestra un gráfico de barras horizontal con las 12 ganancias por banda,
/// permitiendo al usuario ver en tiempo real cómo se está amplificando
/// cada frecuencia según el audiograma y el ambient activo.
///
/// Tap en el gráfico abre un bottom sheet con vista detallada.
///
/// **Propósito:**
/// - Mostrar que las ganancias NO son fijas — vienen del audiograma
/// - Demostrar que casos atípicos (otosclerosis, notch) se manejan correctamente
/// - Aumentar transparencia del sistema (el usuario VE qué está haciendo el audífono)
class ActiveEqVisualization extends StatelessWidget {
  /// Ganancias activas en las 12 bandas (dB).
  /// Orden: 250, 500, 750, 1000, 1500, 2000, 2500, 3000, 3500, 4000, 6000, 8000 Hz.
  final List<double> gains;

  /// Nombre del ambiente activo (ej: "Conversación").
  final String environmentName;

  /// Callback opcional al hacer tap — abre vista detallada.
  final VoidCallback? onTap;

  const ActiveEqVisualization({
    super.key,
    required this.gains,
    required this.environmentName,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    if (gains.length != 12) {
      // Fallback si las ganancias no están completas
      return const SizedBox.shrink();
    }

    final maxGain = gains.reduce((a, b) => a > b ? a : b).clamp(1.0, 50.0);

    return GestureDetector(
      onTap: onTap,
      child: Container(
        margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: const Color(0xFF1a2332),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: Colors.cyan.withOpacity(0.3)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Header con título y ambiente activo
            Row(
              children: [
                const Icon(Icons.equalizer, color: Colors.cyan, size: 18),
                const SizedBox(width: 8),
                const Text(
                  'Amplificación Activa',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const Spacer(),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                  decoration: BoxDecoration(
                    color: Colors.cyan.withOpacity(0.15),
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: Colors.cyan.withOpacity(0.4)),
                  ),
                  child: Text(
                    environmentName,
                    style: const TextStyle(
                      color: Colors.cyan,
                      fontSize: 10,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ),
              ],
            ),

            const SizedBox(height: 10),

            // Gráfico de barras (12 bandas)
            SizedBox(
              height: 74,
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: List.generate(12, (i) {
                  final g = gains[i];
                  final h = (g / maxGain * 49).clamp(2.0, 49.0);
                  final freq = EqPreset.bandFrequencies[i];
                  return Expanded(
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 1),
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.end,
                        children: [
                          // Valor de ganancia sobre la barra
                          if (g > 0.5)
                            Padding(
                              padding: const EdgeInsets.only(bottom: 2),
                              child: Text(
                                '${g.round()}',
                                style: const TextStyle(
                                  color: Colors.cyan,
                                  fontSize: 8,
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                            ),
                          // Barra de ganancia
                          Container(
                            height: h,
                            decoration: BoxDecoration(
                              gradient: LinearGradient(
                                begin: Alignment.bottomCenter,
                                end: Alignment.topCenter,
                                colors: [
                                  Colors.cyan.withOpacity(0.9),
                                  Colors.cyan.withOpacity(0.5),
                                ],
                              ),
                              borderRadius: BorderRadius.circular(2),
                            ),
                          ),
                          const SizedBox(height: 2),
                          // Etiqueta de frecuencia
                          Text(
                            _formatFreq(freq),
                            style: TextStyle(
                              color: Colors.grey[500],
                              fontSize: 7,
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

            // Footer con explicación y tap hint
            Row(
              children: [
                Expanded(
                  child: Text(
                    'Calculado desde tu audiograma con NAL-NL3',
                    style: TextStyle(
                      color: Colors.grey[500],
                      fontSize: 10,
                    ),
                  ),
                ),
                if (onTap != null)
                  Text(
                    'Tap para detalle',
                    style: TextStyle(
                      color: Colors.cyan[300],
                      fontSize: 9,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  /// Formatea la frecuencia para mostrar en el eje X.
  String _formatFreq(int freq) {
    if (freq >= 1000) {
      final kHz = freq / 1000;
      if (kHz == kHz.roundToDouble()) {
        return '${kHz.round()}k';
      }
      return '${kHz.toStringAsFixed(1)}k';
    }
    return '$freq';
  }
}

