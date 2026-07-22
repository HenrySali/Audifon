import 'package:permission_handler/permission_handler.dart';

import '../utils/device_checker.dart';

/// Servicio de permisos y verificaciones de dispositivo para la amplificación.
///
/// Encapsula toda la lógica de verificación previa al inicio:
/// - Permiso RECORD_AUDIO con explicación de justificación al denegar
/// - Verificación de auriculares conectados (BT o cable)
/// - Verificación de soporte de baja latencia (FEATURE_AUDIO_LOW_LATENCY)
/// - Validación combinada de todas las condiciones de inicio
///
/// Diseñado para ser inyectado en el [AmplificationBloc] o llamado
/// desde la UI antes de iniciar la amplificación.
///
/// El flujo completo de validación debe completarse rápidamente para
/// cumplir con el requisito de startup < 500 ms desde el toque del
/// botón hasta que el audio comienza a fluir (Req 5.2).
///
/// Requisitos: 1.4, 3.5, 6.4, 6.5
class PermissionService {
  final DeviceChecker _deviceChecker;

  /// Crea una instancia con el [DeviceChecker] proporcionado.
  ///
  /// El [DeviceChecker] se usa para consultar el estado de auriculares
  /// y soporte de baja latencia vía platform channel.
  PermissionService({required DeviceChecker deviceChecker})
      : _deviceChecker = deviceChecker;

  /// Solicita el permiso RECORD_AUDIO al usuario.
  ///
  /// Flujo:
  /// 1. Verifica si el permiso ya fue concedido → retorna true
  /// 2. Si fue denegado permanentemente → retorna false (usuario debe
  ///    ir a configuración manualmente)
  /// 3. Si fue denegado pero puede volver a pedir → solicita con
  ///    justificación implícita del sistema
  /// 4. Si es la primera vez → solicita normalmente
  ///
  /// Retorna `true` si el permiso fue concedido, `false` si fue denegado.
  ///
  /// La justificación (rationale) se muestra automáticamente por el sistema
  /// Android cuando el usuario denegó previamente. El mensaje explica que
  /// la app necesita el micrófono para capturar audio del entorno.
  ///
  /// Requisito: 6.4
  Future<bool> requestMicrophonePermission() async {
    // Verificar estado actual
    final status = await Permission.microphone.status;

    if (status.isGranted) {
      return true;
    }

    // Si fue denegado permanentemente, no podemos solicitar de nuevo
    if (status.isPermanentlyDenied) {
      return false;
    }

    // Solicitar el permiso — Android muestra rationale automáticamente
    // si el usuario denegó previamente
    final result = await Permission.microphone.request();
    return result.isGranted;
  }

  /// Verifica si hay auriculares (Bluetooth o con cable) conectados.
  ///
  /// Consulta el estado de dispositivos de salida de audio vía
  /// platform channel al AudioManager de Android.
  ///
  /// Retorna `true` si hay al menos un dispositivo de salida externo
  /// conectado (headset, headphones, BT A2DP), `false` si solo está
  /// disponible el parlante del teléfono.
  ///
  /// Se rechaza el inicio sin auriculares porque reproducir audio
  /// amplificado por el parlante causaría retroalimentación acústica.
  ///
  /// Requisito: 3.5
  Future<bool> checkHeadphonesConnected() async {
    return await _deviceChecker.isHeadphoneConnected();
  }

  /// Verifica si el dispositivo soporta FEATURE_AUDIO_LOW_LATENCY.
  ///
  /// Consulta PackageManager.hasSystemFeature(FEATURE_AUDIO_LOW_LATENCY)
  /// vía platform channel.
  ///
  /// Retorna `true` si el dispositivo soporta audio de baja latencia,
  /// `false` si no. Cuando retorna false, la amplificación aún funciona
  /// pero el usuario debe ser advertido de que puede experimentar
  /// latencia perceptible (> 20 ms).
  ///
  /// Requisito: 6.5
  Future<bool> checkLowLatencySupport() async {
    return await _deviceChecker.supportsLowLatency();
  }

