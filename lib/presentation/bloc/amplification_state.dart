import 'package:equatable/equatable.dart';

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

  const AmplificationError({required this.message});

  @override
  List<Object?> get props => [message];
}
