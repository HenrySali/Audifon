import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

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

  /// Canal para consultar métricas DSP.
  static const _channel = MethodChannel('com.psk.hearing_aid/audio');

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
      setState(() {
        _activeRecommendation = recommendation != null
            ? _buildRecommendation(recommendation, state, bloc)
            : null;
      });
    }
  }

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
    }
  }

  // ─── Acciones rápidas ──────────────────────────────────────────────

  void _reduceHighFreqGains(AmplificationBloc bloc, AmplificationActive state) {
    final gains = List<double>.from(
      state.activeEqGains ?? state.bundle?.gainsDb ?? List.filled(12, 0.0),
    );
    // Reducir agudos (bandas 8-11) en -5 dB.
    for (int i = 8; i < 12 && i < gains.length; i++) {
      gains[i] = (gains[i] - 5.0).clamp(0.0, 50.0);
    }
    bloc.add(UpdateEqGains(gains: gains, presetName: state.activeEqPreset));
    _dismiss(AudioRecommendationType.echo);
  }

  void _increaseVolume(AmplificationBloc bloc, AmplificationActive state) {
    final newVol = (state.volumeDb + 3.0).clamp(-20.0, 10.0);
    bloc.add(ChangeVolume(volumeDb: newVol));
    _dismiss(AudioRecommendationType.lowVoice);
  }

  void _reduceAllGains(AmplificationBloc bloc, AmplificationActive state) {
    final gains = List<double>.from(
      state.activeEqGains ?? state.bundle?.gainsDb ?? List.filled(12, 0.0),
    );
    // Reducir todas las bandas en -3 dB.
    for (int i = 0; i < gains.length; i++) {
      gains[i] = (gains[i] - 3.0).clamp(0.0, 50.0);
    }
    bloc.add(UpdateEqGains(gains: gains, presetName: state.activeEqPreset));
    _dismiss(AudioRecommendationType.eqSaturation);
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
      case AudioRecommendationType.eqSaturation:
      case AudioRecommendationType.conversationDetected:
      case AudioRecommendationType.noiseDetected:
      case AudioRecommendationType.silenceDetected:
        break;
    }
    setState(() => _activeRecommendation = null);
  }

  @override
  Widget build(BuildContext context) {
    final rec = _activeRecommendation;
    if (rec == null) return const SizedBox.shrink();

    return AnimatedSize(
      duration: const Duration(milliseconds: 300),
      curve: Curves.easeInOut,
      child: _RecommendationBanner(
        recommendation: rec,
        onDismiss: () => _dismiss(rec.type),
        onAction: rec.action,
      ),
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
