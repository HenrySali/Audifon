import 'package:permission_handler/permission_handler.dart';

import 'device_checker.dart';

/// Resultado de las verificaciones previas al inicio de la amplificación.
///
/// Contiene el estado de cada verificación necesaria y mensajes de error
/// descriptivos para cada caso de fallo.
class StartupCheckResult {
  /// true si todas las verificaciones pasaron y se puede iniciar.
  final bool canStart;

  /// Mensaje de error descriptivo si [canStart] es false.
  /// null si todas las verificaciones pasaron.
  final String? errorMessage;

  /// true si el dispositivo no soporta baja latencia (advertencia, no bloquea).
  final bool lowLatencyWarning;

  /// Mensaje de advertencia sobre latencia si aplica.
  final String? warningMessage;

  const StartupCheckResult({
    required this.canStart,
    this.errorMessage,
    this.lowLatencyWarning = false,
    this.warningMessage,
  });

  /// Resultado exitoso sin advertencias.
  const StartupCheckResult.success()
      : canStart = true,
        errorMessage = null,
        lowLatencyWarning = false,
        warningMessage = null;

  /// Resultado exitoso con advertencia de latencia.
  const StartupCheckResult.successWithWarning(String warning)
      : canStart = true,
        errorMessage = null,
        lowLatencyWarning = true,
        warningMessage = warning;

  /// Resultado fallido con mensaje de error.
  const StartupCheckResult.failure(String error)
      : canStart = false,
        errorMessage = error,
        lowLatencyWarning = false,
        warningMessage = null;
}

/// Utilidad para manejar permisos y verificaciones de dispositivo
/// antes de iniciar la amplificación.
///
/// Ejecuta las siguientes verificaciones en orden:
/// 1. Permiso RECORD_AUDIO (con explicación si fue denegado previamente)
/// 2. Conexión de auriculares (rechaza si no hay dispositivo de salida)
/// 3. Soporte de baja latencia (advierte si no es soportado)
///
/// Esta utilidad es llamada por el [AmplificationBloc] antes de iniciar
/// el motor de audio.
///
/// El flujo completo debe completarse en < 500 ms desde el toque del
/// botón hasta que el audio comienza a fluir (Req 5.2).
///
/// Requisitos: 1.4, 3.5, 6.4, 6.5
class AudioPermissionHandler {
  final DeviceChecker _deviceChecker;

  /// Crea una instancia con el [DeviceChecker] proporcionado.
  AudioPermissionHandler({required DeviceChecker deviceChecker})
      : _deviceChecker = deviceChecker;

  /// Ejecuta todas las verificaciones previas al inicio de la amplificación.
  ///
  /// Retorna un [StartupCheckResult] indicando si se puede iniciar y
  /// cualquier advertencia o error.
  ///
  /// Orden de verificación:
  /// 1. Permiso RECORD_AUDIO
  /// 2. Auriculares conectados
  /// 3. Soporte de baja latencia (solo advertencia)
  ///
  /// Si alguna verificación crítica falla, retorna inmediatamente con
  /// el error correspondiente sin ejecutar las verificaciones restantes.
  Future<StartupCheckResult> performStartupChecks() async {
    // 1. Verificar permiso de micrófono
    final permissionResult = await requestMicrophonePermission();
    if (!permissionResult.canStart) {
      return permissionResult;
    }

    // 2. Verificar auriculares conectados
    final headphoneResult = await checkHeadphoneConnection();
    if (!headphoneResult.canStart) {
      return headphoneResult;
    }

    // 3. Verificar soporte de baja latencia (solo advertencia)
    final lowLatencyResult = await checkLowLatencySupport();

    // Si hay advertencia de latencia, retornar éxito con advertencia
    if (lowLatencyResult.lowLatencyWarning) {
      return lowLatencyResult;
    }

    return const StartupCheckResult.success();
  }

