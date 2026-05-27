import 'package:flutter/material.dart';
import 'package:webview_flutter/webview_flutter.dart';
import 'package:permission_handler/permission_handler.dart';

import '../../data/services/local_web_server.dart';

/// Pantalla de configuración avanzada que muestra el simulador DSP web.
///
/// Levanta un servidor HTTP local (localhost) que sirve los archivos del
/// simulador desde los assets de la app. El WebView se conecta a localhost,
/// lo que permite que Chrome habilite getUserMedia (micrófono) y AudioWorklet
/// sin necesidad de HTTPS ni internet.
class SimulatorScreen extends StatefulWidget {
  const SimulatorScreen({super.key});

  @override
  State<SimulatorScreen> createState() => _SimulatorScreenState();
}

class _SimulatorScreenState extends State<SimulatorScreen> {
  final LocalWebServer _server = LocalWebServer();
  WebViewController? _controller;
  bool _isLoading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _startServer();
  }

  Future<void> _startServer() async {
    try {
      // Pedir permiso de micrófono antes de cargar el WebView
      final micStatus = await Permission.microphone.request();
      if (!micStatus.isGranted) {
        setState(() {
          _error = 'Se necesita permiso de micrófono para el modo tiempo real.';
          _isLoading = false;
        });
        return;
      }

      // Iniciar servidor local
      await _server.start();

      // Crear WebView apuntando al servidor local
      _controller = WebViewController()
        ..setJavaScriptMode(JavaScriptMode.unrestricted)
        ..setNavigationDelegate(
          NavigationDelegate(
            onPageFinished: (_) {
              if (mounted) setState(() => _isLoading = false);
            },
            onWebResourceError: (error) {
              if (mounted) {
                setState(() {
                  _error = 'Error cargando simulador: ${error.description}';
                  _isLoading = false;
                });
              }
            },
          ),
        )
        // Permitir acceso al micrófono desde el WebView
        ..setOnPermissionRequest((request) {
          request.grant();
        })
        ..loadRequest(Uri.parse(_server.url!));

      if (mounted) setState(() {});
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = 'Error iniciando servidor: $e';
          _isLoading = false;
        });
      }
    }
  }

  @override
  void dispose() {
    _server.stop();
    super.dispose();
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
          if (_controller != null)
            IconButton(
              icon: const Icon(Icons.refresh),
              tooltip: 'Recargar',
              onPressed: () {
                _controller!.reload();
                setState(() => _isLoading = true);
              },
            ),
        ],
      ),
      body: _buildBody(),
    );
  }

  Widget _buildBody() {
    if (_error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Icon(Icons.error_outline, size: 48, color: Colors.red),
              const SizedBox(height: 16),
              Text(
                _error!,
                textAlign: TextAlign.center,
                style: const TextStyle(fontSize: 16),
              ),
              const SizedBox(height: 24),
              ElevatedButton(
                onPressed: () {
                  setState(() {
                    _error = null;
                    _isLoading = true;
                  });
                  _startServer();
                },
                child: const Text('Reintentar'),
              ),
            ],
          ),
        ),
      );
    }

    if (_controller == null) {
      return const Center(
        child: CircularProgressIndicator(color: Colors.cyan),
      );
    }

    return Stack(
      children: [
        WebViewWidget(controller: _controller!),
        if (_isLoading)
          const Center(
            child: CircularProgressIndicator(color: Colors.cyan),
          ),
      ],
    );
  }
}
