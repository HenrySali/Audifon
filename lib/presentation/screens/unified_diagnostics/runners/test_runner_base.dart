import 'package:flutter/services.dart';

/// Clase base con helpers compartidos para todos los runners de tests.
abstract class TestRunnerBase {
  static const MethodChannel channel =
      MethodChannel('com.psk.hearing_aid/audio');

  /// Referencia compartida al cancelled flag (manejado externamente).
  bool Function() isCancelled;

  TestRunnerBase({required this.isCancelled});

  /// Ejecuta el test y retorna los datos resultado.
  Future<Map<String, dynamic>> run();

  // ─── Helpers compartidos ────────────────────────────────────────────────

  /// Inicia grabación WAV para un test.
  /// Retorna la ruta COMPLETA REAL del archivo (devuelta por Kotlin) o null.
  Future<String?> startTestWav(String testId) async {
    final now = DateTime.now();
    final ts = '${now.year}${pad2(now.month)}${pad2(now.day)}'
        '_${pad2(now.hour)}${pad2(now.minute)}${pad2(now.second)}';
    final fileName = 'diag_${testId}_$ts.wav';
    try {
      // Kotlin ahora devuelve el fullPath real (String) o null si falla.
      final fullPath = await channel.invokeMethod<String>(
        'startDiagnosticRecording',
        {'filePath': fileName},
      );
      return fullPath; // null si no se pudo iniciar
    } catch (_) {
      return null;
    }
  }

  /// Inicia grabación y devuelve fullPath — versión estática para runners
  /// que manejan su propia grabación (self-recording).
  static Future<String?> startRecording(String relativeFileName) async {
    try {
      final fullPath = await channel.invokeMethod<String>(
        'startDiagnosticRecording',
        {'filePath': relativeFileName},
      );
      return fullPath;
    } catch (_) {
      return null;
    }
  }

  /// Detiene la grabación WAV en curso y CONSERVA el archivo.
  Future<int> stopTestWav() async {
    try {
      return await channel.invokeMethod<int>('stopDiagnosticRecordingKeep') ?? -1;
    } catch (_) {
      return -1;
    }
  }

  /// Padding de 2 dígitos.
  static String pad2(int n) => n.toString().padLeft(2, '0');

  /// Cuenta transiciones en una lista de enteros.
  static int countChanges(List<int> values) {
    int changes = 0;
    for (int i = 1; i < values.length; i++) {
      if (values[i] != values[i - 1]) changes++;
    }
    return changes;
  }

  /// Promedio de una lista de doubles.
  static double avg(List<double> l) =>
      l.isEmpty ? 0 : l.reduce((a, b) => a + b) / l.length;

  /// Mínimo de una lista de doubles.
  static double min(List<double> l) =>
      l.isEmpty ? 0 : l.reduce((a, b) => a < b ? a : b);

  /// Máximo de una lista de doubles.
  static double max(List<double> l) =>
      l.isEmpty ? 0 : l.reduce((a, b) => a > b ? a : b);
}
