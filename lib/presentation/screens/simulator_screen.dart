import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

/// Pantalla que abre el simulador DSP web en el navegador externo (Chrome).
///
/// El simulador está hosteado en GitHub Pages con HTTPS, lo que permite
/// que Chrome habilite getUserMedia (micrófono) y AudioWorklet.
class SimulatorScreen extends StatelessWidget {
  const SimulatorScreen({super.key});

  static const _simulatorUrl =
      'https://henrysalinas1985-source.github.io/audifono/';

  @override
  Widget build(BuildContext context) {
    // Abrir Chrome inmediatamente y volver atrás
    _openSimulator(context);
    return Scaffold(
      appBar: AppBar(
        title: const Text('Configuración Avanzada'),
        backgroundColor: const Color(0xFF0f3460),
        foregroundColor: Colors.white,
      ),
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Icon(Icons.open_in_browser, size: 64, color: Colors.cyan),
              const SizedBox(height: 24),
              const Text(
                'Abriendo simulador en Chrome...',
                style: TextStyle(fontSize: 16, color: Colors.white70),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 16),
              const Text(
                'El simulador se abre en el navegador porque necesita acceso al micrófono con HTTPS.',
                style: TextStyle(fontSize: 13, color: Colors.white38),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 32),
              ElevatedButton.icon(
                onPressed: () => _openSimulator(context),
                icon: const Icon(Icons.refresh),
                label: const Text('Abrir de nuevo'),
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.cyan,
                  foregroundColor: Colors.white,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _openSimulator(BuildContext context) async {
    final uri = Uri.parse(_simulatorUrl);
    if (await canLaunchUrl(uri)) {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    }
  }
}