  /// Valida todas las condiciones necesarias para iniciar la amplificación.
  ///
  /// Ejecuta las verificaciones en orden de prioridad:
  /// 1. Permiso RECORD_AUDIO (bloquea si no se concede)
  /// 2. Auriculares conectados (bloquea si no hay)
  /// 3. Soporte de baja latencia (solo advertencia, no bloquea)
  ///
  /// Retorna `null` si todas las condiciones se cumplen y se puede
  /// iniciar la amplificación. Retorna un `String` con el mensaje
  /// de error descriptivo si alguna condición crítica falla.
  ///
  /// Nota: La advertencia de baja latencia no bloquea el inicio.
  /// Si el dispositivo no soporta baja latencia pero las demás
  /// condiciones se cumplen, retorna null (OK) y el llamador puede
  /// verificar [checkLowLatencySupport] por separado para mostrar
  /// la advertencia al usuario.
  ///
  /// Este método está diseñado para ejecutarse rápidamente (< 200 ms)
  /// como parte del flujo de startup de 500 ms total.
  ///
  /// Requisitos: 1.4, 3.5, 6.4, 6.5
  Future<String?> validateStartConditions() async {
    // 1. Verificar permiso de micrófono
    final hasPermission = await requestMicrophonePermission();
    if (!hasPermission) {
      // Verificar si fue denegado permanentemente para dar mensaje apropiado
      final status = await Permission.microphone.status;
      if (status.isPermanentlyDenied) {
        return 'El permiso de micrófono fue denegado permanentemente. '
            'Por favor, habilítelo en la configuración de la aplicación '
            'para poder usar la amplificación de audio.';
      }
      return 'Se necesita acceso al micrófono para la amplificación. '
          'La aplicación captura el sonido del entorno a través del '
          'micrófono del teléfono y lo amplifica según su audiograma. '
          'Sin este permiso, la amplificación no puede funcionar.';
    }

    // 2. Verificar auriculares conectados
    final headphonesConnected = await checkHeadphonesConnected();
    if (!headphonesConnected) {
      return 'No se detectaron auriculares conectados. '
          'Conecte auriculares Bluetooth o con cable antes de activar '
          'la amplificación. Usar el parlante del teléfono causaría '
          'retroalimentación acústica (pitido).';
    }

    // 3. Verificar baja latencia (solo advertencia, no bloquea)
    // La advertencia se maneja por separado — validateStartConditions
    // solo retorna errores bloqueantes.

    // Todas las condiciones críticas se cumplen
    return null;
  }

  /// Retorna el mensaje de error para micrófono no disponible.
  ///
  /// Usado cuando el motor de audio nativo reporta que el micrófono
  /// está en uso por otra aplicación. En Android no hay API directa
  /// para verificar esto antes de intentar abrir AudioRecord, por lo
  /// que este error se genera cuando el intento de inicio falla.
  ///
  /// Requisito: 1.4
  static String microphoneUnavailableMessage() {
    return 'El micrófono está siendo utilizado por otra aplicación. '
        'Cierre la otra aplicación que esté usando el micrófono '
        '(llamada telefónica, grabadora de voz, etc.) e intente '
        'nuevamente.';
  }

  /// Retorna el mensaje de advertencia para dispositivos sin baja latencia.
  ///
  /// Usado por la UI para mostrar una advertencia no bloqueante cuando
  /// [checkLowLatencySupport] retorna false.
  ///
  /// Requisito: 6.5
  static String lowLatencyWarningMessage() {
    return 'Este dispositivo no soporta audio de baja latencia. '
        'La amplificación funcionará pero puede experimentar un '
        'retardo perceptible entre el sonido real y el amplificado.';
  }

  /// Abre la configuración de la aplicación para que el usuario
  /// pueda habilitar permisos manualmente.
  ///
  /// Usado cuando el permiso fue denegado permanentemente y el
  /// usuario necesita habilitarlo desde la configuración del sistema.
  Future<bool> openAppSettingsPage() async {
    return await openAppSettings();
  }
}
