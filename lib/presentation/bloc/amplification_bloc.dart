import 'dart:async';
import 'dart:convert';
import 'dart:developer' as developer;
import 'dart:math' as math;

import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:hive/hive.dart';

import '../../data/bridges/audio_bridge.dart';
import '../../data/repositories/settings_repository_impl.dart';
import '../../domain/audiogram_driven_presets/audiogram_driven_bundle.dart';
import '../../domain/audiogram_driven_presets/bundle_builder.dart';
import '../../domain/audiogram_driven_presets/environment_profile_mapper.dart';
import '../../domain/audiogram_driven_presets/manual_adjustment_delta.dart';
import '../../domain/audiogram_driven_presets/operating_mode.dart';
import '../../domain/audiogram_driven_presets/recd_provider.dart';
import '../../domain/entities/audio_config.dart';
import '../../domain/entities/audiogram.dart';
import '../../domain/entities/environment_profile.dart';
import '../../domain/entities/nl3_prescription_result.dart';
import '../../domain/entities/patient_profile.dart';
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

  /// Builder del [AudiogramDrivenBundle] (función pura).
  late final BundleBuilder _bundleBuilder;

  /// Modo de operación actual (Diagnóstico / Amplificador).
  ///
  /// Se determina al iniciar la amplificación según haya o no un
  /// audiograma medido (Req 13.1, 13.2). Se usa como state mirror
  /// para los handlers que necesitan saber el modo activo (por
  /// ejemplo, persistencia del [ManualAdjustmentDelta] por modo).
  OperatingMode _operatingMode = OperatingMode.diagnostic;

  /// Factor de escala de ganancia activo en modo Amplificador.
  ///
  /// En modo Diagnóstico se mantiene en `1.0` por contrato (Req 13.4).
  /// Default boot en Amplificador: `0.40` (Req 13.7).
  double _gainScale = 1.0;

  /// Último bundle aplicado atómicamente al motor DSP.
  AudiogramDrivenBundle? _lastBundle;

  /// Delta de ajustes manuales activo para el modo en curso.
  ///
  /// `null` cuando el usuario no aplicó ajustes manuales en este
  /// modo (equivalente a [ManualAdjustmentDelta.zero]).
  ManualAdjustmentDelta? _manualDelta;

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

  /// Experiencia previa del usuario con audífonos en meses.
  ///
  /// `null` indica que el usuario todavía no completó el onboarding,
  /// por lo que se asume usuario nuevo (NL3 aplica -3 dB de
  /// aclimatización si está activo). Se carga desde `SettingsRepository`
  /// en `_onStartAmplification` y se actualiza con `SetExperienceMonths`.
  int? _experienceMonths;

  /// Edad del paciente en años cumplidos. Cuando es no-null, el bloc
  /// pasa un [RecdProvider] al [BundleBuilder] para que se emita el
  /// log informativo de la conversión HL → SPL real-ear (Req 15.9,
  /// hallazgo A-10). El bundle producido NO depende de este valor: la
  /// conversión es solo trazabilidad clínica.
  ///
  /// Se carga desde Hive (`settings_box['patient_age_years']`) en el
  /// boot del bloc (`_onStartAmplification`). Si la clave no está
  /// presente o la lectura falla, queda en `null` y la conversión
  /// real-ear no se emite (comportamiento previo a A-10).
  int? _ageYears;

  /// Construye un [PatientProfile] a partir de la experiencia guardada,
  /// o `null` si todavía no hay un valor (onboarding pendiente). Si
  /// hay una edad cargada en [_ageYears], la incluye para activar la
  /// regla pediátrica del [MpoDeriver] y la conversión real-ear del
  /// [BundleBuilder].
  PatientProfile? _buildPatientProfile() {
    final months = _experienceMonths;
    if (months == null) return null;
    return PatientProfile(experienceMonths: months, ageYears: _ageYears);
  }

  /// Devuelve un [RecdProvider] cuando hay edad del paciente cargada,
  /// o `null` cuando no la hay. El provider se pasa al
  /// [BundleBuilder] solo para que emita el log informativo de la
  /// conversión HL → SPL real-ear; no afecta el bundle producido.
  RecdProvider? _maybeRecdProvider() =>
      _ageYears != null ? const BagattoRecdProvider() : null;

  /// Reloj inyectable para tests deterministas. En producción usa
  /// [DateTime.now]. Se propaga a [GainPrescriberNL3] y [BundleBuilder].
  final DateTime Function() _clock;

  AmplificationBloc({
    required AudioBridge audioBridge,
    required AudiogramRepository audiogramRepository,
    required ProfileRepository profileRepository,
    required SettingsRepository settingsRepository,
    required GainPrescriber gainPrescriber,
    DateTime Function()? clock,
  })  : _audioBridge = audioBridge,
        _audiogramRepository = audiogramRepository,
        _profileRepository = profileRepository,
        _settingsRepository = settingsRepository,
        _gainPrescriber = gainPrescriber,
        _clock = clock ?? DateTime.now,
        super(const AmplificationIdle()) {
    // Instanciar el prescriptor NL3 usando el NL2 existente (composición).
    _nl3Prescriber = GainPrescriberNL3(nl2Prescriber: _gainPrescriber, clock: _clock);

    // Builder del bundle. Reutiliza el prescriptor NL3 ya construido
    // para evitar instanciar dos cadenas de dependencias paralelas.
    _bundleBuilder = BundleBuilder(nl3Prescriber: _nl3Prescriber, clock: _clock);

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
    on<SetExperienceMonths>(_onSetExperienceMonths);
    // FIX Causa C (smart-scene-diagnostico-chasquido.md): registrar handlers
    // para que el preset Smart Scene completo llegue al engine (antes solo
    // EQ + Volume eran despachados; nrLevel + WDRC + TNR quedaban en Hive).
    on<UpdateWdrcParams>(_onUpdateWdrcParams);
    on<SetTnrEnabled>(_onSetTnrEnabled);
    on<SaveCustomPreset>(_onSaveCustomPreset);
    on<DeleteCustomPreset>(_onDeleteCustomPreset);
    // audiogram-driven-presets — wave 4: handlers del bundle clínico.
    on<ApplyAudiogramDrivenBundle>(_onApplyBundle);
    on<GainScaleChanged>(_onGainScaleChanged);
    on<ManualEqAdjust>(_onManualEqAdjust);
    on<ResetManualDelta>(_onResetManualDelta);
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
      // 1. Cargar audiograma (o usar default). Si no hay audiograma
      //    medido se asume Modo Amplificador (Req 13.1, 13.2).
      final storedAudiogram = await _audiogramRepository.getAudiogram();
      final hasMeasuredAudiogram =
          storedAudiogram != null && _isAudiogramComplete(storedAudiogram);
      _currentAudiogram = storedAudiogram ?? Audiogram.defaultAudiogram();

      // 2. Auto-detección de OperatingMode + gainScale (task 4.9).
      if (hasMeasuredAudiogram) {
        _operatingMode = OperatingMode.diagnostic;
        _gainScale = 1.0; // Forzado por contrato (Req 13.4).
      } else {
        _operatingMode = OperatingMode.amplifier;
        _gainScale = await _loadAmplifierGainScale();
      }

      // 3. Restaurar el ManualAdjustmentDelta del modo activo
      //    (cada modo tiene su propio delta independiente — Req 14.6).
      _manualDelta = await _loadManualDeltaFor(_operatingMode);

      // 4. Cargar último perfil y volumen
      final lastConfig = await _settingsRepository.restoreLastConfig();
      final profileName = lastConfig.lastProfile ?? 'Conversación';
      _currentVolumeDb = lastConfig.lastVolume ?? 0.0;

      // 5. Obtener perfil
      _currentProfile =
          await _profileRepository.getProfileByName(profileName) ??
              EnvironmentProfile.conversation;

      // 6. Calcular ganancias NAL-NL2
      final eqGains =
          _gainPrescriber.prescribeFromAudiogram(_currentAudiogram!);
      _lastNl2Gains = List<double>.unmodifiable(eqGains);

      // 6b. Restaurar el modo de prescriptor persistido (Req 5.7, 5.8).
      //     Default = smartNl2 para instalaciones nuevas.
      try {
        final savedMode = await _settingsRepository.getPrescriberMode();
        _currentPrescriberMode = savedMode;
      } catch (_) {
        // Persistencia tolerante: si falla, mantener el default (smartNl2).
      }
      _sceneController.setPrescriberMode(_currentPrescriberMode);

      // 6b'. Restaurar la experiencia previa del usuario (en meses).
      //     `null` se interpreta como onboarding pendiente.
      try {
        _experienceMonths = await _settingsRepository.getExperienceMonths();
      } catch (_) {
        // Persistencia tolerante: dejarlo en null si falla.
        _experienceMonths = null;
      }

      // 6b''. Restaurar la edad del paciente (años cumplidos) desde
      //       Hive. Cuando está presente, el bundle path emite el log
      //       de conversión HL → SPL real-ear (hallazgo A-10). Si la
      //       clave no existe o la lectura falla, dejar en null para
      //       preservar el comportamiento previo (sin conversión).
      try {
        final box = await _openSettingsBox();
        final raw = box?.get('patient_age_years');
        if (raw is int) {
          _ageYears = raw;
        } else if (raw is num) {
          _ageYears = raw.toInt();
        } else {
          _ageYears = null;
        }
      } catch (_) {
        _ageYears = null;
      }

      // 6c. Si el modo restaurado es NL3, recalcular ganancias con ese prescriptor.
      final List<double> startupGains;
      NL3PrescriptionResult? nl3Result;
      if (_currentPrescriberMode == PrescriberMode.smartNl3) {
        nl3Result = _nl3Prescriber.prescribeFromAudiogram(
          _currentAudiogram!,
          profile: _buildPatientProfile(),
        );
        startupGains = nl3Result.prescribedGains;
      } else {
        startupGains = eqGains;
      }
      _lastNl3Result = nl3Result;

      // 7. Construir AudioConfig
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

      // 8. Iniciar el motor de audio nativo
      await _audioBridge.startAudio(config);

      // 9. Suscribirse a streams del engine
      _subscribeToStreams();

      // 10. Emitir estado activo (con el modo restaurado — Req 5.7)
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
        experienceMonths: _experienceMonths,
        operatingMode: _operatingMode,
        gainScale: _gainScale,
        manualDelta: _manualDelta,
      ));

      // 11. Construir el bundle inicial y aplicarlo atómicamente
      //     (Req 13.1, 13.2, 13.3, 13.7, 13.8, 13.9). El dispatch se
      //     hace fuera del emit para que el handler `_onApplyBundle`
      //     reemplace el estado con los datos clínicos completos.
      try {
        final initialBundle = _bundleBuilder.buildFromAudiogram(
          _currentAudiogram!,
          profile: _buildPatientProfile(),
          mode: PrescriptionMode.quiet,
          operatingMode: _operatingMode,
          gainScale: _gainScale,
          recdProvider: _maybeRecdProvider(),
        );
        add(ApplyAudiogramDrivenBundle(
          bundle: initialBundle,
          delta: _manualDelta,
        ));
      } catch (e, st) {
        developer.log(
          'Boot: no se pudo construir el bundle inicial: $e',
          name: 'AmplificationBloc',
          level: 900,
          error: e,
          stackTrace: st,
        );
      }
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

  /// Cambia el perfil de entorno: deriva el [PrescriptionMode]
  /// correspondiente vía [EnvironmentProfileMapper], construye un nuevo
  /// [AudiogramDrivenBundle] y lo despacha vía
  /// [ApplyAudiogramDrivenBundle] para aplicación atómica al motor.
  ///
  /// Persiste el nuevo perfil en settings (Req 8.4).
  ///
  /// Requisitos: 6.2, 6.3, 6.4, 6.5, 8.2, 8.5
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

      // Persistir selección.
      await _settingsRepository.setLastProfile(newProfile.name);

      final audiogram = _currentAudiogram ?? Audiogram.defaultAudiogram();

      // Mapear el perfil al modo de prescripción clínica
      // (Silencioso/Conversación → quiet, Ruidoso → comfortInNoise).
      final prescriptionMode = EnvironmentProfileMapper.modeFor(newProfile);

      // Construir bundle base con el nuevo modo.
      final baseBundle = _bundleBuilder.buildFromAudiogram(
        audiogram,
        profile: _buildPatientProfile(),
        mode: prescriptionMode,
        operatingMode: _operatingMode,
        gainScale: _gainScale,
        recdProvider: _maybeRecdProvider(),
      );

      // Aplicar el `nrDelta` del perfil sobre el `nrLevel` derivado del
      // bundle (clamp a [0, 3] dentro del mapper). Como
      // AudiogramDrivenBundle es inmutable y no expone copyWith,
      // reconstruimos manualmente preservando el resto de campos.
      final adjustedNrLevel = EnvironmentProfileMapper.adjustNr(
        baseBundle.nrLevel,
        newProfile.nrDelta,
      );
      final bundle = adjustedNrLevel == baseBundle.nrLevel
          ? baseBundle
          : AudiogramDrivenBundle(
              gainsDb: baseBundle.gainsDb,
              compressionRatios: baseBundle.compressionRatios,
              compressionKneesDbSpl: baseBundle.compressionKneesDbSpl,
              mpoProfileDbSpl: baseBundle.mpoProfileDbSpl,
              nrLevel: adjustedNrLevel,
              wdrcAttackMs: baseBundle.wdrcAttackMs,
              wdrcReleaseMs: baseBundle.wdrcReleaseMs,
              expansionKneeDbSpl: baseBundle.expansionKneeDbSpl,
              lossType: baseBundle.lossType,
              prescriptionMode: baseBundle.prescriptionMode,
              mode: baseBundle.mode,
              gainScale: baseBundle.gainScale,
              derivedAt: baseBundle.derivedAt,
            );

      // Reflejar el nombre del perfil activo de inmediato; el bundle
      // se aplica vía `_onApplyBundle`.
      emit(currentState.copyWith(activeProfile: newProfile.name));

      add(ApplyAudiogramDrivenBundle(bundle: bundle, delta: _manualDelta));
    } catch (e, st) {
      // A-7: emitir error para que la UI lo muestre, pero NO transicionar
      // a Idle. El engine sigue activo en el último perfil aplicado con
      // éxito; el siguiente evento (ChangeProfile, ChangeVolume, etc.)
      // reemitirá AmplificationActive desde el state actual.
      developer.log(
        '_onChangeProfile: error al construir el bundle: $e',
        name: 'AmplificationBloc',
        level: 1000,
        error: e,
        stackTrace: st,
      );
      emit(AmplificationError(
        message: 'No se pudo cambiar el perfil: $e',
      ));
      return;
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

    // Aplicar al engine nativo. Si el bridge falla, emitir
    // AmplificationError y abortar para no dejar el state
    // desincronizado del engine (hallazgo A-7).
    try {
      await _audioBridge.updateVolume(volumeDb);
    } catch (e, st) {
      developer.log(
        'Error in updateVolume: $e',
        name: 'AmplificationBloc',
        level: 1000, // SEVERE
        error: e,
        stackTrace: st,
      );
      emit(AmplificationError(
        message: 'No se pudo actualizar el volumen: $e',
      ));
      return;
    }

    // Persistir (tolerante: si la persistencia falla, el engine ya
    // se actualizó y la sesión continúa con el nuevo volumen).
    try {
      await _settingsRepository.setLastVolume(volumeDb);
    } catch (_) {
      // Persistencia tolerante.
    }

    // Emitir estado actualizado
    emit(currentState.copyWith(volumeDb: volumeDb));
  }

  /// Actualiza el audiograma del usuario, persiste el nuevo valor y
  /// dispara la cadena bundle-driven: construye un nuevo
  /// [AudiogramDrivenBundle] y lo despacha para aplicación atómica al
  /// motor.
  ///
  /// Detecta cambios significativos (MAD > 5 dB por banda) versus el
  /// audiograma persistido previamente: si superan el umbral, marca
  /// los presets personalizados como obsoletos (`customPresetsStale`)
  /// e invalida `last_eq_preset` (Req 9.1, 9.7). Si la transición
  /// implica pasar de Modo Amplificador a Diagnóstico, ajusta el
  /// `OperatingMode` y limpia el `gainScale` a `1.0`.
  ///
  /// Requisitos: 4.2, 9.1, 9.7
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

    // Snapshot del audiograma previo para comparar MAD.
    final previousAudiogram = await _audiogramRepository.getAudiogram();

    _currentAudiogram = newAudiogram;
    await _audiogramRepository.saveAudiogram(newAudiogram);

    // Detectar cambio MAD > 5 dB versus el audiograma persistido.
    final stalePresets = previousAudiogram != null &&
        _audiogramMadExceeds(previousAudiogram, newAudiogram, 5.0);

    if (stalePresets) {
      // Invalidar last_eq_preset (preset cacheado) — Req 9.1.
      try {
        final box = await _openSettingsBox();
        await box?.delete('lastEqPreset');
      } catch (_) {
        // Persistencia tolerante: el preset queda cacheado pero el
        // bundle nuevo lo va a reemplazar al aplicarse.
      }
      // Marcar los presets personalizados como obsoletos vía el
      // repositorio (Req 9.2, 9.3). El método retorna la lista de
      // presets que no se pudieron actualizar; cualquier fallo se
      // expone además vía `profileRepository.warnings`.
      try {
        final failed =
            await _profileRepository.markCustomPresetsAsStale(newAudiogram);
        if (failed.isNotEmpty) {
          developer.log(
            '_onUpdateAudiogram: ${failed.length} preset(s) no se '
            'pudieron marcar como obsoletos: ${failed.join(", ")}',
            name: 'AmplificationBloc',
            level: 900,
          );
        }
      } catch (e, st) {
        // Persistencia tolerante: el flag stale en el state queda en
        // true (lo seteamos abajo) aunque el repo haya fallado.
        developer.log(
          '_onUpdateAudiogram: markCustomPresetsAsStale falló: $e',
          name: 'AmplificationBloc',
          level: 900,
          error: e,
          stackTrace: st,
        );
      }
    }

    // Auto-detección de Modo: la presencia de un audiograma medido
    // completo activa el Modo Diagnóstico (Req 13.1, 13.2, 13.9).
    final wasAmplifier = _operatingMode == OperatingMode.amplifier;
    if (_isAudiogramComplete(newAudiogram)) {
      _operatingMode = OperatingMode.diagnostic;
      _gainScale = 1.0; // Diagnóstico fuerza gainScale=1 (Req 13.4).
    }

    if (state is! AmplificationActive) {
      // No estamos activos: solo persistir y salir.
      return;
    }

    try {
      // Refrescar caches NL2/NL3 para visualización lado a lado en UI.
      final nl2Gains = _gainPrescriber.prescribeFromAudiogram(newAudiogram);
      _lastNl2Gains = List<double>.unmodifiable(nl2Gains);
      final nl3Result = _nl3Prescriber.prescribeFromAudiogram(
        newAudiogram,
        profile: _buildPatientProfile(),
      );
      _lastNl3Result = nl3Result;

      // Construir bundle desde el audiograma nuevo.
      final prescriptionMode = _currentProfile != null
          ? EnvironmentProfileMapper.modeFor(_currentProfile!)
          : PrescriptionMode.quiet;

      final bundle = _bundleBuilder.buildFromAudiogram(
        newAudiogram,
        profile: _buildPatientProfile(),
        mode: prescriptionMode,
        operatingMode: _operatingMode,
        gainScale: _gainScale,
        recdProvider: _maybeRecdProvider(),
      );

      // Reflejar inmediatamente cambios secundarios en el estado UI:
      // gainScale/operatingMode pueden haber cambiado, las curvas NL2/NL3
      // refrescan, y los presets personalizados pueden estar obsoletos.
      final active = state as AmplificationActive;
      emit(active.copyWith(
        nl2Gains: _lastNl2Gains,
        nl3Gains: nl3Result.prescribedGains,
        clearCinGains: true,
        lossType: nl3Result.lossType,
        prescriptionMode: prescriptionMode,
        operatingMode: _operatingMode,
        gainScale: _gainScale,
        customPresetsStale:
            stalePresets ? true : active.customPresetsStale,
      ));

      // Aplicar el bundle atómicamente.
      add(ApplyAudiogramDrivenBundle(
        bundle: bundle,
        delta: _manualDelta,
      ));

      if (wasAmplifier && _operatingMode == OperatingMode.diagnostic) {
        developer.log(
          '_onUpdateAudiogram: transición Amplificador → Diagnóstico '
          '(audiograma medido aplicado).',
          name: 'AmplificationBloc',
          level: 800,
        );
      }
    } catch (e, st) {
      // No interrumpir por error de actualización del bundle.
      developer.log(
        '_onUpdateAudiogram: error al construir el bundle: $e',
        name: 'AmplificationBloc',
        level: 900,
        error: e,
        stackTrace: st,
      );
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
  /// Persiste el blob unificado del preset (audiograma + bundle +
  /// estilo + override + delta + flags de ciclo de vida) vía la API
  /// nueva del [ProfileRepository] (task 7.1). Si el bundle activo no
  /// está disponible (boot temprano, fallo de aplicación previa) se
  /// reconstruye desde el audiograma del evento usando el modo de
  /// prescripción del perfil activo.
  ///
  /// El blob persistido incluye los campos legacy
  /// (`nrLevel`/`compressionRatio`/`expansionKnee`/`compressionKnee`)
  /// derivados del bundle para retrocompatibilidad de lectura.
  ///
  /// Si el blob serializado supera el tope estructural (64 KB) o si la
  /// validación falla, el handler emite un `AmplificationError` sin
  /// pisar el preset previamente guardado con el mismo nombre
  /// (Req 8.3).
  ///
  /// Requisitos: 8.1, 8.2, 8.3, 9.1
  Future<void> _onSaveCustomPreset(
    SaveCustomPreset event,
    Emitter<AmplificationState> emit,
  ) async {
    try {
      // Construir el audiograma desde los puntos del evento.
      final thresholds = <int, double>{};
      for (final point in event.audiogram) {
        thresholds[point.frequencyHz] = point.thresholdHL;
      }
      final newAudiogram = Audiogram(thresholds: thresholds);

      // Resolver el bundle a persistir. Preferimos el bundle activo si
      // su audiograma coincide; en cualquier otro caso reconstruimos
      // desde el audiograma del evento para preservar fidelidad.
      AudiogramDrivenBundle bundle;
      try {
        final prescriptionMode = _currentProfile != null
            ? EnvironmentProfileMapper.modeFor(_currentProfile!)
            : PrescriptionMode.quiet;
        bundle = _bundleBuilder.buildFromAudiogram(
          newAudiogram,
          profile: _buildPatientProfile(),
          mode: prescriptionMode,
          operatingMode: _operatingMode,
          gainScale: _gainScale,
          recdProvider: _maybeRecdProvider(),
        );
      } catch (e, st) {
        developer.log(
          '_onSaveCustomPreset: no se pudo construir el bundle del '
          'preset "${event.name}": $e',
          name: 'AmplificationBloc',
          level: 1000,
          error: e,
          stackTrace: st,
        );
        emit(AmplificationError(
          message:
              'No se pudo guardar el preset "${event.name}": $e',
        ));
        return;
      }

      final nrOverride = _currentProfile?.nrDelta ?? 0;

      try {
        await _profileRepository.saveCustomProfile(
          name: event.name,
          audiogram: newAudiogram,
          bundle: bundle,
          appliedStyleName: '',
          nrOverride: nrOverride,
          manualDelta: _manualDelta,
        );
      } on StateError catch (e) {
        // Tope de 64 KB / validación fallida (Req 8.3): emitir error
        // sin pisar datos del usuario.
        developer.log(
          '_onSaveCustomPreset: rechazo al guardar "${event.name}": '
          '${e.message}',
          name: 'AmplificationBloc',
          level: 1000,
        );
        emit(AmplificationError(
          message:
              'No se pudo guardar el preset "${event.name}": ${e.message}',
        ));
        return;
      }

      // Persistir el audiograma asociado (mantiene el comportamiento
      // legacy de que guardar el preset también actualiza el
      // audiograma activo del paciente).
      await _audiogramRepository.saveAudiogram(newAudiogram);
    } catch (e, st) {
      developer.log(
        '_onSaveCustomPreset: error al guardar "${event.name}": $e',
        name: 'AmplificationBloc',
        level: 1000,
        error: e,
        stackTrace: st,
      );
      // No interrumpir la amplificación: dejar el log y continuar.
    }
  }

  /// Elimina un preset personalizado por nombre.
  ///
  /// Solo funciona con presets personalizados (no predefinidos): si
  /// el nombre corresponde a un perfil del sistema, el handler ignora
  /// la solicitud sin emitir error.
  ///
  /// Cuando el preset eliminado coincide con el `activeProfile` del
  /// estado actual, el handler dispara un `ChangeProfile` hacia el
  /// fallback predefinido (`Conversación`) para que el bloc
  /// reconstruya el bundle activo. NO modifica el bundle activo
  /// directamente: la transición pasa por la cadena bundle-driven
  /// estándar (Req 8.6).
  ///
  /// Todos los demás presets quedan inalterados.
  ///
  /// Requisitos: 8.6
  Future<void> _onDeleteCustomPreset(
    DeleteCustomPreset event,
    Emitter<AmplificationState> emit,
  ) async {
    if (_profileRepository.isPredefined(event.name)) {
      developer.log(
        '_onDeleteCustomPreset: ignorado, "${event.name}" es un '
        'perfil predefinido (no eliminable).',
        name: 'AmplificationBloc',
        level: 800,
      );
      return;
    }

    try {
      await _profileRepository.deleteCustomProfile(event.name);
    } catch (e, st) {
      developer.log(
        '_onDeleteCustomPreset: error al eliminar "${event.name}": $e',
        name: 'AmplificationBloc',
        level: 1000,
        error: e,
        stackTrace: st,
      );
      // Aun ante fallo, NO modificamos el bundle activo (Req 8.6).
      return;
    }

    // Si el preset eliminado era el activo, redirigir al fallback.
    final current = state;
    if (current is AmplificationActive &&
        current.activeProfile == event.name) {
      add(const ChangeProfile(profile: 'Conversación'));
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
        nl3Result = _nl3Prescriber.prescribeFromAudiogram(
          audiogram,
          profile: _buildPatientProfile(),
        );
        newGains = nl3Result.prescribedGains;
      } else {
        // Cambio a NL2 fuerza CIN off — sceneController ya lo hizo arriba.
        nl3Result = _nl3Prescriber.prescribeFromAudiogram(
          audiogram,
          profile: _buildPatientProfile(),
        );
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
            profile: _buildPatientProfile(),
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

    // 6.2 (system-audit-fix): la versión legacy invocaba
    // `CinModule.apply` directo y luego `_audioBridge.updateEqGains`/
    // `updateWdrcParams`. Tras task 6.1 el `BundleBuilder` ya aplica
    // CIN cuando `mode == comfortInNoise`; volver a invocarlo aquí
    // producía una doble reducción en las bandas non-speech (hallazgos
    // A-4 + M-5). Ahora reconstruimos el bundle con el nuevo modo y
    // delegamos la aplicación atómica a `_onApplyBundle`.
    //
    // Las transiciones de escena nunca rompen la amplificación: el
    // rollback atómico de `_onApplyBundle` restaura el snapshot DSP
    // previo si algún paso del bridge falla (Req 4.7), por lo que el
    // racional original se preserva sin la captura silenciosa.
    try {
      final bundle = _bundleBuilder.buildFromAudiogram(
        audiogram,
        profile: _buildPatientProfile(),
        mode: newMode,
        operatingMode: _operatingMode,
        gainScale: _gainScale,
      );

      // Reflejar inmediatamente el cambio visual de CIN/Quiet en la UI
      // (state.cinGains / state.prescriptionMode); el bundle se aplica
      // al motor DSP a continuación vía `_onApplyBundle`.
      if (newMode == PrescriptionMode.comfortInNoise) {
        emit(currentState.copyWith(
          cinGains: List<double>.unmodifiable(bundle.gainsDb),
          prescriptionMode: PrescriptionMode.comfortInNoise,
        ));
      } else {
        emit(currentState.copyWith(
          clearCinGains: true,
          prescriptionMode: PrescriptionMode.quiet,
        ));
      }

      add(ApplyAudiogramDrivenBundle(
        bundle: bundle,
        delta: _manualDelta,
      ));
    } catch (e, st) {
      developer.log(
        '_onSceneClassUpdated: error al construir el bundle: $e',
        name: 'AmplificationBloc',
        level: 1000,
        error: e,
        stackTrace: st,
      );
      emit(AmplificationError(
        message: 'No se pudo aplicar la transición de escena: $e',
      ));
      return;
    }
  }

  /// Persiste y aplica la experiencia previa del usuario con audífonos.
  ///
  /// Si el modo activo es Smart-NL3, recalcula la prescripción inyectando
  /// el [PatientProfile] con `experienceMonths` y aplica las nuevas
  /// ganancias al engine. Si el modo es NL2, sólo persiste el valor: la
  /// próxima activación de NL3 lo levantará desde el campo en memoria.
  Future<void> _onSetExperienceMonths(
    SetExperienceMonths event,
    Emitter<AmplificationState> emit,
  ) async {
    final clamped = event.months < 0 ? 0 : event.months;
    _experienceMonths = clamped;

    // Persistir tolerantemente — el repo ya hace try/catch interno.
    try {
      await _settingsRepository.setExperienceMonths(clamped);
    } catch (_) {
      // No interrumpir por error de persistencia.
    }

    final currentState = state;
    if (currentState is! AmplificationActive) return;

    // Si NL3 está activo, recalcular ganancias para que la corrección de
    // aclimatización surta efecto inmediatamente.
    //
    // 6.2 (system-audit-fix): la versión legacy invocaba `CinModule.apply`
    // directo cuando el `ScenePrescriptionController` estaba en
    // `comfortInNoise` y luego despachaba `updateEqGains` al bridge.
    // Tras task 6.1 el `BundleBuilder` ya aplica CIN dentro del bundle,
    // por lo que aquí basta con reconstruir el bundle con el modo
    // correspondiente y delegar la aplicación atómica a `_onApplyBundle`.
    // Eso evita la doble reducción CIN en bandas non-speech (hallazgos
    // A-4 + M-5) y deja la cobertura de rollback en un único lugar
    // (`_onApplyBundle`, Req 4.7).
    if (_currentPrescriberMode == PrescriberMode.smartNl3 && !_mhlActive) {
      try {
        final audiogram = _currentAudiogram ?? Audiogram.defaultAudiogram();
        final nl3Result = _nl3Prescriber.prescribeFromAudiogram(
          audiogram,
          profile: _buildPatientProfile(),
        );
        _lastNl3Result = nl3Result;

        final prescriptionMode =
            _sceneController.currentMode == PrescriptionMode.comfortInNoise
                ? PrescriptionMode.comfortInNoise
                : PrescriptionMode.quiet;

        final bundle = _bundleBuilder.buildFromAudiogram(
          audiogram,
          profile: _buildPatientProfile(),
          mode: prescriptionMode,
          operatingMode: _operatingMode,
          gainScale: _gainScale,
        );

        // Reflejar el nuevo experienceMonths + curvas NL3 + chip de modo
        // de inmediato en la UI. El bundle se aplica al motor DSP a
        // continuación vía `_onApplyBundle`, que también va a emitir un
        // `AmplificationActive` con `state.bundle` actualizado.
        emit(currentState.copyWith(
          experienceMonths: clamped,
          nl3Gains: nl3Result.prescribedGains,
          cinGains: prescriptionMode == PrescriptionMode.comfortInNoise
              ? List<double>.unmodifiable(bundle.gainsDb)
              : null,
          clearCinGains: prescriptionMode != PrescriptionMode.comfortInNoise,
          lossType: nl3Result.lossType,
          prescriptionMode: prescriptionMode,
        ));

        add(ApplyAudiogramDrivenBundle(
          bundle: bundle,
          delta: _manualDelta,
        ));
        return;
      } catch (e, st) {
        developer.log(
          '_onSetExperienceMonths: error al reconstruir el bundle '
          'tras cambio de experiencia: $e',
          name: 'AmplificationBloc',
          level: 1000,
          error: e,
          stackTrace: st,
        );
        emit(AmplificationError(
          message: 'No se pudo aplicar la nueva experiencia: $e',
        ));
        return;
      }
    }

    emit(currentState.copyWith(experienceMonths: clamped));
  }

  // ════════════════════════════════════════════════════════════════════
  // audiogram-driven-presets — wave 4: handlers del bundle clínico
  // ════════════════════════════════════════════════════════════════════

  /// Aplica atómicamente un [AudiogramDrivenBundle] al motor DSP,
  /// opcionalmente sumándole un [ManualAdjustmentDelta] aditivo.
  ///
  /// Secuencia atómica (sin yields entre llamadas):
  ///
  /// 1. `setMpoThresholdDbSpl(min(mpoProfileDbSpl))`
  /// 2. `updateWdrcParams(...)` con CR PTA-weighted, knee promediado
  ///    y attack/release del bundle.
  /// 3. `updateEqGains(finalGains)` con el bundle base + delta + clamp
  ///    a `[0, 50] dB` y a headroom MPO.
  /// 4. `updateNrLevel(bundle.nrLevel + delta.nrLevelDelta)`.
  ///
  /// Si alguno de los pasos falla:
  /// - se intenta rollback al snapshot previo (en orden inverso),
  /// - se emite [AmplificationError] con `failedStep` identificando el
  ///   paso que rompió la secuencia (Req 4.7).
  ///
  /// Target: ≤ 200 ms p95 (no se introducen delays artificiales; el
  /// budget se respeta a través del bridge nativo, ver
  /// `native-coordination.md`).
  ///
  /// Requisitos: 4.1, 4.3, 4.4, 4.5, 4.7, 10.1, 10.2
  Future<void> _onApplyBundle(
    ApplyAudiogramDrivenBundle event,
    Emitter<AmplificationState> emit,
  ) async {
    final bundle = event.bundle;
    final delta = event.delta;

    // 1. Validación previa del bundle — si falla, no tocamos el bridge.
    final violations = bundle.validate();
    if (violations.isNotEmpty) {
      emit(AmplificationError(
        message:
            'AudiogramDrivenBundle inválido: ${violations.join('; ')}',
        validationErrors: List<String>.unmodifiable(violations),
      ));
      return;
    }

    // 2. Snapshot DSP previo para rollback.
    final snapshot = _captureDspSnapshot();

    // 3. Calcular parámetros derivados del bundle + delta.
    final finalGains = _resolveFinalGains(bundle, delta);
    final mpoBroadband = _resolveBroadbandMpo(bundle);
    final bridgeCr = _resolveBridgeCompressionRatio(bundle, delta);
    final bridgeKnee = _resolveBridgeCompressionKnee(bundle, delta);
    final nrLevel = _resolveNrLevel(bundle, delta);
    final wdrcParams = WdrcParams(
      expansionKnee: bundle.expansionKneeDbSpl,
      compressionKnee: bridgeKnee,
      compressionRatio: bridgeCr,
      attackMs: bundle.wdrcAttackMs,
      releaseMs: bundle.wdrcReleaseMs,
    );

    // 4. Secuencia atómica. Cualquier excepción dispara rollback.
    int reachedStep = 0;
    try {
      await _audioBridge.setMpoThresholdDbSpl(mpoBroadband);
      reachedStep = 1;

      await _audioBridge.updateWdrcParams(wdrcParams);
      reachedStep = 2;

      await _audioBridge.updateEqGains(finalGains);
      reachedStep = 3;

      await _audioBridge.updateNrLevel(nrLevel);
      reachedStep = 4;
    } catch (e, st) {
      final failedStep = reachedStep + 1;
      developer.log(
        '_onApplyBundle: fallo en paso $failedStep: $e',
        name: 'AmplificationBloc',
        level: 1000,
        error: e,
        stackTrace: st,
      );
      // Rollback en orden inverso, hasta donde se haya llegado.
      await _rollbackToSnapshot(snapshot, reachedStep);
      emit(AmplificationError(
        message:
            'Aplicación atómica del bundle falló en el paso $failedStep: $e',
        failedStep: failedStep,
      ));
      return;
    }

    // 5. Persistencia best-effort del último bundle aplicado y
    //    actualización del state mirror local.
    _lastBundle = bundle;
    _manualDelta = delta;
    _operatingMode = bundle.mode;
    _gainScale = bundle.gainScale;
    try {
      final box = await _openSettingsBox();
      await box?.put('last_bundle', jsonEncode(bundle.toJson()));
    } catch (_) {
      // Persistencia no bloqueante (Req error handling §3).
    }

    // 6. Emitir [AmplificationActive] con los datos clínicos del
    //    bundle. Si todavía no hay un Active state (caso boot antes de
    //    `startAudio` haber emitido) se conserva el state actual.
    final current = state;
    if (current is AmplificationActive) {
      emit(current.copyWith(
        bundle: bundle,
        manualDelta: delta,
        clearManualDelta: delta == null,
        operatingMode: bundle.mode,
        gainScale: bundle.gainScale,
        lossType: bundle.lossType,
        prescriptionMode: bundle.prescriptionMode,
        activeNrLevel: nrLevel,
      ));
    }
  }

  /// Handler de [GainScaleChanged] — modifica el factor de escala de
  /// ganancia en Modo Amplificador y reaplica el bundle.
  ///
  /// Si el modo activo no es Amplificador el evento se ignora (con
  /// log de advertencia) — el `gainScale` no aplica en Diagnóstico
  /// por contrato (Req 13.4).
  ///
  /// Persiste el valor clampado bajo `amplifier_gain_scale` en
  /// `settings_box` y vuelve a despachar
  /// [ApplyAudiogramDrivenBundle].
  ///
  /// Requisitos: 13.6, 13.7
  Future<void> _onGainScaleChanged(
    GainScaleChanged event,
    Emitter<AmplificationState> emit,
  ) async {
    if (_operatingMode != OperatingMode.amplifier) {
      developer.log(
        '_onGainScaleChanged: ignorado (modo activo=$_operatingMode); '
        'gainScale solo aplica en Modo Amplificador.',
        name: 'AmplificationBloc',
        level: 900,
      );
      return;
    }

    final clamped = event.gainScale
        .clamp(
          AudiogramDrivenBundle.gainScaleMin,
          AudiogramDrivenBundle.gainScaleMax,
        )
        .toDouble();
    if (clamped != event.gainScale) {
      developer.log(
        '_onGainScaleChanged: ${event.gainScale} fuera de rango '
        '[${AudiogramDrivenBundle.gainScaleMin}, '
        '${AudiogramDrivenBundle.gainScaleMax}]; clampado a $clamped.',
        name: 'AmplificationBloc',
        level: 900,
      );
    }
    _gainScale = clamped;

    // Persistir el nuevo valor en Hive.
    try {
      final box = await _openSettingsBox();
      await box?.put(_kAmplifierGainScaleKey, clamped);
    } catch (_) {
      // Persistencia tolerante.
    }

    final audiogram = _currentAudiogram ?? Audiogram.defaultAudiogram();
    final prescriptionMode = _currentProfile != null
        ? EnvironmentProfileMapper.modeFor(_currentProfile!)
        : PrescriptionMode.quiet;

    try {
      final bundle = _bundleBuilder.buildFromAudiogram(
        audiogram,
        profile: _buildPatientProfile(),
        mode: prescriptionMode,
        operatingMode: OperatingMode.amplifier,
        gainScale: clamped,
        recdProvider: _maybeRecdProvider(),
      );
      add(ApplyAudiogramDrivenBundle(bundle: bundle, delta: _manualDelta));
    } catch (e, st) {
      developer.log(
        '_onGainScaleChanged: error al construir el bundle: $e',
        name: 'AmplificationBloc',
        level: 900,
        error: e,
        stackTrace: st,
      );
    }
  }

  /// Handler de [ManualEqAdjust] — incrementa de forma aditiva el
  /// `eqDeltaDb[bandIndex]` del [ManualAdjustmentDelta] activo,
  /// persiste el delta por modo y vuelve a despachar
  /// [ApplyAudiogramDrivenBundle] con el delta actualizado.
  ///
  /// Requisitos: 14.1, 14.6, 14.9
  Future<void> _onManualEqAdjust(
    ManualEqAdjust event,
    Emitter<AmplificationState> emit,
  ) async {
    final bandIndex = event.bandIndex;
    if (bandIndex < 0 || bandIndex >= ManualAdjustmentDelta.bandCount) {
      developer.log(
        '_onManualEqAdjust: bandIndex=$bandIndex fuera de rango '
        '[0, ${ManualAdjustmentDelta.bandCount - 1}]; evento ignorado.',
        name: 'AmplificationBloc',
        level: 900,
      );
      return;
    }

    final current = _manualDelta ?? ManualAdjustmentDelta.zero();
    final newEqDeltaDb = List<double>.from(current.eqDeltaDb);
    final raw = newEqDeltaDb[bandIndex] + event.deltaDelta;
    newEqDeltaDb[bandIndex] = raw
        .clamp(
          ManualAdjustmentDelta.eqDeltaMinDb,
          ManualAdjustmentDelta.eqDeltaMaxDb,
        )
        .toDouble();

    final newDelta = ManualAdjustmentDelta(
      eqDeltaDb: List<double>.unmodifiable(newEqDeltaDb),
      volumeDeltaDb: current.volumeDeltaDb,
      nrLevelDelta: current.nrLevelDelta,
      compressionRatioDelta: current.compressionRatioDelta,
      compressionKneeDeltaDbSpl: current.compressionKneeDeltaDbSpl,
      editedAt: _clock().toUtc(),
    );

    _manualDelta = newDelta;

    // Persistir el delta del modo activo (Req 14.6).
    try {
      await _persistManualDeltaFor(_operatingMode, newDelta);
    } catch (_) {
      // Persistencia tolerante.
    }

    // Re-despachar el bundle con el delta actualizado. Si todavía no
    // hay un bundle aplicado, reconstruirlo desde el audiograma actual.
    final bundle = _lastBundle ?? _buildBundleForCurrentMode();
    if (bundle == null) {
      developer.log(
        '_onManualEqAdjust: no hay bundle base disponible para aplicar '
        'el ajuste manual.',
        name: 'AmplificationBloc',
        level: 900,
      );
      return;
    }
    add(ApplyAudiogramDrivenBundle(bundle: bundle, delta: newDelta));
  }

  /// Handler de [ResetManualDelta] — pone a cero el
  /// [ManualAdjustmentDelta] del modo activo, persiste el delta
  /// neutro y vuelve a despachar el bundle base sin overlay.
  ///
  /// Requisitos: 14.1, 14.6, 14.9
  Future<void> _onResetManualDelta(
    ResetManualDelta event,
    Emitter<AmplificationState> emit,
  ) async {
    final zero = ManualAdjustmentDelta.zero();
    _manualDelta = null;

    try {
      await _persistManualDeltaFor(_operatingMode, zero);
    } catch (_) {
      // Persistencia tolerante.
    }

    final bundle = _lastBundle ?? _buildBundleForCurrentMode();
    if (bundle == null) {
      developer.log(
        '_onResetManualDelta: no hay bundle base disponible para '
        'aplicar el reset.',
        name: 'AmplificationBloc',
        level: 900,
      );
      return;
    }
    add(ApplyAudiogramDrivenBundle(bundle: bundle, delta: null));
  }

  // ─────────────────────────────────────────────────────────────────────
  // Helpers privados del bundle path
  // ─────────────────────────────────────────────────────────────────────

  /// Clave de Hive donde se persiste el `gainScale` del Modo
  /// Amplificador.
  static const String _kAmplifierGainScaleKey = 'amplifier_gain_scale';

  /// Clave de Hive del [ManualAdjustmentDelta] del Modo Diagnóstico.
  static const String _kManualDeltaDiagnosticKey = 'manual_delta_diagnostic';

  /// Clave de Hive del [ManualAdjustmentDelta] del Modo Amplificador.
  static const String _kManualDeltaAmplifierKey = 'manual_delta_amplifier';

  /// Default del `gainScale` cuando no hay valor persistido en
  /// Modo Amplificador (Req 13.7).
  static const double _kDefaultAmplifierGainScale = 0.40;

  /// Nivel de input típico (dB SPL) usado para clampar las ganancias
  /// finales contra el headroom MPO. Conversación normal ≈ 65 dB SPL.
  static const double _kTypicalInputDbSpl = 65.0;

  /// Margen de seguridad sustraído al headroom MPO (Req 10.2).
  static const double _kHeadroomSafetyMarginDb = 3.0;

  /// Snapshot del estado DSP previo a aplicar un bundle.
  ///
  /// Se usa para hacer rollback si la secuencia atómica de
  /// `_onApplyBundle` falla en cualquiera de sus 4 pasos.
  /// Cuando alguno de los campos es `null` el rollback de ese paso
  /// se omite (no había estado conocido para restaurar).
  _DspSnapshot _captureDspSnapshot() {
    final bundle = _lastBundle;
    return _DspSnapshot(
      mpoBroadbandDbSpl:
          bundle != null ? _resolveBroadbandMpo(bundle) : null,
      wdrcParams: bundle != null
          ? WdrcParams(
              expansionKnee: bundle.expansionKneeDbSpl,
              compressionKnee:
                  _resolveBridgeCompressionKnee(bundle, _manualDelta),
              compressionRatio:
                  _resolveBridgeCompressionRatio(bundle, _manualDelta),
              attackMs: bundle.wdrcAttackMs,
              releaseMs: bundle.wdrcReleaseMs,
            )
          : null,
      eqGains:
          bundle != null ? _resolveFinalGains(bundle, _manualDelta) : null,
      nrLevel: bundle != null ? _resolveNrLevel(bundle, _manualDelta) : null,
    );
  }

  /// Intenta restaurar el estado DSP previo al fallo. El argumento
  /// [reachedStep] indica el último paso que se completó exitosamente
  /// (1..4); el rollback opera en orden inverso desde ese paso.
  Future<void> _rollbackToSnapshot(
    _DspSnapshot snapshot,
    int reachedStep,
  ) async {
    Future<void> restore(int step, Future<void> Function() action) async {
      if (reachedStep < step) return;
      try {
        await action();
      } catch (e, st) {
        developer.log(
          '_rollbackToSnapshot: fallo restaurando paso $step: $e',
          name: 'AmplificationBloc',
          level: 1000,
          error: e,
          stackTrace: st,
        );
      }
    }

    // Orden inverso: 4 → 3 → 2 → 1.
    if (snapshot.nrLevel != null) {
      await restore(4, () => _audioBridge.updateNrLevel(snapshot.nrLevel!));
    }
    if (snapshot.eqGains != null) {
      await restore(3, () => _audioBridge.updateEqGains(snapshot.eqGains!));
    }
    if (snapshot.wdrcParams != null) {
      await restore(
        2,
        () => _audioBridge.updateWdrcParams(snapshot.wdrcParams!),
      );
    }
    if (snapshot.mpoBroadbandDbSpl != null) {
      await restore(
        1,
        () => _audioBridge.setMpoThresholdDbSpl(snapshot.mpoBroadbandDbSpl!),
      );
    }
  }

  /// Suma el delta sobre los `gainsDb` del bundle, aplica el clamp
  /// genérico `[0, 50] dB` y luego un clamp adicional por headroom
  /// MPO: `gainsDb[i] ≤ mpoProfileDbSpl[i] - input - 3 dB` (Req 10.2).
  List<double> _resolveFinalGains(
    AudiogramDrivenBundle bundle,
    ManualAdjustmentDelta? delta,
  ) {
    final gains = List<double>.filled(
      AudiogramDrivenBundle.bandCount,
      0.0,
      growable: false,
    );
    for (var i = 0; i < AudiogramDrivenBundle.bandCount; i++) {
      double g = bundle.gainsDb[i];
      if (delta != null) {
        g += delta.eqDeltaDb[i] + delta.volumeDeltaDb;
      }
      // Clamp al rango operativo del EQ.
      g = g
          .clamp(
            AudiogramDrivenBundle.gainMinDb,
            AudiogramDrivenBundle.gainMaxDb,
          )
          .toDouble();
      // Clamp por headroom MPO: nunca permitir gains que empujen el
      // pico de salida por encima del MPO de la banda.
      final headroom = bundle.mpoProfileDbSpl[i] -
          _kTypicalInputDbSpl -
          _kHeadroomSafetyMarginDb;
      if (headroom < g) {
        g = math.max(headroom, AudiogramDrivenBundle.gainMinDb);
      }
      gains[i] = g;
    }
    return List<double>.unmodifiable(gains);
  }

  /// Resuelve el MPO broadband enviado al bridge:
  /// `min(bundle.mpoProfileDbSpl)` clampado a `[80, 132]`.
  double _resolveBroadbandMpo(AudiogramDrivenBundle bundle) {
    var minVal = bundle.mpoProfileDbSpl[0];
    for (var i = 1; i < bundle.mpoProfileDbSpl.length; i++) {
      if (bundle.mpoProfileDbSpl[i] < minVal) {
        minVal = bundle.mpoProfileDbSpl[i];
      }
    }
    return minVal
        .clamp(
          AudiogramDrivenBundle.mpoMinDbSpl,
          AudiogramDrivenBundle.mpoMaxDbSpl,
        )
        .toDouble();
  }

  /// Calcula el ratio de compresión broadband enviado al bridge como
  /// promedio PTA-weighted de los 12 ratios del bundle. Las bandas
  /// PTA (500, 1000, 2000, 4000 Hz → índices 1, 3, 5, 9) pesan 2x;
  /// el resto 1x. Aplica el delta opcional y clampa al rango
  /// `[1.0, 3.0]`.
  double _resolveBridgeCompressionRatio(
    AudiogramDrivenBundle bundle,
    ManualAdjustmentDelta? delta,
  ) {
    const ptaIndices = {1, 3, 5, 9};
    double sum = 0;
    double weight = 0;
    for (var i = 0; i < bundle.compressionRatios.length; i++) {
      double cr = bundle.compressionRatios[i];
      if (delta != null) {
        cr += delta.compressionRatioDelta;
      }
      cr = cr
          .clamp(
            AudiogramDrivenBundle.compressionRatioMin,
            AudiogramDrivenBundle.compressionRatioMax,
          )
          .toDouble();
      final w = ptaIndices.contains(i) ? 2.0 : 1.0;
      sum += cr * w;
      weight += w;
    }
    return (sum / weight)
        .clamp(
          AudiogramDrivenBundle.compressionRatioMin,
          AudiogramDrivenBundle.compressionRatioMax,
        )
        .toDouble();
  }

  /// Promedia los 12 knees de compresión por banda y aplica el delta
  /// para producir el knee broadband enviado al bridge. Clampa al
  /// rango `[35, 65] dB SPL`.
  double _resolveBridgeCompressionKnee(
    AudiogramDrivenBundle bundle,
    ManualAdjustmentDelta? delta,
  ) {
    double sum = 0;
    for (final k in bundle.compressionKneesDbSpl) {
      sum += k;
    }
    var knee = sum / bundle.compressionKneesDbSpl.length;
    if (delta != null) {
      knee += delta.compressionKneeDeltaDbSpl;
    }
    return knee
        .clamp(
          AudiogramDrivenBundle.compressionKneeMinDbSpl,
          AudiogramDrivenBundle.compressionKneeMaxDbSpl,
        )
        .toDouble();
  }

  /// Aplica el `nrLevelDelta` opcional sobre `bundle.nrLevel` y
  /// clampa al rango `[0, 3]`.
  int _resolveNrLevel(
    AudiogramDrivenBundle bundle,
    ManualAdjustmentDelta? delta,
  ) {
    final base = bundle.nrLevel + (delta?.nrLevelDelta ?? 0);
    return base.clamp(
      AudiogramDrivenBundle.nrLevelMin,
      AudiogramDrivenBundle.nrLevelMax,
    );
  }

  /// Verifica que el audiograma contenga las 12 frecuencias estándar
  /// con valores finitos en `[-10, 120] dB HL`. Falso si falta alguna
  /// banda o algún umbral está fuera de rango.
  bool _isAudiogramComplete(Audiogram audiogram) {
    for (final f in Audiogram.standardFrequencies) {
      final v = audiogram.thresholds[f];
      if (v == null) return false;
      if (v.isNaN || v.isInfinite) return false;
      if (v < -10.0 || v > 120.0) return false;
    }
    return true;
  }

  /// Calcula la Mean Absolute Deviation por banda entre dos
  /// audiogramas. Devuelve `true` si la MAD máxima banda-a-banda
  /// supera el [thresholdDb] dado (Req 9.1).
  bool _audiogramMadExceeds(
    Audiogram a,
    Audiogram b,
    double thresholdDb,
  ) {
    for (final f in Audiogram.standardFrequencies) {
      final av = a.thresholds[f];
      final bv = b.thresholds[f];
      if (av == null || bv == null) return true; // Cambio estructural.
      if ((av - bv).abs() > thresholdDb) return true;
    }
    return false;
  }

  /// Carga el `gainScale` persistido bajo `amplifier_gain_scale` en
  /// `settings_box`, o devuelve el default ([_kDefaultAmplifierGainScale])
  /// cuando no hay valor guardado.
  Future<double> _loadAmplifierGainScale() async {
    try {
      final box = await _openSettingsBox();
      final raw = box?.get(_kAmplifierGainScaleKey);
      if (raw is num) {
        return raw
            .toDouble()
            .clamp(
              AudiogramDrivenBundle.gainScaleMin,
              AudiogramDrivenBundle.gainScaleMax,
            )
            .toDouble();
      }
    } catch (_) {
      // Persistencia tolerante: caer al default.
    }
    return _kDefaultAmplifierGainScale;
  }

  /// Carga el [ManualAdjustmentDelta] persistido para el modo
  /// indicado. Retorna `null` si no hay valor guardado o el blob es
  /// corrupto.
  Future<ManualAdjustmentDelta?> _loadManualDeltaFor(
    OperatingMode mode,
  ) async {
    final key = _manualDeltaKeyFor(mode);
    try {
      final box = await _openSettingsBox();
      final raw = box?.get(key);
      if (raw is String && raw.isNotEmpty) {
        final json = jsonDecode(raw) as Map<String, dynamic>;
        return ManualAdjustmentDelta.fromJson(json);
      }
    } catch (e) {
      developer.log(
        '_loadManualDeltaFor($mode): error al deserializar delta: $e',
        name: 'AmplificationBloc',
        level: 900,
      );
    }
    return null;
  }

  /// Persiste el delta en Hive bajo la clave correspondiente al modo
  /// indicado.
  Future<void> _persistManualDeltaFor(
    OperatingMode mode,
    ManualAdjustmentDelta delta,
  ) async {
    final key = _manualDeltaKeyFor(mode);
    final box = await _openSettingsBox();
    await box?.put(key, jsonEncode(delta.toJson()));
  }

  /// Devuelve la clave de Hive del delta correspondiente al modo
  /// indicado.
  String _manualDeltaKeyFor(OperatingMode mode) {
    switch (mode) {
      case OperatingMode.diagnostic:
        return _kManualDeltaDiagnosticKey;
      case OperatingMode.amplifier:
        return _kManualDeltaAmplifierKey;
    }
  }

  /// Construye un bundle desde el audiograma y modo actuales.
  /// Devuelve `null` si la construcción falla (audiograma incompleto,
  /// excepción del prescriptor delegado, etc.).
  AudiogramDrivenBundle? _buildBundleForCurrentMode() {
    final audiogram = _currentAudiogram ?? Audiogram.defaultAudiogram();
    final prescriptionMode = _currentProfile != null
        ? EnvironmentProfileMapper.modeFor(_currentProfile!)
        : PrescriptionMode.quiet;
    try {
      return _bundleBuilder.buildFromAudiogram(
        audiogram,
        profile: _buildPatientProfile(),
        mode: prescriptionMode,
        operatingMode: _operatingMode,
        gainScale: _gainScale,
        recdProvider: _maybeRecdProvider(),
      );
    } catch (e, st) {
      developer.log(
        '_buildBundleForCurrentMode: error al construir bundle: $e',
        name: 'AmplificationBloc',
        level: 900,
        error: e,
        stackTrace: st,
      );
      return null;
    }
  }

  /// Abre el `settings_box` de Hive si todavía no está abierto.
  /// Devuelve `null` si Hive no está disponible (test sin Hive
  /// inicializado) en lugar de propagar la excepción.
  Future<Box<dynamic>?> _openSettingsBox() async {
    try {
      if (Hive.isBoxOpen(settingsBoxName)) {
        return Hive.box<dynamic>(settingsBoxName);
      }
      return await Hive.openBox<dynamic>(settingsBoxName);
    } catch (e) {
      developer.log(
        '_openSettingsBox: Hive no disponible: $e',
        name: 'AmplificationBloc',
        level: 900,
      );
      return null;
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

/// Snapshot inmutable del último estado DSP aplicado, usado por
/// `_onApplyBundle` para hacer rollback en caso de fallo en la
/// secuencia atómica de 4 llamadas al [AudioBridge].
///
/// Cada campo es opcional: si la aplicación previa nunca llegó a
/// cierto paso (por ejemplo, primera aplicación tras boot) los
/// valores correspondientes son `null` y el rollback de ese paso
/// se omite.
class _DspSnapshot {
  /// Valor del MPO broadband (dB SPL) que estaba activo en el bridge.
  final double? mpoBroadbandDbSpl;

  /// Parámetros WDRC que estaban activos en el bridge.
  final WdrcParams? wdrcParams;

  /// Ganancias EQ (12 valores, dB) que estaban activas en el bridge.
  final List<double>? eqGains;

  /// Nivel de NR que estaba activo en el bridge.
  final int? nrLevel;

  const _DspSnapshot({
    required this.mpoBroadbandDbSpl,
    required this.wdrcParams,
    required this.eqGains,
    required this.nrLevel,
  });
}
