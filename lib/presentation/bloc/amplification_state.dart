import 'package:equatable/equatable.dart';

import '../../domain/audiogram_driven_presets/audiogram_driven_bundle.dart';
import '../../domain/audiogram_driven_presets/manual_adjustment_delta.dart';
import '../../domain/audiogram_driven_presets/operating_mode.dart';
import '../../domain/entities/loss_type.dart';
import '../../domain/entities/prescription_mode.dart';

/// Razón por la que la amplificación está pausada.
enum PauseReason {
  /// Auriculares Bluetooth desconectados (Req 3.3).
  btDisconnected,

  /// Foco de audio perdido por otra app (Req 6.2).
  audioFocusLost,

  /// Pausado manualmente por el usuario.
  userPaused,
}

/// Estados del sistema de amplificación.
///
/// Máquina de estados:
/// Idle → Starting → Active → Paused → Active (resume)
///                  → Error → Idle
///
/// Requisitos: 1.1, 1.3, 3.3, 3.4, 6.2, 6.3
sealed class AmplificationState extends Equatable {
  const AmplificationState();

  @override
  List<Object?> get props => [];
}

/// Estado inactivo: no hay amplificación en curso.
///
/// Estado inicial y estado final tras detener la amplificación.
class AmplificationIdle extends AmplificationState {
  const AmplificationIdle();
}

/// Estado de inicio: verificando permisos, auriculares y foco de audio.
///
/// Transición breve (< 500 ms) entre Idle y Active (Req 5.2).
class AmplificationStarting extends AmplificationState {
  const AmplificationStarting();
}

/// Estado activo: audio siendo procesado y reproducido en tiempo real.
///
/// Contiene información del estado actual del procesamiento para la UI.
class AmplificationActive extends AmplificationState {
  /// Nivel de entrada del micrófono en dB SPL (actualizado ~10 Hz).
  final double inputLevelDb;

  /// Nombre del perfil de entorno activo.
  final String activeProfile;

  /// Volumen maestro actual en dB [-20, +10].
  final double volumeDb;

  /// Estado de conexión de auriculares.
  final bool headphonesConnected;

  /// Nombre del preset de EQ activo (Normal, Mild, etc.).
  final String activeEqPreset;

  /// Nivel de NR activo (0-3).
  final int activeNrLevel;

  /// Modo de prescriptor activo (Smart-NL2 / Smart-NL3).
  final PrescriberMode prescriberMode;

  /// Indica si el modo MHL (Minimal Hearing Loss) está activo.
  /// Requisito 4.5: acción explícita del usuario para activar/desactivar.
  final bool mhlActive;

  /// Indica si el PTA del paciente supera 25 dB HL.
  /// Cuando true, la UI muestra una advertencia recomendando
  /// el modo de prescripción estándar. Requisito 4.3.
  final bool ptaWarning;

  /// Últimas ganancias prescritas por NAL-NL2 (12 valores, dB).
  /// Se exponen para que la UI compare NL2 vs NL3 lado a lado.
  /// Lista vacía si todavía no se calculó (estado inicial).
  final List<double> nl2Gains;

  /// Últimas ganancias prescritas por NAL-NL3-inspired (12 valores, dB).
  /// Lista vacía si el modo NL3 nunca se evaluó en esta sesión.
  final List<double> nl3Gains;

  /// Ganancias modificadas por CIN (12 valores, dB) o null si CIN
  /// no está activo en este momento. Permite mostrar la curva CIN
  /// como overlay en el [GainComparisonWidget].
  final List<double>? cinGains;

  /// Tipo de pérdida detectada por el clasificador NL3 (null hasta
  /// que se calcule por primera vez).
  final LossType? lossType;

  /// Modo de prescripción efectivo aplicado al pipeline DSP.
  /// Útil para diagnosticar si CIN está desactivado por dwell pendiente.
  final PrescriptionMode prescriptionMode;

