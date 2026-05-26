import 'package:flutter/services.dart';

/// Resultado de la verificación de dispositivo antes de iniciar la amplificación.
///
/// Contiene el estado de auriculares y soporte de baja latencia.
class DeviceCheckResult {
  /// true si hay auriculares (BT o cable) conectados.
  final bool headphoneConnected;

  /// true si el dispositivo soporta FEATURE_AUDIO_LOW_LATENCY.
  final bool supportsLowLatency;

  const DeviceCheckResult({
    required this.headphoneConnected,
    required this.supportsLowLatency,
  });
}

/// Interfaz para verificar capacidades del dispositivo de audio.
///
/// Consulta el estado de auriculares y soporte de baja latencia
/// del dispositivo Android vía platform channel.
///
/// Requisitos: 3.5, 6.5
abstract class DeviceChecker {
  /// Verifica si hay auriculares (Bluetooth o con cable) conectados.
  ///
  /// Retorna true si hay al menos un dispositivo de salida de audio
  /// externo conectado (headset, headphones, BT A2DP).
  Future<bool> isHeadphoneConnected();

  /// Verifica si el dispositivo soporta audio de baja latencia.
  ///
  /// Consulta PackageManager.hasSystemFeature(FEATURE_AUDIO_LOW_LATENCY).
  /// Si retorna false, la latencia puede ser perceptible (> 20 ms).
  Future<bool> supportsLowLatency();

  /// Ejecuta ambas verificaciones y retorna el resultado combinado.
  Future<DeviceCheckResult> checkDevice();
}

/// Implementación de [DeviceChecker] usando MethodChannel de Flutter.
///
/// Se comunica con el lado nativo Android para consultar AudioManager
/// y PackageManager.
class DeviceCheckerImpl implements DeviceChecker {
  /// Canal de métodos para consultas de dispositivo.
  final MethodChannel _methodChannel;

  /// Crea una instancia con el canal de plataforma por defecto.
  DeviceCheckerImpl()
      : _methodChannel =
            const MethodChannel('com.psk.hearing_aid/device');

  /// Constructor para testing con canal inyectado.
  DeviceCheckerImpl.withChannel(this._methodChannel);

  @override
  Future<bool> isHeadphoneConnected() async {
    try {
      final result = await _methodChannel
          .invokeMethod<bool>('isHeadphoneConnected');
      return result ?? false;
    } on PlatformException {
      // Si falla la consulta, asumir que no hay auriculares
      return false;
    } on MissingPluginException {
      // Canal no implementado aún en nativo — asumir conectado para dev
      return true;
    }
  }

  @override
  Future<bool> supportsLowLatency() async {
    try {
      final result = await _methodChannel
          .invokeMethod<bool>('supportsLowLatency');
      return result ?? false;
    } on PlatformException {
      // Si falla la consulta, asumir que no soporta
      return false;
    } on MissingPluginException {
      // Canal no implementado aún en nativo — asumir soportado para dev
      return true;
    }
  }

  @override
  Future<DeviceCheckResult> checkDevice() async {
    final headphone = await isHeadphoneConnected();
    final lowLatency = await supportsLowLatency();
    return DeviceCheckResult(
      headphoneConnected: headphone,
      supportsLowLatency: lowLatency,
    );
  }
}
