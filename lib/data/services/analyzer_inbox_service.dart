/// Servicio que acumula WAV paths generados por el diagnóstico
/// para que la ventana Analizador los tenga disponibles.
///
/// Patrón singleton: sobrevive al cierre de pantallas.
/// El diagnóstico agrega WAVs con [addWav].
/// El Analizador los consume con [pendingWavs].

import 'dart:async';

class AnalyzerInboxService {
  AnalyzerInboxService._();
  static final AnalyzerInboxService instance = AnalyzerInboxService._();

  final List<String> _wavPaths = [];
  final StreamController<void> _changeController =
      StreamController<void>.broadcast();

  Stream<void> get onChange => _changeController.stream;
  List<String> get pendingWavs => List.unmodifiable(_wavPaths);
  int get count => _wavPaths.length;

  /// Agrega un WAV al inbox (llamado por el diagnóstico al exportar).
  void addWav(String path) {
    _wavPaths.add(path);
    _changeController.add(null);
  }

  /// Remueve un WAV del inbox (llamado por el Analizador al procesarlo).
  void removeWav(String path) {
    _wavPaths.remove(path);
    _changeController.add(null);
  }

  /// Limpia todo el inbox.
  void clear() {
    _wavPaths.clear();
    _changeController.add(null);
  }
}
