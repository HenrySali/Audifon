/// Identificadores y nombres de los 13 tests de diagnóstico.
class DiagTestId {
  DiagTestId._();

  static const String smartScene = 'smart_scene';
  static const String dspRecording = 'dsp_recording';
  static const String sessionLog = 'session_log';
  static const String spectrum = 'spectrum';
  static const String enhancement = 'enhancement';
  static const String latency = 'latency';
  static const String dnnDenoiser = 'dnn_denoiser';
  static const String wdrc = 'wdrc';
  static const String mpoLimiter = 'mpo_limiter';
  static const String protection = 'protection';
  static const String routing = 'audio_routing';
  static const String health = 'system_health';
  static const String abComparative = 'ab_comparative';

  static const List<String> all = [
    smartScene,
    dspRecording,
    sessionLog,
    spectrum,
    enhancement,
    latency,
    dnnDenoiser,
    wdrc,
    mpoLimiter,
    protection,
    routing,
    health,
    abComparative,
  ];

  static String displayName(String id) {
    switch (id) {
      case smartScene:
        return '1. Smart Scene';
      case dspRecording:
        return '2. Diagnóstico DSP';
      case sessionLog:
        return '3. Registro de Sesión';
      case spectrum:
        return '4. Spectrum Analyzer';
      case enhancement:
        return '5. Motor de Realce';
      case latency:
        return '6. Latencia';
      case dnnDenoiser:
        return '7. DNN Denoiser';
      case wdrc:
        return '8. WDRC';
      case mpoLimiter:
        return '9. MPO Limiter';
      case protection:
        return '10. Protección';
      case routing:
        return '11. Audio Routing';
      case health:
        return '12. Salud del Sistema';
      case abComparative:
        return '13. Comparativa A/B (WAV)';
      default:
        return id;
    }
  }
}
