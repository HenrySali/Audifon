import 'dart:typed_data';

import 'package:flutter/services.dart';

import '../../domain/entities/spectrum_snapshot.dart';

/// Bridge para comunicación con el SpectrumAnalyzer nativo (C++).
///
/// Usa el mismo MethodChannel que el audio bridge existente
/// ('com.psk.hearing_aid/audio') para enviar comandos de control
/// del analizador de espectro y recibir datos de snapshot.
///
/// Métodos disponibles:
/// - startAnalysis / stopAnalysis: activa/desactiva FFT en pipeline
/// - startRecording / stopRecording: graba snapshots (max 3 min)
/// - getRecordingData: obtiene todos los snapshots grabados como bytes
/// - getCurrentSpectrum: obtiene el snapshot actual (polling a 10 Hz)
class SpectrumBridge {
  /// Canal de métodos compartido con el audio bridge.
  static const MethodChannel _channel =
      MethodChannel('com.psk.hearing_aid/audio');

  /// Activa el análisis de espectro (FFT computation en cada bloque).
  ///
  /// Debe llamarse al abrir la pantalla del analizador.
  /// El análisis consume CPU adicional (~27 µs por bloque FFT).
  Future<void> startAnalysis() async {
    try {
      await _channel.invokeMethod<void>('startSpectrumAnalysis');
    } on PlatformException catch (_) {
      // Silently handle — engine may not be running
    }
  }

  /// Desactiva el análisis de espectro (ahorra CPU).
  ///
  /// Debe llamarse al cerrar la pantalla del analizador.
  Future<void> stopAnalysis() async {
    try {
      await _channel.invokeMethod<void>('stopSpectrumAnalysis');
    } on PlatformException catch (_) {
      // Silently handle
    }
  }

  /// Inicia grabación de snapshots (máximo 1800 = 3 minutos a 10 Hz).
  ///
  /// Limpia cualquier grabación previa y comienza a almacenar
  /// snapshots en el buffer nativo C++.
  Future<void> startRecording() async {
    try {
      await _channel.invokeMethod<void>('startSpectrumRecording');
    } on PlatformException catch (_) {
      // Silently handle
    }
  }

  /// Detiene la grabación y retorna el número de snapshots capturados.
  ///
  /// Retorna 0 si no había grabación activa o si ocurrió un error.
  Future<int> stopRecording() async {
    try {
      final count = await _channel.invokeMethod<int>('stopSpectrumRecording');
      return count ?? 0;
    } on PlatformException catch (_) {
      return 0;
    }
  }

  /// Obtiene todos los snapshots grabados como bytes crudos.
  ///
  /// Cada snapshot ocupa [SpectrumSnapshot.sizeInBytes] bytes (1136).
  /// El total de bytes = count * 1136.
  /// Retorna Uint8List vacío si no hay datos o si ocurrió un error.
  Future<Uint8List> getRecordingData() async {
    try {
      final bytes =
          await _channel.invokeMethod<Uint8List>('getRecordingData');
      return bytes ?? Uint8List(0);
    } on PlatformException catch (_) {
      return Uint8List(0);
    }
  }

  /// Obtiene el snapshot actual del espectro (para polling a 10 Hz).
  ///
  /// Retorna null si el engine no está activo, el analizador está
  /// desactivado, o si ocurrió un error de plataforma.
  Future<SpectrumSnapshot?> getCurrentSpectrum() async {
    try {
      final bytes =
          await _channel.invokeMethod<Uint8List>('getCurrentSpectrum');
      if (bytes == null || bytes.length < SpectrumSnapshot.sizeInBytes) {
        return null;
      }
      return SpectrumSnapshot.fromBytes(bytes, 0);
    } on PlatformException catch (_) {
      return null;
    }
  }
}
