import 'package:flutter/services.dart';

/// Bridge Dart → Kotlin para el plugin nativo de volumen del sistema
/// usado durante la calibración biológica.
///
/// Expone los tres métodos del plugin Android
/// (`BiologicalCalibrationVolumePlugin`) a través del [MethodChannel]
/// `biological_calibration/volume`:
///
/// - [setMaxVolume]  → fija `STREAM_MUSIC` al volumen máximo del dispositivo.
/// - [getCurrentVolume] → devuelve el volumen actual del stream de música.
/// - [getMaxVolume] → devuelve el volumen máximo soportado.
///
/// Los valores devueltos son enteros: el sistema Android usa "pasos" de
/// volumen (típicamente 0..15). La interpretación absoluta no es relevante
/// para la calibración: lo importante es que `current == max` durante toda
/// la sesión.
///
/// Esta clase no aplica lógica de negocio. La verificación post-condición
/// (¿quedó realmente al máximo?) la realiza [SystemVolumeController].
class VolumeMethodChannel {
  /// Nombre del canal compartido con `BiologicalCalibrationVolumePlugin`.
  static const String channelName = 'biological_calibration/volume';

  final MethodChannel _channel;

  /// Crea un nuevo canal usando el [MethodChannel] por defecto.
  VolumeMethodChannel() : _channel = const MethodChannel(channelName);

  /// Constructor para inyectar un [MethodChannel] alternativo en tests.
  VolumeMethodChannel.withChannel(this._channel);

  /// Fija `STREAM_MUSIC` al volumen máximo del dispositivo.
  ///
  /// No retorna el valor aplicado — usar [getCurrentVolume] / [getMaxVolume]
  /// para verificar la post-condición.
  ///
  /// Lanza [PlatformException] si el sistema rechaza el cambio
  /// (por ejemplo en dispositivos con DND activo o restricciones MDM).
  Future<void> setMaxVolume() async {
    await _channel.invokeMethod<int>('setMaxVolume');
  }

  /// Devuelve el volumen actual de `STREAM_MUSIC` como entero
  /// en el rango `[0, getMaxVolume()]`.
  ///
  /// Lanza [PlatformException] si el plugin no está registrado o
  /// si la plataforma no es Android.
  Future<int> getCurrentVolume() async {
    final result = await _channel.invokeMethod<int>('getCurrentVolume');
    if (result == null) {
      throw PlatformException(
        code: 'VOLUME_NULL',
        message: 'El plugin nativo devolvió null al consultar el volumen actual.',
      );
    }
    return result;
  }

  /// Devuelve el volumen máximo soportado por `STREAM_MUSIC` como entero.
  ///
  /// Lanza [PlatformException] si el plugin no está registrado o
  /// si la plataforma no es Android.
  Future<int> getMaxVolume() async {
    final result = await _channel.invokeMethod<int>('getMaxVolume');
    if (result == null) {
      throw PlatformException(
        code: 'VOLUME_NULL',
        message: 'El plugin nativo devolvió null al consultar el volumen máximo.',
      );
    }
    return result;
  }
}
