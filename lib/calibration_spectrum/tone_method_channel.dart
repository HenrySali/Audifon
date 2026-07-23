/// @file tone_method_channel.dart
/// @brief Wrapper Dart sobre el MethodChannel de Calibration Spectrum.

import 'dart:typed_data';
import 'package:flutter/services.dart';

import 'tone_snapshot.dart';

/// Cliente del MethodChannel `com.psk.hearing_aid/audio` para los métodos
/// específicos del Calibration Spectrum Validator.
///
/// Reusa el canal existente para no abrir uno nuevo. Todos los métodos
/// del validador comparten ese canal (handlers nuevos en `AudioMethodChannel.kt`).
class ToneMethodChannel {
  static const MethodChannel _channel = MethodChannel('com.psk.hearing_aid/audio');

  const ToneMethodChannel();

  /// Configura el ToneAnalyzer nativo.
  /// @return true si configuró correctamente.
  Future<bool> configure({
    required int sampleRate,
    required int fftSize,
    required WindowType windowType,
    required int harmonicsCount,
    required double dbfsToDbsplOffset,
  }) async {
    final result = await _channel.invokeMethod<bool>('configureToneAnalyzer', {
      'sampleRate': sampleRate,
      'fftSize': fftSize,
      'windowType': windowType == WindowType.blackmanHarris ? 1 : 0,
      'harmonicsCount': harmonicsCount,
      'dbfsToDbsplOffset': dbfsToDbsplOffset,
    });
    return result ?? false;
  }

  /// Activa o desactiva el procesamiento del ToneAnalyzer.
  Future<void> setActive(bool active) async {
    await _channel.invokeMethod<void>('setToneAnalyzerActive', {'active': active});
  }

  /// Establece la frecuencia esperada del tono actual.
  Future<void> setExpectedFrequency(double freqHz) async {
    await _channel.invokeMethod<void>('setToneExpectedFrequency', {'freqHz': freqHz});
  }

  /// Establece el piso de ruido medido.
  Future<void> setNoiseFloor({required double amplitudeLin, required double dbfs}) async {
    await _channel.invokeMethod<void>('setToneNoiseFloor', {
      'amplitudeLin': amplitudeLin,
      'dbfs': dbfs,
    });
  }

  /// Resetea el ToneAnalyzer entre tonos.
  Future<void> reset() async {
    await _channel.invokeMethod<void>('resetToneAnalyzer');
  }

  /// Obtiene el último snapshot del ToneAnalyzer.
  Future<ToneSnapshot> getSnapshot() async {
    final bytes = await _channel.invokeMethod<Uint8List>('getToneSnapshot');
    if (bytes == null || bytes.isEmpty) return ToneSnapshot.empty();
    return ToneSnapshot.fromBytes(bytes);
  }
}
