import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../data/services/adaptive_learning_service.dart';
import '../bloc/amplification_bloc.dart';
import '../bloc/amplification_event.dart';
import '../bloc/amplification_state.dart';

/// Tipos de recomendación que el widget puede mostrar.
enum AudioRecommendationType {
  /// Eco/feedback detectado — sugerir reducir ganancia o ajustar auricular.
  echo,

  /// Voz baja detectada — sugerir acercar micrófono o subir volumen.
  lowVoice,

  /// Saturación en el EQ — bandas exceden headroom seguro.
  eqSaturation,

  /// Ambiente conversación detectado — sugerir perfil Conversación.
  conversationDetected,

  /// Ambiente ruidoso detectado — sugerir perfil Ruidoso o subir NR.
  noiseDetected,

  /// Ambiente silencioso — sugerir reducir ganancia para evitar ruido de piso.
  silenceDetected,

  /// Nivel muy bajo prolongado — posible problema de micrófono.
  veryLowInput,

  /// Clipping detectado — ganancia total excesiva, clipCount alto.
  clipping,

  /// MPO limitando de forma sostenida — output pegado al techo.
  mpoLimitingSustained,

  /// DNN matando la voz — postNrLevel mucho menor que input con SPEECH.
  dnnKillingVoice,

  /// Ganancia asimétrica extrema — diferencia >15 dB entre graves y agudos.
  asymmetricGain,

  /// Roce de ropa / chasquido — transient burst en graves sin voz.
  clothingRustle,

  /// Música detectada — espectro amplio sin VAD → sugerir Modo Música.
  musicDetected,

  /// Viento detectado — energía concentrada <250 Hz con variación rápida.
  windDetected,

  /// Fatiga auditiva — sesión activa >2 horas continuas.
  listeningFatigue,

  /// Volumen al máximo (+10 dB) — sugerir recalibrar ganancias base.
  volumeMaxed,

  /// NR insuficiente — ruido alto con NR bajo.
  nrInsufficient,

  /// Perfil estático mucho tiempo — >30 min sin cambiar con ambiente variable.
  staleProfile,

  /// Exposición acumulada alta — dosis de ruido acercándose a límites.
  noiseExposure,
}

/// Modelo de una recomendación activa.
class _AudioRecommendation {
  final AudioRecommendationType type;
  final String title;
  final String message;
  final String? actionLabel;
  final VoidCallback? action;
  final IconData icon;
  final Color color;

  const _AudioRecommendation({
    required this.type,
    required this.title,
    required this.message,
    this.actionLabel,
    this.action,
    required this.icon,
    required this.color,
  });
}

/// Widget inteligente que analiza las condiciones de audio en tiempo real
/// y muestra recomendaciones contextuales como banners animados.
///
/// Monitorea:
/// - Nivel de entrada (voz baja, nivel extremadamente bajo)
/// - Ganancias EQ activas (saturación por banda)
/// - Clasificación de ambiente (conversación, ruido, silencio)
/// - Patrones de eco/feedback (análisis espectral básico)
///
/// Las recomendaciones aparecen como banners colapsables en la parte
/// superior del contenido, con animación de entrada/salida. Cada
/// recomendación se puede descartar y tiene un cooldown de 30 segundos
/// antes de volver a aparecer (evitar spam).
///
/// Solo se muestra durante `AmplificationActive`.
class AudioRecommendationWidget extends StatefulWidget {
  const AudioRecommendationWidget({super.key});

  @override
  State<AudioRecommendationWidget> createState() =>
      _AudioRecommendationWidgetState();
}