  /// Solicita el permiso RECORD_AUDIO.
  ///
  /// Si el permiso fue denegado previamente, muestra una explicación
  /// (rationale) antes de volver a solicitar.
  ///
  /// Retorna:
  /// - [StartupCheckResult.success] si el permiso fue concedido
  /// - [StartupCheckResult.failure] con mensaje descriptivo si fue denegado
  ///
  /// Requisito: 6.4
  Future<StartupCheckResult> requestMicrophonePermission() async {
    // Verificar estado actual del permiso
    final status = await Permission.microphone.status;

    if (status.isGranted) {
      return const StartupCheckResult.success();
    }

    // Si fue denegado permanentemente, dirigir a configuración
    if (status.isPermanentlyDenied) {
      return const StartupCheckResult.failure(
        'El permiso de micrófono fue denegado permanentemente. '
        'Por favor, habilítelo en la configuración de la aplicación '
        'para poder usar la amplificación de audio.',
      );
    }

    // Si necesita justificación (fue denegado antes pero no permanentemente)
    if (status.isDenied) {
      // En Android, shouldShowRequestRationale indica si debemos
      // mostrar explicación antes de pedir de nuevo.
      // El paquete permission_handler maneja esto internamente.
      // Solicitamos el permiso — el sistema mostrará el diálogo.
      final result = await Permission.microphone.request();

      if (result.isGranted) {
        return const StartupCheckResult.success();
      }

      if (result.isPermanentlyDenied) {
        return const StartupCheckResult.failure(
          'El permiso de micrófono fue denegado. '
          'La aplicación necesita acceso al micrófono para capturar '
          'el audio del entorno y amplificarlo. '
          'Puede habilitarlo en Configuración > Aplicaciones > '
          'Hearing Aid > Permisos.',
        );
      }

      // Denegado pero no permanentemente — puede volver a pedir
      return const StartupCheckResult.failure(
        'Se necesita acceso al micrófono para la amplificación. '
        'La aplicación captura el sonido del entorno a través del '
        'micrófono del teléfono y lo amplifica según su audiograma. '
        'Sin este permiso, la amplificación no puede funcionar.',
      );
    }

    // Estado restringido (iOS) o limitado — no aplica en Android típicamente
    if (status.isRestricted || status.isLimited) {
      return const StartupCheckResult.failure(
        'El acceso al micrófono está restringido en este dispositivo. '
        'Verifique las políticas de su dispositivo.',
      );
    }

    // Intentar solicitar si el estado es desconocido
    final result = await Permission.microphone.request();
    if (result.isGranted) {
      return const StartupCheckResult.success();
    }

    return const StartupCheckResult.failure(
      'No se pudo obtener el permiso de micrófono. '
      'La amplificación requiere acceso al micrófono del dispositivo.',
    );
  }

  /// Verifica si hay auriculares conectados (BT o cable).
  ///
  /// Rechaza el inicio si no hay dispositivo de salida de audio externo,
  /// ya que reproducir audio amplificado por el parlante del teléfono
  /// causaría retroalimentación acústica (feedback).
  ///
  /// Requisito: 3.5
  Future<StartupCheckResult> checkHeadphoneConnection() async {
    final connected = await _deviceChecker.isHeadphoneConnected();

    if (!connected) {
      return const StartupCheckResult.failure(
        'No se detectaron auriculares conectados. '
        'Conecte auriculares Bluetooth o con cable antes de activar '
        'la amplificación. Usar el parlante del teléfono causaría '
        'retroalimentación acústica (pitido).',
      );
    }

    return const StartupCheckResult.success();
  }

  /// Verifica si el dispositivo soporta audio de baja latencia.
  ///
  /// Si no es soportado, retorna éxito con advertencia (no bloquea el inicio).
  /// La amplificación funcionará pero con latencia potencialmente perceptible.
  ///
  /// Requisito: 6.5
  Future<StartupCheckResult> checkLowLatencySupport() async {
    final supportsLowLatency = await _deviceChecker.supportsLowLatency();

    if (!supportsLowLatency) {
      return const StartupCheckResult.successWithWarning(
        'Este dispositivo no soporta audio de baja latencia. '
        'La amplificación funcionará pero puede experimentar un '
        'retardo perceptible entre el sonido real y el amplificado.',
      );
    }

    return const StartupCheckResult.success();
  }

  /// Verifica si el micrófono está disponible (no en uso por otra app).
  ///
  /// Esta verificación se realiza intentando iniciar la captura de audio.
  /// Si falla con error de micrófono ocupado, retorna un error descriptivo.
  ///
  /// Nota: En Android, no hay una API directa para verificar si el
  /// micrófono está en uso. La verificación real ocurre al intentar
  /// abrir AudioRecord en el lado nativo. Este método proporciona
  /// el mensaje de error apropiado cuando el nativo reporta el fallo.
  ///
  /// Requisito: 1.4
  static StartupCheckResult microphoneUnavailableError() {
    return const StartupCheckResult.failure(
      'El micrófono está siendo utilizado por otra aplicación. '
      'Cierre la otra aplicación que esté usando el micrófono '
      '(llamada telefónica, grabadora de voz, etc.) e intente '
      'nuevamente.',
    );
  }

  /// Verifica si el permiso de micrófono ya fue concedido sin solicitarlo.
  ///
  /// Útil para verificar el estado sin disparar el diálogo del sistema.
  Future<bool> isMicrophonePermissionGranted() async {
    final status = await Permission.microphone.status;
    return status.isGranted;
  }

  /// Abre la configuración de la aplicación para que el usuario
  /// pueda habilitar permisos manualmente.
  ///
  /// Usado cuando el permiso fue denegado permanentemente.
  Future<bool> openSettings() async {
    return await openAppSettings();
  }
}
