import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../platform/volume_method_channel.dart';

/// Controlador de alto nivel sobre [VolumeMethodChannel].
///
/// Se encarga de:
/// - Pedir al sistema que fije `STREAM_MUSIC` al máximo.
/// - Verificar la post-condición consultando el volumen actual y el máximo.
/// - Capturar [PlatformException] y traducirlas a un resultado booleano,
///   evitando que la pantalla de calibración tenga que conocer el detalle
///   del bridge nativo.
///
/// La calibración biológica requiere que el volumen quede al 100 % durante
/// toda la sesión. Si el usuario o un evento del sistema (llamada entrante,
/// notificación con ducking) cambia el volumen, los umbrales medidos en
/// dBFS dejan de corresponderse con dB HL — por eso es importante poder
/// re-verificar el estado en cualquier momento con [isAtMaxVolume].
class SystemVolumeController {
  final VolumeMethodChannel _channel;

  /// Crea un nuevo controlador usando el [VolumeMethodChannel] por defecto.
  SystemVolumeController() : _channel = VolumeMethodChannel();

  /// Constructor para inyectar un [VolumeMethodChannel] alternativo en tests.
  @visibleForTesting
  SystemVolumeController.withChannel(this._channel);

  /// Solicita al sistema fijar `STREAM_MUSIC` al máximo y verifica el
  /// resultado consultando el volumen actual y el máximo.
  ///
  /// Devuelve `true` si tras la operación `currentVolume == maxVolume`.
  /// Devuelve `false` si:
  /// - El plugin lanzó una [PlatformException] (típico en plataformas no
  ///   Android o con políticas que impiden modificar el volumen).
  /// - La verificación detecta que el sistema no aplicó el cambio
  ///   (por ejemplo DND, perfil de trabajo restringido, MDM).
  ///
  /// Nunca lanza: la UI puede traducir directamente el booleano a un
  /// indicador de chequeo en la fase de Setup.
  Future<bool> ensureMaxVolume() async {
    try {
      await _channel.setMaxVolume();
      return await isAtMaxVolume();
    } on PlatformException catch (e) {
      debugPrint(
        'SystemVolumeController.ensureMaxVolume: PlatformException '
        '(${e.code}) ${e.message}',
      );
      return false;
    } catch (e, st) {
      debugPrint('SystemVolumeController.ensureMaxVolume: error inesperado $e\n$st');
      return false;
    }
  }

  /// Devuelve `true` si el volumen actual de `STREAM_MUSIC` es exactamente
  /// igual al máximo del dispositivo.
  ///
  /// Permite que la pantalla de calibración monitoree el estado del
  /// volumen en cada cambio de fase y avise al usuario si bajó por
  /// cualquier motivo.
  ///
  /// Nunca lanza: ante cualquier error devuelve `false`.
  Future<bool> isAtMaxVolume() async {
    try {
      final current = await _channel.getCurrentVolume();
      final max = await _channel.getMaxVolume();
      return current == max && max > 0;
    } on PlatformException catch (e) {
      debugPrint(
        'SystemVolumeController.isAtMaxVolume: PlatformException '
        '(${e.code}) ${e.message}',
      );
      return false;
    } catch (e, st) {
      debugPrint('SystemVolumeController.isAtMaxVolume: error inesperado $e\n$st');
      return false;
    }
  }
}
