import 'dart:async';
import 'dart:convert';
import 'dart:developer' as developer;
import 'dart:math' as math;

import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:hive/hive.dart';

import '../../data/bridges/audio_bridge.dart';
import '../../data/repositories/settings_repository_impl.dart';
import '../../domain/audiogram_driven_presets/audiogram_driven_bundle.dart';
import '../../domain/audiogram_driven_presets/bundle_builder.dart';
import '../../domain/audiogram_driven_presets/environment_profile_mapper.dart';
import '../../domain/audiogram_driven_presets/manual_adjustment_delta.dart';
import '../../domain/audiogram_driven_presets/style_applicator.dart';
import '../../domain/audiogram_driven_presets/operating_mode.dart';
import '../../domain/audiogram_driven_presets/recd_provider.dart';
import '../../domain/audiogram_driven_presets/wcpf_fitter.dart';
import '../../domain/entities/audio_config.dart';
import '../../domain/entities/audiogram.dart';
import '../../domain/entities/environment_profile.dart';
import '../../domain/entities/eq_preset.dart';
import '../../domain/entities/nl3_prescription_result.dart';
import '../../domain/entities/patient_profile.dart';
import '../../domain/entities/prescription_mode.dart';
import '../../domain/entities/wdrc_params.dart';
import '../../domain/gain_prescriber.dart';
import '../../domain/gain_prescriber_nl3.dart';
import '../../domain/repositories/audiogram_repository.dart';
import '../../domain/repositories/profile_repository.dart';
import '../../domain/repositories/settings_repository.dart';
import '../../domain/scene_prescription_controller.dart';
import '../../scene/scene_class.dart';
import '../../scene/scene_engine.dart';
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

  /// Expone el [AudioBridge] para que screens orientadas a diagnóstico
  /// (por ejemplo, `SmartSceneScreen` en su polling 1 Hz de
  /// `getDspStageMetrics()`, o `DiagnosticoDspScreen` para el progreso
  /// de grabación) puedan invocar métodos del bridge sin acoplarse al
  /// `MethodChannel` directo. Mantiene el patrón ya usado por los otros
  /// repositorios expuestos arriba.
  ///
  /// Requisitos: 2.1, 2.2, 2.10
  AudioBridge get audioBridge => _audioBridge;

  /// Expone el audiograma actualmente cargado en el bloc.
  ///
  /// La pantalla de Diagnóstico DSP lo lee para incluir
  /// `audiogramThresholds` en el JSON acompañante (Req 6.6). Devuelve
  /// `null` cuando todavía no se cargó (boot temprano o estado idle).
  ///
  /// Requisitos: 6.6
  Audiogram? get currentAudiogram => _currentAudiogram;

  /// Expone el último [AudiogramDrivenBundle] aplicado atómicamente al
  /// motor.
  ///
  /// La pantalla de Diagnóstico DSP lo lee para registrar el snapshot
  /// clínico (gains, compresión, MPO, NR, attack/release) al momento
  /// de la grabación (Req 6.5, 6.7, 6.13). Devuelve `null` cuando
  /// todavía no se aplicó ningún bundle al motor.
  ///
  /// Requisitos: 6.5, 6.7
  AudiogramDrivenBundle? get lastBundle => _lastBundle;

  /// Mirror lógico del estado del Smart Scene Engine que vive en
  /// [_smartEnabled].
  ///
  /// La pantalla de Diagnóstico DSP lo lee para incluir `smartEnabled`
  /// en el JSON acompañante (Req 6.13). El bloc fuerza este mirror a
  /// `false` durante MHL Prescripción y Modo Música (Req 1.5, 1.6),
  /// y lo restaura al desactivar el modo, así que el valor leído
  /// refleja siempre el estado clínicamente correcto en el instante
  /// de la grabación.
  ///
  /// Requisitos: 6.13
  bool get isSmartEnabled => _smartEnabled;

  /// Versión pública de `_effectiveCompressionRatio`.
  ///
  /// Permite a las screens (en particular `DiagnosticoDspScreen`)
  /// registrar en el JSON el `compressionRatio` EFECTIVAMENTE aplicado
  /// al motor (con el offset del slider "Comodidad" del usuario) en
  /// lugar del valor crudo del bundle. Mantiene consistencia con
  /// `dnn.intensity` y `nrLevel`, que también se serializan con valores
  /// de Settings, no con defaults del bundle.
  ///
  /// Operación read-only sobre [bundle]: nunca lo muta.
  ///
  /// Requisitos: 4.4, 4.5, 6.7
  double computeEffectiveCompressionRatio(AudiogramDrivenBundle bundle) =>
      _effectiveCompressionRatio(bundle);

  /// Versión pública de `_resolveBroadbandMpo`.
  ///
  /// Devuelve el MPO broadband enviado al bridge para [bundle]: el
  /// mínimo de `bundle.mpoProfileDbSpl` clampado al rango
  /// `[80, 132] dB SPL`. La pantalla de Diagnóstico DSP lo usa como
  /// `mpoThresholdDbSpl` escalar en el JSON acompañante (Req 6.6).
  ///
  /// Operación read-only sobre [bundle].
  ///
  /// Requisitos: 6.6
  double computeBroadbandMpo(AudiogramDrivenBundle bundle) =>
      _resolveBroadbandMpo(bundle);

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

  // ═════════════════════════════════════════════════════════════════
  // tecnico-paciente-feature-parity — task 4.2 / 4.3
  // ═════════════════════════════════════════════════════════════════

  /// Estado lógico del "Smart Scene Engine" según lo entiende el bloc.
  ///
  /// El control real del clasificador automático en el motor C++ vive en
  /// el lado de UI (el handler Kotlin `applyMhlPrescription` ya invoca
  /// `setAutoClassifyEnabled(false)` defensivamente al activar MHL o
  /// Modo Música, ver `AudioMethodChannel.kt`). Este field es el mirror
  /// lógico que el bloc usa para el snapshot/restore en los handlers de
  /// MHL Prescripción (task 4.2) y Modo Música (task 4.3).
  ///
  /// Default `false` mientras el técnico no expone un setter dedicado en
  /// el `AudioBridge`. Cuando un futuro handler de "ToggleSmart" exista,
  /// este campo será su single-source-of-truth.
  bool _smartEnabled = false;

  /// Timer del polling Smart continuo (smart-continuo-dnn-modulado).
  /// Se arma a 1 Hz cuando [_smartEnabled] = true; cancelado en cualquier
  /// otro caso. La fuente de la clase es
  /// `getDspStageMetrics()['environmentClass']` — la 4-clases real del
  /// `EnvironmentClassifier` C++.
  Timer? _smartPollTimer;

  /// Última clase de entorno conocida desde el polling. Usada para
  /// no despachar `ChangeProfile` redundante (idempotencia) y para
  /// alimentar el chip indicador de escena en `main_screen.dart`.
  /// Expuesto como [lastEnvClass] para BlocBuilder/listeners.
  int? _lastEnvClass;

  /// Lectura pública del último `environmentClass` reportado por el
  /// polling Smart (smart-continuo-dnn-modulado). Devuelve `null`
  /// cuando el polling no está activo o todavía no hubo lectura.
  int? get lastEnvClass => _lastEnvClass;

  /// Motor de análisis de escenas para Smart automático mejorado.
  /// Inicializado lazy en el primer tick de `_startSmartPolling()`.
  /// Null cuando Smart está apagado.
  SceneEngine? _sceneEngine;

  /// Audiograma cargado para Smart automático. Null si no hay audiograma
  /// medido (fallback a default en `analyze()`).
  Audiogram? _audiogram;

  /// Última clase de escena detectada por el análisis completo del Smart
  /// automático (SceneClass.QUIET/SPEECH/NOISE/etc). Usado para
  /// idempotencia: solo aplicar preset si la clase cambió.
  SceneClass? _lastSceneClass;

  /// Snapshot del [_smartEnabled] al activar MHL Prescripción o Modo
  /// Música. Permite restaurar el estado previo al desactivar el modo.
  ///
  /// Réplica del campo `_smartBeforeMhl` del paciente
  /// (`PACIENTE/oir_pro_patient_app/lib/presentation/home_screen.dart`).
  /// Cuando los dos toggles se cruzan (Música ON → MHL ON o viceversa),
  /// el bloc respeta el snapshot anidado: el Smart "real" guardado al
  /// activar el primer modo se preserva hasta que se apague el segundo.
  ///
  /// `null` cuando no hay un modo MHL/Música activo (no hay nada que
  /// restaurar).
  ///
  /// Requisitos: 1.5, 1.6
  bool? _smartEnabledBeforeMhl;

  /// Snapshot simétrico del [_smartEnabled] al activar Modo Música.
  ///
  /// Réplica del campo `_smartBeforeMusic` del paciente
  /// (`home_screen.dart`). El cruce con MHL es anidado: si MHL ya
  /// había guardado un Smart previo, ese mismo valor se respeta al
  /// activar Música porque la rama OFF de MHL ejecutada como mutex
  /// restaura `_smartEnabled` antes de que Música tome su snapshot.
  ///
  /// Requisitos: 1.5, 1.6
  bool? _smartEnabledBeforeMusic;

  /// Mirror lógico del flag `musicModeEnabled` persistido en
  /// [SettingsRepository]. Permite que `_onSceneClassUpdated` y otras
  /// rutinas dependientes ignoren eventos de clasificación cuando
  /// Música está ON. La fuente de verdad para persistencia sigue
  /// siendo el repositorio.
  ///
  /// Requisitos: 1.2, 1.4, 1.11
  bool _musicModeActive = false;

  /// Mirror lógico del flag `conversationMode` persistido en Hive
  /// bajo la key `'conversationMode'`. Indica si el "Modo Conversación"
  /// (SCO baja latencia) está activo. Se carga en Phase 1 del boot y
  /// se persiste en cada toggle.
  ///
  /// Requisitos: modo-conversacion-sco
  bool _conversationMode = false;

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

  /// Delay aplicado entre la finalización exitosa de
  /// `audioBridge.startAudio` y la aplicación de los setters runtime
  /// (Phase 3 del lifecycle, Req 3.3 del spec
  /// `tecnico-paciente-feature-parity`). En producción es 200 ms (mismo
  /// valor que el paciente). En tests del bloc se inyecta `Duration.zero`
  /// para que las aserciones sobre transiciones de estado no necesiten
  /// awaits artificiales.
  final Duration _bootDelay;

  AmplificationBloc({
    required AudioBridge audioBridge,
    required AudiogramRepository audiogramRepository,
    required ProfileRepository profileRepository,
    required SettingsRepository settingsRepository,
    required GainPrescriber gainPrescriber,
    DateTime Function()? clock,
    Duration bootDelay = const Duration(milliseconds: 200),
  })  : _audioBridge = audioBridge,
        _audiogramRepository = audiogramRepository,
        _profileRepository = profileRepository,
        _settingsRepository = settingsRepository,
        _gainPrescriber = gainPrescriber,
        _clock = clock ?? DateTime.now,
        _bootDelay = bootDelay,
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
    // tecnico-paciente-feature-parity — task 4.2: nuevo handler para
    // "MHL Prescripción" como modo selectivo (gains flat 8 dB + ratio 1.0
    // sin tocar NR/DNN/knees/attack/release). El evento legacy
    // [ToggleMhlMode] se conserva con su firma actual; en task 4.4
    // delegará a este handler.
    on<ToggleMhlPrescription>(_onToggleMhlPrescription);
    // tecnico-paciente-feature-parity — task 4.3: handler de "Modo Música"
    // como modo selectivo (NR=0 + dnnIntensity=0 sin tocar EQ/WDRC/knees/
    // attack/release). Réplica simétrica de [_onToggleMhlPrescription]; el
    // cruce con MHL (Req 1.4) ejecuta la rama OFF de MHL primero.
    on<ToggleMusicMode>(_onToggleMusicMode);
    // smart-continuo-dnn-modulado: handler del Smart Scene Engine
    // continuo. Activa/desactiva el clasificador C++ + el polling Dart
    // 1 Hz que mapea escena → profile + cap de DNN intensity.
    on<ToggleSmart>(_onToggleSmart);
    // modo-conversacion-sco: handler del toggle "Modo Conversación"
    // (SCO baja latencia). Activa/desactiva el modo de conversación
    // en el motor nativo con persistencia en Hive.
    on<ToggleConversationMode>(_onToggleConversationMode);
    // tecnico-paciente-feature-parity — task 4.5: handler del slider
    // "Comodidad". Recalcula WDRC con `_effectiveCompressionRatio(bundle)`
    // sobre el bundle activo y reaplica solo `compressionRatio` al motor;
    // los demás parámetros (knees, attack/release, NR, EQ, MPO) quedan
    // intactos. La persistencia del valor `comfort` ocurre en la UI
    // (`SimulatorScreen.onChangeEnd`) ANTES del despacho del evento; el
    // handler lee `comfort` vía `SettingsRepository.comfort` (sync) dentro
    // del helper.
    on<ChangeComfort>(_onChangeComfort);
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

  /// Inicia la amplificación con secuencia ordenada en 4 fases.
  ///
  /// **tecnico-paciente-feature-parity — task 5.1 (Req 1.13, 1.14, 3.1,
  /// 3.2, 3.3, 3.4, 3.5, 3.7)**:
  ///
  /// La secuencia replica la del paciente (`PACIENTE/.../home_screen.dart`)
  /// para evitar el race del lifecycle donde setters DSP se aplicaban
  /// antes de que el motor JNI estuviera listo y silenciosamente se
  /// perdían:
  ///
  /// 1. **Fase 1 — Carga de estado persistido (timeout 2000 ms).** Sin
  ///    tocar el motor. Carga audiograma, modo de operación, gainScale,
  ///    manualDelta, perfil, volumen, modo prescriptor, experiencia,
  ///    edad, NL2/NL3 gains, bundle inicial, lastEqPreset, flags
  ///    `mhlPrescriptionEnabled`/`musicModeEnabled` y `nrLevel`. Si la
  ///    carga falla o excede 2000 ms, emite
  ///    `AmplificationError('Fallo de carga de configuración persistida')`
  ///    y NO invoca `startAudio` (Req 3.2). Detección defensiva del
  ///    estado inválido `(mhl, music) = (true, true)`: fuerza
  ///    `musicModeEnabled = false` y log warning antes de continuar
  ///    (Req 1.14).
  ///
  /// 2. **Fase 2 — `audioBridge.startAudio(config)` con timeout 5000 ms.**
  ///    En fallo emite `AmplificationError` y NO aplica setters runtime
  ///    (Req 3.7).
  ///
  /// 3. **Fase 3 — `Future.delayed(200 ms)`.** El motor JNI necesita
  ///    ~150 ms para producir el primer callback de `AudioRecord`.
  ///    Aplicar setters antes hace que el primer ciclo del DSP los
  ///    pise con valores default (Req 3.3).
  ///
  /// 4. **Fase 4 — Setters runtime en orden estricto (Req 3.4):**
  ///    `updateEqGains` (con [_resolveGainsForPreset]) →
  ///    `updateWdrcParams` (con [_effectiveCompressionRatio]) →
  ///    `setMpoThresholdDbSpl` → `updateNrLevel` → `setSmartEnabled`
  ///    (mirror lógico — el técnico no expone setter dedicado, ver
  ///    nota abajo) → `setMhlPrescriptionEnabled` (sólo si
  ///    persistido `true`) → `setMusicModeEnabled` (sólo si persistido
  ///    `true`) → `updateVolume`. En excepción de cualquier setter:
  ///    detener cadena, emitir `AmplificationError(setterName)`, NO
  ///    revertir setters previos (Req 3.5).
  ///
  /// **Nota sobre `setSmartEnabled`**: el [AudioBridge] del técnico no
  /// expone un setter dedicado para el Smart Scene Engine. El
  /// invariante clínico al boot — Smart=false hasta que el usuario lo
  /// active — se mantiene actualizando el mirror lógico
  /// [_smartEnabled] que los handlers de MHL/Música snapshotean. Si
  /// en el futuro [AudioBridge] expone `setSmartEnabled`, este lugar
  /// de la cadena es donde la llamada nativa debe insertarse, sin
  /// alterar el orden ni el flag mirror.
  ///
  /// Tras Fase 4: persiste `_lastBundle`, escribe `last_bundle` en
  /// `settings_box` (best-effort), suscribe streams del engine y
  /// emite `AmplificationActive` con los datos clínicos del bundle
  /// inicial (gains, lossType, prescriptionMode, modo, gainScale).
  ///
  /// Requisitos: 1.13, 1.14, 3.1, 3.2, 3.3, 3.4, 3.5, 3.7
  Future<void> _onStartAmplification(
    StartAmplification event,
    Emitter<AmplificationState> emit,
  ) async {
    if (state is AmplificationActive || state is AmplificationStarting) {
      return;
    }

    emit(const AmplificationStarting());

    // ─────────────────────────────────────────────────────────────
    // Fase 0 — Verificación de auricular externo (seguridad).
    // Las ganancias EQ de 20-50 dB diseñadas para auricular saturan
    // y distorsionan en un speaker a 5 cm del oído. Bloquear inicio.
    // ─────────────────────────────────────────────────────────────
    try {
      final hasExternal = await _audioBridge.hasExternalOutput();
      if (!hasExternal) {
        emit(const AmplificationError(
          message: 'Conectá un auricular o parlante externo para activar. '
              'El parlante del celular no es seguro para amplificación.',
        ));
        return;
      }
    } catch (e) {
      // Si falla el check (API no disponible), permitir continuar
      // con advertencia. No bloquear por un fallo de consulta.
      developer.log(
        'Boot Phase 0: hasExternalOutput falló: $e — continuando.',
        name: 'AmplificationBloc',
        level: 800,
      );
    }

    // ─────────────────────────────────────────────────────────────
    // Fase 1 — Carga de estado persistido (timeout 2000 ms).
    // Sin tocar el motor nativo (Req 3.1, 3.2).
    // ─────────────────────────────────────────────────────────────
    late final AudiogramDrivenBundle initialBundle;
    late final AudioConfig config;
    NL3PrescriptionResult? nl3Result;
    EqPreset? bootPreset;
    late final bool mhlPersisted;
    late final bool musicPersisted;

    try {
      await Future<void>(() async {
        // 1. Audiograma + auto-detección OperatingMode/gainScale
        //    (Req 13.1, 13.2, 13.4).
        final storedAudiogram = await _audiogramRepository.getAudiogram();
        final hasMeasuredAudiogram = storedAudiogram != null &&
            _isAudiogramComplete(storedAudiogram);
        _currentAudiogram = storedAudiogram ?? Audiogram.defaultAudiogram();

        if (hasMeasuredAudiogram) {
          _operatingMode = OperatingMode.diagnostic;
          _gainScale = 1.0;
        } else {
          _operatingMode = OperatingMode.amplifier;
          _gainScale = await _loadAmplifierGainScale();
        }

        // 2. ManualAdjustmentDelta del modo activo (Req 14.6).
        _manualDelta = await _loadManualDeltaFor(_operatingMode);

        // 3. Último perfil + volumen.
        final lastConfig = await _settingsRepository.restoreLastConfig();
        final profileName = lastConfig.lastProfile ?? 'Conversación';
        _currentVolumeDb = lastConfig.lastVolume ?? 0.0;
        _currentProfile =
            await _profileRepository.getProfileByName(profileName) ??
                EnvironmentProfile.conversation;

        // 4. Modo prescriptor (Req 5.7, 5.8). Tolerante a fallo.
        try {
          _currentPrescriberMode =
              await _settingsRepository.getPrescriberMode();
        } catch (_) {
          // Default smartNl2.
        }
        _sceneController.setPrescriberMode(_currentPrescriberMode);

        // 5. Experiencia previa + edad. Tolerantes; informativos para
        //    el bundle path (real-ear conversion log — A-10).
        try {
          _experienceMonths =
              await _settingsRepository.getExperienceMonths();
        } catch (_) {
          _experienceMonths = null;
        }
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

        // 6. Ganancias NL2 (cache para state.nl2Gains) y NL3 si
        //    el modo restaurado lo pide.
        final eqGains =
            _gainPrescriber.prescribeFromAudiogram(_currentAudiogram!);
        _lastNl2Gains = List<double>.unmodifiable(eqGains);

        if (_currentPrescriberMode == PrescriberMode.smartNl3) {
          nl3Result = _nl3Prescriber.prescribeFromAudiogram(
            _currentAudiogram!,
            profile: _buildPatientProfile(),
          );
        }
        _lastNl3Result = nl3Result;

        // 7. Bundle clínico inicial — fuente de verdad para los
        //    setters runtime de Phase 4 (gains, WDRC, MPO, NR).
        initialBundle = _bundleBuilder.buildFromAudiogram(
          _currentAudiogram!,
          profile: _buildPatientProfile(),
          mode: PrescriptionMode.quiet,
          operatingMode: _operatingMode,
          gainScale: _gainScale,
          recdProvider: _maybeRecdProvider(),
        );

        // 8. AudioConfig usado por startAudio (Phase 2). Aquí pasamos
        //    los parámetros base del perfil/bundle pero sin aplicar
        //    todavía `_effectiveCompressionRatio` ni el delta — esos
        //    valores se aplican como setters runtime DESPUÉS del
        //    delay de 200 ms (Req 3.3, 3.4).
        final startupGains =
            (_currentPrescriberMode == PrescriberMode.smartNl3 &&
                    nl3Result != null)
                ? nl3Result!.prescribedGains
                : eqGains;
        config = AudioConfig(
          eqGains: startupGains,
          volumeDb: _currentVolumeDb,
          wdrcParams: WdrcParams(
            expansionKnee: _currentProfile!.expansionKnee,
            compressionKnee: _currentProfile!.compressionKnee,
            compressionRatio: _currentProfile!.compressionRatio,
          ),
          nrLevel: _currentProfile!.nrLevel,
        );

        // 9. lastEqPreset persistido — Phase 4 setter 1 lo pasa por
        //    [_resolveGainsForPreset] para cubrir bundles legacy
        //    (Req 5.1, 5.2).
        bootPreset = await _readBootEqPreset();

        // 10. Flags MHL/Música persistidos (Req 1.13, 1.14).
        mhlPersisted = _readMhlPrescriptionEnabledOrFalse();
        var music = _readMusicModeEnabledOrFalse();

        if (mhlPersisted && music) {
          // Req 1.14: estado inválido detectado al boot. Forzar
          // `musicModeEnabled = false` y dejar log warning antes de
          // continuar. La UI ya impone mutex, pero al boot pueden
          // coexistir si un binario anterior los persistió juntos.
          developer.log(
            'Boot Phase 1: estado inválido detectado '
            '(mhlPrescriptionEnabled=true, musicModeEnabled=true). '
            'Forzando musicModeEnabled=false para preservar mutex '
            '(Req 1.14).',
            name: 'AmplificationBloc',
            level: 900,
          );
          try {
            await _settingsRepository.setMusicModeEnabled(false);
          } catch (e, st) {
            developer.log(
              'Boot Phase 1: persistencia de musicModeEnabled=false '
              'falló: $e — continuando con music=false en memoria.',
              name: 'AmplificationBloc',
              level: 900,
              error: e,
              stackTrace: st,
            );
          }
          music = false;
        }
        musicPersisted = music;

        // 11. Flag conversationMode desde Hive. Default: false.
        try {
          final box = await _openSettingsBox();
          final raw = box?.get('conversationMode');
          _conversationMode = raw is bool ? raw : false;
        } catch (_) {
          _conversationMode = false;
        }
      }).timeout(const Duration(milliseconds: 2000));
    } on TimeoutException catch (e, st) {
      developer.log(
        'Boot Phase 1: timeout 2000 ms en carga persistida.',
        name: 'AmplificationBloc',
        level: 1000,
        error: e,
        stackTrace: st,
      );
      emit(const AmplificationError(
        message: 'Fallo de carga de configuración persistida',
      ));
      return;
    } catch (e, st) {
      developer.log(
        'Boot Phase 1: error de carga persistida: $e',
        name: 'AmplificationBloc',
        level: 1000,
        error: e,
        stackTrace: st,
      );
      emit(const AmplificationError(
        message: 'Fallo de carga de configuración persistida',
      ));
      return;
    }

    // ─────────────────────────────────────────────────────────────
    // Fase 2 — startAudio con timeout 5000 ms (Req 3.7).
    // ─────────────────────────────────────────────────────────────
    try {
      await _audioBridge
          .startAudio(config)
          .timeout(const Duration(milliseconds: 5000));
    } on TimeoutException catch (e, st) {
      developer.log(
        'Boot Phase 2: startAudio excedió 5000 ms.',
        name: 'AmplificationBloc',
        level: 1000,
        error: e,
        stackTrace: st,
      );
      emit(const AmplificationError(
        message: 'Fallo de arranque del engine: timeout 5000 ms',
      ));
      return;
    } catch (e, st) {
      developer.log(
        'Boot Phase 2: startAudio falló: $e',
        name: 'AmplificationBloc',
        level: 1000,
        error: e,
        stackTrace: st,
      );
      emit(AmplificationError(
        message: 'Fallo de arranque del engine: $e',
      ));
      return;
    }

    // Suscripciones a streams del engine. Independientes del orden
    // de setters runtime; se montan justo después de que startAudio
    // retornó éxito para no perder eventos tempranos del motor.
    _subscribeToStreams();

    // ─────────────────────────────────────────────────────────────
    // Fase 3 — Delay de 200 ms (Req 3.3).
    // ─────────────────────────────────────────────────────────────
    await Future<void>.delayed(_bootDelay);

    // ─────────────────────────────────────────────────────────────
    // Fase 4 — Setters runtime (Req 3.4, 3.5).
    //
    // La cadena atómica (MPO → WDRC → EQ → NR con rollback) la maneja
    // `_onApplyBundle` (Req 4.7 del spec audiogram-driven-presets);
    // dispatcheamos `ApplyAudiogramDrivenBundle` para reusar esa lógica
    // probada en lugar de aplicar setters manualmente. Después del
    // bundle aplicamos los modos persistidos y el volumen — esos sí
    // viven solo en el path de boot del técnico, así que se aplican
    // directamente acá.
    // ─────────────────────────────────────────────────────────────

    // 1) Smart mirror queda en false al boot. El invariante clínico
    //    se mantiene actualizando el mirror lógico [_smartEnabled]
    //    que los handlers de MHL Prescripción y Modo Música
    //    snapshotean. Si en el futuro [AudioBridge] expone
    //    `setSmartEnabled`, este lugar de la cadena es donde la
    //    llamada nativa debe insertarse.
    _smartEnabled = false;

    //    Sincronizar el estado NATIVO con el mirror lógico: el motor
    //    arranca con `autoClassifyEnabled_ = true` por default (header
    //    C++), así que sin esto el clasificador quedaría ON pisando el
    //    WDRC cada bloque mientras el mirror dice false (desincronización).
    //    El Técnico es manual: clasificador APAGADO en el modo normal.
    //    Tolerante a fallo — no abortar el boot si el canal nativo falla.
    //    Cadena: updateAutoClassify → AudioMethodChannel.handleUpdateAutoClassify
    //    → nativeBridge.setAutoClassifyEnabled(false).
    try {
      await const MethodChannel('com.psk.hearing_aid/audio')
          .invokeMethod('updateAutoClassify', {'enabled': false});
    } catch (e, st) {
      developer.log(
        'No se pudo sincronizar autoClassify=false al boot (no crítico)',
        name: 'AmplificationBloc',
        error: e,
        stackTrace: st,
      );
    }

    // 1b) Inicializar y habilitar el DNN denoiser (GTCRN). El modelo se
    //     carga desde assets y se habilita con la intensidad persistida.
    //     Sin esto, el DNN queda en bypass permanente y el ruido no se
    //     filtra. Tolerante: si falla, el motor sigue con NR Wiener.
    try {
      await const MethodChannel('com.psk.hearing_aid/audio')
          .invokeMethod<bool>('initDnnDenoiser');
      await const MethodChannel('com.psk.hearing_aid/audio')
          .invokeMethod<void>('setDnnEnabled', {'enabled': true});
      double dnnInt = 0.6;
      try { dnnInt = _settingsRepository.dnnIntensity; } catch (_) {}
      await _audioBridge.setDnnIntensity(dnnInt);
    } catch (e, st) {
      developer.log(
        'Boot Phase 4: initDnnDenoiser falló: $e — NR Wiener activo.',
        name: 'AmplificationBloc',
        level: 800,
        error: e,
        stackTrace: st,
      );
    }

    // 1c) Aplicar micrófono preferido si hay uno persistido.
    // Tolerante: si falla, el motor usa el mic default (builtin).
    try {
      final box = await _openSettingsBox();
      final preferredMicId = box?.get('preferred_mic_id');
      if (preferredMicId is int && preferredMicId != -1) {
        await _audioBridge.setPreferredMicrophone(preferredMicId);
      }
    } catch (e, st) {
      developer.log(
        'Boot Phase 4: setPreferredMicrophone falló: $e — mic default.',
        name: 'AmplificationBloc',
        level: 800,
        error: e,
        stackTrace: st,
      );
    }

    // 2) Emitir Active inicial ANTES de dispatchear el bundle. El
    //    handler `_onApplyBundle` reemitirá `Active` con `bundle:
    //    initialBundle` después de aplicar la cadena atómica al
    //    motor; los tests existentes esperan ambas emisiones.
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
      conversationMode: _conversationMode,
    ));

    // 3) Cadena atómica MPO → WDRC → EQ → NR (Req 4.7 del spec
    //    audiogram-driven-presets). Llamamos directamente a
    //    `_onApplyBundle` (en vez de `add(...)`) para que la cadena
    //    se ejecute inline y los setters de modo/volumen que vienen
    //    después queden DESPUÉS de la cadena atómica, no antes (de lo
    //    contrario el `add` encola el evento y los setters
    //    posteriores corren primero).
    await _onApplyBundle(
      ApplyAudiogramDrivenBundle(
        bundle: initialBundle,
        delta: _manualDelta,
      ),
      emit,
    );

    // 4) Modos persistidos y volumen: aplicados directamente al
    //    motor después del bundle. La cadena atómica del bundle no
    //    los toca porque son estado runtime de UI propio del
    //    técnico (no parte del bundle clínico).
    if (mhlPersisted) {
      try {
        await _audioBridge.setMhlPrescriptionEnabled(true);
        _mhlActive = true;
        _smartEnabledBeforeMhl = false;
      } catch (e, st) {
        developer.log(
          'Boot Phase 4: setMhlPrescriptionEnabled falló: $e',
          name: 'AmplificationBloc',
          level: 900,
          error: e,
          stackTrace: st,
        );
      }
    }
    if (musicPersisted) {
      try {
        await _audioBridge.setMusicModeEnabled(true);
        _musicModeActive = true;
        _smartEnabledBeforeMusic = false;
      } catch (e, st) {
        developer.log(
          'Boot Phase 4: setMusicModeEnabled falló: $e',
          name: 'AmplificationBloc',
          level: 900,
          error: e,
          stackTrace: st,
        );
      }
    }
    try {
      await _audioBridge.updateVolume(_currentVolumeDb);
    } catch (e, st) {
      developer.log(
        'Boot Phase 4: updateVolume falló: $e',
        name: 'AmplificationBloc',
        level: 900,
        error: e,
        stackTrace: st,
      );
    }

    // 5) bootPreset es read-only para Phase 1 (lo dejamos como
    //    referencia futura si se quiere reaplicar `lastEqPreset`
    //    sobre el bundle, pero por ahora `_onApplyBundle` ya aplica
    //    los gains del bundle con delta manual).
    // ignore: unused_local_variable
    final _ = bootPreset;
  }

  /// Lee `lastEqPreset` desde Settings y construye un [EqPreset]
  /// transient (con `description=''`). Devuelve `null` si el preset
  /// no está persistido o el JSON es corrupto / la lista de gains no
  /// tiene exactamente 12 valores numéricos.
  ///
  /// Phase 4 setter 1 (`updateEqGains`) lo pasa por
  /// [_resolveGainsForPreset] para cubrir el caso de bundles legacy
  /// con `gains == [0, ..., 0]` y nombre distinto a "Sin amplificación"
  /// (Req 5.1, 5.2).
  ///
  /// Réplica funcional del read del paciente
  /// (`PACIENTE/.../home_screen.dart`), pero como helper privado del
  /// boot path; el resto del bloc usa [_resolvePresetGainsForRestore]
  /// que requiere un nombre de preset desde [AmplificationActive]
  /// (no disponible al boot).
  Future<EqPreset?> _readBootEqPreset() async {
    Map<String, dynamic>? raw;
    try {
      raw = await _settingsRepository.getLastEqPreset();
    } catch (e, st) {
      developer.log(
        '_readBootEqPreset: getLastEqPreset falló: $e',
        name: 'AmplificationBloc',
        level: 900,
        error: e,
        stackTrace: st,
      );
      return null;
    }
    if (raw == null) return null;
    final rawName = raw['name'];
    final rawGains = raw['gains'];
    if (rawGains is! List || rawGains.length != 12) return null;
    try {
      final gains = rawGains
          .map((e) => (e as num).toDouble())
          .toList(growable: false);
      final name = (rawName is String && rawName.isNotEmpty)
          ? rawName
          : 'Normal';
      return EqPreset(name: name, description: '', gains: gains);
    } catch (e, st) {
      developer.log(
        '_readBootEqPreset: parseo de lastEqPreset falló: $e',
        name: 'AmplificationBloc',
        level: 900,
        error: e,
        stackTrace: st,
      );
      return null;
    }
  }

  /// Detiene la amplificación y libera recursos.
  ///
  /// **tecnico-paciente-feature-parity — task 5.2 (Req 3.6)**: las
  /// suscripciones a `inputLevelStream` y `stateStream` se cancelan
  /// **y se espera su finalización** antes de invocar
  /// `audioBridge.stopAudio`. Esto evita el race donde un callback
  /// pendiente del motor (nivel de entrada o transición de estado)
  /// llega al bloc después de que el motor nativo ya cerró sus
  /// recursos, lo que causaba `null pointer` esporádicos en JNI.
  ///
  /// Debe completarse en < 100 ms (Req 1.3). El `await` adicional
  /// sobre los `cancel()` agrega solo el tiempo necesario para que
  /// el stream subyacente termine de drenar (típicamente < 1 ms),
  /// muy por debajo del presupuesto.
  ///
  /// Requisitos: 1.3, 3.6
  Future<void> _onStopAmplification(
    StopAmplification event,
    Emitter<AmplificationState> emit,
  ) async {
    // Cancelar suscripciones y esperar su finalización ANTES de
    // detener el motor (Req 3.6).
    await _cancelSubscriptions();

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
  // ─── Mapeo de ambiente manual → estilo EQ ────────────────────────────
  //
  // Réplica del comportamiento del paciente con Smart ON:
  //   SILENCE → "Suave Plano"  (ganancia conservadora, perfil neutro)
  //   VOICE   → "Medio Voz"   (NAL-NL2 pura + énfasis voz 1-4 kHz)
  //   NOISE   → "Alto Voz"    (más agresiva + énfasis voz)
  //
  // Justificación clínica: en silencio, ganancias bajas evitan
  // amplificar el piso de ruido; en conversación, NAL-NL2 pleno con
  // foco en inteligibilidad; en ruido, se compensa la caída de SNR
  // con +30 % de gain y énfasis en banda de habla.
  static const Map<String, String> _profileToStyle = <String, String>{
    'Silencioso': StyleApplicator.styleSoftFlat,    // ×0.7, Plano
    'Conversación': StyleApplicator.styleMediumVoice, // ×1.0, Voz
    'Ruidoso': StyleApplicator.styleHighVoice,      // ×1.3, Voz
  };

  /// Requisitos: 6.2, 6.3, 6.4, 6.5, 8.2, 8.5
  Future<void> _onChangeProfile(
    ChangeProfile event,
    Emitter<AmplificationState> emit,
  ) async {
    final currentState = state;
    if (currentState is! AmplificationActive) return;

    // smart-continuo-dnn-modulado: mutex con Smart toggle.
    // Si el cambio NO viene del polling Smart (`fromSmartPoll = false`)
    // y Smart está ON, lo apagamos. Decisión de producto: el usuario
    // decide; Smart NO se reactiva solo cuando el usuario vuelve a un
    // perfil distinto. El mismo evento pasa al polling Smart con
    // `fromSmartPoll = true` y este branch se salta para no auto-
    // apagarse en cada tick.
    if (!event.fromSmartPoll && _smartEnabled) {
      _smartEnabled = false;
      _stopSmartPolling();
    }

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
      final nrBundle = adjustedNrLevel == baseBundle.nrLevel
          ? baseBundle
          : AudiogramDrivenBundle(
              gainsDb: baseBundle.gainsDb,
              compressionRatios: baseBundle.compressionRatios,
              compressionKneesDbSpl: baseBundle.compressionKneesDbSpl,
              mpoProfileDbSpl: baseBundle.mpoProfileDbSpl,
              prescribedTargetsDb: baseBundle.prescribedTargetsDb,
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

      // ─── Adaptación EQ por ambiente ────────────────────────────────
      //
      // Aplica el estilo (multiplicador + delta espectral) sobre las
      // gains NAL del bundle, emulando el comportamiento del paciente
      // Smart. Si el perfil no tiene mapeo (custom), se usa el bundle
      // tal cual (sin colorear).
      final styleName = _profileToStyle[newProfile.name];
      final AudiogramDrivenBundle bundle;
      final String eqPresetLabel;

      if (styleName != null) {
        bundle = StyleApplicator.applyStyle(
          nrBundle,
          styleName,
          derivedAt: _clock().toUtc(),
        );
        eqPresetLabel = styleName;
      } else {
        bundle = nrBundle;
        eqPresetLabel = currentState.activeEqPreset;
      }

      // Reflejar el nombre del perfil activo y el preset EQ derivado
      // de inmediato; el bundle se aplica vía `_onApplyBundle`.
      emit(currentState.copyWith(
        activeProfile: newProfile.name,
        activeEqPreset: eqPresetLabel,
      ));

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
      // Req 3.6: esperar cancelación de streams antes de stopAudio.
      await _cancelSubscriptions();

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
      // Req 3.6: esperar cancelación de streams antes de stopAudio.
      await _cancelSubscriptions();

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

      // smart-continuo-dnn-modulado: cargar el modelo DNN denoiser
      // (`gtcrn.onnx`) en el motor recién arrancado. Antes de este push,
      // el técnico solo cargaba el DNN cuando se abría la pantalla
      // SmartSceneScreen (`_initDnnDenoiser` en `initState`). Si el
      // usuario nunca abría esa pantalla, la DNN nunca se inicializaba
      // y el cap por escena no procesaba audio.
      //
      // Patient-style: el handler Kotlin `initDnnDenoiser` es idempotente
      // y tolerante a engine recién arrancado (200 ms del bootDelay
      // ya bastan en la práctica), así que un único intento aquí es
      // suficiente. La SmartSceneScreen sigue intentándolo en su
      // polling de 500 ms como red de seguridad.
      try {
        await const MethodChannel('com.psk.hearing_aid/audio')
            .invokeMethod<bool>('initDnnDenoiser');
        // FIX: habilitar el DNN con intensidad por defecto (0.6) al arrancar.
        // Sin esto, el DNN queda inicializado pero en bypass (enabled=false)
        // y el ruido no se filtra hasta que el usuario abra SmartSceneScreen.
        await const MethodChannel('com.psk.hearing_aid/audio')
            .invokeMethod<void>('setDnnEnabled', {'enabled': true});
        final dnnIntensity =
            _settingsRepository.dnnIntensity ?? 0.6;
        await _audioBridge.setDnnIntensity(dnnIntensity);
      } catch (e, st) {
        developer.log(
          '_onStartAmplification: initDnnDenoiser falló: $e — la '
          'SmartSceneScreen reintentará al abrir.',
          name: 'AmplificationBloc',
          level: 800,
          error: e,
          stackTrace: st,
        );
      }

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

  /// Actualiza las ganancias del EQ directamente (desde configuración
  /// avanzada, chips de perfil/preset "Personal" en main_screen, el
  /// simulador, step5_recommendation y el scene_engine).
  ///
  /// **patient-dsp-controls-fix — Tarea 3 (reaplicar WDRC/MPO/clamp).**
  /// Antes este handler mandaba los gains CRUDOS del evento con
  /// `updateEqGains(event.gains)`, sin pasar por el clamp de headroom y
  /// sin reaplicar WDRC ni MPO. Al cambiar de preset o tocar ganancias,
  /// el motor quedaba con gains altos + el compresor/MPO de la escena
  /// anterior → saturación audible ("reventado"). Ahora reaplica la
  /// cadena coherente **MPO → WDRC → EQ** replicando el patrón probado
  /// de [_onApplyBundle], con la misma tolerancia a fallos histórica
  /// (un error en cualquier setter no aborta el resto ni propaga).
  ///
  /// Funciona en cualquier estado: si el audífono está activo aplica al
  /// engine y emite el nuevo estado; si está inactivo solo persiste para
  /// usar al próximo encendido (contrato original sin cambios).
  ///
  /// Resolución de WDRC/MPO según haya o no un bundle clínico activo:
  ///
  /// - **Con [_lastBundle] != null** (caso normal): el bundle es la
  ///   fuente autoritativa. Se reaplica WDRC con
  ///   `compressionRatio = _effectiveCompressionRatio(_lastBundle)` — el
  ///   MISMO CR efectivo que usan MHL/Comodidad/`_onApplyBundle`, lo que
  ///   también corrige la incoherencia de CR entre rutas. Knees,
  ///   attack/release salen del bundle (vía [_resolveBridgeCompressionKnee]
  ///   y `bundle.wdrc*`). El MPO broadband se reaplica con
  ///   [_resolveBroadbandMpo]. Los gains del evento se acotan banda-a-banda
  ///   contra `mpoProfileDbSpl` del bundle (misma fórmula de headroom que
  ///   [_resolveFinalGains], con `_kHeadroomInputDbSpl`).
  ///
  /// - **Con [_lastBundle] == null** (flujo legacy preset-only, sin bundle
  ///   clínico todavía): no hay perfil MPO por banda disponible. Se honra
  ///   el WDRC sugerido por nombre de preset vía [_findEqPresetWdrcParams],
  ///   pero el ratio se pasa por [_applyComfortToRatio] para respetar
  ///   Comodidad (decisión documentada: no podemos llamar
  ///   `_effectiveCompressionRatio` porque exige un bundle; reusamos su
  ///   misma fórmula escalar). El MPO no se reaplica (no hay perfil del
  ///   cual derivarlo) y los gains se clampean de forma conservadora al
  ///   rango operativo del EQ `[gainMinDb, gainMaxDb]`.
  Future<void> _onUpdateEqGains(
    UpdateEqGains event,
    Emitter<AmplificationState> emit,
  ) async {
    try {
      final presetName = event.presetName ?? 'Custom';

      // FIX Causa B' (smart-scene-diagnostico-chasquido.md):
      // Si el preset NO viene de Smart Scene (no empieza con "SmartScene"),
      // liberamos el pin del preset Smart en el motor. Esto permite que
      // el clasificador automático retome el control del WDRC + NR
      // automáticamente cuando el usuario cambia a un preset custom o
      // factory tras haber aplicado uno Smart. Sin esto, el pin quedaba
      // pegado y el preset nuevo se mezclaba con los WDRC/NR fijados
      // por el Smart anterior.
      // Tolerante a fallos del bridge.
      if (!presetName.startsWith('SmartScene')) {
        try {
          await const MethodChannel('com.psk.hearing_aid/audio')
              .invokeMethod<void>(
            'setSmartPresetPinned',
            <String, dynamic>{'pinned': false},
          );
        } catch (_) {
          // No bloquear el flujo del preset por un fallo del bridge.
        }
      }

      // 1. Persistir el preset SIEMPRE (independiente del estado).
      await _settingsRepository.setLastEqPreset({
        'name': presetName,
        'gains': event.gains,
      });

      // 2. Aplicar al engine solo si está activo. Si no, solo persiste
      //    (contrato original sin cambios).
      if (state is! AmplificationActive) {
        return;
      }

      final bundle = _lastBundle;

      // 2a. Clamp de headroom sobre los gains del evento. Con bundle se
      //     acota por banda contra su mpoProfile; sin bundle, clamp
      //     conservador al rango operativo del EQ.
      final clampedGains = _clampGainsToHeadroom(event.gains, bundle);

      // 2b. Resolver WDRC + MPO coherentes con la escena clínica activa.
      WdrcParams? wdrcParams;
      double? mpoBroadband;
      if (bundle != null) {
        // Bundle clínico = fuente autoritativa. CR efectivo (con
        // Comodidad) idéntico al de MHL/Comodidad/_onApplyBundle →
        // todas las rutas quedan coherentes.
        wdrcParams = WdrcParams(
          expansionKnee: bundle.expansionKneeDbSpl,
          compressionKnee: _resolveBridgeCompressionKnee(bundle, _manualDelta),
          compressionRatio: _effectiveCompressionRatio(bundle),
          attackMs: bundle.wdrcAttackMs,
          releaseMs: bundle.wdrcReleaseMs,
        );
        mpoBroadband = _resolveBroadbandMpo(bundle);
      } else {
        // Flujo legacy preset-only: honrar el WDRC sugerido por nombre,
        // pasando el ratio por la fórmula de Comodidad. Sin perfil MPO
        // disponible no se reaplica MPO.
        final presetWdrc = _findEqPresetWdrcParams(presetName);
        if (presetWdrc != null) {
          wdrcParams = WdrcParams(
            expansionKnee: presetWdrc.expansionKnee,
            compressionKnee: presetWdrc.compressionKnee,
            compressionRatio:
                _applyComfortToRatio(presetWdrc.compressionRatio),
          );
        }
      }

      // 2c. Aplicar en orden seguro MPO → WDRC → EQ (mismo orden que la
      //     cadena atómica de _onApplyBundle). Cada setter es tolerante a
      //     fallos: un error no aborta los siguientes (contrato histórico
      //     del handler — "no interrumpir por error de actualización").
      if (mpoBroadband != null) {
        try {
          await _audioBridge.setMpoThresholdDbSpl(mpoBroadband);
        } catch (e, st) {
          developer.log(
            '_onUpdateEqGains: setMpoThresholdDbSpl falló: $e',
            name: 'AmplificationBloc',
            level: 900,
            error: e,
            stackTrace: st,
          );
        }
      }
      if (wdrcParams != null) {
        try {
          await _audioBridge.updateWdrcParams(wdrcParams);
        } catch (e, st) {
          developer.log(
            '_onUpdateEqGains: updateWdrcParams falló: $e',
            name: 'AmplificationBloc',
            level: 900,
            error: e,
            stackTrace: st,
          );
        }
      }
      try {
        await _audioBridge.updateEqGains(clampedGains);
      } catch (e, st) {
        developer.log(
          '_onUpdateEqGains: updateEqGains falló: $e',
          name: 'AmplificationBloc',
          level: 900,
          error: e,
          stackTrace: st,
        );
      }

      // 2d. Re-emitir el state activo con el nombre del preset Y las
      //     ganancias realmente aplicadas. Se re-evalúa `state` post-await
      //     (puede haber cambiado).
      final current = state;
      if (current is AmplificationActive) {
        emit(current.copyWith(
          activeEqPreset: presetName,
          activeEqGains: clampedGains,
        ));
      }
    } catch (_) {
      // No interrumpir por error de actualización de EQ.
    }
  }

  /// Acota una lista de ganancias EQ sueltas (del evento [UpdateEqGains])
  /// por headroom MPO, replicando la fórmula de [_resolveFinalGains] pero
  /// sobre gains que NO provienen de un bundle.
  ///
  /// - Siempre clampa al rango operativo del EQ `[gainMinDb, gainMaxDb]`.
  /// - Si [bundle] != null, aplica además el clamp de headroom por banda:
  ///   `g ≤ mpoProfileDbSpl[i] - _kHeadroomInputDbSpl - _kHeadroomSafetyMarginDb`,
  ///   nunca por debajo del piso `gainMinDb`. Si una banda no existe en el
  ///   perfil (longitudes distintas), usa el MPO broadband como cota.
  /// - Si [bundle] == null, no hay perfil MPO del cual derivar headroom →
  ///   clamp conservador solo al rango operativo (caso documentado).
  /// - Aplica siempre el techo de ganancia del hardware (`hardwareGainCeilingPerBandDb`)
  ///   vía [fitPrescriptionToCeiling] (WCPF — Weighted Constrained Proportional
  ///   Fitting): escala la curva proporcionalmente con pesos SII en lugar de
  ///   recortar banda por banda, preservando la forma para inteligibilidad.
  List<double> _clampGainsToHeadroom(
    List<double> gains,
    AudiogramDrivenBundle? bundle,
  ) {
    // Cap por banda según severidad del audiograma + override manual
    // del slider "Tope de ganancia" en Servicio Técnico
    // (ver _audiogramSeverityGainCapDb). Preserva la forma de la curva
    // clínica NAL/DSL pero limita el techo por banda al valor que el
    // usuario validó auditivamente. Si el cap es null, no se aplica
    // ningún tope (rango operativo del EQ se respeta como antes).
    final severityCap = _audiogramSeverityGainCapDb();

    final n = gains.length;
    final out = List<double>.filled(n, 0.0, growable: false);
    final double? broadband =
        bundle != null ? _resolveBroadbandMpo(bundle) : null;
    for (var i = 0; i < n; i++) {
      double g = gains[i]
          .clamp(
            AudiogramDrivenBundle.gainMinDb,
            AudiogramDrivenBundle.gainMaxDb,
          )
          .toDouble();
      if (bundle != null) {
        final mpoBand = i < bundle.mpoProfileDbSpl.length
            ? bundle.mpoProfileDbSpl[i]
            : broadband!;
        final headroom =
            mpoBand - _kHeadroomInputDbSpl - _kHeadroomSafetyMarginDb;
        if (headroom < g) {
          g = math.max(headroom, AudiogramDrivenBundle.gainMinDb);
        }
      }
      out[i] = g;
    }
    // Cap por banda según severidad del audiograma + override manual.
    // Aplicado ANTES del WCPF para que la escala proporcional opere
    // sobre la curva ya acotada al techo seguro.
    if (severityCap != null) {
      for (var i = 0; i < n; i++) {
        if (out[i] > severityCap) out[i] = severityCap;
      }
    }
    // WCPF: escala proporcionalmente con pesos SII para respetar el
    // techo per-band del hardware sin destruir la forma de la curva.
    // Si la longitud no es 12 (caso defensivo), el helper acepta peso
    // uniforme; si los 12 techos son 50 (sin calibrar), retorna el
    // input intacto (backward compat). Si no hay calibración (null), omitir.
    final ceiling = _settingsRepository.hardwareGainCeilingPerBandDb;
    if (ceiling != null && ceiling.length == n) {
      return fitPrescriptionToCeiling(out, ceiling);
    }
    return List<double>.unmodifiable(out);
  }

  /// Reaplica al motor la cadena DSP coherente al RESTAURAR desde MHL
  /// Prescripción OFF o Modo Música OFF, replicando bit-a-bit el orden y los
  /// resolvers de la Tarea 3 (`_onUpdateEqGains`) y de la cadena atómica de
  /// [_onApplyBundle]:
  ///
  ///   1. MPO broadband vía [_resolveBroadbandMpo].
  ///   2. WDRC con `compressionRatio = _effectiveCompressionRatio(bundle)`
  ///      (preservando knees/expansion/attack/release del bundle).
  ///   3. EQ con los gains del preset acotados por headroom vía
  ///      [_clampGainsToHeadroom].
  ///
  /// **Objetivo (patient-dsp-controls-fix — Tarea 4)**: encender y apagar
  /// MHL/Música debe dejar el motor EXACTAMENTE en el mismo estado coherente
  /// que tendría sin haber tocado esos modos. Antes la restauración solo
  /// reaplicaba EQ (gains crudos, SIN clamp) + WDRC, dejando el MPO de la
  /// escena viejo y los gains sin acotar por headroom — la misma incoherencia
  /// que la Tarea 3 corrigió para `_onUpdateEqGains`. Reusar este helper
  /// alinea las tres rutas de restore (MHL OFF, mutex MHL OFF, Música OFF)
  /// con esa cadena.
  ///
  /// - Con [bundle] != null (caso normal): se reaplican MPO + WDRC derivados
  ///   del bundle y los gains se acotan por banda contra `mpoProfileDbSpl`.
  /// - Con [bundle] == null (boot temprano / fallo previo): no hay perfil
  ///   clínico del cual derivar MPO/WDRC → se omiten esos dos setters (no se
  ///   envían parámetros arbitrarios al motor) y los gains se clampean solo al
  ///   rango operativo del EQ, idéntico al fallback de [_clampGainsToHeadroom]
  ///   y de la Tarea 3.
  ///
  /// Cada setter es tolerante a fallos: un error se loguea (nivel 900) pero no
  /// aborta los siguientes (mismo contrato que `_onUpdateEqGains`).
  /// [logContext] identifica el call-site en los logs.
  ///
  /// Requisitos: 1.6, 4.4, 4.5, 10.1, 10.2
  Future<void> _reapplyCoherentChainOnRestore(
    List<double> presetGains,
    AudiogramDrivenBundle? bundle,
    String logContext,
  ) async {
    // 1. MPO broadband — primero, igual que T3 / _onApplyBundle.
    if (bundle != null) {
      try {
        await _audioBridge.setMpoThresholdDbSpl(_resolveBroadbandMpo(bundle));
      } catch (e, st) {
        developer.log(
          '$logContext: setMpoThresholdDbSpl falló: $e',
          name: 'AmplificationBloc',
          level: 900,
          error: e,
          stackTrace: st,
        );
      }
    }

    // 2. WDRC con _effectiveCompressionRatio(bundle) (CR efectivo idéntico al
    //    de MHL/Comodidad/_onApplyBundle/_onUpdateEqGains).
    if (bundle != null) {
      try {
        final wdrcParams = WdrcParams(
          expansionKnee: bundle.expansionKneeDbSpl,
          compressionKnee: _resolveBridgeCompressionKnee(bundle, _manualDelta),
          compressionRatio: _effectiveCompressionRatio(bundle),
          attackMs: bundle.wdrcAttackMs,
          releaseMs: bundle.wdrcReleaseMs,
        );
        await _audioBridge.updateWdrcParams(wdrcParams);
      } catch (e, st) {
        developer.log(
          '$logContext: updateWdrcParams falló: $e',
          name: 'AmplificationBloc',
          level: 900,
          error: e,
          stackTrace: st,
        );
      }
    }

    // 3. EQ con clamp de headroom (mismo clamp que la Tarea 3).
    if (presetGains.isNotEmpty) {
      final clampedGains = _clampGainsToHeadroom(presetGains, bundle);
      try {
        await _audioBridge.updateEqGains(clampedGains);
      } catch (e, st) {
        developer.log(
          '$logContext: updateEqGains falló: $e',
          name: 'AmplificationBloc',
          level: 900,
          error: e,
          stackTrace: st,
        );
      }
    }
  }

  /// Busca los parámetros WDRC recomendados para un preset EQ por nombre.
  /// Retorna null si no es un preset conocido.
  ///
  /// La grilla actual son los 9 presets de [StyleApplicator] (Suave/Medio/Alto
  /// × Plano/Voz/Agudos). Los parámetros WDRC dependen principalmente de la
  /// **intensidad** (loudness range) — Suave usa knee alto y CR bajo, Alto
  /// usa knee bajo y CR alto. La forma (Plano/Voz/Agudos) no afecta WDRC.
  ///
  /// Mantiene compatibilidad con los 10 nombres legacy
  /// (Normal, Mild High, Mild Flat, etc.) por si un bundle viejo o un test
  /// los llega a referenciar.
  ({double compressionRatio, double compressionKnee, double expansionKnee})?
      _findEqPresetWdrcParams(String presetName) {
    switch (presetName) {
      // ─── Grilla actual (9 presets de StyleApplicator) ─────────────────
      case 'Suave Plano':
      case 'Suave Voz':
      case 'Suave Agudos':
        return (compressionRatio: 1.3, compressionKnee: 58.0, expansionKnee: 35.0);
      case 'Medio Plano':
      case 'Medio Voz':
      case 'Medio Agudos':
        return (compressionRatio: 1.5, compressionKnee: 55.0, expansionKnee: 35.0);
      case 'Alto Plano':
      case 'Alto Voz':
      case 'Alto Agudos':
        return (compressionRatio: 1.8, compressionKnee: 52.0, expansionKnee: 35.0);

      // ─── Bypass intencional (sin amplificación) ───────────────────────
      case 'Sin amplificación':
        return (compressionRatio: 1.2, compressionKnee: 60.0, expansionKnee: 35.0);

      // ─── Compatibilidad backward con nombres legacy ───────────────────
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
      // Se pasa por _clampGainsToHeadroom para respetar headroom MPO
      // y el techo de ganancia del hardware (gain ceiling).
      final clampedNewGains = _clampGainsToHeadroom(newGains, _lastBundle);
      await _audioBridge.updateEqGains(clampedNewGains);

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

  /// Activa o desactiva MHL — handler legacy delegado a
  /// [_onToggleMhlPrescription].
  ///
  /// **tecnico-paciente-feature-parity — task 4.4 (Req 1.12)**:
  /// Conserva la firma original del evento [ToggleMhlMode] (payload
  /// `activate: bool`) sin cambios para no romper screens viejas que aún
  /// despachan el evento legacy (p.ej. `main_screen.dart`). El cuerpo
  /// reemplaza la semántica legacy previa (PTA warning,
  /// `MhlModule.prescribe`, recálculo NL3 al desactivar) por la
  /// semántica selectiva nueva: gains flat 8 dB en 12 bandas +
  /// `compressionRatio = 1.0`, snapshot/restauración Smart, persistencia
  /// de `mhlPrescriptionEnabled` y mutex con Modo Música.
  ///
  /// Garantiza Property 7 del design: para todo `activate ∈ {true, false}`
  /// y todo estado inicial del bloc, despachar
  /// `ToggleMhlMode(activate: v)` produce el mismo conjunto de
  /// invocaciones al motor y la misma secuencia de escrituras a
  /// SettingsRepository que despachar `ToggleMhlPrescription(activate: v)`.
  ///
  /// Requisitos: 1.12
  Future<void> _onToggleMhlMode(
    ToggleMhlMode event,
    Emitter<AmplificationState> emit,
  ) =>
      _onToggleMhlPrescription(
        ToggleMhlPrescription(activate: event.activate),
        emit,
      );

  // ═════════════════════════════════════════════════════════════════════
  // tecnico-paciente-feature-parity — task 4.2
  // _onToggleMhlPrescription
  // ═════════════════════════════════════════════════════════════════════

  /// Activa o desactiva el modo "MHL Prescripción" como modo selectivo.
  ///
  /// **ON** (`event.activate == true`):
  /// 1. Si Modo Música está ON, ejecuta primero el branch OFF de Música
  ///    (persiste `musicModeEnabled=false`, llama a
  ///    `_audioBridge.setMusicModeEnabled(false)` y reaplica `nrLevel`
  ///    desde Settings) — Req 1.3, 1.7.
  /// 2. Snapshot del Smart actual a [_smartEnabledBeforeMhl] (anidado:
  ///    si Música había guardado un Smart previo, ese valor se respeta
  ///    porque la rama OFF de Música ya restauró el mirror) — Req 1.5.
  /// 3. Fuerza `_smartEnabled = false` (mirror lógico; el handler
  ///    Kotlin `applyMhlPrescription` también invoca
  ///    `setAutoClassifyEnabled(false)` defensivamente).
  /// 4. Aplica MHL al motor vía
  ///    `_audioBridge.setMhlPrescriptionEnabled(true)` — el handler
  ///    Kotlin pone gains flat 8 dB en las 12 bandas + `compRatio = 1.0`
  ///    sin tocar NR/DNN/knees/attack/release/volumen — Req 1.1.
  /// 5. Persiste `mhlPrescriptionEnabled=true` ANTES de emitir el nuevo
  ///    estado para garantizar que cualquier observador vea la
  ///    persistencia consistente con el state — Req 1.10.
  /// 6. Emite `AmplificationActive` con `mhlActive: true`.
  ///
  /// **OFF** (`event.activate == false`):
  /// 1. Persiste `mhlPrescriptionEnabled=false` — Req 1.10.
  /// 2. Llama a `_audioBridge.setMhlPrescriptionEnabled(false)` para que
  ///    el motor restaure el EQ desde su cache nativo — Req 1.1.
  /// 3. Restaura `_smartEnabled` desde [_smartEnabledBeforeMhl] (default
  ///    `false` si no había snapshot) — Req 1.6.
  /// 4. Reaplica `nrLevel` desde Settings vía `updateNrLevel`.
  ///    Ante fallo de Settings: log warning, default `nrLevel=0` — Req
  ///    1.7, 1.9.
  /// 5. Reaplica los gains del preset activo usando
  ///    [_resolveGainsForPreset] (re-derivación audiogram-driven para
  ///    bundles legacy) — Req 5.1, 5.2.
  /// 6. Reaplica WDRC al motor con `compressionRatio` calculado por
  ///    [_effectiveCompressionRatio] sobre el último bundle aplicado
  ///    ([_lastBundle]); preserva knees/attack/release del bundle — Req
  ///    1.6, 4.4, 4.5.
  /// 7. Emite `AmplificationActive` con `mhlActive: false` y
  ///    `activeNrLevel` actualizado.
  ///
  /// **Réplica del paciente**: el flujo OFF/ON está mapeado bit-a-bit
  /// con `_onMhlPrescriptionChanged` de
  /// `PACIENTE/.../home_screen.dart` (líneas 444-487), salvo que en el
  /// técnico la persistencia se hace ANTES del bridge call para
  /// preservar el invariante "persistencia precede notificación"
  /// (Req 1.10).
  ///
  /// **Tolerancia a fallos**: cualquier fallo de persistencia o del
  /// bridge se loguea con `developer.log` nivel 900 (WARNING) y NO
  /// aborta el flujo. El estado emitido refleja el resultado final
  /// alcanzable con los recursos disponibles.
  ///
  /// **Mutex con Modo Música**: el branch OFF de Música embebido en la
  /// rama ON cubre Req 1.3 (al activar MHL con Música ON, Música se
  /// apaga primero). El branch simétrico — apagar MHL al activar Música
  /// — vive en `_onToggleMusicMode` (task 4.3).
  ///
  /// Requisitos: 1.1, 1.3, 1.5, 1.6, 1.7, 1.9, 1.10
  Future<void> _onToggleMhlPrescription(
    ToggleMhlPrescription event,
    Emitter<AmplificationState> emit,
  ) async {
    final currentState = state;
    if (currentState is! AmplificationActive) return;

    if (event.activate) {
      // ─── Rama ON ────────────────────────────────────────────────────

      // Mutex (Req 1.3): si Modo Música está ON, ejecutar primero el
      // branch OFF de Música. Leemos el flag persistido sincrónicamente.
      final wasMusicOn = _readMusicModeEnabledOrFalse();

      if (wasMusicOn) {
        await _applyMusicOffBranchForMutex();
      }

      // Snapshot Smart (Req 1.5). Si Música había snapshot-eado Smart
      // previamente, la rama OFF de Música ya restauró [_smartEnabled]
      // al valor real; tomar la lectura actual preserva la semántica
      // anidada del paciente (`_smartBeforeMhl = _smartBeforeMusic ??
      // _smart`).
      _smartEnabledBeforeMhl = _smartEnabled;

      // Forzar Smart=false a nivel mirror lógico. El handler Kotlin
      // `applyMhlPrescription(true)` también invoca
      // `setAutoClassifyEnabled(false)` defensivamente.
      _smartEnabled = false;

      // Aplicar MHL al motor (gains flat 8 dB + compRatio=1.0 + Smart
      // off vía Kotlin) — Req 1.1.
      try {
        await _audioBridge.setMhlPrescriptionEnabled(true);
      } catch (e, st) {
        developer.log(
          '_onToggleMhlPrescription[ON]: bridge.setMhlPrescriptionEnabled '
          'falló: $e — revirtiendo snapshot Smart.',
          name: 'AmplificationBloc',
          level: 900,
          error: e,
          stackTrace: st,
        );
        _smartEnabled = _smartEnabledBeforeMhl ?? false;
        _smartEnabledBeforeMhl = null;
        return;
      }

      // Persistencia ANTES de notificar (Req 1.10).
      try {
        await _settingsRepository.setMhlPrescriptionEnabled(true);
      } catch (e, st) {
        developer.log(
          '_onToggleMhlPrescription[ON]: setMhlPrescriptionEnabled '
          'persistencia falló: $e — el motor ya aplicó MHL, sesión '
          'continúa pero el flag no quedó persistido.',
          name: 'AmplificationBloc',
          level: 900,
          error: e,
          stackTrace: st,
        );
      }

      // Mantener el mirror legacy del modo MHL para que
      // `_onSceneClassUpdated` lo respete (no aplica CIN mientras MHL
      // está ON).
      _mhlActive = true;

      emit(currentState.copyWith(
        mhlActive: true,
      ));
      return;
    }

    // ─── Rama OFF ────────────────────────────────────────────────────

    // Persistencia ANTES de notificar (Req 1.10).
    try {
      await _settingsRepository.setMhlPrescriptionEnabled(false);
    } catch (e, st) {
      developer.log(
        '_onToggleMhlPrescription[OFF]: setMhlPrescriptionEnabled '
        'persistencia falló: $e — continuando con la restauración.',
        name: 'AmplificationBloc',
        level: 900,
        error: e,
        stackTrace: st,
      );
    }

    // Apagar MHL en motor (restaura EQ desde cache nativo) — Req 1.1.
    try {
      await _audioBridge.setMhlPrescriptionEnabled(false);
    } catch (e, st) {
      developer.log(
        '_onToggleMhlPrescription[OFF]: bridge.setMhlPrescriptionEnabled '
        'falló: $e — continuando con la restauración Dart.',
        name: 'AmplificationBloc',
        level: 900,
        error: e,
        stackTrace: st,
      );
    }

    // Restaurar Smart al snapshot (Req 1.6).
    final restoreSmart = _smartEnabledBeforeMhl ?? false;
    _smartEnabledBeforeMhl = null;
    _smartEnabled = restoreSmart;
    if (restoreSmart) {
      // smart-continuo-dnn-modulado: si Smart estaba ON antes de MHL,
      // reactivar el clasificador C++ y el polling 1 Hz.
      _startSmartPolling();
    }

    // Leer nrLevel desde Settings con default tolerante (Req 1.7, 1.9).
    int restoredNrLevel;
    try {
      restoredNrLevel = _settingsRepository.nrLevel;
    } catch (e, st) {
      developer.log(
        '_onToggleMhlPrescription[OFF]: SettingsRepository.nrLevel '
        'falló: $e — usando default nrLevel=0.',
        name: 'AmplificationBloc',
        level: 900,
        error: e,
        stackTrace: st,
      );
      restoredNrLevel = 0;
    }

    // Reaplicar nrLevel al motor.
    try {
      await _audioBridge.updateNrLevel(restoredNrLevel);
    } catch (e, st) {
      developer.log(
        '_onToggleMhlPrescription[OFF]: bridge.updateNrLevel falló: $e',
        name: 'AmplificationBloc',
        level: 900,
        error: e,
        stackTrace: st,
      );
    }

    // Reaplicar la cadena DSP coherente (MPO → WDRC → EQ con clamp de
    // headroom), idéntica a la Tarea 3 (`_onUpdateEqGains`) y a la cadena
    // atómica de `_onApplyBundle`. Esto garantiza que apagar MHL deje el motor
    // EXACTAMENTE en el estado coherente que tendría sin haber tocado el modo
    // (patient-dsp-controls-fix — Tarea 4) — Req 1.6, 4.4, 4.5. Los gains del
    // preset activo se resuelven con _resolveGainsForPreset (Req 5.1, 5.2);
    // sin bundle activo se omiten MPO/WDRC y los gains se clampean solo al
    // rango operativo del EQ.
    final List<double> presetGains = await _resolvePresetGainsForRestore(
      currentState.activeEqPreset,
    );
    await _reapplyCoherentChainOnRestore(
      presetGains,
      _lastBundle,
      '_onToggleMhlPrescription[OFF]',
    );

    // Apagar el mirror legacy del modo MHL (Req 1.10).
    _mhlActive = false;

    emit(currentState.copyWith(
      mhlActive: false,
      ptaWarning: false,
      activeNrLevel: restoredNrLevel,
    ));
  }

  /// Lee `musicModeEnabled` desde [SettingsRepository] tolerando
  /// excepciones (Req 1.9: ante fallo de Settings, defaults seguros).
  /// Retorna `false` si la lectura lanza.
  bool _readMusicModeEnabledOrFalse() {
    try {
      return _settingsRepository.musicModeEnabled;
    } catch (e, st) {
      developer.log(
        '_readMusicModeEnabledOrFalse: lectura falló: $e — asumiendo false.',
        name: 'AmplificationBloc',
        level: 900,
        error: e,
        stackTrace: st,
      );
      return false;
    }
  }

  /// Branch OFF de Modo Música ejecutado como mutex desde el handler
  /// de MHL Prescripción (Req 1.3).
  ///
  /// - Persiste `musicModeEnabled=false` (Req 1.10).
  /// - Apaga Música en el motor vía `_audioBridge.setMusicModeEnabled(false)`.
  /// - Reaplica `nrLevel` desde Settings (default `0` ante fallo —
  ///   Req 1.7, 1.9). El handler Kotlin `applyMusicMode(false)` es un
  ///   no-op a nivel motor por contrato del paciente; la restauración
  ///   real vive en Dart.
  /// - Reaplica `dnnIntensity` desde Settings (default `0.6` ante fallo
  ///   — Req 1.8, 1.9) vía `_audioBridge.setDnnIntensity`.
  ///
  /// Refleja el [_musicModeActive] en `false` para que la UI y los
  /// dependientes (`_onSceneClassUpdated`) vean el cambio antes de que
  /// el caller continúe con la rama ON del modo entrante.
  Future<void> _applyMusicOffBranchForMutex() async {
    try {
      await _settingsRepository.setMusicModeEnabled(false);
    } catch (e, st) {
      developer.log(
        '_applyMusicOffBranchForMutex: setMusicModeEnabled persistencia '
        'falló: $e — continuando con el branch OFF.',
        name: 'AmplificationBloc',
        level: 900,
        error: e,
        stackTrace: st,
      );
    }

    try {
      await _audioBridge.setMusicModeEnabled(false);
    } catch (e, st) {
      developer.log(
        '_applyMusicOffBranchForMutex: bridge.setMusicModeEnabled falló: $e',
        name: 'AmplificationBloc',
        level: 900,
        error: e,
        stackTrace: st,
      );
    }

    // Restaurar nrLevel (Req 1.7, 1.9).
    int restoredNrLevel;
    try {
      restoredNrLevel = _settingsRepository.nrLevel;
    } catch (e, st) {
      developer.log(
        '_applyMusicOffBranchForMutex: SettingsRepository.nrLevel '
        'falló: $e — usando default nrLevel=0.',
        name: 'AmplificationBloc',
        level: 900,
        error: e,
        stackTrace: st,
      );
      restoredNrLevel = 0;
    }
    try {
      await _audioBridge.updateNrLevel(restoredNrLevel);
    } catch (e, st) {
      developer.log(
        '_applyMusicOffBranchForMutex: bridge.updateNrLevel falló: $e',
        name: 'AmplificationBloc',
        level: 900,
        error: e,
        stackTrace: st,
      );
    }

    // Restaurar dnnIntensity (Req 1.8, 1.9). Si Settings falla, default
    // 0.6 (mismo default que el contrato del paciente).
    double restoredDnnIntensity;
    try {
      restoredDnnIntensity = _settingsRepository.dnnIntensity;
    } catch (e, st) {
      developer.log(
        '_applyMusicOffBranchForMutex: SettingsRepository.dnnIntensity '
        'falló: $e — usando default dnnIntensity=0.6.',
        name: 'AmplificationBloc',
        level: 900,
        error: e,
        stackTrace: st,
      );
      restoredDnnIntensity = 0.6;
    }
    try {
      await _audioBridge.setDnnIntensity(restoredDnnIntensity);
    } catch (e, st) {
      developer.log(
        '_applyMusicOffBranchForMutex: bridge.setDnnIntensity falló: $e',
        name: 'AmplificationBloc',
        level: 900,
        error: e,
        stackTrace: st,
      );
    }

    // Mirror lógico (Req 1.2, 1.4, 1.11). El caller (rama ON de MHL)
    // toma el snapshot Smart después de esta restauración, así que el
    // valor anidado se preserva.
    _musicModeActive = false;
  }

  /// Resuelve los 12 gains a aplicar al motor cuando se restaura el
  /// preset activo (rama OFF de MHL Prescripción).
  ///
  /// Estrategia:
  /// 1. Lee `lastEqPreset` desde Settings (`{name, gains}`). Si está
  ///    presente y `gains` tiene exactamente 12 valores numéricos,
  ///    construye un [EqPreset] transient y lo pasa por
  ///    [_resolveGainsForPreset] para cubrir el caso de bundles legacy
  ///    (Req 5.1, 5.2).
  /// 2. Si `lastEqPreset` no existe o está corrupto, intenta usar
  ///    `_lastBundle.gainsDb` aplicando `_resolveFinalGains` para
  ///    incluir el [_manualDelta] activo.
  /// 3. Si tampoco hay bundle, retorna lista vacía y el caller omite
  ///    la actualización del EQ.
  ///
  /// El nombre [activePresetNameFromState] es un fallback para
  /// construir el [EqPreset] cuando `lastEqPreset` no incluye el
  /// nombre (caso muy raro pero posible si el JSON está parcialmente
  /// escrito).
  Future<List<double>> _resolvePresetGainsForRestore(
    String activePresetNameFromState,
  ) async {
    Map<String, dynamic>? presetData;
    try {
      presetData = await _settingsRepository.getLastEqPreset();
    } catch (e, st) {
      developer.log(
        '_resolvePresetGainsForRestore: getLastEqPreset falló: $e',
        name: 'AmplificationBloc',
        level: 900,
        error: e,
        stackTrace: st,
      );
      presetData = null;
    }

    if (presetData != null) {
      final rawName = presetData['name'];
      final rawGains = presetData['gains'];
      if (rawGains is List && rawGains.length == 12) {
        try {
          final gains = rawGains
              .map((e) => (e as num).toDouble())
              .toList(growable: false);
          final name = (rawName is String && rawName.isNotEmpty)
              ? rawName
              : activePresetNameFromState;
          final preset = EqPreset(
            name: name,
            description: '',
            gains: gains,
          );
          return await _resolveGainsForPreset(preset, _currentAudiogram);
        } catch (e, st) {
          developer.log(
            '_resolvePresetGainsForRestore: parseo de lastEqPreset '
            'falló: $e — fallback al bundle activo.',
            name: 'AmplificationBloc',
            level: 900,
            error: e,
            stackTrace: st,
          );
        }
      }
    }

    // Fallback: usar gains del bundle activo (con delta manual aplicado).
    final bundle = _lastBundle;
    if (bundle != null) {
      try {
        return _resolveFinalGains(bundle, _manualDelta);
      } catch (e, st) {
        developer.log(
          '_resolvePresetGainsForRestore: _resolveFinalGains '
          'falló: $e — omitiendo update de gains.',
          name: 'AmplificationBloc',
          level: 900,
          error: e,
          stackTrace: st,
        );
      }
    }

    return const <double>[];
  }

  // ═════════════════════════════════════════════════════════════════════
  // tecnico-paciente-feature-parity — task 4.3
  // _onToggleMusicMode + _applyMhlOffBranchForMutex + _readMhlPrescriptionEnabledOrFalse
  // ═════════════════════════════════════════════════════════════════════

  /// Lee `mhlPrescriptionEnabled` desde [SettingsRepository] tolerando
  /// excepciones (Req 1.9: ante fallo de Settings, defaults seguros).
  /// Retorna `false` si la lectura lanza.
  ///
  /// Réplica simétrica de [_readMusicModeEnabledOrFalse]; necesario para
  /// la rama ON de [_onToggleMusicMode] (Req 1.4: si MHL está ON al
  /// activar Música, ejecutar primero la rama OFF de MHL).
  bool _readMhlPrescriptionEnabledOrFalse() {
    try {
      return _settingsRepository.mhlPrescriptionEnabled;
    } catch (e, st) {
      developer.log(
        '_readMhlPrescriptionEnabledOrFalse: lectura falló: $e — '
        'asumiendo false.',
        name: 'AmplificationBloc',
        level: 900,
        error: e,
        stackTrace: st,
      );
      return false;
    }
  }

  /// Branch OFF de MHL Prescripción ejecutado como mutex desde el
  /// handler de Modo Música (Req 1.4).
  ///
  /// Réplica simétrica de [_applyMusicOffBranchForMutex]:
  /// - Persiste `mhlPrescriptionEnabled=false` (Req 1.10).
  /// - Apaga MHL en el motor vía `_audioBridge.setMhlPrescriptionEnabled(false)`
  ///   — el handler Kotlin restaura el EQ desde su cache nativo.
  /// - Reaplica `nrLevel` desde Settings (default `0` ante fallo —
  ///   Req 1.7, 1.9).
  /// - Reaplica los gains del preset activo vía
  ///   [_resolvePresetGainsForRestore] (re-derivación audiogram-driven
  ///   para bundles legacy — Req 5.1, 5.2).
  /// - Reaplica WDRC con [_effectiveCompressionRatio] sobre el último
  ///   bundle activo, preservando knees/attack/release del bundle
  ///   (Req 1.6, 4.4, 4.5).
  ///
  /// Refleja el [_mhlActive] en `false` para que el caller (rama ON de
  /// Música) tome el snapshot Smart correcto: el handler Kotlin
  /// `applyMhlPrescription(false)` no toca el clasificador automático,
  /// así que [_smartEnabled] todavía representa el valor "real"
  /// guardado al activar MHL — la rama ON de Música tomará un snapshot
  /// limpio sobre ese valor.
  ///
  /// **Diferencia con `_applyMusicOffBranchForMutex`**: aquí sí se
  /// reaplica el EQ y el WDRC porque el handler Kotlin de MHL OFF
  /// restaura `lastEqGains` (cache nativo) pero el técnico mantiene la
  /// invariante "Dart es la fuente de verdad clínica": el bundle
  /// activo o el último preset persistido toman precedencia. La rama
  /// OFF de Música no necesita reaplicar EQ/WDRC porque Música nunca
  /// los modificó.
  Future<void> _applyMhlOffBranchForMutex(
    AmplificationActive currentState,
  ) async {
    try {
      await _settingsRepository.setMhlPrescriptionEnabled(false);
    } catch (e, st) {
      developer.log(
        '_applyMhlOffBranchForMutex: setMhlPrescriptionEnabled '
        'persistencia falló: $e — continuando con el branch OFF.',
        name: 'AmplificationBloc',
        level: 900,
        error: e,
        stackTrace: st,
      );
    }

    try {
      await _audioBridge.setMhlPrescriptionEnabled(false);
    } catch (e, st) {
      developer.log(
        '_applyMhlOffBranchForMutex: bridge.setMhlPrescriptionEnabled '
        'falló: $e — continuando con la restauración Dart.',
        name: 'AmplificationBloc',
        level: 900,
        error: e,
        stackTrace: st,
      );
    }

    // Restaurar nrLevel (Req 1.7, 1.9).
    int restoredNrLevel;
    try {
      restoredNrLevel = _settingsRepository.nrLevel;
    } catch (e, st) {
      developer.log(
        '_applyMhlOffBranchForMutex: SettingsRepository.nrLevel '
        'falló: $e — usando default nrLevel=0.',
        name: 'AmplificationBloc',
        level: 900,
        error: e,
        stackTrace: st,
      );
      restoredNrLevel = 0;
    }
    try {
      await _audioBridge.updateNrLevel(restoredNrLevel);
    } catch (e, st) {
      developer.log(
        '_applyMhlOffBranchForMutex: bridge.updateNrLevel falló: $e',
        name: 'AmplificationBloc',
        level: 900,
        error: e,
        stackTrace: st,
      );
    }

    // Reaplicar la cadena DSP coherente (MPO → WDRC → EQ con clamp), igual
    // que la rama OFF directa de MHL (patient-dsp-controls-fix — Tarea 4) —
    // Req 1.6, 4.4, 4.5, 5.1, 5.2.
    final List<double> presetGains = await _resolvePresetGainsForRestore(
      currentState.activeEqPreset,
    );
    await _reapplyCoherentChainOnRestore(
      presetGains,
      _lastBundle,
      '_applyMhlOffBranchForMutex',
    );

    // Mirror lógico (Req 1.10).
    _mhlActive = false;
  }

  /// Activa o desactiva el modo "Música" como modo selectivo.
  ///
  /// **ON** (`event.activate == true`):
  /// 1. Si MHL Prescripción está ON, ejecuta primero la rama OFF de MHL
  ///    vía [_applyMhlOffBranchForMutex] (persiste
  ///    `mhlPrescriptionEnabled=false`, apaga MHL en motor, restaura
  ///    nrLevel y gains/WDRC del preset activo) — Req 1.4, 1.7.
  /// 2. Snapshot del Smart actual a [_smartEnabledBeforeMusic] (anidado:
  ///    si MHL había snapshot-eado Smart previamente, la rama OFF de
  ///    MHL no toca [_smartEnabled], así que el valor "real" se
  ///    preserva) — Req 1.5.
  /// 3. Fuerza `_smartEnabled = false` (mirror lógico; el handler
  ///    Kotlin `applyMusicMode(true)` también invoca
  ///    `setAutoClassifyEnabled(false)` defensivamente).
  /// 4. Aplica Música al motor vía
  ///    `_audioBridge.setMusicModeEnabled(true)` — el handler Kotlin
  ///    pone `nrLevel = 0` + `dnnIntensity = 0.0` sin tocar EQ/WDRC/
  ///    knees/attack/release/volumen — Req 1.2.
  /// 5. Persiste `musicModeEnabled=true` ANTES de emitir el nuevo
  ///    estado (Req 1.11).
  /// 6. Emite `AmplificationActive` con `musicModeActive: true` y
  ///    `activeNrLevel: 0` para reflejar el estado runtime del NR.
  ///
  /// **OFF** (`event.activate == false`):
  /// 1. Persiste `musicModeEnabled=false` (Req 1.11).
  /// 2. Llama a `_audioBridge.setMusicModeEnabled(false)` (no-op a
  ///    nivel motor por contrato del paciente; la restauración real
  ///    vive en Dart) — Req 1.2.
  /// 3. Restaura `_smartEnabled` desde [_smartEnabledBeforeMusic]
  ///    (default `false` si no había snapshot) — Req 1.6.
  /// 4. Reaplica `nrLevel` desde Settings vía `updateNrLevel`
  ///    (default `0` ante fallo de Settings — Req 1.8, 1.9).
  /// 5. Reaplica `dnnIntensity` desde Settings vía `setDnnIntensity`
  ///    (default `0.6` ante fallo — Req 1.8, 1.9).
  /// 6. Reaplica los gains del preset activo usando
  ///    [_resolvePresetGainsForRestore] (re-derivación
  ///    audiogram-driven para bundles legacy — Req 5.1, 5.2).
  /// 7. Reaplica WDRC con `compressionRatio` calculado por
  ///    [_effectiveCompressionRatio] sobre [_lastBundle], preservando
  ///    knees/attack/release del bundle (Req 1.6, 4.4, 4.5).
  /// 8. Emite `AmplificationActive` con `musicModeActive: false` y
  ///    `activeNrLevel` actualizado.
  ///
  /// **Réplica del paciente**: el flujo OFF/ON está mapeado bit-a-bit
  /// con `_onMusicModeChanged` de
  /// `PACIENTE/.../home_screen.dart` (líneas 497-543), salvo que en el
  /// técnico la persistencia se hace ANTES del bridge call para
  /// preservar el invariante "persistencia precede notificación"
  /// (Req 1.11).
  ///
  /// **Tolerancia a fallos**: cualquier fallo de persistencia o del
  /// bridge se loguea con `developer.log` nivel 900 (WARNING) y NO
  /// aborta el flujo. El estado emitido refleja el resultado final
  /// alcanzable con los recursos disponibles.
  ///
  /// **Mutex con MHL Prescripción**: el branch OFF de MHL embebido en
  /// la rama ON cubre Req 1.4 (al activar Música con MHL ON, MHL se
  /// apaga primero). El branch simétrico — apagar Música al activar
  /// MHL — vive en `_onToggleMhlPrescription` (task 4.2).
  ///
  /// Requisitos: 1.2, 1.4, 1.5, 1.6, 1.8, 1.9, 1.11
  Future<void> _onToggleMusicMode(
    ToggleMusicMode event,
    Emitter<AmplificationState> emit,
  ) async {
    final currentState = state;
    if (currentState is! AmplificationActive) return;

    if (event.activate) {
      // ─── Rama ON ────────────────────────────────────────────────────

      // Mutex (Req 1.4): si MHL Prescripción está ON, ejecutar primero
      // la rama OFF de MHL.
      final wasMhlOn = _readMhlPrescriptionEnabledOrFalse();

      AmplificationActive stateAfterMutex = currentState;
      if (wasMhlOn) {
        await _applyMhlOffBranchForMutex(currentState);
        // Reflejar inmediatamente que MHL quedó OFF antes de continuar
        // con la rama ON de Música. La emisión refleja el cambio
        // ordenado: MHL OFF → Música ON (Req 1.4).
        stateAfterMutex = currentState.copyWith(
          mhlActive: false,
          ptaWarning: false,
        );
      }

      // Snapshot Smart (Req 1.5). Si MHL había snapshot-eado Smart
      // previamente, su rama OFF NO toca [_smartEnabled] (el handler
      // Kotlin tampoco), así que la lectura actual representa el
      // valor "real". Esto preserva la semántica anidada del paciente
      // (`_smartBeforeMusic = _smartBeforeMhl ?? _smart`).
      _smartEnabledBeforeMusic = _smartEnabled;

      // Forzar Smart=false a nivel mirror lógico. El handler Kotlin
      // `applyMusicMode(true)` también invoca
      // `setAutoClassifyEnabled(false)` defensivamente.
      _smartEnabled = false;

      // Aplicar Música al motor (NR=0 + dnnIntensity=0 + Smart off vía
      // Kotlin) — Req 1.2.
      try {
        await _audioBridge.setMusicModeEnabled(true);
      } catch (e, st) {
        developer.log(
          '_onToggleMusicMode[ON]: bridge.setMusicModeEnabled '
          'falló: $e — revirtiendo snapshot Smart.',
          name: 'AmplificationBloc',
          level: 900,
          error: e,
          stackTrace: st,
        );
        _smartEnabled = _smartEnabledBeforeMusic ?? false;
        _smartEnabledBeforeMusic = null;
        // Aún si el bridge falló, refleja el estado del mutex (MHL OFF
        // ya quedó persistido) en la UI.
        if (wasMhlOn) emit(stateAfterMutex);
        return;
      }

      // Persistencia ANTES de notificar (Req 1.11).
      try {
        await _settingsRepository.setMusicModeEnabled(true);
      } catch (e, st) {
        developer.log(
          '_onToggleMusicMode[ON]: setMusicModeEnabled persistencia '
          'falló: $e — el motor ya aplicó Música, sesión continúa '
          'pero el flag no quedó persistido.',
          name: 'AmplificationBloc',
          level: 900,
          error: e,
          stackTrace: st,
        );
      }

      // Mirror lógico (Req 1.2, 1.4, 1.11).
      _musicModeActive = true;

      emit(stateAfterMutex.copyWith(
        musicModeActive: true,
        // El handler Kotlin pone NR a 0 en el motor; reflejar en state
        // para que la UI vea el cambio.
        activeNrLevel: 0,
      ));
      return;
    }

    // ─── Rama OFF ────────────────────────────────────────────────────

    // Persistencia ANTES de notificar (Req 1.11).
    try {
      await _settingsRepository.setMusicModeEnabled(false);
    } catch (e, st) {
      developer.log(
        '_onToggleMusicMode[OFF]: setMusicModeEnabled persistencia '
        'falló: $e — continuando con la restauración.',
        name: 'AmplificationBloc',
        level: 900,
        error: e,
        stackTrace: st,
      );
    }

    // Apagar Música en motor (no-op a nivel motor por contrato del
    // paciente; el handler Kotlin `applyMusicMode(false)` no toca
    // nada — la restauración real vive en Dart) — Req 1.2.
    try {
      await _audioBridge.setMusicModeEnabled(false);
    } catch (e, st) {
      developer.log(
        '_onToggleMusicMode[OFF]: bridge.setMusicModeEnabled '
        'falló: $e — continuando con la restauración Dart.',
        name: 'AmplificationBloc',
        level: 900,
        error: e,
        stackTrace: st,
      );
    }

    // Restaurar Smart al snapshot (Req 1.6).
    final restoreSmart = _smartEnabledBeforeMusic ?? false;
    _smartEnabledBeforeMusic = null;
    _smartEnabled = restoreSmart;
    if (restoreSmart) {
      // smart-continuo-dnn-modulado: simétrico a _onToggleMhlPrescription
      // OFF — si Smart estaba ON antes de Música, reactivar.
      _startSmartPolling();
    }

    // Leer nrLevel desde Settings con default tolerante (Req 1.8, 1.9).
    int restoredNrLevel;
    try {
      restoredNrLevel = _settingsRepository.nrLevel;
    } catch (e, st) {
      developer.log(
        '_onToggleMusicMode[OFF]: SettingsRepository.nrLevel '
        'falló: $e — usando default nrLevel=0.',
        name: 'AmplificationBloc',
        level: 900,
        error: e,
        stackTrace: st,
      );
      restoredNrLevel = 0;
    }

    // Reaplicar nrLevel al motor.
    try {
      await _audioBridge.updateNrLevel(restoredNrLevel);
    } catch (e, st) {
      developer.log(
        '_onToggleMusicMode[OFF]: bridge.updateNrLevel falló: $e',
        name: 'AmplificationBloc',
        level: 900,
        error: e,
        stackTrace: st,
      );
    }

    // Leer dnnIntensity desde Settings con default tolerante (Req 1.8,
    // 1.9). Default 0.6 por contrato del paciente.
    double restoredDnnIntensity;
    try {
      restoredDnnIntensity = _settingsRepository.dnnIntensity;
    } catch (e, st) {
      developer.log(
        '_onToggleMusicMode[OFF]: SettingsRepository.dnnIntensity '
        'falló: $e — usando default dnnIntensity=0.6.',
        name: 'AmplificationBloc',
        level: 900,
        error: e,
        stackTrace: st,
      );
      restoredDnnIntensity = 0.6;
    }

    // Reaplicar dnnIntensity al motor.
    try {
      await _audioBridge.setDnnIntensity(restoredDnnIntensity);
    } catch (e, st) {
      developer.log(
        '_onToggleMusicMode[OFF]: bridge.setDnnIntensity falló: $e',
        name: 'AmplificationBloc',
        level: 900,
        error: e,
        stackTrace: st,
      );
    }

    // Reaplicar la cadena DSP coherente (MPO → WDRC → EQ con clamp de
    // headroom), idéntica a la Tarea 3 (`_onUpdateEqGains`). Garantiza que
    // apagar Música deje el motor EXACTAMENTE en el estado coherente que
    // tendría sin haber tocado el modo (patient-dsp-controls-fix — Tarea 4) —
    // Req 1.6, 4.4, 4.5, 5.1, 5.2.
    final List<double> presetGains = await _resolvePresetGainsForRestore(
      currentState.activeEqPreset,
    );
    await _reapplyCoherentChainOnRestore(
      presetGains,
      _lastBundle,
      '_onToggleMusicMode[OFF]',
    );

    // Apagar el mirror lógico de Música (Req 1.11).
    _musicModeActive = false;

    emit(currentState.copyWith(
      musicModeActive: false,
      activeNrLevel: restoredNrLevel,
    ));
  }

  // ═════════════════════════════════════════════════════════════════════
  // tecnico-paciente-feature-parity — task 4.5
  // _onChangeComfort
  // ═════════════════════════════════════════════════════════════════════

  /// Aplica un nuevo valor del slider "Comodidad" recalculando el
  /// `compressionRatio` broadband del WDRC sobre el bundle activo.
  ///
  /// Réplica funcional del handler homónimo del paciente
  /// (`PACIENTE/.../home_screen.dart::_onComfortChanged`). El paciente
  /// persiste `comfort` en su `SettingsRepository` desde la UI ANTES
  /// de despachar el evento, igual que el técnico
  /// (`SimulatorScreen.onChangeEnd` — task 7.1). Por contrato, este
  /// handler NO escribe `comfort` en Settings: solo lo lee (de forma
  /// sincrónica) dentro de [_effectiveCompressionRatio].
  ///
  /// Comportamiento:
  /// 1. Si el state actual no es [AmplificationActive], descarta el
  ///    evento silenciosamente (no hay motor activo al que aplicarle
  ///    nada).
  /// 2. Si [_lastBundle] es `null` (boot temprano antes de la primera
  ///    aplicación atómica), emite un log informativo y retorna sin
  ///    tocar el motor — Req 4.4 exige que el ratio efectivo se
  ///    derive del bundle, así que sin bundle no hay nada que
  ///    recalcular.
  /// 3. Construye un [WdrcParams] con:
  ///    - `compressionRatio = _effectiveCompressionRatio(bundle)`
  ///      (broadband con offset Comodidad — Req 4.4, 4.5).
  ///    - `compressionKnee` resuelto vía
  ///      [_resolveBridgeCompressionKnee] (preserva el delta manual).
  ///    - `expansionKnee`, `attackMs`, `releaseMs` tomados del bundle
  ///      sin modificar (Req 4.5: "sin modificar otros parámetros").
  /// 4. Invoca `audioBridge.updateWdrcParams(...)` con try/catch: si
  ///    la llamada nativa falla, deja el motor en su último estado
  ///    consistente y emite un log de severidad media. NO emite
  ///    [AmplificationError] para no interrumpir la sesión por un
  ///    fallo aislado del bridge (consistente con [_onUpdateWdrcParams]
  ///    y con los reapply de WDRC en los handlers de MHL/Música).
  /// 5. Emite el state activo (vía `copyWith()`) para notificar a los
  ///    observadores. Como `comfort` no es un campo de
  ///    [AmplificationActive] y `_effectiveCompressionRatio` lo lee de
  ///    Settings on-demand, el state derivado no cambia visualmente:
  ///    la re-emisión es defensiva y mantiene la simetría con el resto
  ///    de handlers.
  ///
  /// El parámetro `event.comfort` es informativo (la fuente de verdad
  /// es `SettingsRepository.comfort` dentro del helper). Se mantiene
  /// en la firma del evento para trazabilidad y para que los tests de
  /// la UI puedan assertir el valor despachado.
  ///
  /// Requisitos: 4.4, 4.5
  Future<void> _onChangeComfort(
    ChangeComfort event,
    Emitter<AmplificationState> emit,
  ) async {
    final currentState = state;
    if (currentState is! AmplificationActive) return;

    final bundle = _lastBundle;
    if (bundle == null) {
      developer.log(
        '_onChangeComfort: _lastBundle == null; se omite el recálculo '
        'WDRC (no hay bundle activo todavía).',
        name: 'AmplificationBloc',
        level: 800,
      );
      return;
    }

    final wdrcParams = WdrcParams(
      expansionKnee: bundle.expansionKneeDbSpl,
      compressionKnee: _resolveBridgeCompressionKnee(bundle, _manualDelta),
      compressionRatio: _effectiveCompressionRatio(bundle),
      attackMs: bundle.wdrcAttackMs,
      releaseMs: bundle.wdrcReleaseMs,
    );

    try {
      await _audioBridge.updateWdrcParams(wdrcParams);
    } catch (e, st) {
      developer.log(
        '_onChangeComfort: bridge.updateWdrcParams falló: $e — el motor '
        'mantiene el último ratio aplicado, sesión continúa.',
        name: 'AmplificationBloc',
        level: 900,
        error: e,
        stackTrace: st,
      );
      return;
    }

    emit(currentState.copyWith());
  }

  /// Procesa una nueva clasificación del Smart Scene Engine y, si el
  /// modo activo es NL3, aplica/desactiva el módulo CIN respetando la
  /// histéresis del [ScenePrescriptionController].
  ///
  /// Si el modo activo es NL2, MHL Prescripción está habilitado, o
  /// Modo Música está habilitado, el evento se ignora silenciosamente.
  /// Música y MHL son ortogonales al Smart Scene Engine: ambos fuerzan
  /// `_smartEnabled = false` en el bloc, pero el evento de clasificación
  /// puede llegar de un polling pre-existente, por lo que el guard
  /// adicional es defensivo (Req 1.5, 1.6).
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
    // tecnico-paciente-feature-parity — task 4.3: bloquear CIN
    // mientras Modo Música está activo. Mirror de la guardia análoga
    // sobre `_mhlActive`.
    if (_musicModeActive) return;

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
        activeEqGains: finalGains,
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

  /// Nivel de input de referencia (dB SPL) usado para clampar las ganancias
  /// finales contra el headroom MPO.
  ///
  /// Se dimensiona al PEOR CASO OPERATIVO, no a la conversación normal:
  /// - Conversación normal ≈ 65 dB SPL.
  /// - Voz alzada / interlocutor cercano ≈ 75-85 dB SPL.
  /// Clampar contra 65 dB SPL solo garantizaba no-saturación para charla
  /// tranquila; con inputs fuertes (75-85 dB SPL) el presupuesto de headroom
  /// se desbordaba y el MPO saturaba audible ("reventado"). Usamos 80 dB SPL
  /// como referencia: cubre voz fuerte/cercana, que es el peor caso realista
  /// sostenido (los transitorios puntuales por encima de 80 dB SPL los
  /// absorben el TNR y el peak-limiter instantáneo del MPO, no este clamp
  /// estático de ganancia).
  ///
  /// TRADE-OFF (sub-amplificación): subir la referencia recorta más la
  /// ganancia en bandas con MPO bajo (audiogramas severos). Es aceptable y
  /// está acotado: el clamp NUNCA baja la ganancia por debajo de
  /// [AudiogramDrivenBundle.gainMinDb] (piso clínico del EQ), así que no
  /// puede sub-amplificar de forma absurda. Preferimos perder unos dB de
  /// ganancia máxima en picos fuertes antes que entregar salida distorsionada
  /// por MPO saturado, que es clínicamente peor (peor inteligibilidad y
  /// fatiga/incomodidad en pediatría).
  static const double _kHeadroomInputDbSpl = 80.0;

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
  ///
  /// Adicionalmente, aplica el techo de ganancia del hardware
  /// (`hardwareGainCeilingPerBandDb`) vía [fitPrescriptionToCeiling]
  /// (WCPF). Si los 12 techos son 50 (default — sin calibrar), no
  /// recorta nada (backward compat).
  List<double> _resolveFinalGains(
    AudiogramDrivenBundle bundle,
    ManualAdjustmentDelta? delta,
  ) {
    // Cap por banda según severidad del audiograma + override manual
    // del slider "Tope de ganancia". Preserva la curva NAL/DSL del
    // bundle pero limita el techo por banda al valor validado por el
    // usuario. Si el cap es null, no se aplica tope.
    final severityCap = _audiogramSeverityGainCapDb();

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
          _kHeadroomInputDbSpl -
          _kHeadroomSafetyMarginDb;
      if (headroom < g) {
        g = math.max(headroom, AudiogramDrivenBundle.gainMinDb);
      }
      gains[i] = g;
    }
    // Cap por banda según severidad + override manual. Aplicado ANTES
    // del WCPF para que la escala proporcional opere sobre la curva ya
    // acotada al techo seguro.
    if (severityCap != null) {
      for (var i = 0; i < AudiogramDrivenBundle.bandCount; i++) {
        if (gains[i] > severityCap) gains[i] = severityCap;
      }
    }
    // Clamp final: techo de ganancia del hardware vía WCPF (escala
    // proporcionalmente con pesos SII para preservar la forma de la
    // curva). Backward compat: si los 12 techos son 50, retorna gains
    // intactos. Si no hay calibración (null), se omite.
    final ceiling = _settingsRepository.hardwareGainCeilingPerBandDb;
    if (ceiling != null && ceiling.length == AudiogramDrivenBundle.bandCount) {
      return fitPrescriptionToCeiling(gains, ceiling);
    }
    return List<double>.unmodifiable(gains);
  }

  /// Cap por banda según severidad del audiograma (decisión del usuario,
  /// junio 2026, evolución del override flat anterior): preserva la
  /// forma de la curva NAL/DSL prescrita por el bundle pero limita el
  /// techo por banda según PTA-4 para evitar saturación con audiogramas
  /// agresivos sin perder el carácter clínico.
  ///
  /// Devuelve `null` cuando no hay que hacer cap (sin audiograma, audiograma
  /// incompleto, o pérdida mínima). Si retorna un cap > 0, significa que
  /// los gains finales se deben clampear banda-a-banda contra ese tope.
  ///
  /// Reglas:
  /// - Sin `_currentAudiogram` o audiograma incompleto → `null`.
  /// - PTA = promedio de umbrales en 500/1000/2000/4000 Hz (PTA-4 estándar).
  /// - PTA ≤ 20 dB HL (pérdida mínima/normal) → `null` (sin cap → preset
  ///   normal con gains del bundle).
  /// - PTA > 35 dB HL → cap **14 dB** por banda (audiograma severo:
  ///   protección anti-saturación más agresiva, justo arriba del flat 8 dB
  ///   de MHL pero permite ganar agudos).
  /// - 20 < PTA ≤ 35 dB HL → cap **16 dB** por banda (pérdida leve:
  ///   un poco más de margen, aún seguro contra saturación).
  ///
  /// Diferencia con la versión anterior (override flat): en lugar de
  /// reemplazar TODOS los gains por un valor plano (que destruye la
  /// curva clínica y deja al paciente sin compensación de agudos), esta
  /// versión PRESERVA la prescripción NAL/DSL y solo recorta los picos
  /// que estarían encima del cap. Resultado: graves bajos, agudos altos
  /// pero acotados, sin saturación.
  ///
  /// El usuario reportó que el flat anterior "no era clínico" porque
  /// amplificaba lo mismo en todas las bandas (no compensaba la pérdida
  /// real por banda). Este cap por severidad mantiene la forma de la
  /// curva (lo que el oído del paciente necesita) y solo previene los
  /// niveles que disparaban el MPO/limiter al techo.
  double? _audiogramSeverityGainCapDb() {
    final audiogram = _currentAudiogram;
    if (audiogram == null) return null;
    if (!_isAudiogramComplete(audiogram)) return null;

    // PTA-4: promedio de umbrales en 500, 1000, 2000, 4000 Hz.
    const ptaFrequencies = [500, 1000, 2000, 4000];
    double sum = 0.0;
    int count = 0;
    for (final f in ptaFrequencies) {
      final v = audiogram.thresholds[f];
      if (v != null && v.isFinite) {
        sum += v;
        count++;
      }
    }
    if (count == 0) return null;
    final pta = sum / count;

    if (pta <= 20.0) return null;

    // Override manual del usuario (slider en Servicio Técnico). Si el
    // usuario fijó un valor explícito, lo respetamos. Si no, default
    // 8 dB (severo) / 14 dB (leve) — los valores que el usuario validó
    // auditivamente como seguros.
    double? userOverride;
    try {
      userOverride = _settingsRepository.gainCapManualDb;
    } catch (_) {
      userOverride = null;
    }
    if (userOverride != null && userOverride.isFinite && userOverride > 0) {
      return userOverride.clamp(4.0, 24.0).toDouble();
    }

    return pta > 35.0 ? 8.0 : 14.0;
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

  /// Ratio de compresión broadband efectivo enviado al motor DSP,
  /// aplicando el offset del slider "Comodidad" sobre el ratio base
  /// del [bundle].
  ///
  /// Réplica funcional del `_effectiveCompressionRatio` del paciente
  /// (`PACIENTE/.../home_screen.dart`). El paciente expone un escalar
  /// `b.wdrc.compressionRatio`; en el técnico el bundle es
  /// [AudiogramDrivenBundle] con 12 ratios por banda
  /// ([AudiogramDrivenBundle.compressionRatios]), por lo que la base
  /// se reduce primero al escalar broadband que sería enviado al
  /// bridge (PTA-weighted average con [_manualDelta] y clamp a
  /// `[1.0, 3.0]`) vía [_resolveBridgeCompressionRatio]. Sobre ese
  /// escalar se aplica la fórmula del paciente:
  ///
  /// ```
  /// result = base + (1 - base) * comfort
  /// ```
  ///
  /// con:
  /// - `comfort = 0` → result = base (lo que el técnico fijó).
  /// - `comfort = 1` → result = 1.0 (sin compresión, "natural").
  /// - `base = 1.0` → result = 1.0 para cualquier comfort.
  ///
  /// `comfort` se lee sincrónicamente de [SettingsRepository.comfort]
  /// (sin `await`). El getter del repositorio ya retorna `0.5` cuando
  /// la key está ausente, es no numérica o `NaN`, y clampea a
  /// `[0.0, 1.0]`. Igualmente, este helper sanitiza defensivamente
  /// `NaN`/`±Infinity` → `0.5` y aplica un clamp final a `[0.0, 1.0]`
  /// antes de la fórmula, para tolerar boxes corruptos o lecturas
  /// inesperadas (Req 4.7).
  ///
  /// **Operación read-only sobre [bundle]**: nunca modifica
  /// `bundle.compressionRatios` ni ningún otro campo del bundle.
  ///
  /// Requisitos: 4.4, 4.5, 4.7, 4.8, 4.11
  double _effectiveCompressionRatio(AudiogramDrivenBundle bundle) {
    // Base broadband: PTA-weighted average con delta manual y clamp
    // a [1.0, 3.0] aplicados (read-only sobre el bundle).
    final base = _resolveBridgeCompressionRatio(bundle, _manualDelta);
    return _applyComfortToRatio(base);
  }

  /// Aplica el offset del slider "Comodidad" sobre un ratio de compresión
  /// escalar [base] ya resuelto.
  ///
  /// Extraído de [_effectiveCompressionRatio] para que ambas rutas (la
  /// bundle-driven y la de presets legacy con WDRC propio en
  /// [_onUpdateEqGains]) honren Comodidad con la MISMA fórmula:
  ///
  /// ```
  /// result = base + (1 - base) * comfort
  /// ```
  ///
  /// `comfort` se lee sincrónicamente de [SettingsRepository.comfort]
  /// (sin `await`). Defensivo contra NaN/Infinity a pesar de que el
  /// getter del repo ya sanea estos casos: si la lectura lanza, default
  /// a 0.5; si es no finita, también 0.5. Clamp final a `[0.0, 1.0]`.
  ///
  /// Requisitos: 4.4, 4.5, 4.7, 4.8, 4.11
  double _applyComfortToRatio(double base) {
    double comfort;
    try {
      final raw = _settingsRepository.comfort;
      comfort = (raw.isNaN || raw.isInfinite) ? 0.5 : raw;
    } catch (_) {
      comfort = 0.5;
    }
    comfort = comfort.clamp(0.0, 1.0).toDouble();
    return base + (1.0 - base) * comfort;
  }

  /// Resuelve las 12 ganancias EQ a aplicar al motor para [preset],
  /// re-derivándolas desde el audiograma cuando el preset trae
  /// `gains == [0, ..., 0]` y NO se llama "Sin amplificación".
  ///
  /// Réplica funcional del helper homónimo del paciente
  /// (`PACIENTE/.../home_screen.dart`). Cubre el caso de bundles
  /// legacy donde un preset con todos los gains a cero (con
  /// tolerancia `1e-6`) indica un bundle malformado en lugar de un
  /// bypass intencional. El único preset legítimo con gains-cero es
  /// "Sin amplificación" (comparación case-sensitive, sin `trim`).
  ///
  /// Reglas (Req 5.1, 5.2, 5.3, 5.4, 5.5):
  ///
  /// 1. Si `preset.gains` no es todo-cero (con tolerancia `1e-6`) o
  ///    `preset.name == 'Sin amplificación'`, retorna `preset.gains`
  ///    sin tocar nada.
  /// 2. Si todo-cero y el nombre es distinto, intenta re-derivar:
  ///    - Si [audiogram] es `null` → warning "audiograma nulo" y
  ///      retorna `preset.gains` como fallback (Req 5.3).
  ///    - Si [audiogram] está incompleto en alguna frecuencia NAL-NL2
  ///      (vía [_isAudiogramComplete]) → warning "audiograma
  ///      incompleto" y retorna `preset.gains` (Req 5.3).
  ///    - Si el prescriptor lanza → warning "prescriptor falló" y
  ///      retorna `preset.gains` (Req 5.4).
  ///    - En éxito: log informativo con el nombre del preset y las
  ///      12 ganancias re-derivadas, retorna esas ganancias (Req 5.5).
  ///
  /// **Nota de mapeo Dart**: el campo se llama `gains` en
  /// [EqPreset] (técnico) pero `gainsDb` en `BundlePreset`
  /// (paciente). La semántica es idéntica — ganancias en dB para las
  /// 12 bandas estándar. El docstring del design.md usa `gainsDb`
  /// porque traza con la app del paciente; esta implementación lee
  /// `preset.gains` que es el nombre real del campo en el técnico.
  ///
  /// La firma es `Future` para permitir prescriptores asíncronos en
  /// el futuro; la implementación actual del [GainPrescriber] del
  /// técnico es sincrónica, así que el `Future` se completa en el
  /// mismo frame.
  ///
  /// Requisitos: 5.1, 5.2, 5.3, 5.4, 5.5
  Future<List<double>> _resolveGainsForPreset(
    EqPreset preset,
    Audiogram? audiogram,
  ) async {
    const tolerance = 1e-6;
    final allZero = preset.gains.every((g) => g.abs() <= tolerance);

    // Req 5.1, 5.2: comparación case-sensitive, sin trim, contra el
    // string canónico "Sin amplificación".
    if (!allZero || preset.name == 'Sin amplificación') {
      return preset.gains;
    }

    // Req 5.3: audiograma nulo → warning con causa específica.
    if (audiogram == null) {
      developer.log(
        '_resolveGainsForPreset: re-derivación omitida para preset='
        '"${preset.name}": audiograma nulo. Usando gains del preset.',
        name: 'AmplificationBloc',
        level: 900, // WARNING
      );
      return preset.gains;
    }

    // Req 5.3: audiograma incompleto en alguna freq NAL-NL2 →
    // warning con causa específica.
    if (!_isAudiogramComplete(audiogram)) {
      developer.log(
        '_resolveGainsForPreset: re-derivación omitida para preset='
        '"${preset.name}": audiograma incompleto (faltan bandas o '
        'umbrales fuera de rango). Usando gains del preset.',
        name: 'AmplificationBloc',
        level: 900, // WARNING
      );
      return preset.gains;
    }

    // Req 5.4: excepción del prescriptor → warning, fallback a gains
    // originales del preset.
    try {
      final derived = _gainPrescriber.prescribeFromAudiogram(audiogram);
      // Req 5.5: log informativo en re-derivación exitosa.
      developer.log(
        '_resolveGainsForPreset: re-derivación exitosa para preset='
        '"${preset.name}". Gains=$derived',
        name: 'AmplificationBloc',
        level: 800, // INFO
      );
      return derived;
    } catch (e, st) {
      developer.log(
        '_resolveGainsForPreset: prescriptor falló para preset='
        '"${preset.name}": $e. Usando gains del preset.',
        name: 'AmplificationBloc',
        level: 900, // WARNING
        error: e,
        stackTrace: st,
      );
      return preset.gains;
    }
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

  /// Cancela todas las suscripciones a streams del engine y espera
  /// que cada cancelación se complete antes de retornar.
  ///
  /// **tecnico-paciente-feature-parity — task 5.2 (Req 3.6)**:
  /// `StreamSubscription.cancel()` retorna un `Future<void>` que se
  /// completa cuando el stream subyacente liberó sus recursos. Para
  /// garantizar que `audioBridge.stopAudio` no compita con callbacks
  /// pendientes (`InputLevelUpdated`, `AudioEngineState`) que el
  /// motor pudo haber emitido justo antes del stop, esperamos cada
  /// `.cancel()` secuencialmente antes de devolver el control al
  /// caller. El orden secuencial mantiene el contrato simple y es
  /// equivalente al usado en el paciente.
  ///
  /// Nullea cada referencia tras cancelar para que un segundo
  /// `_cancelSubscriptions()` (por ejemplo desde `close()` tras un
  /// `_onStopAmplification`) sea idempotente.
  ///
  // ═══════════════════════════════════════════════════════════════════
  // smart-continuo-dnn-modulado: Smart Scene continuo + DNN por escena
  // ═══════════════════════════════════════════════════════════════════

  /// Cap de DNN intensity por escena. Aplicado SOLO mientras Smart está
  /// ON. Cuando Smart se apaga (o MHL/Música activos), la intensidad
  /// del usuario se restaura sin cap.
  ///
  /// Tabla:
  ///   - QUIET            → 0.00  (DNN off — sin artefactos audibles)
  ///   - SPEECH           → 0.40  (limpieza suave, transparencia voz)
  ///   - SPEECH_IN_NOISE  → 0.70  (limpieza media; el VAD cuida la voz)
  ///   - NOISE            → 0.85  (limpieza fuerte — ambiente desagradable)
  ///
  /// Devuelve `null` para clases fuera de [0, 3]: el caller debe usar
  /// `userIntensity` sin cap (no aplica DNN cap).
  static double? _sceneDnnCap(int envClass) {
    switch (envClass) {
      case 0: return 0.00;  // QUIET
      case 1: return 0.40;  // SPEECH
      case 2: return 0.55;  // SPEECH_IN_NOISE — voz dominante post-DNN
      case 3: return 0.70;  // NOISE — preserva voz residual (Crukley/Healy)
      default: return null;
    }
  }

  /// Restaura la intensidad de DNN al valor del usuario (Settings).
  /// Se llama al apagar Smart, al activar MHL/Música, y antes de que
  /// un cambio manual de profile tome el control.
  Future<void> _restoreUserDnnIntensity() async {
    double user;
    try {
      user = _settingsRepository.dnnIntensity;
    } catch (_) {
      user = 0.6;
    }
    try {
      await const MethodChannel('com.psk.hearing_aid/audio')
          .invokeMethod<void>('setDnnEnabled', {'enabled': user > 0.0});
      await _audioBridge.setDnnIntensity(user);
    } catch (e, st) {
      developer.log(
        '_restoreUserDnnIntensity falló: $e',
        name: 'AmplificationBloc',
        level: 800,
        error: e,
        stackTrace: st,
      );
    }
  }

  /// Activa el clasificador C++ (`updateAutoClassify(true)`) y arranca
  /// el polling Smart mejorado cada 12 segundos.
  ///
  /// El nuevo polling usa el mismo motor que el botón "Detectar y aplicar"
  /// de `smart_scene_screen.dart`: analiza snapshots del SceneAnalyzer C++
  /// con features espectrales completas (VAD, tilt, centroid, flux) y
  /// aplica presets personalizados con audiograma automáticamente.
  ///
  /// Cambios vs polling viejo (1 Hz con EnvironmentClassifier básico):
  /// - Intervalo: 1s → 12s (análisis toma ~1.5s, más estable)
  /// - Motor: `environmentClass` básico → `SceneEngine.analyze()` completo
  /// - Output: `ChangeProfile` genérico → `apply()` preset con audiograma
  /// - Idempotencia: Solo aplica si SceneClass cambió
  ///
  /// Idempotente: cancela el timer previo antes de armar uno nuevo.
  void _startSmartPolling() {
    _smartPollTimer?.cancel();
    _lastEnvClass = null;
    _lastSceneClass = null;
    
    // Inicializar SceneEngine con config optimizada para polling automático:
    // - Session corto (1.5s vs 5s del manual) para reactividad
    // - Menos muestras (8-15 vs 10-25) para no bloquear el bloc
    _sceneEngine = SceneEngine(
      sessionTimeout: const Duration(milliseconds: 1500),
      minSamples: 8,
      maxSamples: 15,
    );
    
    // Despertar el clasificador C++ para que la UI siga mostrando
    // environmentClass básico en el chip indicador (backward-compat).
    () async {
      try {
        await const MethodChannel('com.psk.hearing_aid/audio')
            .invokeMethod<void>('updateAutoClassify', {'enabled': true});
        
        // Cargar settings del SceneEngine (toggle personalizar)
        await _sceneEngine!.loadSettings();
        
        // Cargar audiograma para el análisis (lazy load, una sola vez)
        try {
          _audiogram = await _audiogramRepository.getAudiogram();
        } catch (_) {
          _audiogram = null; // Fallback a default en analyze()
        }
      } catch (e, st) {
        developer.log(
          '_startSmartPolling: init falló: $e',
          name: 'AmplificationBloc',
          level: 800,
          error: e,
          stackTrace: st,
        );
      }
    }();
    
    // Polling mejorado cada 12 segundos (vs 1s del viejo)
    _smartPollTimer = Timer.periodic(
      const Duration(seconds: 12),
      (_) => _onSmartPollV2(),
    );
  }

  /// Cancela el polling Smart, apaga el clasificador C++, libera el pin
  /// del preset Smart, restaura la intensidad de DNN del usuario (uncap),
  /// y limpia el SceneEngine. Idempotente.
  void _stopSmartPolling() {
    _smartPollTimer?.cancel();
    _smartPollTimer = null;
    _lastEnvClass = null;
    _lastSceneClass = null;
    _sceneEngine = null;
    _audiogram = null;
    
    () async {
      try {
        await const MethodChannel('com.psk.hearing_aid/audio')
            .invokeMethod<void>('updateAutoClassify', {'enabled': false});
      } catch (_) { /* tolerante */ }
      // FIX Causa B' (smart-scene-diagnostico-chasquido.md): liberar el
      // pin para que el clasificador automático del próximo encendido
      // arranque limpio (sin un pin stale del Smart anterior).
      try {
        await const MethodChannel('com.psk.hearing_aid/audio')
            .invokeMethod<void>(
          'setSmartPresetPinned',
          <String, dynamic>{'pinned': false},
        );
      } catch (_) { /* tolerante */ }
      await _restoreUserDnnIntensity();
    }();
  }

  /// Tick del polling Smart mejorado (v2).
  ///
  /// En lugar de solo leer `environmentClass` básico y despachar
  /// `ChangeProfile`, ahora:
  /// 1. Ejecuta análisis completo con `SceneEngine.analyze()` (1.5s)
  /// 2. Usa features espectrales avanzadas (VAD, tilt, centroid, flux)
  /// 3. Genera preset personalizado con audiograma
  /// 4. Aplica preset completo automáticamente (EQ + WDRC + NR + TNR)
  /// 5. Solo si la SceneClass cambió (idempotencia)
  ///
  /// Mismo comportamiento que el botón manual "Detectar y aplicar" de
  /// `smart_scene_screen.dart`, pero corriendo invisible cada 12s.
  Future<void> _onSmartPollV2() async {
    if (!_smartEnabled) return;
    if (_sceneEngine == null) {
      developer.log(
        'Smart poll v2: SceneEngine null (init failed?)',
        name: 'SmartAutoV2',
        level: 800,
      );
      return;
    }

    // Análisis completo (SceneAnalyzer C++ + SceneDecisionMaker)
    SceneAnalysisResult result;
    try {
      // Obtener perfil activo actual para pasarlo al analyze()
      // (determina el PrescriptionMode del bundle base)
      final currentProfile = _getCurrentEnvironmentProfile();
      
      result = await _sceneEngine!.analyze(
        audiogram: _audiogram, // null → fallback a default
        profile: currentProfile,
      );
      
      developer.log(
        'Smart auto: clase=${result.sceneClass.name}, '
        'conf=${(result.confidence * 100).toStringAsFixed(0)}%, '
        'samples=${result.sampleCount}, '
        'usedDefault=${result.usedDefaultAudiogram}',
        name: 'SmartAutoV2',
        level: 300,
      );
    } catch (e, st) {
      developer.log(
        'Smart auto analyze failed: $e',
        name: 'SmartAutoV2',
        level: 800,
        error: e,
        stackTrace: st,
      );
      return; // Reintentar en próximo tick (12s)
    }

    // Idempotencia: solo aplicar si la clase de escena cambió
    if (result.sceneClass == _lastSceneClass) {
      developer.log(
        'Smart auto: clase sin cambios (${result.sceneClass.name}), skip apply',
        name: 'SmartAutoV2',
        level: 300,
      );
      return;
    }
    
    final previousClass = _lastSceneClass;
    _lastSceneClass = result.sceneClass;

    // Aplicar preset completo automáticamente
    try {
      await _sceneEngine!.apply(result, bloc: this);
      
      developer.log(
        'Smart auto: preset aplicado OK '
        '(${previousClass?.name ?? "null"} → ${result.sceneClass.name})',
        name: 'SmartAutoV2',
        level: 300,
      );
    } catch (e, st) {
      developer.log(
        'Smart auto apply failed: $e',
        name: 'SmartAutoV2',
        level: 800,
        error: e,
        stackTrace: st,
      );
      // Revertir _lastSceneClass para reintentar en próximo tick
      _lastSceneClass = previousClass;
    }
    
    // Backward-compat: actualizar también _lastEnvClass para el chip
    // indicador de escena en main_screen.dart (mapea SceneClass → int)
    _lastEnvClass = _sceneClassToEnvClass(result.sceneClass);
  }

  /// Helper: obtiene el EnvironmentProfile activo actual para pasarlo
  /// a `SceneEngine.analyze()`. Devuelve null si no hay perfil activo
  /// (fallback a PrescriptionMode.quiet en el bundle builder).
  EnvironmentProfile? _getCurrentEnvironmentProfile() {
    final st = state;
    String? activeProfileName;
    
    if (st is AmplificationActive) {
      activeProfileName = st.activeProfile;
    } else if (st is AmplificationPaused) {
      activeProfileName = st.lastActiveProfile;
    }
    
    if (activeProfileName == null) return null;
    
    // Mapear nombre de perfil → enum EnvironmentProfile
    switch (activeProfileName) {
      case 'Silencioso':
        return EnvironmentProfile.quiet;
      case 'Conversación':
        return EnvironmentProfile.conversation;
      case 'Ruidoso':
        return EnvironmentProfile.noisy;
      default:
        return null;
    }
  }

  /// Helper: mapea SceneClass → int environmentClass para backward-compat
  /// con el chip indicador de escena en main_screen.dart.
  ///
  /// Mapeo aproximado (la semántica NO es 1:1):
  /// - unknown/silence → QUIET (0)
  /// - voiceOnly → SPEECH (1)
  /// - voiceInNoiseLow/Mid → SPEECH_IN_NOISE (2)
  /// - noiseLowDominant/noiseHighDominant/music → NOISE (3)
  int _sceneClassToEnvClass(SceneClass sceneClass) {
    switch (sceneClass) {
      case SceneClass.unknown:
      case SceneClass.silence:
        return 0; // QUIET
      case SceneClass.voiceOnly:
        return 1; // SPEECH
      case SceneClass.voiceInNoiseLow:
      case SceneClass.voiceInNoiseMid:
        return 2; // SPEECH_IN_NOISE
      case SceneClass.noiseLowDominant:
      case SceneClass.noiseHighDominant:
      case SceneClass.music:
        return 3; // NOISE
    }
  }

  /// Tick del polling Smart VIEJO (fallback si v2 falla).
  /// Mantiene la lógica original de leer environmentClass básico y
  /// despachar ChangeProfile. NO debería llamarse con la v2 activa,
  /// pero lo dejamos comentado como referencia histórica.
  @Deprecated('Reemplazado por _onSmartPollV2')
  Future<void> _onSmartPoll() async {
    if (!_smartEnabled) return;
    Map<String, dynamic>? metrics;
    try {
      metrics = await _audioBridge.getDspStageMetrics();
    } catch (_) {
      return; // motor parado → próximo tick
    }
    if (metrics == null) return;
    final cls = metrics['environmentClass'];
    if (cls is! int) return;
    if (cls == _lastEnvClass) return; // idempotente
    _lastEnvClass = cls;

    // Cap de DNN por escena. Se aplica ANTES del ChangeProfile para
    // que el cross-fade del EQ/WDRC ocurra contra el nivel de NR
    // correcto. El cap NO se persiste — el slider del usuario sigue
    // siendo la fuente de verdad; el cap solo se aplica al motor.
    final cap = _sceneDnnCap(cls);
    if (cap != null) {
      double user;
      try {
        user = _settingsRepository.dnnIntensity;
      } catch (_) {
        user = 0.6;
      }
      final effective = user < cap ? user : cap;
      try {
        await const MethodChannel('com.psk.hearing_aid/audio')
            .invokeMethod<void>(
                'setDnnEnabled', {'enabled': effective > 0.0});
        await _audioBridge.setDnnIntensity(effective);
      } catch (e, st) {
        developer.log(
          '_onSmartPoll: aplicar cap DNN falló: $e',
          name: 'AmplificationBloc',
          level: 800,
          error: e,
          stackTrace: st,
        );
      }
    }

    // Resolver perfil del técnico (Silencioso/Conversación/Ruidoso) y
    // despachar `ChangeProfile`. La función `resolveEnvironmentProfile`
    // ya maneja el contrato de 4 clases (QUIET/SPEECH/SPEECH_IN_NOISE/
    // NOISE) → 3 perfiles del técnico.
    final profile = _resolveEnvironmentProfile(cls);
    if (profile == null) return;
    final st = state;
    String? activeProfileName;
    if (st is AmplificationActive) {
      activeProfileName = st.activeProfile;
    } else if (st is AmplificationPaused) {
      activeProfileName = st.lastActiveProfile;
    }
    if (profile == activeProfileName) return; // ya activo
    add(ChangeProfile(profile: profile, fromSmartPoll: true));
  }

  /// Mapea la 4-clases del `EnvironmentClassifier` C++ → perfil del
  /// técnico. Réplica del helper `resolveEnvironmentProfile` de
  /// `smart_preset_resolver.dart` (mantenido inline para no acoplar el
  /// bloc a la screen).
  String? _resolveEnvironmentProfile(int envClass) {
    switch (envClass) {
      case 0: return 'Silencioso';
      case 1: return 'Conversación';
      case 2:
      case 3: return 'Ruidoso';
      default: return null;
    }
  }

  /// Handler del evento `ToggleSmart`.
  Future<void> _onToggleSmart(
    ToggleSmart event,
    Emitter<AmplificationState> emit,
  ) async {
    final activate = event.activate;
    if (activate == _smartEnabled) return; // idempotente

    _smartEnabled = activate;
    if (activate) {
      _startSmartPolling();
    } else {
      _stopSmartPolling();
    }
  }

  // ═════════════════════════════════════════════════════════════════════
  // modo-conversacion-sco
  // _onToggleConversationMode
  // ═════════════════════════════════════════════════════════════════════

  /// Activa o desactiva el "Modo Conversación" (SCO baja latencia).
  ///
  /// Delega en `_audioBridge.setConversationMode(enabled)` que a su vez
  /// invoca el handler Kotlin `handleSetConversationMode`. Este handler:
  /// - Detiene el engine si está corriendo.
  /// - Levanta SCO + cambia a MODE_IN_COMMUNICATION si ON.
  /// - Reinicia a 16 kHz / 64 frames (ON) o 48 kHz / 256 frames (OFF).
  /// - Re-inicializa el DNN denoiser tras el reinicio.
  /// - Retorna un string con el resultado: "connected", "fallback_builtin",
  ///   "failed", "engine_idle", "disabled".
  ///
  /// **Mutex con MHL y Música**: si alguno de estos modos está activo al
  /// encender Conversación, se apagan primero (mismo patrón que
  /// `_onToggleSmart`). No se snapshotea Smart porque el reinicio del
  /// engine destruye el estado del clasificador C++.
  ///
  /// **Persistencia**: guarda `conversationMode` en Hive (`settings_box`)
  /// bajo la key `'conversationMode'`. Se carga en Phase 1 del boot.
  ///
  /// Requisitos: modo-conversacion-sco
  Future<void> _onToggleConversationMode(
    ToggleConversationMode event,
    Emitter<AmplificationState> emit,
  ) async {
    final currentState = state;
    if (currentState is! AmplificationActive) return;

    final activate = event.activate;
    developer.log(
      '🔍 TOGGLE BLOC: activate=$activate, _conversationMode=$_conversationMode',
      name: 'AmplificationBloc',
      level: 800,
    );
    // REMOVIDO: if (activate == _conversationMode) return;
    // El check de idempotencia causaba desincronización cuando el state
    // se actualizaba fuera del handler. Ahora siempre ejecutamos el cambio.

    // ─── Mutex: apagar MHL y Música si están ON ─────────────────────
    if (activate) {
      if (_mhlActive) {
        try {
          await _audioBridge.setMhlPrescriptionEnabled(false);
          _mhlActive = false;
        } catch (e, st) {
          developer.log(
            '_onToggleConversationMode[ON]: mutex MHL OFF falló: $e',
            name: 'AmplificationBloc',
            level: 900,
            error: e,
            stackTrace: st,
          );
        }
      }
      if (_musicModeActive) {
        try {
          await _audioBridge.setMusicModeEnabled(false);
          _musicModeActive = false;
        } catch (e, st) {
          developer.log(
            '_onToggleConversationMode[ON]: mutex Música OFF falló: $e',
            name: 'AmplificationBloc',
            level: 900,
            error: e,
            stackTrace: st,
          );
        }
      }
    }

    // ─── Delegar al bridge nativo ───────────────────────────────────
    final String scoStatus;
    try {
      scoStatus = await _audioBridge.setConversationMode(activate);
    } catch (e, st) {
      developer.log(
        '_onToggleConversationMode: bridge.setConversationMode '
        'falló: $e',
        name: 'AmplificationBloc',
        level: 900,
        error: e,
        stackTrace: st,
      );
      // No cambiar el mirror — el toggle queda donde estaba.
      return;
    }

    _conversationMode = activate;

    // ─── Persistencia en Hive ───────────────────────────────────────
    try {
      final box = await _openSettingsBox();
      await box?.put('conversationMode', activate);
    } catch (e, st) {
      developer.log(
        '_onToggleConversationMode: persistencia falló: $e',
        name: 'AmplificationBloc',
        level: 900,
        error: e,
        stackTrace: st,
      );
    }

    // ─── Emitir estado con el flag y el resultado SCO ───────────────
    // Nota: el flag `conversationMode` se incluye en el state; el
    // resultado `scoStatus` se deja como log para que la UI lo lea
    // vía `BlocListener` y muestre un SnackBar.
    developer.log(
      '_onToggleConversationMode: activate=$activate, scoStatus=$scoStatus',
      name: 'AmplificationBloc',
      level: 800,
    );

    emit(currentState.copyWith(
      conversationMode: activate,
      mhlActive: _mhlActive,
      musicModeActive: _musicModeActive,
    ));
  }

  /// Cancela las suscripciones a los streams del [AudioBridge] y
  /// nullea los handles. Idempotente.
  ///
  /// Requisitos: 3.6
  Future<void> _cancelSubscriptions() async {
    final inputSub = _inputLevelSubscription;
    _inputLevelSubscription = null;
    if (inputSub != null) {
      await inputSub.cancel();
    }

    final engineSub = _engineStateSubscription;
    _engineStateSubscription = null;
    if (engineSub != null) {
      await engineSub.cancel();
    }
  }

  @override
  Future<void> close() async {
    _smartPollTimer?.cancel();
    _smartPollTimer = null;
    await _cancelSubscriptions();
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
