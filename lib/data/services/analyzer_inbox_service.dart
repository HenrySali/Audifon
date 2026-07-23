/// Servicio que acumula WAV paths y reportes generados por el diagnóstico
/// para que la ventana Analizador los tenga disponibles.
///
/// Patrón singleton: sobrevive al cierre de pantallas.
/// El diagnóstico agrega WAVs con [addWav] y reportes con [setReport].
/// El Analizador los consume con [pendingWavs] y [lastReport].

import 'dart:async';

import '../../presentation/screens/unified_diagnostics/models/diagnostic_report.dart';

class AnalyzerInboxService {
  AnalyzerInboxService._();
  static final AnalyzerInboxService instance = AnalyzerInboxService._();

  final List<String> _wavPaths = [];
  DiagnosticReport? _lastReport;
  final StreamController<void> _changeController =
      StreamController<void>.broadcast();

  Stream<void> get onChange => _changeController.stream;
  List<String> get pendingWavs => List.unmodifiable(_wavPaths);
  int get count => _wavPaths.length;

  /// El último reporte de diagnóstico generado (null si no se ha ejecutado).
  DiagnosticReport? get lastReport => _lastReport;

  /// Indica si hay un reporte disponible.
  bool get hasReport => _lastReport != null;

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

  /// Establece el reporte de diagnóstico unificado.
  void setReport(DiagnosticReport report) {
    _lastReport = report;
    _changeController.add(null);
  }

  /// Limpia todo el inbox (WAVs + reporte).
  void clear() {
    _wavPaths.clear();
    _lastReport = null;
    _changeController.add(null);
  }
}