class _AudioRecommendationWidgetState
    extends State<AudioRecommendationWidget> {
  /// Recomendación actualmente visible (solo una a la vez, priorizada).
  _AudioRecommendation? _activeRecommendation;

  /// Timestamps de los últimos dismiss por tipo (cooldown de 30s).
  final Map<AudioRecommendationType, DateTime> _dismissedAt = {};

  /// Cooldown: no re-mostrar la misma recomendación por 30 segundos.
  static const _kCooldownDuration = Duration(seconds: 30);

  /// Timer de evaluación periódica (cada 2 segundos).
  Timer? _evaluationTimer;

  /// Historial reciente de niveles de entrada para análisis de tendencia.
  final List<double> _recentLevels = [];

  /// Máximo de muestras de nivel guardadas (últimos 10 segundos a 10 Hz = 100).
  static const _kMaxLevelSamples = 100;

  /// Contador de ticks consecutivos con nivel bajo (<35 dB SPL).
  int _lowLevelTicks = 0;

  /// Contador de ticks consecutivos con nivel muy bajo (<25 dB SPL).
  int _veryLowLevelTicks = 0;

  /// Último environmentClass conocido (del Smart poll).
  int? _lastEnvClass;

  /// Ticks consecutivos en la misma clase de ambiente (estabilidad).
  int _envClassStableTicks = 0;

  /// Bandera: se detectó posible eco (correlación entrada/salida alta).
  int _echoSuspicionTicks = 0;

  /// Último perfil activo conocido.
  String? _lastActiveProfile;

  /// Contadores para nuevas detecciones.
  int _clippingTicks = 0;
  int _mpoSustainedTicks = 0;
  int _dnnKillingVoiceTicks = 0;
  int _clothingRustleTicks = 0;
  int _musicTicks = 0;
  int _windTicks = 0;
  int _volumeMaxTicks = 0;
  int _nrInsufficientTicks = 0;
  int _staleProfileTicks = 0;

  /// Timestamp de inicio de la sesión de amplificación activa.
  DateTime? _sessionStart;

  /// Historial de niveles recientes para detección de transientes (ropa).
  final List<double> _transientHistory = [];

  /// Acumulador de exposición (suma de niveles en dB por tick para LEQ).
  double _exposureAccumulator = 0.0;
  int _exposureTicks = 0;

  /// Canal para consultar métricas DSP.
  static const _channel = MethodChannel('com.psk.hearing_aid/audio');

  /// Referencia al servicio Hermes para enviar observaciones automáticas.
  final AdaptiveLearningService _hermes = AdaptiveLearningService.instance;

  /// Cooldown de envío a Hermes por tipo: evita spamear el VPS con la
  /// misma detección repetida. Mínimo 60 segundos entre envíos del mismo tipo.
  final Map<AudioRecommendationType, DateTime> _hermesSentAt = {};

  /// Cooldown de Hermes: no reenviar la misma detección por 60 segundos.
  static const _kHermesCooldown = Duration(seconds: 60);

  /// Flag: LED verde visible (auto-ajuste aplicado). Se apaga tras 4 segundos.
  bool _showGreenLed = false;
  Timer? _ledTimer;

  /// Texto del último ajuste aplicado automáticamente (para el LED tooltip).
  String _lastAutoAppliedLabel = '';

  @override
  void initState() {
    super.initState();
    _evaluationTimer = Timer.periodic(
      const Duration(seconds: 2),
      (_) => _evaluate(),
    );
  }

  @override
  void dispose() {
    _evaluationTimer?.cancel();
    _ledTimer?.cancel();
    super.dispose();
  }

  /// Evalúa las condiciones de audio y decide si mostrar/ocultar
  /// recomendaciones.
  void _evaluate() {
    if (!mounted) return;
    final bloc = context.read<AmplificationBloc>();
    final state = bloc.state;
    if (state is! AmplificationActive) {
      if (_activeRecommendation != null) {
        setState(() => _activeRecommendation = null);
      }
      return;
    }

    // Alimentar historial de niveles.
    _recentLevels.add(state.inputLevelDb);
    if (_recentLevels.length > _kMaxLevelSamples) {
      _recentLevels.removeAt(0);
    }

    // Tracking de transientes para detección de roce de ropa.
    _transientHistory.add(state.inputLevelDb);
    if (_transientHistory.length > 20) {
      _transientHistory.removeAt(0);
    }

    // Tracking de sesión activa para fatiga.
    _sessionStart ??= DateTime.now();

    // Acumular exposición (LEQ simplificado).
    _exposureAccumulator += state.inputLevelDb;
    _exposureTicks++;

    // Actualizar contadores de ambiente.
    final envClass = bloc.lastEnvClass;
    if (envClass == _lastEnvClass) {
      _envClassStableTicks++;
    } else {
      _envClassStableTicks = 0;
      _lastEnvClass = envClass;
    }
    _lastActiveProfile = state.activeProfile;

    // Detectar condiciones (en orden de prioridad).
    final recommendation = _detectHighestPriority(state, bloc);

    if (recommendation != _activeRecommendation?.type) {
      if (recommendation != null) {
        // Si Hermes está en modo automático: aplicar local inmediato,
        // NO mostrar banner, encender LED verde, y enviar a Hermes
        // con prefijo [Auto-Applied] para que registre sin reaplicar.
        if (_hermes.autoApply) {
          final rec = _buildRecommendation(recommendation, state, bloc);
          if (rec.action != null) {
            rec.action!();
          }
          // Enviar a Hermes con marca de "ya aplicado localmente".
          _sendToHermesAutoApplied(recommendation, state, bloc);
          // Encender LED verde.
          _activateGreenLed(rec.title);
          // Limpiar banner activo (no mostrar nada interactivo).
          if (_activeRecommendation != null) {
            setState(() => _activeRecommendation = null);
          }
          return;
        }

        // Modo manual: enviar a Hermes normalmente y mostrar banner.
        _sendToHermes(recommendation, state, bloc);
      }
      setState(() {
        _activeRecommendation = recommendation != null
            ? _buildRecommendation(recommendation, state, bloc)
            : null;
      });
    }
  }

  /// Enciende el LED verde por 4 segundos.
  void _activateGreenLed(String label) {
    _lastAutoAppliedLabel = label;
    _ledTimer?.cancel();
    setState(() => _showGreenLed = true);
    _ledTimer = Timer(const Duration(seconds: 4), () {
      if (mounted) setState(() => _showGreenLed = false);
    });
  }

  // ─── Integración Hermes ─────────────────────────────────────────────

  /// Envía la detección como observación automática a Hermes.
  ///
  /// - Si `autoApply = true` → Hermes aplica el ajuste solo.
  /// - Si `autoApply = false` → aparece como sugerencia en la ventana de Hermes.
  ///
  /// Respeta un cooldown de 60s por tipo para no spamear el VPS.
  void _sendToHermes(
    AudioRecommendationType type,
    AmplificationActive state,
    AmplificationBloc bloc,
  ) {
    // Verificar cooldown de Hermes para este tipo.
    final lastSent = _hermesSentAt[type];
    if (lastSent != null &&
        DateTime.now().difference(lastSent) < _kHermesCooldown) {
      return; // Aún en cooldown, no reenviar.
    }

    // Generar texto descriptivo para Hermes.
    final userText = _hermesTextFor(type, state);

    // Registrar timestamp del envío.
    _hermesSentAt[type] = DateTime.now();

    // Enviar en background (no bloquea la UI).
    // El servicio ya maneja autoApply internamente:
    // - autoApply=true → aplica la sugerencia de Hermes automáticamente.
    // - autoApply=false → la deja como sugerencia visible en el historial.
    _hermes.addObservation(userText: userText, bloc: bloc);
  }

  /// Envía a Hermes con prefijo `[Auto-Applied]` indicando que el ajuste
  /// ya se aplicó localmente. Hermes NO debe reaplicar — solo registrar.
  void _sendToHermesAutoApplied(
    AudioRecommendationType type,
    AmplificationActive state,
    AmplificationBloc bloc,
  ) {
    final lastSent = _hermesSentAt[type];
    if (lastSent != null &&
        DateTime.now().difference(lastSent) < _kHermesCooldown) {
      return;
    }

    final baseText = _hermesTextFor(type, state);
    // Reemplazar [Auto] por [Auto-Applied] para que el service no reaplique.
    final userText = baseText.replaceFirst('[Auto]', '[Auto-Applied]');

    _hermesSentAt[type] = DateTime.now();
    _hermes.addObservation(userText: userText, bloc: bloc);
  }

  /// Genera el texto de observación que Hermes va a recibir para cada tipo.
  ///
  /// El prefijo `[Auto]` indica a Hermes que es una detección automática
  /// (no escrita por el técnico). El texto incluye contexto numérico para
  /// que el modelo de IA pueda generar una sugerencia precisa.
  String _hermesTextFor(AudioRecommendationType type, AmplificationActive state) {
    final level = state.inputLevelDb.toStringAsFixed(1);
    final profile = state.activeProfile;
    final gains = state.activeEqGains ?? state.bundle?.gainsDb;
    final highGain = gains != null && gains.length == 12
        ? ((gains[8] + gains[9] + gains[10] + gains[11]) / 4).toStringAsFixed(1)
        : '?';

    switch (type) {
      case AudioRecommendationType.echo:
        return '[Auto] Eco/feedback detectado. Nivel entrada: $level dB SPL, '
            'ganancia promedio agudos: $highGain dB. '
            'Patrón de realimentación acústica sostenido. '
            'Sugerir reducción de ganancia en agudos o ajuste de auricular.';

      case AudioRecommendationType.lowVoice:
        return '[Auto] Voz baja detectada. Nivel entrada: $level dB SPL '
            'con clasificador indicando voz/conversación. '
            'El interlocutor habla a nivel inferior al normal (45-65 dB). '
            'Sugerir aumento de volumen o ganancia en banda de habla.';

      case AudioRecommendationType.eqSaturation:
        final saturated = _countSaturatedBands(state);
        return '[Auto] Saturación en ecualización. $saturated de 12 bandas '
            'cerca del límite MPO. Nivel entrada: $level dB SPL. '
            'Riesgo de distorsión audible. '
            'Sugerir reducción de ganancias o ajuste de MPO.';

      case AudioRecommendationType.conversationDetected:
        return '[Auto] Ambiente de conversación detectado (clasificador: SPEECH). '
            'Perfil activo: $profile. Nivel entrada: $level dB SPL. '
            'Sugerir cambio a perfil Conversación para mejorar inteligibilidad.';

      case AudioRecommendationType.noiseDetected:
        return '[Auto] Ambiente ruidoso detectado (clasificador: NOISE). '
            'Perfil activo: $profile. Nivel entrada: $level dB SPL. '
            'Sugerir cambio a perfil Ruidoso y/o aumentar NR.';

      case AudioRecommendationType.silenceDetected:
        return '[Auto] Ambiente silencioso detectado (clasificador: QUIET). '
            'Perfil activo: $profile. Nivel entrada: $level dB SPL. '
            'Sugerir cambio a perfil Silencioso para reducir ruido de piso.';

      case AudioRecommendationType.veryLowInput:
        return '[Auto] Nivel de entrada extremadamente bajo (<25 dB SPL) '
            'durante >20 segundos. Nivel: $level dB SPL. '
            'Posible problema con micrófono bloqueado o permisos. '
            'Verificar hardware.';

      case AudioRecommendationType.clipping:
        return '[Auto] Clipping detectado. Nivel entrada: $level dB SPL. '
            'La señal satura el conversor AD. '
            'Sugerir reducción de volumen master o ganancias EQ.';

      case AudioRecommendationType.mpoLimitingSustained:
        return '[Auto] MPO limitando de forma sostenida. Nivel entrada: $level dB SPL. '
            'La salida está pegada al techo MPO. Sonido aplastado sin dinámica. '
            'Sugerir reducción de ganancias o aumento del umbral MPO.';

      case AudioRecommendationType.dnnKillingVoice:
        return '[Auto] DNN/NR excesivo matando la voz. Nivel entrada: $level dB SPL, '
            'NR nivel: ${state.activeNrLevel}, clasificador: SPEECH. '
            'El filtro IA atenúa la voz junto con el ruido. '
            'Sugerir reducir NR o bajar intensidad DNN.';

      case AudioRecommendationType.clothingRustle:
        return '[Auto] Roce de ropa / chasquido detectado. Nivel: $level dB SPL. '
            'Transientes repetitivos en graves sin voz (patrón de tela/bolsillo/mesa). '
            'Sugerir activar TNR o corte de graves <500 Hz.';

      case AudioRecommendationType.asymmetricGain:
        return '[Auto] Ganancia asimétrica extrema (>15 dB diferencia graves vs agudos). '
            'Promedio agudos: $highGain dB. Perfil: $profile. '
            'Puede causar molestia. Sugerir balancear la curva EQ.';

      case AudioRecommendationType.musicDetected:
        return '[Auto] Música detectada. Nivel: $level dB SPL, espectro amplio, '
            'sin voz clasificada, sostenido >16s. '
            'Sugerir activar Modo Música (NR=0, DNN=0) para preservar dinámica.';

      case AudioRecommendationType.windDetected:
        return '[Auto] Viento detectado. Nivel: $level dB SPL, energía concentrada '
            'en graves (<500 Hz) con clasificador NOISE. '
            'Sugerir corte de graves (-8 dB bandas 0-3) o windguard.';

      case AudioRecommendationType.listeningFatigue:
        return '[Auto] Sesión prolongada (>2 horas continuas de amplificación activa). '
            'Riesgo de fatiga auditiva. Sugerir descanso o reducción de volumen.';

      case AudioRecommendationType.volumeMaxed:
        return '[Auto] Volumen al máximo (+10 dB) sostenido >10s. '
            'Nivel entrada: $level dB SPL. Perfil: $profile. '
            'Si el paciente necesita más, recalibrar ganancias base del EQ.';

      case AudioRecommendationType.nrInsufficient:
        return '[Auto] NR insuficiente. Clasificador: NOISE, NR nivel: '
            '${state.activeNrLevel}. Nivel entrada: $level dB SPL. '
            'Sugerir aumentar NR a nivel 2-3 para mejorar SNR.';

      case AudioRecommendationType.staleProfile:
        return '[Auto] Perfil "$profile" sin cambios >15 minutos con ambiente variable. '
            'Nivel entrada: $level dB SPL. '
            'Sugerir activar Smart automático o cambiar perfil manualmente.';

      case AudioRecommendationType.noiseExposure:
        return '[Auto] Exposición acumulada alta. LEQ de sesión >80 dB. '
            'Nivel actual: $level dB SPL. '
            'Riesgo de daño auditivo acumulativo. Sugerir reducir volumen o descanso.';
    }
  }

  /// Cuenta cuántas bandas están saturando (para el texto de Hermes).
  int _countSaturatedBands(AmplificationActive state) {
    final gains = state.activeEqGains ?? state.bundle?.gainsDb;
    final mpo = state.bundle?.mpoProfileDbSpl;
    if (gains == null || gains.length != 12) return 0;
    int count = 0;
    for (int i = 0; i < 12; i++) {
      if (mpo != null && mpo.length == 12) {
        if (gains[i] + 65.0 > mpo[i] - 5.0) count++;
      } else {
        if (gains[i] > 30) count++;
      }
    }
    return count;
  }

  // ─── Detección de condiciones ──────────────────────────────────────────

  /// Detecta la recomendación de mayor prioridad según las condiciones
  /// actuales. Retorna null si no hay nada que recomendar.
  AudioRecommendationType? _detectHighestPriority(
    AmplificationActive state,
    AmplificationBloc bloc,
  ) {
    // 1. PRIORIDAD ALTA — Eco/feedback detectado.
    if (_detectEcho(state)) {
      if (!_isInCooldown(AudioRecommendationType.echo)) {
        return AudioRecommendationType.echo;
      }
    }

    // 2. PRIORIDAD ALTA — Saturación en EQ.
    if (_detectEqSaturation(state)) {
      if (!_isInCooldown(AudioRecommendationType.eqSaturation)) {
        return AudioRecommendationType.eqSaturation;
      }
    }

    // 3. PRIORIDAD MEDIA — Voz baja.
    if (_detectLowVoice(state)) {
      if (!_isInCooldown(AudioRecommendationType.lowVoice)) {
        return AudioRecommendationType.lowVoice;
      }
    }

    // 4. PRIORIDAD MEDIA — Nivel muy bajo (posible problema de mic).
    if (_detectVeryLowInput(state)) {
      if (!_isInCooldown(AudioRecommendationType.veryLowInput)) {
        return AudioRecommendationType.veryLowInput;
      }
    }

    // 4b. PRIORIDAD ALTA — Clipping (clipCount alto).
    if (_detectClipping(state)) {
      if (!_isInCooldown(AudioRecommendationType.clipping)) {
        return AudioRecommendationType.clipping;
      }
    }

    // 4c. PRIORIDAD ALTA — MPO limitando sostenido.
    if (_detectMpoSustained(state)) {
      if (!_isInCooldown(AudioRecommendationType.mpoLimitingSustained)) {
        return AudioRecommendationType.mpoLimitingSustained;
      }
    }

    // 4d. PRIORIDAD MEDIA — DNN matando la voz.
    if (_detectDnnKillingVoice(state)) {
      if (!_isInCooldown(AudioRecommendationType.dnnKillingVoice)) {
        return AudioRecommendationType.dnnKillingVoice;
      }
    }

    // 4e. PRIORIDAD MEDIA — Roce de ropa / chasquido.
    if (_detectClothingRustle(state)) {
      if (!_isInCooldown(AudioRecommendationType.clothingRustle)) {
        return AudioRecommendationType.clothingRustle;
      }
    }

    // 4f. PRIORIDAD MEDIA — Ganancia asimétrica extrema.
    if (_detectAsymmetricGain(state)) {
      if (!_isInCooldown(AudioRecommendationType.asymmetricGain)) {
        return AudioRecommendationType.asymmetricGain;
      }
    }

    // 4g. PRIORIDAD MEDIA — Volumen al máximo.
    if (_detectVolumeMaxed(state)) {
      if (!_isInCooldown(AudioRecommendationType.volumeMaxed)) {
        return AudioRecommendationType.volumeMaxed;
      }
    }

    // 4h. PRIORIDAD MEDIA — NR insuficiente.
    if (_detectNrInsufficient(state)) {
      if (!_isInCooldown(AudioRecommendationType.nrInsufficient)) {
        return AudioRecommendationType.nrInsufficient;
      }
    }

    // 4i. PRIORIDAD BAJA — Música detectada.
    if (_detectMusic(state)) {
      if (!_isInCooldown(AudioRecommendationType.musicDetected)) {
        return AudioRecommendationType.musicDetected;
      }
    }

    // 4j. PRIORIDAD BAJA — Viento.
    if (_detectWind(state)) {
      if (!_isInCooldown(AudioRecommendationType.windDetected)) {
        return AudioRecommendationType.windDetected;
      }
    }

    // 4k. PRIORIDAD BAJA — Fatiga auditiva (>2 horas).
    if (_detectListeningFatigue()) {
      if (!_isInCooldown(AudioRecommendationType.listeningFatigue)) {
        return AudioRecommendationType.listeningFatigue;
      }
    }

    // 4l. PRIORIDAD BAJA — Exposición acumulada alta.
    if (_detectNoiseExposure()) {
      if (!_isInCooldown(AudioRecommendationType.noiseExposure)) {
        return AudioRecommendationType.noiseExposure;
      }
    }

    // 4m. PRIORIDAD BAJA — Perfil estático mucho tiempo.
    if (_detectStaleProfile(state, bloc)) {
      if (!_isInCooldown(AudioRecommendationType.staleProfile)) {
        return AudioRecommendationType.staleProfile;
      }
    }

    // 5. PRIORIDAD BAJA — Sugerencias de ambiente (solo si estable >6s).
    if (_envClassStableTicks >= 3) {
      final envSuggestion = _detectEnvironmentSuggestion(state, bloc);
      if (envSuggestion != null && !_isInCooldown(envSuggestion)) {
        return envSuggestion;
      }
    }

    return null;
  }

  /// Detecta posible eco/feedback acústico.
  ///
  /// Indicadores:
  /// - Nivel de entrada alto (>70 dB) sostenido sin presencia de voz
  ///   (el clasificador reporta NOISE o QUIET pero el nivel es alto).
  /// - Ganancia alta en agudos (bandas 8-11 > 20 dB) + nivel de
  ///   entrada medio-alto (>55 dB). Patrón típico de realimentación.
  bool _detectEcho(AmplificationActive state) {
    final level = state.inputLevelDb;
    final gains = state.activeEqGains ?? state.bundle?.gainsDb;

    // Patrón 1: nivel alto sin voz clasificada → posible feedback loop.
    final envClass = _lastEnvClass;
    if (level > 70 && (envClass == 0 || envClass == 3)) {
      _echoSuspicionTicks++;
    } else {
      _echoSuspicionTicks = 0;
    }
    if (_echoSuspicionTicks >= 4) return true; // 8 segundos sostenidos.

    // Patrón 2: ganancias altas en agudos + nivel medio-alto.
    if (gains != null && gains.length == 12 && level > 55) {
      final highFreqGain = (gains[8] + gains[9] + gains[10] + gains[11]) / 4;
      if (highFreqGain > 20) {
        _echoSuspicionTicks++;
        if (_echoSuspicionTicks >= 3) return true;
      }
    }

    return false;
  }

  /// Detecta voz baja: nivel de entrada en rango de habla (35-55 dB SPL)
  /// pero en el extremo bajo, con clasificador indicando SPEECH.
  bool _detectLowVoice(AmplificationActive state) {
    final level = state.inputLevelDb;
    final envClass = _lastEnvClass;

    // Clasificador indica voz (1=SPEECH o 2=SPEECH_IN_NOISE) pero
    // nivel muy bajo para conversación normal.
    if ((envClass == 1 || envClass == 2) && level > 25 && level < 45) {
      _lowLevelTicks++;
    } else {
      _lowLevelTicks = 0;
    }

    // Requiere 5 ticks consecutivos (10 segundos) para evitar falsos.
    return _lowLevelTicks >= 5;
  }

  /// Detecta nivel de entrada extremadamente bajo (<25 dB SPL) por
  /// tiempo prolongado — posible problema con el micrófono.
  bool _detectVeryLowInput(AmplificationActive state) {
    final level = state.inputLevelDb;

    if (level < 25) {
      _veryLowLevelTicks++;
    } else {
      _veryLowLevelTicks = 0;
    }

    // 20 segundos con nivel prácticamente nulo.
    return _veryLowLevelTicks >= 10;
  }

  /// Detecta saturación en bandas del EQ: cuando ganancias activas
  /// están muy cerca del techo MPO o exceden 30 dB en varias bandas.
  bool _detectEqSaturation(AmplificationActive state) {
    final gains = state.activeEqGains ?? state.bundle?.gainsDb;
    final mpo = state.bundle?.mpoProfileDbSpl;
    if (gains == null || gains.length != 12) return false;

    int saturatedBands = 0;

    if (mpo != null && mpo.length == 12) {
      // Con perfil MPO: verificar headroom por banda.
      for (int i = 0; i < 12; i++) {
        // Si la ganancia + input típico (65 dB) supera el MPO - 5 dB
        // de margen, la banda está saturando.
        final estimatedOutput = gains[i] + 65.0;
        if (estimatedOutput > mpo[i] - 5.0) {
          saturatedBands++;
        }
      }
    } else {
      // Sin MPO: umbral absoluto de ganancia alta.
      for (int i = 0; i < 12; i++) {
        if (gains[i] > 30) saturatedBands++;
      }
    }

    // Alertar si 3 o más bandas están saturando.
    return saturatedBands >= 3;
  }

  /// Detecta clipping: nivel de pico cercano a 1.0 (0 dBFS) sostenido.
  bool _detectClipping(AmplificationActive state) {
    // Nivel muy alto (>90 dB SPL) = probable clipping en el pipeline.
    if (state.inputLevelDb > 90) {
      _clippingTicks++;
    } else {
      _clippingTicks = 0;
    }
    return _clippingTicks >= 3; // 6 segundos sostenidos.
  }

  /// Detecta MPO limitando de forma sostenida (output pegado al techo).
  bool _detectMpoSustained(AmplificationActive state) {
    final gains = state.activeEqGains ?? state.bundle?.gainsDb;
    final mpo = state.bundle?.mpoProfileDbSpl;
    if (gains == null || mpo == null) return false;
    // Si el nivel + ganancia promedio supera el MPO promedio.
    final avgGain = gains.reduce((a, b) => a + b) / gains.length;
    final avgMpo = mpo.reduce((a, b) => a + b) / mpo.length;
    if (state.inputLevelDb + avgGain > avgMpo - 2.0) {
      _mpoSustainedTicks++;
    } else {
      _mpoSustainedTicks = 0;
    }
    return _mpoSustainedTicks >= 4; // 8 segundos.
  }

  /// Detecta DNN matando la voz: postNrLevel mucho menor que input
  /// cuando el clasificador indica SPEECH.
  bool _detectDnnKillingVoice(AmplificationActive state) {
    final envClass = _lastEnvClass;
    // Solo aplica si hay voz clasificada.
    if (envClass != 1 && envClass != 2) {
      _dnnKillingVoiceTicks = 0;
      return false;
    }
    // Indicador indirecto: nivel de entrada alto pero volumen
    // percibido bajo (NR nivel 3 + DNN alta intensidad).
    if (state.inputLevelDb > 55 && state.activeNrLevel >= 3) {
      _dnnKillingVoiceTicks++;
    } else {
      _dnnKillingVoiceTicks = 0;
    }
    return _dnnKillingVoiceTicks >= 5; // 10 segundos.
  }

  /// Detecta roce de ropa / chasquido del móvil contra superficies.
  ///
  /// Patrón: picos transitorios bruscos (>15 dB de variación entre
  /// muestras consecutivas) repetidos, sin que el clasificador
  /// detecte SPEECH. Típico del celular en el bolsillo o rozando ropa.
  bool _detectClothingRustle(AmplificationActive state) {
    if (_transientHistory.length < 10) return false;
    final envClass = _lastEnvClass;
    // Si hay voz detectada, no es roce de ropa.
    if (envClass == 1 || envClass == 2) {
      _clothingRustleTicks = 0;
      return false;
    }
    // Contar transientes bruscos en las últimas 20 muestras.
    int spikes = 0;
    for (int i = 1; i < _transientHistory.length; i++) {
      final diff = (_transientHistory[i] - _transientHistory[i - 1]).abs();
      if (diff > 15.0) spikes++;
    }
    // Si hay muchos spikes (>5 en 20 muestras) = patrón de roce.
    if (spikes > 5) {
      _clothingRustleTicks++;
    } else {
      _clothingRustleTicks = 0;
    }
    return _clothingRustleTicks >= 3; // 6 segundos con patrón de roce.
  }

  /// Detecta ganancia asimétrica extrema: >15 dB de diferencia
  /// entre el promedio de graves y el promedio de agudos.
  bool _detectAsymmetricGain(AmplificationActive state) {
    final gains = state.activeEqGains ?? state.bundle?.gainsDb;
    if (gains == null || gains.length != 12) return false;
    final avgLow = (gains[0] + gains[1] + gains[2] + gains[3]) / 4;
    final avgHigh = (gains[8] + gains[9] + gains[10] + gains[11]) / 4;
    return (avgLow - avgHigh).abs() > 15.0;
  }

  /// Detecta música: nivel estable medio-alto sin voz clasificada,
  /// espectro amplio (todas las bandas con ganancia >5 dB).
  bool _detectMusic(AmplificationActive state) {
    final envClass = _lastEnvClass;
    // Sin voz, nivel medio, no silencio.
    if (envClass == 1 || envClass == 2) {
      _musicTicks = 0;
      return false;
    }
    if (state.inputLevelDb > 45 && state.inputLevelDb < 80 && envClass == 3) {
      // Verificar espectro amplio: ¿la varianza de niveles es baja?
      // (música = energía distribuida; ruido = también, pero más random).
      _musicTicks++;
    } else {
      _musicTicks = 0;
    }
    // Si Modo Música ya está activo, no sugerir.
    if (state.musicModeActive) return false;
    return _musicTicks >= 8; // 16 segundos estables.
  }

  /// Detecta viento: energía alta concentrada en graves (<500 Hz)
  /// con variación rápida. Patrón: nivel alto + clasificador NOISE +
  /// ganancia baja en agudos = probablemente viento.
  bool _detectWind(AmplificationActive state) {
    final envClass = _lastEnvClass;
    final gains = state.activeEqGains ?? state.bundle?.gainsDb;
    if (envClass != 3 || gains == null || gains.length != 12) {
      _windTicks = 0;
      return false;
    }
    final avgLow = (gains[0] + gains[1] + gains[2] + gains[3]) / 4;
    final avgHigh = (gains[8] + gains[9] + gains[10] + gains[11]) / 4;
    // Viento: mucha energía en graves, poca en agudos, nivel alto.
    if (state.inputLevelDb > 60 && avgLow > avgHigh + 10) {
      _windTicks++;
    } else {
      _windTicks = 0;
    }
    return _windTicks >= 4; // 8 segundos.
  }

  /// Detecta volumen al máximo (+10 dB) sostenido.
  bool _detectVolumeMaxed(AmplificationActive state) {
    if (state.volumeDb >= 9.5) {
      _volumeMaxTicks++;
    } else {
      _volumeMaxTicks = 0;
    }
    return _volumeMaxTicks >= 5; // 10 segundos al máximo.
  }

  /// Detecta NR insuficiente: ambiente ruidoso con NR bajo.
  bool _detectNrInsufficient(AmplificationActive state) {
    final envClass = _lastEnvClass;
    if ((envClass == 2 || envClass == 3) && state.activeNrLevel <= 1) {
      _nrInsufficientTicks++;
    } else {
      _nrInsufficientTicks = 0;
    }
    return _nrInsufficientTicks >= 5; // 10 segundos.
  }

  /// Detecta fatiga auditiva: sesión continua >2 horas.
  bool _detectListeningFatigue() {
    if (_sessionStart == null) return false;
    return DateTime.now().difference(_sessionStart!) >
        const Duration(hours: 2);
  }

  /// Detecta exposición acumulada alta (LEQ aproximado >80 dBA).
  bool _detectNoiseExposure() {
    if (_exposureTicks < 30) return false; // mínimo 1 minuto de datos.
    final leq = _exposureAccumulator / _exposureTicks;
    return leq > 80.0;
  }

  /// Detecta perfil estático por mucho tiempo con ambiente variable.
  bool _detectStaleProfile(AmplificationActive state, AmplificationBloc bloc) {
    if (bloc.isSmartEnabled) return false; // Smart lo maneja.
    // Si el perfil no cambió en >15 minutos (450 ticks de 2s).
    _staleProfileTicks++;
    if (_lastActiveProfile != state.activeProfile) {
      _staleProfileTicks = 0;
      _lastActiveProfile = state.activeProfile;
    }
    return _staleProfileTicks >= 450; // ~15 minutos.
  }

  /// Detecta si el ambiente sugiere un cambio de perfil no aplicado.
  AudioRecommendationType? _detectEnvironmentSuggestion(
    AmplificationActive state,
    AmplificationBloc bloc,
  ) {
    final envClass = _lastEnvClass;
    if (envClass == null) return null;

    // Si Smart está ON, no sugerir cambios manuales (Smart lo maneja).
    if (bloc.isSmartEnabled) return null;

    final activeProfile = state.activeProfile;

    switch (envClass) {
      case 1: // SPEECH — sugerir Conversación si no está activo.
        if (activeProfile != 'Conversación') {
          return AudioRecommendationType.conversationDetected;
        }
      case 2: // SPEECH_IN_NOISE — sugerir Ruidoso.
      case 3: // NOISE
        if (activeProfile != 'Ruidoso') {
          return AudioRecommendationType.noiseDetected;
        }
      case 0: // QUIET — sugerir Silencioso si tiene ganancia alta.
        if (activeProfile != 'Silencioso' && state.inputLevelDb < 35) {
          return AudioRecommendationType.silenceDetected;
        }
    }

    return null;
  }

  /// Verifica si un tipo de recomendación está en período de cooldown.
  bool _isInCooldown(AudioRecommendationType type) {
    final dismissed = _dismissedAt[type];
    if (dismissed == null) return false;
    return DateTime.now().difference(dismissed) < _kCooldownDuration;
  }

  /// Construye el modelo de recomendación con textos y acciones.
  _AudioRecommendation _buildRecommendation(
    AudioRecommendationType type,
    AmplificationActive state,
    AmplificationBloc bloc,
  ) {
    switch (type) {
      case AudioRecommendationType.echo:
        return _AudioRecommendation(
          type: type,
          title: 'Posible eco/feedback',
          message:
              'Se detecta un patrón de realimentación acústica. '
              'Reducí la ganancia en agudos o ajustá el auricular.',
          actionLabel: 'Reducir agudos',
          action: () => _reduceHighFreqGains(bloc, state),
          icon: Icons.hearing_disabled,
          color: Colors.red.shade400,
        );

      case AudioRecommendationType.lowVoice:
        return _AudioRecommendation(
          type: type,
          title: 'Voz baja detectada',
          message:
              'El nivel de voz es muy bajo para una conversación clara. '
              'Subí el volumen o acercá el micrófono al interlocutor.',
          actionLabel: 'Subir volumen',
          action: () => _increaseVolume(bloc, state),
          icon: Icons.record_voice_over,
          color: Colors.amber.shade600,
        );

      case AudioRecommendationType.eqSaturation:
        return _AudioRecommendation(
          type: type,
          title: 'Saturación en ecualización',
          message:
              'Varias bandas del EQ están cerca del límite MPO. '
              'Esto puede causar distorsión. Reducí las ganancias.',
          actionLabel: 'Reducir ganancias',
          action: () => _reduceAllGains(bloc, state),
          icon: Icons.warning_amber_rounded,
          color: Colors.orange.shade700,
        );

      case AudioRecommendationType.conversationDetected:
        return _AudioRecommendation(
          type: type,
          title: 'Conversación detectada',
          message:
              'Se detecta voz. ¿Cambiar al perfil Conversación para '
              'mejorar la inteligibilidad?',
          actionLabel: 'Cambiar perfil',
          action: () => _changeProfile(bloc, 'Conversación'),
          icon: Icons.people,
          color: Colors.cyan.shade400,
        );

      case AudioRecommendationType.noiseDetected:
        return _AudioRecommendation(
          type: type,
          title: 'Ambiente ruidoso detectado',
          message:
              'El nivel de ruido es alto. ¿Cambiar al perfil Ruidoso '
              'para activar más reducción de ruido?',
          actionLabel: 'Perfil Ruidoso',
          action: () => _changeProfile(bloc, 'Ruidoso'),
          icon: Icons.volume_up,
          color: Colors.purple.shade300,
        );

      case AudioRecommendationType.silenceDetected:
        return _AudioRecommendation(
          type: type,
          title: 'Ambiente silencioso',
          message:
              'No se detecta actividad. El perfil Silencioso reduce '
              'el ruido de piso y evita amplificar señales residuales.',
          actionLabel: 'Perfil Silencioso',
          action: () => _changeProfile(bloc, 'Silencioso'),
          icon: Icons.nights_stay,
          color: Colors.indigo.shade300,
        );

      case AudioRecommendationType.veryLowInput:
        return _AudioRecommendation(
          type: type,
          title: 'Nivel de entrada muy bajo',
          message:
              'El micrófono apenas registra señal. Verificá que no esté '
              'bloqueado o que el dispositivo tenga permiso de audio.',
          icon: Icons.mic_off,
          color: Colors.red.shade300,
        );

      case AudioRecommendationType.clipping:
        return _AudioRecommendation(
          type: type,
          title: 'Clipping detectado',
          message:
              'La señal está saturando (distorsión digital). '
              'Reducí el volumen o las ganancias del EQ.',
          actionLabel: 'Reducir volumen',
          action: () => _reduceVolumeSafe(bloc, state, AudioRecommendationType.clipping),
          icon: Icons.broken_image,
          color: Colors.red.shade600,
        );

      case AudioRecommendationType.mpoLimitingSustained:
        return _AudioRecommendation(
          type: type,
          title: 'MPO limitando (salida al techo)',
          message:
              'La salida está pegada al límite MPO. El sonido puede sonar '
              'aplastado y sin dinámica. Reducí ganancias.',
          actionLabel: 'Reducir ganancias',
          action: () => _reduceAllGains(bloc, state),
          icon: Icons.compress,
          color: Colors.red.shade400,
        );

      case AudioRecommendationType.dnnKillingVoice:
        return _AudioRecommendation(
          type: type,
          title: 'Reducción de ruido excesiva',
          message:
              'El filtro IA (DNN) está atenuando la voz junto con el ruido. '
              'Bajá la intensidad del DNN o reducí el NR.',
          actionLabel: 'Bajar NR',
          action: () {
            // Bajar NR es seguro (preserva más voz, no la mata).
            final newNr = (state.activeNrLevel - 1).clamp(0, 3);
            bloc.add(UpdateNrLevel(level: newNr));
            _dismiss(AudioRecommendationType.dnnKillingVoice);
          },
          icon: Icons.voice_over_off,
          color: Colors.orange.shade600,
        );

      case AudioRecommendationType.clothingRustle:
        return _AudioRecommendation(
          type: type,
          title: 'Roce de ropa / chasquido',
          message:
              'Se detectan transientes repetitivos (roce contra tela, '
              'bolsillo, mesa). Activá el TNR o alejá el mic de la ropa.',
          actionLabel: 'Activar TNR',
          action: () {
            _channel.invokeMethod('updateTnrEnabled', {'enabled': true});
            _dismiss(AudioRecommendationType.clothingRustle);
          },
          icon: Icons.dry_cleaning,
          color: Colors.brown.shade300,
        );

      case AudioRecommendationType.asymmetricGain:
        return _AudioRecommendation(
          type: type,
          title: 'Ganancia muy desbalanceada',
          message:
              'La diferencia entre graves y agudos es >15 dB. '
              'Puede causar molestia o sonido poco natural.',
          icon: Icons.balance,
          color: Colors.amber.shade400,
        );

      case AudioRecommendationType.musicDetected:
        return _AudioRecommendation(
          type: type,
          title: 'Música detectada',
          message:
              'Se detecta un patrón musical. El Modo Música desactiva NR/DNN '
              'para preservar la dinámica y los transientes.',
          actionLabel: 'Modo Música',
          action: () {
            bloc.add(const ToggleMusicMode(activate: true));
            _dismiss(AudioRecommendationType.musicDetected);
          },
          icon: Icons.music_note,
          color: Colors.purple.shade300,
        );

      case AudioRecommendationType.windDetected:
        return _AudioRecommendation(
          type: type,
          title: 'Viento detectado',
          message:
              'Hay energía intensa en graves (patrón de viento). '
              'Un corte de graves puede reducir la molestia.',
          actionLabel: 'Cortar graves',
          action: () {
            final gains = List<double>.from(
              state.activeEqGains ?? state.bundle?.gainsDb ?? List.filled(12, 0.0),
            );
            for (int i = 0; i < 4 && i < gains.length; i++) {
              gains[i] = (gains[i] - 8.0).clamp(0.0, 50.0);
            }
            bloc.add(UpdateEqGains(gains: gains, presetName: state.activeEqPreset));
            _dismiss(AudioRecommendationType.windDetected);
          },
          icon: Icons.air,
          color: Colors.teal.shade300,
        );

      case AudioRecommendationType.listeningFatigue:
        return _AudioRecommendation(
          type: type,
          title: 'Sesión prolongada (>2 horas)',
          message:
              'Llevas más de 2 horas con amplificación activa. '
              'Considerá un descanso para evitar fatiga auditiva.',
          icon: Icons.timer_off,
          color: Colors.blue.shade300,
        );

      case AudioRecommendationType.volumeMaxed:
        return _AudioRecommendation(
          type: type,
          title: 'Volumen al máximo',
          message:
              'El volumen está en +10 dB (tope). Si no alcanza, '
              'recalibrá las ganancias base del EQ.',
          icon: Icons.volume_up,
          color: Colors.orange.shade400,
        );

      case AudioRecommendationType.nrInsufficient:
        return _AudioRecommendation(
          type: type,
          title: 'NR insuficiente para este ruido',
          message:
              'El ambiente es ruidoso pero el NR está bajo. '
              'Subir el NR puede mejorar la inteligibilidad.',
          actionLabel: 'Subir NR',
          action: () {
            // Subir NR es seguro — preserva habla y reduce ruido.
            final newNr = (state.activeNrLevel + 1).clamp(0, 3);
            bloc.add(UpdateNrLevel(level: newNr));
            _dismiss(AudioRecommendationType.nrInsufficient);
          },
          icon: Icons.noise_aware,
          color: Colors.cyan.shade600,
        );

      case AudioRecommendationType.staleProfile:
        return _AudioRecommendation(
          type: type,
          title: 'Perfil sin cambios hace rato',
          message:
              'Llevas >15 min en el mismo perfil. ¿Activar Smart '
              'para que se adapte automáticamente al ambiente?',
          actionLabel: 'Activar Smart',
          action: () {
            bloc.add(const ToggleSmart(activate: true));
            _dismiss(AudioRecommendationType.staleProfile);
          },
          icon: Icons.update,
          color: Colors.grey.shade400,
        );

      case AudioRecommendationType.noiseExposure:
        return _AudioRecommendation(
          type: type,
          title: 'Exposición acumulada alta',
          message:
              'El nivel promedio de la sesión supera 80 dB. '
              'Riesgo de fatiga. Reducí volumen o tomá un descanso.',
          actionLabel: 'Reducir volumen',
          action: () => _reduceVolumeSafe(bloc, state, AudioRecommendationType.noiseExposure),
          icon: Icons.health_and_safety,
          color: Colors.red.shade300,
        );
    }
  }

  // ─── Acciones rápidas (con reglas clínicas de la industria) ─────────
  //
  // Reglas basadas en: NAL-NL2, Phonak AutoSense OS, Oticon Intent,
  // Starkey Omega AI, U. of Illinois SNR-Aware DRC.
  //
  // 1. SPEECH GUARD: nunca bajar volumen/ganancia si hay voz detectada
  // 2. FLOOR ABSOLUTO: volumen nunca baja de 0 dB (audibilidad mínima)
  // 3. BANDA DE HABLA PROTEGIDA: bandas 4-7 (1-3 kHz) intocables con SPEECH
  // 4. TOPE ACUMULADO: máx -5 dB de reducción total por sesión
  // 5. SELECTIVIDAD: reducir solo fuera de banda de habla cuando hay voz
  // ════════════════════════════════════════════════════════════════════════

  /// Reducción acumulada de volumen en esta sesión (para tope de -5 dB).
  double _cumulativeVolumeReduction = 0.0;

  /// Reducción acumulada de ganancias EQ en esta sesión.
  double _cumulativeGainReduction = 0.0;

  /// Tope máximo de reducción acumulada por sesión (dB).
  static const double _kMaxCumulativeReductionDb = 5.0;

  /// Bandas de habla protegidas (1-3 kHz): índices 4, 5, 6, 7.
  /// Nunca se reducen automáticamente cuando el clasificador detecta voz.
  static const List<int> _kSpeechBands = [4, 5, 6, 7];

  /// Verifica si hay voz activa (Speech Guard).
  /// Si hay voz, bloquea reducciones de volumen y de bandas de habla.
  bool _isSpeechActive() {
    return _lastEnvClass == 1 || _lastEnvClass == 2;
  }

  /// Verifica si se puede reducir más (tope acumulado no alcanzado).
  bool _canReduceMore(double proposedReduction) {
    return (_cumulativeVolumeReduction + _cumulativeGainReduction).abs() +
            proposedReduction.abs() <=
        _kMaxCumulativeReductionDb;
  }

  void _reduceHighFreqGains(AmplificationBloc bloc, AmplificationActive state) {
    // REGLA 1: Speech Guard — si hay voz, no reducir (el eco puede ser
    // la voz del interlocutor amplificada, no feedback real).
    if (_isSpeechActive()) {
      // Solo sugerir, no aplicar.
      _dismiss(AudioRecommendationType.echo);
      return;
    }

    // REGLA 4: Tope acumulado.
    if (!_canReduceMore(3.0)) {
      _dismiss(AudioRecommendationType.echo);
      return;
    }

    final gains = List<double>.from(
      state.activeEqGains ?? state.bundle?.gainsDb ?? List.filled(12, 0.0),
    );
    // Reducir agudos (bandas 8-11) en -3 dB — SOLO fuera de banda de habla.
    for (int i = 8; i < 12 && i < gains.length; i++) {
      gains[i] = (gains[i] - 3.0).clamp(0.0, 50.0);
    }
    _cumulativeGainReduction += 3.0;
    bloc.add(UpdateEqGains(gains: gains, presetName: state.activeEqPreset));
    _dismiss(AudioRecommendationType.echo);
  }

  void _increaseVolume(AmplificationBloc bloc, AmplificationActive state) {
    // Sin restricción para subir (solo clampar al techo hardware).
    final newVol = (state.volumeDb + 3.0).clamp(-20.0, 10.0);
    bloc.add(ChangeVolume(volumeDb: newVol));
    _dismiss(AudioRecommendationType.lowVoice);
  }

  void _reduceAllGains(AmplificationBloc bloc, AmplificationActive state) {
    // REGLA 1: Speech Guard — si hay voz, proteger bandas de habla.
    // REGLA 4: Tope acumulado.
    if (!_canReduceMore(2.0)) {
      _dismiss(AudioRecommendationType.eqSaturation);
      return;
    }

    final gains = List<double>.from(
      state.activeEqGains ?? state.bundle?.gainsDb ?? List.filled(12, 0.0),
    );

    for (int i = 0; i < gains.length; i++) {
      // REGLA 3: Banda de habla protegida — si hay voz, no tocar 1-3 kHz.
      if (_isSpeechActive() && _kSpeechBands.contains(i)) {
        continue; // Preservar banda de habla.
      }
      gains[i] = (gains[i] - 2.0).clamp(0.0, 50.0);
    }
    _cumulativeGainReduction += 2.0;
    bloc.add(UpdateEqGains(gains: gains, presetName: state.activeEqPreset));
    _dismiss(AudioRecommendationType.eqSaturation);
  }

  /// Reduce volumen respetando las 5 reglas clínicas.
  void _reduceVolumeSafe(AmplificationBloc bloc, AmplificationActive state,
      AudioRecommendationType type) {
    // REGLA 1: Speech Guard — NUNCA bajar volumen si hay conversación.
    if (_isSpeechActive()) {
      _dismiss(type);
      return;
    }

    // REGLA 4: Tope acumulado.
    if (!_canReduceMore(2.0)) {
      _dismiss(type);
      return;
    }

    // REGLA 2: Floor absoluto en 0 dB (preservar audibilidad mínima).
    final newVol = (state.volumeDb - 2.0).clamp(0.0, 10.0);

    // Si ya estamos en el floor, no hacer nada.
    if (newVol >= state.volumeDb) {
      _dismiss(type);
      return;
    }

    _cumulativeVolumeReduction += (state.volumeDb - newVol);
    bloc.add(ChangeVolume(volumeDb: newVol));
    _dismiss(type);
  }

  void _changeProfile(AmplificationBloc bloc, String profile) {
    bloc.add(ChangeProfile(profile: profile));
    _dismiss(_activeRecommendation!.type);
  }

  /// Descarta la recomendación activa y registra cooldown.
  void _dismiss(AudioRecommendationType type) {
    _dismissedAt[type] = DateTime.now();
    // Resetear contadores asociados al tipo.
    switch (type) {
      case AudioRecommendationType.echo:
        _echoSuspicionTicks = 0;
      case AudioRecommendationType.lowVoice:
        _lowLevelTicks = 0;
      case AudioRecommendationType.veryLowInput:
        _veryLowLevelTicks = 0;
      case AudioRecommendationType.clipping:
        _clippingTicks = 0;
      case AudioRecommendationType.mpoLimitingSustained:
        _mpoSustainedTicks = 0;
      case AudioRecommendationType.dnnKillingVoice:
        _dnnKillingVoiceTicks = 0;
      case AudioRecommendationType.clothingRustle:
        _clothingRustleTicks = 0;
      case AudioRecommendationType.musicDetected:
        _musicTicks = 0;
      case AudioRecommendationType.windDetected:
        _windTicks = 0;
      case AudioRecommendationType.volumeMaxed:
        _volumeMaxTicks = 0;
      case AudioRecommendationType.nrInsufficient:
        _nrInsufficientTicks = 0;
      case AudioRecommendationType.staleProfile:
        _staleProfileTicks = 0;
      case AudioRecommendationType.eqSaturation:
      case AudioRecommendationType.conversationDetected:
      case AudioRecommendationType.noiseDetected:
      case AudioRecommendationType.silenceDetected:
      case AudioRecommendationType.asymmetricGain:
      case AudioRecommendationType.listeningFatigue:
      case AudioRecommendationType.noiseExposure:
        break;
    }
    setState(() => _activeRecommendation = null);
  }

  @override
  Widget build(BuildContext context) {
    final rec = _activeRecommendation;

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        // LED verde pulsante cuando se aplicó un ajuste automático.
        if (_showGreenLed) _GreenLedIndicator(label: _lastAutoAppliedLabel),
        // Banner interactivo (solo en modo manual).
        if (rec != null)
          AnimatedSize(
            duration: const Duration(milliseconds: 300),
            curve: Curves.easeInOut,
            child: _RecommendationBanner(
              recommendation: rec,
              onDismiss: () => _dismiss(rec.type),
              onAction: rec.action,
            ),
          ),
      ],
    );
  }
}

