import 'package:equatable/equatable.dart';

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

  const AmplificationActive({
    required this.inputLevelDb,
    required this.activeProfile,
    required this.volumeDb,
    required this.headphonesConnected,
  });

  /// Crea una copia con campos actualizados.
  AmplificationActive copyWith({
    double? inputLevelDb,
    String? activeProfile,
    double? volumeDb,
    bool? headphonesConnected,
  }) {
    return AmplificationActive(
      inputLevelDb: inputLevelDb ?? this.inputLevelDb,
      activeProfile: activeProfile ?? this.activeProfile,
      volumeDb: volumeDb ?? this.volumeDb,
      headphonesConnected: headphonesConnected ?? this.headphonesConnected,
    );
  }

  @override
  List<Object?> get props => [
        inputLevelDb,
        activeProfile,
        volumeDb,
        headphonesConnected,
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