  /// Experiencia previa del usuario con audífonos en meses.
  ///
  /// `null` indica que el usuario todavía no completó el onboarding,
  /// por lo que se asume usuario nuevo (NL3 aplicará -3 dB de
  /// aclimatización si se activa). Cuando el usuario selecciona un
  /// chip en el [ExperienceMonthsPicker] este campo refleja el valor
  /// guardado en `SettingsRepository`.
  final int? experienceMonths;

  /// Último [AudiogramDrivenBundle] aplicado atómicamente al motor DSP.
  ///
  /// `null` cuando todavía no se ejecutó el camino bundle-driven (por
  /// ejemplo, antes de la primera aplicación atómica tras boot). El
  /// bundle es la fuente única de verdad de los parámetros clínicos
  /// (gains + compression + MPO + NR + WDRC) y replica
  /// `lossType`/`prescriptionMode`/`mode` para consumo en la UI.
  ///
  /// Requisitos: 4.1, 4.7
  final AudiogramDrivenBundle? bundle;

  /// [ManualAdjustmentDelta] activo para el modo de operación corriente.
  ///
  /// `null` cuando no hay ajuste manual aplicado (equivalente a
  /// [ManualAdjustmentDelta.zero]). Se persiste por modo: cada modo
  /// tiene su propio delta independiente bajo `manual_delta_diagnostic`
  /// o `manual_delta_amplifier` (Req 14.6).
  final ManualAdjustmentDelta? manualDelta;

  /// Modo de operación de la app (Diagnóstico vs Amplificador).
  ///
  /// Determinado por `_onStartAmplification` mediante auto-detección
  /// (audiograma medido → diagnóstico; ausente → amplificador).
  ///
  /// Requisitos: 13.1, 13.2, 13.3
  final OperatingMode operatingMode;

  /// Factor de escala global de las ganancias EQ usado en modo
  /// Amplificador. En modo Diagnóstico se fuerza a `1.0` por contrato.
  ///
  /// Rango válido: `[0.10, 1.00]`. Persistido bajo
  /// `amplifier_gain_scale` en `settings_box`.
  ///
  /// Requisitos: 13.4, 13.6
  final double gainScale;

  /// Indica si los presets personalizados quedaron desfasados respecto
  /// al audiograma actual (MAD > 5 dB en alguna banda).
  ///
  /// La UI debe mostrar la badge "obsoleto" en los presets
  /// personalizados afectados y ofrecer "regenerar" cuando este flag
  /// está en `true`. La invalidación se delega al repositorio vía
  /// `ProfileRepository.markCustomPresetsAsStale` (task 7.3).
  ///
  /// Requisitos: 9.1, 9.7
  final bool customPresetsStale;

  const AmplificationActive({
    required this.inputLevelDb,
    required this.activeProfile,
    required this.volumeDb,
    required this.headphonesConnected,
    this.activeEqPreset = 'Normal',
    this.activeNrLevel = 0,
    this.prescriberMode = PrescriberMode.smartNl2,
    this.mhlActive = false,
    this.ptaWarning = false,
    this.nl2Gains = const [],
    this.nl3Gains = const [],
    this.cinGains,
    this.lossType,
    this.prescriptionMode = PrescriptionMode.quiet,
    this.experienceMonths,
    this.bundle,
    this.manualDelta,
    this.operatingMode = OperatingMode.diagnostic,
    this.gainScale = 1.0,
    this.customPresetsStale = false,
  });

