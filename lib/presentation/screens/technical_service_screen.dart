import 'package:flutter/material.dart';
import 'diagnostic/calibration_step.dart';

/// Pantalla de Servicio Técnico — herramientas para técnicos/audiólogos.
///
/// Contiene utilidades técnicas que NO son parte del diagnóstico médico
/// del paciente, como:
/// - Calibración del micrófono y auriculares
/// - (Futuro) Test de loopback, verificación de hardware, etc.
///
/// Acceso: desde el menú principal (icono de servicio).
class TechnicalServiceScreen extends StatelessWidget {
  const TechnicalServiceScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF1a1a2e),
      appBar: AppBar(
        backgroundColor: const Color(0xFF0f3460),
        title: const Text(
          'Servicio Técnico',
          style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
        ),
        iconTheme: const IconThemeData(color: Colors.white),
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          // Header descriptivo
          Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: const Color(0xFF16213e),
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: Colors.cyan.withOpacity(0.3)),
            ),
            child: const Row(
              children: [
                Icon(Icons.build_circle, color: Color(0xFF00e5ff), size: 28),
                SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Herramientas Técnicas',
                        style: TextStyle(
                          color: Color(0xFF00e5ff),
                          fontSize: 14,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      SizedBox(height: 4),
                      Text(
                        'Utilidades para audiólogos y técnicos. No son parte del diagnóstico médico del paciente.',
                        style: TextStyle(
                          color: Colors.white70,
                          fontSize: 11,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),

          // Tarjeta: Calibración
          _ServiceCard(
            icon: Icons.tune,
            iconColor: Colors.cyan,
            title: 'Calibración de Hardware',
            description:
                'Calibra el micrófono y los auriculares para mediciones precisas. '
                'Usar en cada nuevo dispositivo o cambio de auriculares.',
            buttonText: 'Iniciar Calibración',
            onTap: () => _openCalibration(context),
          ),
          const SizedBox(height: 12),

          // Tarjeta: Información del Sistema
          _ServiceCard(
            icon: Icons.info_outline,
            iconColor: Colors.blue,
            title: 'Información del Sistema',
            description:
                'Versión, dispositivo, configuración del DSP y estado de los componentes.',
            buttonText: 'Ver Info',
            onTap: () => _showSystemInfo(context),
          ),
        ],
      ),
    );
  }

  void _openCalibration(BuildContext context) {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => Scaffold(
          backgroundColor: const Color(0xFF1a1a2e),
          appBar: AppBar(
            backgroundColor: const Color(0xFF0f3460),
            title: const Text('Calibración'),
            iconTheme: const IconThemeData(color: Colors.white),
          ),
          body: CalibrationStep(
            onComplete: () => Navigator.of(context).pop(),
            onBack: () => Navigator.of(context).pop(),
          ),
        ),
      ),
    );
  }

  void _showSystemInfo(BuildContext context) {
    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: const Color(0xFF16213e),
        title: const Text(
          'Información del Sistema',
          style: TextStyle(color: Color(0xFF00e5ff)),
        ),
        content: const Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _InfoRow(label: 'Versión', value: '1.0.0'),
            _InfoRow(label: 'DSP', value: 'PSK Pipeline v2'),
            _InfoRow(label: 'Sample Rate', value: '16 kHz'),
            _InfoRow(label: 'Buffer', value: '64 samples'),
            _InfoRow(label: 'Latencia', value: '~10 ms'),
            _InfoRow(label: 'TNR', value: 'Habilitado'),
            _InfoRow(label: 'Presets EQ', value: '10 disponibles'),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Cerrar', style: TextStyle(color: Color(0xFF00e5ff))),
          ),
        ],
      ),
    );
  }
}

class _ServiceCard extends StatelessWidget {
  final IconData icon;
  final Color iconColor;
  final String title;
  final String description;
  final String buttonText;
  final VoidCallback onTap;

  const _ServiceCard({
    required this.icon,
    required this.iconColor,
    required this.title,
    required this.description,
    required this.buttonText,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: const Color(0xFF16213e),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon, color: iconColor, size: 22),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  title,
                  style: TextStyle(
                    color: iconColor,
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            description,
            style: const TextStyle(color: Colors.white70, fontSize: 12),
          ),
          const SizedBox(height: 12),
          Align(
            alignment: Alignment.centerRight,
            child: ElevatedButton(
              onPressed: onTap,
              style: ElevatedButton.styleFrom(
                backgroundColor: iconColor.withOpacity(0.15),
                foregroundColor: iconColor,
                side: BorderSide(color: iconColor.withOpacity(0.4)),
                padding:
                    const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              ),
              child: Text(buttonText),
            ),
          ),
        ],
      ),
    );
  }
}

class _InfoRow extends StatelessWidget {
  final String label;
  final String value;
  const _InfoRow({required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        children: [
          SizedBox(
            width: 100,
            child: Text(label,
                style: const TextStyle(color: Colors.white54, fontSize: 12)),
          ),
          Expanded(
            child: Text(value,
                style: const TextStyle(color: Colors.white, fontSize: 12)),
          ),
        ],
      ),
    );
  }
}
