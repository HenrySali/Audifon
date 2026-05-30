import '../../domain/entities/audio_config.dart';
import '../../domain/entities/calibration_data.dart';
import '../../domain/entities/wdrc_params.dart';

/// Estado del motor de audio nativo.
enum AudioEngineState {
  /// Motor inactivo, sin procesamiento.
  idle,

  /// Motor iniciándose (configurando AudioRecord/AudioTrack).
  starting,

  /// Motor activo, procesando audio en tiempo real.
  active,

  /// Motor pausado (BT desconectado, foco de audio perdido, etc.).
  paused,

  /// Motor en estado de error.
  error,
}

/// Interfaz abstracta de comunicación Dart ↔ Android Native.
///
/// Define el contrato para controlar el pipeline de audio DSP nativo
/// desde la capa Dart. La implementación usa MethodChannel para comandos
/// y EventChannel para streams de datos del motor nativo.
///
/// El audio fluye enteramente en el lado nativo (AudioRecord → DSP → AudioTrack).
/// Flutter solo envía comandos de control vía esta interfaz.
///
/// Requisitos: 2.1, 5.4
abstract class AudioBridge {
  /// Inicia el pipeline de audio con la configuración dada.
  ///
  /// Configura AudioRecord (entrada) y AudioTrack (salida) a 16 kHz mono,
  /// inicializa el pipeline DSP con los parámetros proporcionados, y
  /// comienza el procesamiento en tiempo real en un hilo dedicado.
  ///
  /// Lanza excepción si el micrófono no está disponible o los auriculares
  /// no están conectados.
  Future<void> startAudio(AudioConfig config);

  /// Detiene el pipeline de audio y libera todos los recursos nativos.
  ///
  /// Debe completarse en menos de 100 ms (Req 1.3).
  Future<void> stopAudio();

  /// Actualiza las ganancias del EQ de 12 bandas en tiempo real.
  ///
  /// [gains] debe contener exactamente 12 valores en dB, rango [0, 50].
  /// La actualización se aplica sin interrumpir el flujo de audio.
  Future<void> updateEqGains(List<double> gains);

  /// Actualiza el volumen maestro.
  ///
  /// [volumeDb] rango: -20 a +10 dB.
  /// Se aplica en menos de 50 ms sin artefactos audibles (Req 8.5).
  Future<void> updateVolume(double volumeDb);

  /// Actualiza los parámetros del compresor WDRC.
  ///
  /// Incluye knees de expansión/compresión, ratios, y tiempos de
  /// ataque/liberación. Se aplica con crossfade de 10 ms.
  Future<void> updateWdrcParams(WdrcParams params);

  /// Actualiza la intensidad de la reducción de ruido.
  ///
  /// [level] valores: 0=off, 1=bajo, 2=medio, 3=alto.
  Future<void> updateNrLevel(int level);

  /// Habilita/deshabilita el Transient Noise Reducer (TNR).
  ///
  /// Cuando está habilitado, atenúa automáticamente impulsos abruptos como
  /// timbre del subte, puertas que se cierran, bocinas. No afecta la voz.
  Future<void> updateTnrEnabled(bool enabled);

  /// Stream del nivel de entrada del micrófono en dB SPL.
  ///
  /// Emitido aproximadamente 10 veces por segundo (~10 Hz).
  /// Usado para el indicador visual de nivel en la UI (Req 5.4).
  Stream<double> get inputLevelStream;

  /// Stream del estado del motor de audio.
  ///
  /// Emite cambios de estado: idle → starting → active → paused → idle.
  /// Usado por el BLoC para actualizar la UI según el estado del engine.
  Stream<AudioEngineState> get stateStream;

  /// Inicia calibración del micrófono.
  ///
  /// Reproduce un tono de referencia y mide el nivel capturado para
  /// calcular el offset dBFS → dB SPL del micrófono del dispositivo.
  ///
  /// [referenceSplLevel] es el nivel SPL conocido de la fuente de
  /// referencia externa (típicamente 94 dB SPL para calibrador).
  Future<MicCalibrationResult> calibrateMicrophone({
    required double referenceSplLevel,
  });

  /// Inicia calibración del auricular.
  ///
  /// Reproduce un sweep de frecuencias (250-8000 Hz) por el auricular
  /// y mide la respuesta en frecuencia relativa usando el micrófono
  /// del teléfono como receptor (acoplador improvisado).
  ///
  /// [headphoneId] es la dirección MAC del auricular BT o "wired_default".
  Future<HeadphoneCalibrationResult> calibrateHeadphones({
    required String headphoneId,
  });

  /// Aplica datos de calibración al motor de audio.
  ///
  /// Actualiza el offset SPL del micrófono y la compensación EQ
  /// del auricular en el pipeline DSP nativo.
  Future<void> applyCalibration(CalibrationData calibration);

  /// Obtiene información de los dispositivos de audio activos.
  ///
  /// Retorna un mapa con:
  /// - inputDeviceName: nombre del micrófono activo
  /// - outputDeviceName: nombre del auricular/parlante activo
  /// - bluetoothConnected: si hay auricular BT conectado
  /// - bluetoothName: nombre del dispositivo BT
  /// - bluetoothIsA2dp: si la conexión es A2DP (alta calidad)
  Future<Map<String, dynamic>> getDeviceInfo();
}