  /// Crea una copia con campos actualizados.
  AmplificationActive copyWith({
    double? inputLevelDb,
    String? activeProfile,
    double? volumeDb,
    bool? headphonesConnected,
    String? activeEqPreset,
    int? activeNrLevel,
    PrescriberMode? prescriberMode,
    bool? mhlActive,
    bool? ptaWarning,
    List<double>? nl2Gains,
    List<double>? nl3Gains,
    List<double>? cinGains,
    bool clearCinGains = false,
    LossType? lossType,
    PrescriptionMode? prescriptionMode,
    int? experienceMonths,
    bool clearExperienceMonths = false,
    AudiogramDrivenBundle? bundle,
    bool clearBundle = false,
    ManualAdjustmentDelta? manualDelta,
    bool clearManualDelta = false,
    OperatingMode? operatingMode,
    double? gainScale,
    bool? customPresetsStale,
  }) {
    return AmplificationActive(
      inputLevelDb: inputLevelDb ?? this.inputLevelDb,
      activeProfile: activeProfile ?? this.activeProfile,
      volumeDb: volumeDb ?? this.volumeDb,
      headphonesConnected: headphonesConnected ?? this.headphonesConnected,
      activeEqPreset: activeEqPreset ?? this.activeEqPreset,
      activeNrLevel: activeNrLevel ?? this.activeNrLevel,
      prescriberMode: prescriberMode ?? this.prescriberMode,
      mhlActive: mhlActive ?? this.mhlActive,
      ptaWarning: ptaWarning ?? this.ptaWarning,
      nl2Gains: nl2Gains ?? this.nl2Gains,
      nl3Gains: nl3Gains ?? this.nl3Gains,
      cinGains: clearCinGains ? null : (cinGains ?? this.cinGains),
      lossType: lossType ?? this.lossType,
      prescriptionMode: prescriptionMode ?? this.prescriptionMode,
      experienceMonths: clearExperienceMonths
          ? null
          : (experienceMonths ?? this.experienceMonths),
      bundle: clearBundle ? null : (bundle ?? this.bundle),
      manualDelta:
          clearManualDelta ? null : (manualDelta ?? this.manualDelta),
      operatingMode: operatingMode ?? this.operatingMode,
      gainScale: gainScale ?? this.gainScale,
      customPresetsStale: customPresetsStale ?? this.customPresetsStale,
    );
  }

  @override
  List<Object?> get props => [
        inputLevelDb,
        activeProfile,
        volumeDb,
        headphonesConnected,
        activeEqPreset,
        activeNrLevel,
        prescriberMode,
        mhlActive,
        ptaWarning,
        nl2Gains,
        nl3Gains,
        cinGains,
        lossType,
        prescriptionMode,
        experienceMonths,
        bundle,
        manualDelta,
        operatingMode,
        gainScale,
        customPresetsStale,
      ];
}

/// Estado pausado: amplificación suspendida temporalmente.
///
/// Puede reanudar automáticamente al resolverse la causa de la pausa
/// (reconexión BT, recuperación de foco).
class AmplificationPaused extends AmplificationState {
  /// Razón de la pausa.
  final PauseReason reason;

  /// Nombre del perfil que estaba activo al pausar.
  final String lastActiveProfile;

  /// Volumen que estaba activo al pausar.
  final double lastVolumeDb;

  const AmplificationPaused({
    required this.reason,
    required this.lastActiveProfile,
    required this.lastVolumeDb,
  });

  @override
  List<Object?> get props => [reason, lastActiveProfile, lastVolumeDb];
}

/// Estado de error: algo falló y la amplificación no puede continuar.
///
/// Causas posibles: micrófono no disponible, permiso denegado,
/// error de inicialización del engine nativo.
class AmplificationError extends AmplificationState {
  /// Mensaje descriptivo del error.
  final String message;

  /// Identificador del paso de la secuencia atómica de
  /// `_onApplyBundle` que falló (1=`setMpoThresholdDbSpl`,
  /// 2=`updateWdrcParams`, 3=`updateEqGains`, 4=`updateNrLevel`).
  ///
  /// `null` para errores no relacionados con la aplicación atómica
  /// del bundle (por ejemplo, error de inicio del engine, validación
  /// previa, etc.).
  ///
  /// Requisitos: 4.7
  final int? failedStep;

  /// Lista de violaciones de validación reportadas por
  /// [AudiogramDrivenBundle.validate]. Vacía cuando el error no
  /// corresponde a una validación de bundle.
  ///
  /// Requisitos: 4.7
  final List<String> validationErrors;

  const AmplificationError({
    required this.message,
    this.failedStep,
    this.validationErrors = const [],
  });

  @override
  List<Object?> get props => [message, failedStep, validationErrors];
}
