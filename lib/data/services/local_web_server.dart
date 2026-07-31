import 'dart:async';
import 'dart:io';
import 'package:flutter/services.dart';

/// Servidor HTTP local que sirve los archivos del simulador DSP desde los assets.
///
/// Corre en localhost en un puerto aleatorio. El WebView se conecta a este
/// servidor local, lo que permite que getUserMedia y AudioWorklet funcionen
/// (Chrome permite estas APIs en localhost sin HTTPS).
///
/// No requiere internet — todo es local en el dispositivo.
class LocalWebServer {
  HttpServer? _server;
  int? _port;

  /// Puerto en el que está corriendo el servidor.
  int? get port => _port;

  /// URL base del servidor (ej: http://localhost:8443)
  String? get url => _port != null ? 'http://localhost:$_port' : null;

  /// Inicia el servidor en un puerto disponible.
  Future<void> start() async {
    if (_server != null) return; // Ya está corriendo

    _server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    _port = _server!.port;

    _server!.listen(_handleRequest);
  }

  /// Detiene el servidor.
  Future<void> stop() async {
    await _server?.close(force: true);
    _server = null;
    _port = null;
  }

  /// Maneja cada request HTTP sirviendo archivos desde assets/simulator/
  Future<void> _handleRequest(HttpRequest request) async {
    var path = request.uri.path;
    if (path == '/') path = '/index.html';

    // Quitar el / inicial para formar la ruta del asset
    final assetPath = 'assets/simulator${path}';

    try {
      final data = await rootBundle.load(assetPath);
      final bytes = data.buffer.asUint8List();

      request.response.statusCode = 200;
      request.response.headers.set('Content-Type', _mimeType(path));
      // Permitir acceso al micrófono desde el WebView
      request.response.headers.set('Access-Control-Allow-Origin', '*');
      request.response.add(bytes);
    } catch (e) {
      request.response.statusCode = 404;
      request.response.write('Not found: $path');
    }

    await request.response.close();
  }

  /// Determina el Content-Type basado en la extensión del archivo.
  String _mimeType(String path) {
    if (path.endsWith('.html')) return 'text/html; charset=utf-8';
    if (path.endsWith('.js')) return 'application/javascript; charset=utf-8';
    if (path.endsWith('.css')) return 'text/css; charset=utf-8';
    if (path.endsWith('.json')) return 'application/json';
    if (path.endsWith('.wav')) return 'audio/wav';
    if (path.endsWith('.png')) return 'image/png';
    if (path.endsWith('.svg')) return 'image/svg+xml';
    return 'application/octet-stream';
  }
}
