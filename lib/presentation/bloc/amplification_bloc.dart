import 'dart:async';

import 'package:flutter_bloc/flutter_bloc.dart';

import '../../data/bridges/audio_bridge.dart';
import '../../domain/cin_module.dart';
import '../../domain/entities/audio_config.dart';
import '../../domain/entities/audiogram.dart';
import '../../domain/entities/environment_profile.dart';
import '../../domain/entities/nl3_prescription_result.dart';
import '../../domain/entities/prescription_mode.dart';
import '../../domain/entities/wdrc_params.dart';
import '../../domain/gain_prescriber.dart';
import '../../domain/gain_prescriber_nl3.dart';
import '../../domain/mhl_module.dart';
import '../../domain/repositories/audiogram_repository.dart';
import '../../domain/repositories/profile_repository.dart';
import '../../domain/repositories/settings_repository.dart';
import '../../domain/scene_prescription_controller.dart';
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

  /// Expone el repositorio de settings para consultas desde la UI.
  SettingsRepository get settingsRepository => _settingsRepository;

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

  /// Modo de prescriptor activo (NL2 / NL3).
  PrescriberMode _currentPrescriberMode = PrescriberMode.smartNl2;

  /// Indica si el modo MHL está activo.
  bool _mhlActive = false;

  /// Expone el estado MHL para consultas internas.
  bool get isMhlActive => _mhlActive;

  /// Modo de prescripción previo a la activación de MHL.
  /// Se usa para restaurar al desactivar MHL (Req 4.6).
  PrescriptionMode _previousPrescriptionMode = PrescriptionMode.quiet;

  /// Prescriptor NL3-inspired (instanciado una sola vez).
  late final GainPrescriberNL3 _nl3Prescriber;

  /// Controlador de transiciones Escena → Modo de prescripción (CIN).
  /// Aplica histéresis para evitar oscilación del modo CIN cuando la
  /// clasificación del Smart Scene Engine fluctúa.
  late final ScenePrescriptionController _sceneController;

  /// Cache de la última prescripción NL3 calculada para el audiograma
  /// activo. Permite componer ganancias CIN en `_onSceneClassUpdated`
  /// sin recalcular toda la prescripción.
  NL3PrescriptionResult? _lastNl3Result;

  /// Cache de las últimas ganancias NL2 (sin correcciones NL3) para
  /// la visualización lado a lado en el [GainComparisonWidget].
  List<double> _lastNl2Gains = const [];

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
    // Instanciar el prescriptor NL3 usando el NL2 existente (composición).
    _nl3Prescriber = GainPrescriberNL3(nl2Prescriber: _gainPrescriber);

    // Controlador de transiciones Escena → modo de prescripción (CIN).
    // Default arranca en NL2: el setter se actualiza al restaurar el
    // modo persistido en `_onStartAmplification`.
    _sceneController = ScenePrescriptionController(
      prescriberMode: PrescriberMode.smartNl2,
    );

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
    on<ChangePrescriberMode>(_onChangePrescriberMode);
    on<ToggleMhlMode>(_onToggleMhlMode);
    on<SceneClassUpdated>(_onSceneClassUpdated);
    // FIX Causa C (smart-scene-diagnostico-chasquido.md): registrar handlers
    // para que el preset Smart Scene completo llegue al engine (antes solo
    // EQ + Volume eran despachados; nrLevel + WDRC + TNR quedaban en Hive).
    on<UpdateWdrcParams>(_onUpdateWdrcParams);
    on<SetTnrEnabled>(_onSetTnrEnabled);
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
      _lastNl2Gains = List<double>.unmodifiable(eqGains);

      // 4b. Restaurar el modo de prescriptor persistido (Req 5.7, 5.8).
      //     Default = smartNl2 para instalaciones nuevas.
      try {
        final savedMode = await _settingsRepository.getPrescriberMode();
        _currentPrescriberMode = savedMode;
      } catch (_) {
        // Persistencia tolerante: si falla, mantener el default (smartNl2).
      }
      _sceneController.setPrescriberMode(_currentPrescriberMode);

      // 4c. Si el modo restaurado es NL3, recalcular ganancias con ese prescriptor.
      final List<double> startupGains;
      NL3PrescriptionResult? nl3Result;
      if (_currentPrescriberMode == PrescriberMode.smartNl3) {
        nl3Result = _nl3Prescriber.prescribeFromAudiogram(_currentAudiogram!);
        startupGains = nl3Result.prescribedGains;
      } else {
        startupGains = eqGains;
      }
      _lastNl3Result = nl3Result;

      // 5. Construir AudioConfig
      final config = AudioConfig(
        eqGains: startupGains,
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

      // 8. Emitir estado activo (con el modo restaurado — Req 5.7)
      emit(AmplificationActive(
        inputLevelDb: 0.0,
        activeProfile: _currentProfile!.name,
        volumeDb: _currentVolumeDb,
        headphonesConnected: _headphonesConnected,
        prescriberMode: _currentPrescriberMode,
        nl2Gains: _lastNl2Gains,
        nl3Gains: nl3Result?.prescribedGains ?? const [],
        lossType: nl3Result?.lossType,
        prescriptionMode: PrescriptionMode.quiet,
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
        final nl2Gains = _gainPrescriber.prescribeFromAudiogram(newAudiogram);
        _lastNl2Gains = List<double>.unmodifiable(nl2Gains);

        // Recalcular NL3 también para mantener el cache fresco aunque el
        // modo activo sea NL2 (la UI muestra siempre la comparación).
        final nl3Result =
            _nl3Prescriber.prescribeFromAudiogram(newAudiogram);
        _lastNl3Result = nl3Result;

        final List<double> targetGains;
        List<double>? cinGainsForState;
        var prescriptionMode = PrescriptionMode.quiet;

        if (_currentPrescriberMode == PrescriberMode.smartNl3) {
          // Si el scene controller mantenía CIN activo, recomponerlo
          // sobre la nueva prescripción NL3.
          if (_sceneController.currentMode ==
              PrescriptionMode.comfortInNoise) {
            final cin = CinModule.apply(
              nl3Result.prescribedGains,
              nl3Result.compressionRatios,
            );
            targetGains = cin.gains;
            cinGainsForState = cin.gains;
            prescriptionMode = PrescriptionMode.comfortInNoise;
          } else {
            targetGains = nl3Result.prescribedGains;
          }
        } else {
          targetGains = nl2Gains;
        }

        await _audioBridge.updateEqGains(targetGains);

        emit((state as AmplificationActive).copyWith(
          nl2Gains: _lastNl2Gains,
          nl3Gains: nl3Result.prescribedGains,
          cinGains: cinGainsForState,
          clearCinGains: cinGainsForState == null,
          lossType: nl3Result.lossType,
          prescriptionMode: prescriptionMode,
        ));
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
  ///
  /// Usa la misma lógica que UpdateAudiogram: solo llama updateEqGains()
  /// directamente al bridge nativo. Esto funciona sin ruido porque el engine
  /// maneja la transición internamente (igual que la pantalla de audiometría).
  ///
  /// Funciona en cualquier estado: si el audífono está activo aplica al engine
  /// y emite el nuevo estado; si está inactivo solo persiste para usar al
  /// próximo encendido.
  Future<void> _onUpdateEqGains(
    UpdateEqGains event,
    Emitter<AmplificationState> emit,
  ) async {
    try {
      final presetName = event.presetName ?? 'Custom';

      // 1. Persistir el preset SIEMPRE (independiente del estado)
      await _settingsRepository.setLastEqPreset({
        'name': presetName,
        'gains': event.gains,
      });

      // 2. Aplicar al engine solo si está activo
      if (state is AmplificationActive) {
        await _audioBridge.updateEqGains(event.gains);
        // Actualizar estado con el nombre del preset activo
        emit((state as AmplificationActive).copyWith(
          activeEqPreset: presetName,
        ));
      }
    } catch (_) {
      // No interrumpir por error de actualización de EQ
    }
  }

  /// Busca los parámetros WDRC recomendados para un preset EQ por nombre.
  /// Retorna null si no es un preset conocido.
  ({double compressionRatio, double compressionKnee, double expansionKnee})?
      _findEqPresetWdrcParams(String presetName) {
    // Parámetros WDRC optimizados por preset (de eq_preset.dart)
    switch (presetName) {
      case 'Normal':
        return (compressionRatio: 1.2, compressionKnee: 60.0, expansionKnee: 35.0);
      case 'Mild High':
        return (compressionRatio: 1.3, compressionKnee: 58.0, expansionKnee: 35.0);
      case 'Mild Flat':
        return (compressionRatio: 1.4, compressionKnee: 56.0, expansionKnee: 35.0);
      case 'Moderate High':
        return (compressionRatio: 1.5, compressionKnee: 55.0, expansionKnee: 35.0);
      case 'Moderate Flat':
        return (compressionRatio: 1.8, compressionKnee: 52.0, expansionKnee: 35.0);
      case 'Moderate+':
        return (compressionRatio: 2.0, compressionKnee: 50.0, expansionKnee: 35.0);
      case 'Voice Clarity':
        return (compressionRatio: 1.6, compressionKnee: 53.0, expansionKnee: 35.0);
      case 'Music':
        return (compressionRatio: 1.3, compressionKnee: 58.0, expansionKnee: 35.0);
      case 'Outdoor':
        return (compressionRatio: 1.7, compressionKnee: 52.0, expansionKnee: 35.0);
      case 'TV/Media':
        return (compressionRatio: 1.5, compressionKnee: 55.0, expansionKnee: 35.0);
      default:
        return null;
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

  /// FIX Causa C (smart-scene-diagnostico-chasquido.md):
  /// Aplica un set completo de parámetros WDRC (knees + ratios + attack/release).
  ///
  /// Antes el preset Smart Scene persistía `compressionKnee`, `compressionRatio`
  /// y `expansionKnee` en Hive pero el `apply()` no los despachaba al engine,
  /// quedando el WDRC controlado solo por el `EnvironmentClassifier` automático.
  /// Ahora este handler hace el bridge.invokeMethod correspondiente para que
  /// el pipeline DSP nativo reciba los parámetros del preset.
  Future<void> _onUpdateWdrcParams(
    UpdateWdrcParams event,
    Emitter<AmplificationState> emit,
  ) async {
    if (state is! AmplificationActive) return;

    try {
      await _audioBridge.updateWdrcParams(event.params);
    } catch (_) {
      // No interrumpir por error de actualización de WDRC
    }
  }

  /// FIX Causa C (smart-scene-diagnostico-chasquido.md):
  /// Habilita/deshabilita el Transient Noise Reducer.
  ///
  /// Antes el `tnrEnabled` del preset Smart Scene se persistía en Hive pero
  /// nunca llegaba al engine.
  Future<void> _onSetTnrEnabled(
    SetTnrEnabled event,
    Emitter<AmplificationState> emit,
  ) async {
    if (state is! AmplificationActive) return;

    try {
      await _audioBridge.updateTnrEnabled(event.enabled);
    } catch (_) {
      // No interrumpir por error de actualización de TNR
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

  /// Cambia el modo de prescriptor (NL2 / NL3) y recalcula ganancias.
  ///
  /// Al cambiar el modo se recalculan los targets de ganancia usando el
  /// prescriptor correspondiente y se aplican al EQ en ≤ 200 ms.
  /// El modo se persiste para restaurarlo en el próximo inicio.
  ///
  /// Requisitos: 5.1, 5.2, 5.3, 5.4, 5.5, 5.6
  Future<void> _onChangePrescriberMode(
    ChangePrescriberMode event,
    Emitter<AmplificationState> emit,
  ) async {
    final currentState = state;
    if (currentState is! AmplificationActive) return;
    if (event.mode == _currentPrescriberMode) return;

    _currentPrescriberMode = event.mode;
    _sceneController.setPrescriberMode(event.mode);

    // Desactivar MHL si estaba activo al cambiar de prescriptor.
    _mhlActive = false;

    // Persistir el modo seleccionado para restaurarlo al reiniciar (Req 5.6).
    try {
      await _settingsRepository.setPrescriberMode(event.mode);
    } catch (_) {
      // Persistencia tolerante: si Hive falla, el modo queda en memoria.
    }

    try {
      // Recalcular ganancias según el prescriptor seleccionado.
      final audiogram = _currentAudiogram ?? Audiogram.defaultAudiogram();
      final List<double> newGains;

      // Refrescar caches NL2 + NL3 para mantener visualización consistente.
      final nl2Gains = _gainPrescriber.prescribeFromAudiogram(audiogram);
      _lastNl2Gains = List<double>.unmodifiable(nl2Gains);

      NL3PrescriptionResult? nl3Result;
      if (event.mode == PrescriberMode.smartNl3) {
        nl3Result = _nl3Prescriber.prescribeFromAudiogram(audiogram);
        newGains = nl3Result.prescribedGains;
      } else {
        // Cambio a NL2 fuerza CIN off — sceneController ya lo hizo arriba.
        nl3Result = _nl3Prescriber.prescribeFromAudiogram(audiogram);
        newGains = nl2Gains;
      }
      _lastNl3Result = nl3Result;

      // Aplicar al engine nativo (debe completarse en ≤ 200 ms).
      await _audioBridge.updateEqGains(newGains);

      // Emitir estado con nuevo modo activo y MHL desactivado.
      emit(currentState.copyWith(
        prescriberMode: event.mode,
        mhlActive: false,
        ptaWarning: false,
        nl2Gains: _lastNl2Gains,
        nl3Gains: nl3Result.prescribedGains,
        clearCinGains: true,
        lossType: nl3Result.lossType,
        prescriptionMode: PrescriptionMode.quiet,
      ));
    } catch (_) {
      // No interrumpir la amplificación por error de cambio de modo.
      // Revertir el modo interno si falló la aplicación.
      _currentPrescriberMode = currentState.prescriberMode;
      _sceneController.setPrescriberMode(currentState.prescriberMode);
    }
  }

  /// Activa o desactiva el modo MHL (Minimal Hearing Loss).
  ///
  /// Al activar: guarda el modo de prescripción actual, prescribe ganancia
  /// MHL flat y aplica al EQ. Si PTA > 25 dB HL, emite warning en el estado.
  ///
  /// Al desactivar: restaura el modo previo (quiet o CIN) recalculando
  /// ganancias según el prescriptor activo, en ≤ 100 ms.
  ///
  /// Requisitos: 4.3, 4.5, 4.6
  Future<void> _onToggleMhlMode(
    ToggleMhlMode event,
    Emitter<AmplificationState> emit,
  ) async {
    final currentState = state;
    if (currentState is! AmplificationActive) return;

    final audiogram = _currentAudiogram ?? Audiogram.defaultAudiogram();

    if (event.activate) {
      // Guardar el modo previo para restaurar al desactivar (Req 4.6).
      _previousPrescriptionMode = PrescriptionMode.quiet;
      _mhlActive = true;

      try {
        // Prescribir MHL (ganancia flat, compresión lineal, NR máximo).
        final mhlResult = MhlModule.prescribe(audiogram);

        // Aplicar ganancias MHL al engine.
        await _audioBridge.updateEqGains(mhlResult.gains);

        // Aplicar NR nivel máximo.
        await _audioBridge.updateNrLevel(mhlResult.noiseReductionLevel);

        // Emitir estado con MHL activo y flag de advertencia PTA.
        emit(currentState.copyWith(
          mhlActive: true,
          ptaWarning: mhlResult.ptaWarning,
          activeNrLevel: mhlResult.noiseReductionLevel,
        ));
      } catch (_) {
        // Revertir si falla la activación.
        _mhlActive = false;
      }
    } else {
      // Desactivar MHL: restaurar modo previo en ≤ 100 ms (Req 4.6).
      _mhlActive = false;

      try {
        final List<double> restoredGains;

        if (_currentPrescriberMode == PrescriberMode.smartNl3) {
          final result = _nl3Prescriber.prescribeFromAudiogram(
            audiogram,
            mode: _previousPrescriptionMode,
          );
          restoredGains = result.prescribedGains;
        } else {
          restoredGains = _gainPrescriber.prescribeFromAudiogram(audiogram);
        }

        // Aplicar ganancias restauradas al engine.
        await _audioBridge.updateEqGains(restoredGains);

        // Restaurar nivel de NR del perfil activo.
        final nrLevel = _currentProfile?.nrLevel ?? 0;
        await _audioBridge.updateNrLevel(nrLevel);

        // Emitir estado sin MHL.
        emit(currentState.copyWith(
          mhlActive: false,
          ptaWarning: false,
          activeNrLevel: nrLevel,
        ));
      } catch (_) {
        // No interrumpir la amplificación por error de restauración.
      }
    }
  }

  /// Procesa una nueva clasificación del Smart Scene Engine y, si el
  /// modo activo es NL3, aplica/desactiva el módulo CIN respetando la
  /// histéresis del [ScenePrescriptionController].
  ///
  /// Si el modo activo es NL2 o el modo MHL está habilitado, el evento
  /// se ignora silenciosamente.
  ///
  /// Requisitos: 6.1, 6.2, 6.3, 6.4, 6.5
  Future<void> _onSceneClassUpdated(
    SceneClassUpdated event,
    Emitter<AmplificationState> emit,
  ) async {
    final currentState = state;
    if (currentState is! AmplificationActive) return;
    if (_currentPrescriberMode != PrescriberMode.smartNl3) return;
    if (_mhlActive) return;

    final previousMode = _sceneController.currentMode;
    _sceneController.onSceneChanged(event.sceneClass);
    final newMode = _sceneController.currentMode;

    if (newMode == previousMode) return;

    final audiogram = _currentAudiogram;
    if (audiogram == null) return;

    // Asegurar prescripción NL3 fresca en cache.
    final nl3Result = _lastNl3Result ??
        _nl3Prescriber.prescribeFromAudiogram(audiogram);
    _lastNl3Result = nl3Result;

    try {
      if (newMode == PrescriptionMode.comfortInNoise) {
        // Activar CIN: componer ganancias modificadas y enviarlas al engine.
        final cin = CinModule.apply(
          nl3Result.prescribedGains,
          nl3Result.compressionRatios,
        );
        await _audioBridge.updateEqGains(cin.gains);
        await _audioBridge.updateWdrcParams(cin.wdrcOverrides);

        emit(currentState.copyWith(
          cinGains: cin.gains,
          prescriptionMode: PrescriptionMode.comfortInNoise,
        ));
      } else {
        // Volver a quiet (CIN off) — restaurar ganancias NL3 base.
        await _audioBridge.updateEqGains(nl3Result.prescribedGains);

        // Restaurar WDRC del perfil activo (si lo hay).
        final profile = _currentProfile;
        if (profile != null) {
          await _audioBridge.updateWdrcParams(WdrcParams(
            expansionKnee: profile.expansionKnee,
            compressionKnee: profile.compressionKnee,
            compressionRatio: profile.compressionRatio,
          ));
        }

        emit(currentState.copyWith(
          clearCinGains: true,
          prescriptionMode: PrescriptionMode.quiet,
        ));
      }
    } catch (_) {
      // Las transiciones de escena nunca rompen la amplificación.
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
