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

  /// Ajusta la intensidad del DNN (Deep Neural Network) denoiser en
  /// runtime, en el rango `[0.0, 1.0]`.
  ///
  /// Valores fuera de rango se clampan en el lado nativo. La firma
  /// replica `AudioBridge.setDnnIntensity` del paciente
  /// (`PACIENTE/oir_pro_patient_app/lib/core/audio_bridge.dart`); el
  /// canal y el handler Kotlin del técnico ya están cableados desde
  /// la integración inicial del DNN denoiser
  /// (`AudioMethodChannel.kt` → `setDnnIntensity` →
  /// `nativeBridge.nativeSetDnnIntensity(intensity)`).
  ///
  /// El bloc usa este setter al desactivar Modo Música (Req 1.8) para
  /// reaplicar el valor persistido en `SettingsRepository.dnnIntensity`.
  ///
  /// Requisitos: 1.8
  Future<void> setDnnIntensity(double intensity);

  /// Habilita/deshabilita el Transient Noise Reducer (TNR).
  ///
  /// Cuando está habilitado, atenúa automáticamente impulsos abruptos como
  /// timbre del subte, puertas que se cierran, bocinas. No afecta la voz.
  Future<void> updateTnrEnabled(bool enabled);

  /// Activa/desactiva "MHL Prescripción": amplificación lineal mínima.
  ///
  /// Cuando se activa, el motor aplica gains flat 8 dB en las 12 bandas EQ
  /// y `compressionRatio = 1.0` sin tocar `nrLevel`, `dnnIntensity` ni los
  /// demás parámetros WDRC (knees, attack, release). Cuando se desactiva,
  /// el handler nativo restaura el EQ guardado.
  ///
  /// La firma replica `AudioBridge.setMhlPrescriptionEnabled` del paciente
  /// (`PACIENTE/oir_pro_patient_app/lib/core/audio_bridge.dart`).
  ///
  /// Requisitos: 1.1
  Future<void> setMhlPrescriptionEnabled(bool enabled);

  /// Activa/desactiva "Modo Música": preserva timbres y dinámicas musicales.
  ///
  /// Cuando se activa, el motor aplica `nrLevel = 0` y `dnnIntensity = 0.0`
  /// sin modificar gains EQ, `compressionRatio`, knees, attack ni release
  /// del bundle activo. Cuando se desactiva, el caller (bloc) reaplica los
  /// valores persistidos en `SettingsRepository`.
  ///
  /// La firma replica `AudioBridge.setMusicModeEnabled` del paciente
  /// (`PACIENTE/oir_pro_patient_app/lib/core/audio_bridge.dart`).
  ///
  /// Requisitos: 1.2
  Future<void> setMusicModeEnabled(bool enabled);

  /// Activa/desactiva "Modo Conversación": rutea audio por SCO Bluetooth
  /// (o builtin si no hay BT) con `MODE_IN_COMMUNICATION`, y baja el
  /// sample rate del pipeline a 16 kHz / 64 frames. Latencia BT cae
  /// de ~200 ms a ~25 ms.
  ///
  /// Devuelve un string con el resultado de la activación SCO:
  ///   - "connected"          → SCO BT activo, ruteado al auricular.
  ///   - "fallback_builtin"   → no hay BT, queda en speaker/mic builtin
  ///                            (igual con MODE_IN_COMMUNICATION → menor
  ///                            latencia que A2DP).
  ///   - "failed"             → no se pudo cambiar de modo.
  ///   - "engine_idle"        → motor todavía no arrancó; el flag queda
  ///                            registrado y se aplica en el próximo start.
  ///   - "disabled"           → toggle OFF, vuelve a A2DP @ 48 kHz.
  Future<String> setConversationMode(bool enabled);

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

  /// Actualiza el umbral MPO del limitador broadband en runtime.
  ///
  /// [thresholdDbSpl] rango cerrado: [80.0, 132.0] dB SPL.
  /// Aplica el nuevo techo al limitador MPO del pipeline DSP nativo
  /// sin reiniciar el motor de audio.
  ///
  /// Lanza [ArgumentError] si el valor es NaN, Infinity o fuera de rango.
  /// Propagación al motor: ≤ 50 ms p95.
  ///
  /// Requisitos: audiogram-driven-presets Req 3.1
  Future<void> setMpoThresholdDbSpl(double thresholdDbSpl);

  /// Obtiene información de los dispositivos de audio activos.
  ///
  /// Retorna un mapa con:
  /// - inputDeviceName: nombre del micrófono activo
  /// - outputDeviceName: nombre del auricular/parlante activo
  /// - bluetoothConnected: si hay auricular BT conectado
  /// - bluetoothName: nombre del dispositivo BT
  /// - bluetoothIsA2dp: si la conexión es A2DP (alta calidad)
  Future<Map<String, dynamic>> getDeviceInfo();

  // ─── Diagnostic Recording (DSP Verification) ────────────────────────────

  /// Inicia una grabación de diagnóstico DSP de 15 segundos.
  ///
  /// [filePath] es el nombre del archivo WAV (se resuelve en el lado nativo).
  /// El nombre debe seguir el formato `diag_YYYYMMDD_HHMMSS.wav`.
  ///
  /// Retorna `true` si la grabación inició correctamente, `false` si el
  /// motor no está corriendo, ya hay otra grabación activa, o falló la
  /// apertura del archivo.
  ///
  /// La firma replica `AudioBridge.startDiagnosticRecording` del paciente
  /// (`PACIENTE/oir_pro_patient_app/lib/core/audio_bridge.dart`).
  ///
  /// Requisitos: 6.2
  Future<bool> startDiagnosticRecording(String filePath);

  /// Detiene la grabación de diagnóstico en curso.
  ///
  /// Retorna `0` si la grabación se completó correctamente (60 s), `1` si
  /// fue descartada por una parada temprana del usuario, o `-1` si ocurrió
  /// un error nativo durante la grabación o el cierre del archivo.
  ///
  /// La firma replica `AudioBridge.stopDiagnosticRecording` del paciente
  /// (`PACIENTE/oir_pro_patient_app/lib/core/audio_bridge.dart`).
  ///
  /// Requisitos: 6.4
  Future<int> stopDiagnosticRecording();

  /// Obtiene el tiempo transcurrido de la grabación activa, en milisegundos.
  ///
  /// Retorna `-1` si no hay grabación activa o si el handler nativo no
  /// está disponible. Pensado para polling cíclico (1 Hz) durante el
  /// progreso de la grabación.
  ///
  /// La firma replica `AudioBridge.getDiagnosticRecordingProgress` del
  /// paciente (`PACIENTE/oir_pro_patient_app/lib/core/audio_bridge.dart`).
  ///
  /// Requisitos: 6.3
  Future<int> getDiagnosticRecordingProgress();

  /// Aplica un preset completo del Smart Scene de forma atómica.
  ///
  /// Fase G — applyScenePreset único: reemplaza 4+ llamadas separadas
  /// (updateEqGains + updateWdrcParams + updateNrLevel + updateTnrEnabled +
  /// setMpoThresholdDbSpl + setSmartPresetPinned) por una sola llamada
  /// MethodChannel. El motor C++ lo aplica en orden seguro (MPO → WDRC →
  /// EQ → NR → TNR → pin) sin ventana de incoherencia entre llamadas.
  ///
  /// [gains] debe contener exactamente 12 valores en dB, rango [0, 50].
  /// [wdrcParams] parámetros WDRC completos.
  /// [nrLevel] nivel de NR [0, 3].
  /// [tnrEnabled] true para activar TNR.
  /// [mpoThresholdDbSpl] MPO broadband en dB SPL.
  /// [pinPreset] true para fijar el pin del preset Smart.
  Future<void> applyScenePreset({
    required List<double> gains,
    required WdrcParams wdrcParams,
    required int nrLevel,
    required bool tnrEnabled,
    required double mpoThresholdDbSpl,
    bool pinPreset = true,
  });

  /// Obtiene un snapshot de las métricas por etapa del pipeline DSP.
  ///
  /// Devuelve un `Map<String, dynamic>` con las claves expuestas por el
  /// handler Kotlin `NativeAudioBridge.getDspStageMetrics()` (técnico):
  /// `expansionGainDb`, `linearGainDb`, `compressionGainDb`,
  /// `wdrcRegion`, `eqMaxGain`, `inputLevel`, `postNrLevel`,
  /// `postEqLevel`, `postWdrcLevel`, `postVolumeLevel`, `outputLevel`,
  /// `peakSample`, `clipCount`, `wdrcGainFactor`, `preDnnLevelDb`,
  /// `wdrcLevelSource`, `mpoLimitingFraction`, `mpoLimitingSustained`
  /// y — clave clave para Smart Scene polling —
  /// **`environmentClass`** (int en `[0, 7]` correspondiente al enum C++
  /// `smart_scene::SceneClass`; valores fuera de rango se tratan como 0).
  ///
  /// `mpoLimitingFraction` (double `[0,1]`) y `mpoLimitingSustained` (bool)
  /// exponen el aviso de limitación sostenida del MPO clínico (spec
  /// audifono-v3 task 10.2, decisión B): `mpoLimitingSustained == true`
  /// indica que la salida está pegada al límite de seguridad de forma
  /// sostenida (Requirement 9.2). Motores nativos viejos que no exponen
  /// estos campos devuelven `0.0` / `false` por defecto.
  ///
  /// Retorna `null` cuando:
  /// - el motor de audio no está corriendo (`getDspStageMetrics()`
  ///   nativo retorna `null`),
  /// - el handler nativo no está implementado
  ///   (`MissingPluginException`),
  /// - la invocación falla por cualquier otra razón
  ///   (`PlatformException` u otra excepción).
  ///
  /// La firma replica exactamente `AudioBridge.getDspStageMetrics` del
  /// paciente (`PACIENTE/oir_pro_patient_app/lib/core/audio_bridge.dart`):
  /// el caller (bloc / `SmartSceneScreen` polling) recibe `null` y debe
  /// tratarlo como tick fallido sin actualizar `_lastEnvClass` (Req 2.12).
  ///
  /// Requisitos: 2.1, 2.2, 2.10, 2.11, 2.12, 2.13, 6.13
  Future<Map<String, dynamic>?> getDspStageMetrics();
}
