import 'dart:async';

import 'package:flutter_bloc/flutter_bloc.dart';

import '../../data/bridges/audio_bridge.dart';
import '../../domain/entities/audio_config.dart';
import '../../domain/entities/audiogram.dart';
import '../../domain/entities/environment_profile.dart';
import '../../domain/entities/wdrc_params.dart';
import '../../domain/gain_prescriber.dart';
import '../../domain/repositories/audiogram_repository.dart';
import '../../domain/repositories/profile_repository.dart';
import '../../domain/repositories/settings_repository.dart';
import 'amplification_event.dart';
import 'amplification_state.dart';

/// BLoC de amplificación — gestiona el ciclo de vida completo del
/// procesamiento de audio en tiempo real.
///
/// Máquina de estados:
/// ```
/// Idle → Starting → Active ⇄ Paused
///                  ↘ Error → Idle
/// ```
///
/// Dependencias:
/// - [AudioBridge]: comunicación con el motor DSP nativo
/// - [AudiogramRepository]: persistencia del audiograma del usuario
/// - [ProfileRepository]: perfiles de entorno (Silencioso, Conversación, Ruidoso)
/// - [SettingsRepository]: configuración persistente (último perfil, volumen)
/// - [GainPrescriber]: cálculo de ganancias NAL-NL2
///
/// Requisitos: 1.1, 1.3, 3.3, 3.4, 5.2, 6.2, 6.3, 8.2, 8.5
class AmplificationBloc
    extends Bloc<AmplificationEvent, AmplificationState> {
  final AudioBridge _audioBridge;
  final AudiogramRepository _audiogramRepository;
  final ProfileRepository _profileRepository;
  final SettingsRepository _settingsRepository;
  final GainPrescriber _gainPrescriber;

  /// Expone el repositorio de audiograma para consultas desde la UI.
  AudiogramRepository get audiogramRepository => _audiogramRepository;

  /// Expone el repositorio de perfiles para consultas desde la UI.
  ProfileRepository get profileRepository => _profileRepository;

  /// Suscripción al stream de nivel de entrada (~10 Hz).
  StreamSubscription<double>? _inputLevelSubscription;

  /// Suscripción al stream de estado del engine nativo.
  StreamSubscription<AudioEngineState>? _engineStateSubscription;

  /// Audiograma actual en uso.
  Audiogram? _currentAudiogram;

  /// Perfil activo actual.
  EnvironmentProfile? _currentProfile;

  /// Volumen actual en dB.
  double _currentVolumeDb = 0.0;

  /// Estado de conexión de auriculares.
  bool _headphonesConnected = true;

  AmplificationBloc({
    required AudioBridge audioBridge,
    required AudiogramRepository audiogramRepository,
    required ProfileRepository profileRepository,
    required SettingsRepository settingsRepository,
    required GainPrescriber gainPrescriber,
  })  : _audioBridge = audioBridge,
        _audiogramRepository = audiogramRepository,
        _profileRepository = profileRepository,
        _settingsRepository = settingsRepository,
        _gainPrescriber = gainPrescriber,
        super(const AmplificationIdle()) {
    on<StartAmplification>(_onStartAmplification);
    on<StopAmplification>(_onStopAmplification);
    on<ChangeProfile>(_onChangeProfile);
    on<ChangeVolume>(_onChangeVolume);
    on<UpdateAudiogram>(_onUpdateAudiogram);
    on<HeadphonesStateChanged>(_onHeadphonesStateChanged);
    on<AudioFocusChanged>(_onAudioFocusChanged);
    on<InputLevelUpdated>(_onInputLevelUpdated);
    on<ResumeAmplification>(_onResumeAmplification);
    on<UpdateEqGains>(_onUpdateEqGains);
    on<UpdateNrLevel>(_onUpdateNrLevel);
    on<SaveCustomPreset>(_onSaveCustomPreset);
    on<DeleteCustomPreset>(_onDeleteCustomPreset);
  }

  /// Inicia la amplificación: permisos → auriculares → foco → servicio.
  ///
  /// Flujo completo en < 500 ms (Req 5.2).
  Future<void> _onStartAmplification(
    StartAmplification event,
    Emitter<AmplificationState> emit,
  ) async {
    if (state is AmplificationActive || state is AmplificationStarting) {
      return;
    }

    emit(const AmplificationStarting());

    try {
      // 1. Cargar audiograma (o usar default)
      _currentAudiogram = await _audiogramRepository.getAudiogram() ??
          Audiogram.defaultAudiogram();

      // 2. Cargar último perfil y volumen
      final lastConfig = await _settingsRepository.restoreLastConfig();
      final profileName = lastConfig.lastProfile ?? 'Conversación';
      _currentVolumeDb = lastConfig.lastVolume ?? 0.0;

      // 3. Obtener perfil
      _currentProfile =
          await _profileRepository.getProfileByName(profileName) ??
              EnvironmentProfile.conversation;

      // 4. Calcular ganancias NAL-NL2
      final eqGains =
          _gainPrescriber.prescribeFromAudiogram(_currentAudiogram!);

      // 5. Construir AudioConfig
      final config = AudioConfig(
        eqGains: eqGains,
        volumeDb: _currentVolumeDb,
        wdrcParams: WdrcParams(
          expansionKnee: _currentProfile!.expansionKnee,
          compressionKnee: _currentProfile!.compressionKnee,
          compressionRatio: _currentProfile!.compressionRatio,
        ),
        nrLevel: _currentProfile!.nrLevel,
      );

      // 6. Iniciar el motor de audio nativo
      await _audioBridge.startAudio(config);

      // 7. Suscribirse a streams del engine
      _subscribeToStreams();

      // 8. Emitir estado activo
      emit(AmplificationActive(
        inputLevelDb: 0.0,
        activeProfile: _currentProfile!.name,
        volumeDb: _currentVolumeDb,
        headphonesConnected: _headphonesConnected,
      ));
    } catch (e) {
      emit(AmplificationError(message: e.toString()));
    }
  }

  /// Detiene la amplificación y libera recursos.
  ///
  /// Debe completarse en < 100 ms (Req 1.3).
  Future<void> _onStopAmplification(
    StopAmplification event,
    Emitter<AmplificationState> emit,
  ) async {
    _cancelSubscriptions();

    try {
      await _audioBridge.stopAudio();
    } catch (_) {
      // Ignorar errores al detener — siempre volver a Idle
    }

    emit(const AmplificationIdle());
  }

  /// Cambia el perfil de entorno con crossfade de 10 ms.
  ///
  /// Actualiza WDRC params y NR level sin interrumpir el audio (Req 8.2).
  /// Persiste el nuevo perfil en settings (Req 8.4).
  Future<void> _onChangeProfile(
    ChangeProfile event,
    Emitter<AmplificationState> emit,
  ) async {
    final currentState = state;
    if (currentState is! AmplificationActive) return;

    try {
      // Obtener el nuevo perfil
      final newProfile =
          await _profileRepository.getProfileByName(event.profile);
      if (newProfile == null) return;

      _currentProfile = newProfile;

      // Aplicar parámetros WDRC del nuevo perfil (crossfade 10 ms en nativo)
      await _audioBridge.updateWdrcParams(WdrcParams(
        expansionKnee: newProfile.expansionKnee,
        compressionKnee: newProfile.compressionKnee,
        compressionRatio: newProfile.compressionRatio,
      ));

      // Aplicar nivel de NR del nuevo perfil
      await _audioBridge.updateNrLevel(newProfile.nrLevel);

      // Persistir selección
      await _settingsRepository.setLastProfile(newProfile.name);

      // Emitir estado actualizado
      emit(currentState.copyWith(activeProfile: newProfile.name));
    } catch (e) {
      // No interrumpir la amplificación por error de cambio de perfil
      // El perfil anterior sigue activo
    }
  }

  /// Cambia el volumen maestro en < 50 ms sin artefactos (Req 8.5).
  ///
  /// Persiste el nuevo volumen en settings.
  Future<void> _onChangeVolume(
    ChangeVolume event,
    Emitter<AmplificationState> emit,
  ) async {
    final currentState = state;
    if (currentState is! AmplificationActive) return;

    // Clampar al rango válido
    final volumeDb = event.volumeDb.clamp(-20.0, 10.0);
    _currentVolumeDb = volumeDb;

    try {
      // Aplicar al engine nativo
      await _audioBridge.updateVolume(volumeDb);

      // Persistir
      await _settingsRepository.setLastVolume(volumeDb);

      // Emitir estado actualizado
      emit(currentState.copyWith(volumeDb: volumeDb));
    } catch (e) {
      // No interrumpir por error de volumen
    }
  }

  /// Actualiza el audiograma y recalcula la prescripción NAL-NL2.
  ///
  /// Aplica las nuevas ganancias EQ sin reiniciar la sesión (Req 4.3).
  Future<void> _onUpdateAudiogram(
    UpdateAudiogram event,
    Emitter<AmplificationState> emit,
  ) async {
    // Convertir lista de puntos a Audiogram
    final thresholds = <int, double>{};
    for (final point in event.audiogram) {
      thresholds[point.frequencyHz] = point.thresholdHL;
    }
    final newAudiogram = Audiogram(thresholds: thresholds);
    _currentAudiogram = newAudiogram;

    // Persistir el nuevo audiograma
    await _audiogramRepository.saveAudiogram(newAudiogram);

    // Si estamos activos, recalcular y aplicar ganancias
    if (state is AmplificationActive) {
      try {
        final newGains =
            _gainPrescriber.prescribeFromAudiogram(newAudiogram);
        await _audioBridge.updateEqGains(newGains);
      } catch (e) {
        // No interrumpir por error de actualización de EQ
      }
    }
  }

  /// Maneja cambio de estado de auriculares.
  ///
  /// Desconexión → Paused(btDisconnected) (Req 3.3).
  /// Reconexión → ofrece reanudar (Req 3.4).
  Future<void> _onHeadphonesStateChanged(
    HeadphonesStateChanged event,
    Emitter<AmplificationState> emit,
  ) async {
    _headphonesConnected = event.connected;

    final currentState = state;

    if (!event.connected && currentState is AmplificationActive) {
      // Auriculares desconectados durante amplificación activa → pausar
      _cancelSubscriptions();

      try {
        await _audioBridge.stopAudio();
      } catch (_) {}

      emit(AmplificationPaused(
        reason: PauseReason.btDisconnected,
        lastActiveProfile: currentState.activeProfile,
        lastVolumeDb: currentState.volumeDb,
      ));
    } else if (event.connected && currentState is AmplificationPaused) {
      if (currentState.reason == PauseReason.btDisconnected) {
        // Auriculares reconectados — ofrecer reanudar
        // El estado Paused con headphones reconectados indica al UI
        // que puede mostrar opción de reanudar. El usuario decide
        // enviando ResumeAmplification.
        // Mantenemos el estado Paused hasta que el usuario confirme.
      }
    }
  }

  /// Maneja cambio de foco de audio.
  ///
  /// Foco perdido → Paused(audioFocusLost) (Req 6.2).
  /// Foco recuperado → ofrece reanudar (Req 6.3).
  Future<void> _onAudioFocusChanged(
    AudioFocusChanged event,
    Emitter<AmplificationState> emit,
  ) async {
    final currentState = state;

    if (!event.hasFocus && currentState is AmplificationActive) {
      // Foco de audio perdido durante amplificación activa → pausar
      _cancelSubscriptions();

      try {
        await _audioBridge.stopAudio();
      } catch (_) {}

      emit(AmplificationPaused(
        reason: PauseReason.audioFocusLost,
        lastActiveProfile: currentState.activeProfile,
        lastVolumeDb: currentState.volumeDb,
      ));
    } else if (event.hasFocus && currentState is AmplificationPaused) {
      if (currentState.reason == PauseReason.audioFocusLost) {
        // Foco recuperado — ofrecer reanudar
        // Similar a BT: mantenemos Paused hasta que el usuario confirme.
      }
    }
  }

  /// Actualiza el nivel de entrada en el estado activo.
  void _onInputLevelUpdated(
    InputLevelUpdated event,
    Emitter<AmplificationState> emit,
  ) {
    final currentState = state;
    if (currentState is AmplificationActive) {
      emit(currentState.copyWith(inputLevelDb: event.levelDb));
    }
  }

  /// Reanuda la amplificación tras una pausa.
  ///
  /// Reconstruye la configuración y reinicia el engine.
  Future<void> _onResumeAmplification(
    ResumeAmplification event,
    Emitter<AmplificationState> emit,
  ) async {
    final currentState = state;
    if (currentState is! AmplificationPaused) return;

    emit(const AmplificationStarting());

    try {
      // Reconstruir config con el estado previo a la pausa
      final audiogram = _currentAudiogram ?? Audiogram.defaultAudiogram();
      final profile = _currentProfile ?? EnvironmentProfile.conversation;
      final volumeDb = currentState.lastVolumeDb;

      final eqGains = _gainPrescriber.prescribeFromAudiogram(audiogram);

      final config = AudioConfig(
        eqGains: eqGains,
        volumeDb: volumeDb,
        wdrcParams: WdrcParams(
          expansionKnee: profile.expansionKnee,
          compressionKnee: profile.compressionKnee,
          compressionRatio: profile.compressionRatio,
        ),
        nrLevel: profile.nrLevel,
      );

      await _audioBridge.startAudio(config);
      _subscribeToStreams();

      emit(AmplificationActive(
        inputLevelDb: 0.0,
        activeProfile: currentState.lastActiveProfile,
        volumeDb: volumeDb,
        headphonesConnected: _headphonesConnected,
      ));
    } catch (e) {
      emit(AmplificationError(message: e.toString()));
    }
  }

  /// Suscribe a los streams del AudioBridge.
  void _subscribeToStreams() {
    _inputLevelSubscription = _audioBridge.inputLevelStream.listen(
      (level) => add(InputLevelUpdated(levelDb: level)),
    );

    _engineStateSubscription = _audioBridge.stateStream.listen(
      (engineState) {
        // Manejar cambios de estado del engine si es necesario
        if (engineState == AudioEngineState.error) {
          add(const StopAmplification());
        }
      },
    );
  }

  /// Actualiza las ganancias del EQ directamente (desde configuración avanzada).
  Future<void> _onUpdateEqGains(
    UpdateEqGains event,
    Emitter<AmplificationState> emit,
  ) async {
    if (state is! AmplificationActive) return;

    try {
      await _audioBridge.updateEqGains(event.gains);
      // Persistir el preset
      if (event.presetName != null) {
        await _settingsRepository.setLastEqPreset({
          'name': event.presetName,
          'gains': event.gains,
        });
      } else {
        await _settingsRepository.setLastEqPreset({
          'name': 'Custom',
          'gains': event.gains,
        });
      }
    } catch (_) {
      // No interrumpir por error de actualización de EQ
    }
  }

  /// Actualiza el nivel de reducción de ruido (desde configuración avanzada).
  Future<void> _onUpdateNrLevel(
    UpdateNrLevel event,
    Emitter<AmplificationState> emit,
  ) async {
    if (state is! AmplificationActive) return;

    try {
      await _audioBridge.updateNrLevel(event.level);
      // Persistir el nivel de NR
      await _settingsRepository.setLastNrLevel(event.level);
    } catch (_) {
      // No interrumpir por error de actualización de NR
    }
  }

  /// Guarda un preset personalizado con nombre.
  ///
  /// Persiste el audiograma y los parámetros actuales como un preset
  /// que aparece en la lista de perfiles disponibles.
  Future<void> _onSaveCustomPreset(
    SaveCustomPreset event,
    Emitter<AmplificationState> emit,
  ) async {
    try {
      // Guardar el audiograma como preset
      final thresholds = <int, double>{};
      for (final point in event.audiogram) {
        thresholds[point.frequencyHz] = point.thresholdHL;
      }

      // Crear un perfil con los parámetros WDRC actuales
      final profile = EnvironmentProfile(
        name: event.name,
        nrLevel: _currentProfile?.nrLevel ?? 1,
        compressionRatio: _currentProfile?.compressionRatio ?? 2.0,
        expansionKnee: _currentProfile?.expansionKnee ?? 35.0,
        compressionKnee: _currentProfile?.compressionKnee ?? 55.0,
      );

      await _profileRepository.saveCustomProfile(profile);

      // También guardar el audiograma asociado
      final newAudiogram = Audiogram(thresholds: thresholds);
      await _audiogramRepository.saveAudiogram(newAudiogram);
    } catch (_) {
      // No interrumpir por error de guardado
    }
  }

  /// Elimina un preset personalizado por nombre.
  ///
  /// Solo funciona con presets personalizados (no predefinidos).
  Future<void> _onDeleteCustomPreset(
    DeleteCustomPreset event,
    Emitter<AmplificationState> emit,
  ) async {
    try {
      await _profileRepository.deleteCustomProfile(event.name);
    } catch (_) {
      // No interrumpir por error de eliminación
    }
  }

  /// Cancela suscripciones a streams.
  void _cancelSubscriptions() {
    _inputLevelSubscription?.cancel();
    _inputLevelSubscription = null;
    _engineStateSubscription?.cancel();
    _engineStateSubscription = null;
  }

  @override
  Future<void> close() {
    _cancelSubscriptions();
    return super.close();
  }
}
