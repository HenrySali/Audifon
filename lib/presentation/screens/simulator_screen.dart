import 'package:flutter/material.dart';
import 'package:webview_flutter/webview_flutter.dart';

/// Pantalla de configuración avanzada que muestra el simulador DSP web
/// embebido en un WebView. Permite ajustar audiograma, EQ, WDRC, calibración
/// y probar el modo tiempo real desde la misma app.
///
/// Los archivos del simulador se cargan desde los assets locales de la app
/// (no requiere internet ni servidor).
class SimulatorScreen extends StatefulWidget {
  const SimulatorScreen({super.key});

  @override
  State<SimulatorScreen> createState() => _SimulatorScreenState();
}

class _SimulatorScreenState extends State<SimulatorScreen> {
  late final WebViewController _controller;
  bool _isLoading = true;

  @override
  void initState() {
    super.initState();
    _controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setNavigationDelegate(
        NavigationDelegate(
          onPageFinished: (_) {
            setState(() => _isLoading = false);
          },
        ),
      )
      ..loadFlutterAsset('assets/simulator/index.html');
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Configuración Avanzada'),
        backgroundColor: const Color(0xFF0f3460),
        foregroundColor: Colors.white,
        elevation: 0,
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            tooltip: 'Recargar',
            onPressed: () {
              _controller.reload();
              setState(() => _isLoading = true);
            },
          ),
        ],
      ),
      body: Stack(
        children: [
          WebViewWidget(controller: _controller),
          if (_isLoading)
            const Center(
              child: CircularProgressIndicator(color: Colors.cyan),
            ),
        ],
      ),
    );
  }
}