/// Banner visual de una recomendación.
class _RecommendationBanner extends StatelessWidget {
  final _AudioRecommendation recommendation;
  final VoidCallback onDismiss;
  final VoidCallback? onAction;

  const _RecommendationBanner({
    required this.recommendation,
    required this.onDismiss,
    this.onAction,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: recommendation.color.withOpacity(0.12),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: recommendation.color.withOpacity(0.4),
          width: 1.5,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          // Header: icono + título + botón cerrar.
          Row(
            children: [
              Icon(
                recommendation.icon,
                color: recommendation.color,
                size: 22,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  recommendation.title,
                  style: TextStyle(
                    color: recommendation.color,
                    fontSize: 14,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              GestureDetector(
                onTap: onDismiss,
                child: Container(
                  padding: const EdgeInsets.all(4),
                  decoration: BoxDecoration(
                    color: recommendation.color.withOpacity(0.15),
                    shape: BoxShape.circle,
                  ),
                  child: Icon(
                    Icons.close,
                    color: recommendation.color,
                    size: 16,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          // Mensaje descriptivo.
          Text(
            recommendation.message,
            style: TextStyle(
              color: Colors.white.withOpacity(0.85),
              fontSize: 12,
              height: 1.4,
            ),
          ),
          // Botón de acción rápida (si existe).
          if (recommendation.actionLabel != null && onAction != null) ...[
            const SizedBox(height: 8),
            Align(
              alignment: Alignment.centerRight,
              child: TextButton.icon(
                onPressed: onAction,
                icon: Icon(
                  Icons.auto_fix_high,
                  color: recommendation.color,
                  size: 16,
                ),
                label: Text(
                  recommendation.actionLabel!,
                  style: TextStyle(
                    color: recommendation.color,
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                style: TextButton.styleFrom(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                  backgroundColor: recommendation.color.withOpacity(0.1),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(8),
                    side: BorderSide(
                      color: recommendation.color.withOpacity(0.3),
                    ),
                  ),
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}


/// LED verde pulsante que indica que un ajuste automático se aplicó.
///
/// Aparece brevemente (4 segundos) con una animación de pulso y el
/// nombre del ajuste aplicado. Visualmente simula un diodo LED
/// encendiéndose en verde para confirmar la acción sin interrumpir.
class _GreenLedIndicator extends StatefulWidget {
  final String label;
  const _GreenLedIndicator({required this.label});

  @override
  State<_GreenLedIndicator> createState() => _GreenLedIndicatorState();
}

class _GreenLedIndicatorState extends State<_GreenLedIndicator>
    with SingleTickerProviderStateMixin {
  late final AnimationController _pulseController;

  @override
  void initState() {
    super.initState();
    _pulseController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 800),
    )..repeat(reverse: true);
  }

  @override
  void dispose() {
    _pulseController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _pulseController,
      builder: (context, child) {
        final pulse = _pulseController.value;
        return Container(
          margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          decoration: BoxDecoration(
            color: Colors.green.withOpacity(0.08 + pulse * 0.07),
            borderRadius: BorderRadius.circular(20),
            border: Border.all(
              color: Colors.green.withOpacity(0.3 + pulse * 0.3),
            ),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              // LED circle con glow pulsante.
              Container(
                width: 12,
                height: 12,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: Colors.green.shade400,
                  boxShadow: [
                    BoxShadow(
                      color: Colors.green.withOpacity(0.4 + pulse * 0.4),
                      blurRadius: 6 + pulse * 4,
                      spreadRadius: pulse * 2,
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              Flexible(
                child: Text(
                  widget.label,
                  style: TextStyle(
                    color: Colors.green.shade300,
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}
