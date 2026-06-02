import 'package:equatable/equatable.dart';

import '../../domain/entities/audiogram.dart';
import '../../domain/entities/wdrc_params.dart';

/// Eventos del BLoC de amplificación.
///
/// Representan acciones del usuario y eventos del sistema que
/// modifican el estado de la amplificación.
sealed class AmplificationEvent extends Equatable {
  const AmplificationEvent();

  @override
  List<Object?> get props => [];
}

/// Solicita iniciar la amplificación.
///
/// Flujo: verificar permisos → verificar auriculares → solicitar foco
/// de audio → iniciar servicio → emitir Active.
///
/// Requisitos: 1.1, 5.2
class StartAmplification extends AmplificationEvent {
  const StartAmplification();
}

/// Solicita detener la amplificación.
///
/// Detiene el pipeline DSP, libera recursos de audio y el foco.
/// Debe completarse en < 100 ms (Req 1.3).
class StopAmplification extends AmplificationEvent {
  const StopAmplification();
}

/// Solicita cambiar el perfil de entorno activo.
///
/// Aplica los parámetros del nuevo perfil (NR, WDRC) con crossfade
/// de 10 ms para evitar artefactos audibles (Req 8.2).
///
/// Requisitos: 8.2, 8.5
class ChangeProfile extends AmplificationEvent {
  /// Nombre del perfil a activar.
  final String profile;

  const ChangeProfile({required this.profile});

  @override
  List<Object?> get props => [profile];
}

/// Solicita cambiar el volumen maestro.
///
/// Rango: -20 a +10 dB. Se aplica en < 50 ms sin artefactos (Req 8.5).
/// El nuevo volumen se persiste en settings.
///
/// Requisitos: 5.3, 8.5
class ChangeVolume extends AmplificationEvent {
  /// Nuevo volumen en dB [-20, +10].
  final double volumeDb;

  const ChangeVolume({required this.volumeDb});

  @override
  List<Object?> get props => [volumeDb];
}

/// Solicita actualizar el audiograma y recalcular la prescripción.
///
/// Recalcula ganancias NAL-NL2 y las aplica al DSP sin reiniciar
/// la sesión de audio (Req 4.3).
class UpdateAudiogram extends AmplificationEvent {
  /// Nuevo audiograma con umbrales actualizados.
  final List<AudiogramPoint> audiogram;

  const UpdateAudiogram({required this.audiogram});

  @override
  List<Object?> get props => [audiogram];
}

/// Evento del sistema: cambio en el estado de conexión de auriculares.
///
/// Si connected=false durante amplificación activa → Paused(btDisconnected).
/// Si connected=true durante pausa por BT → ofrecer reanudar.
///
/// Requisitos: 3.3, 3.4
class HeadphonesStateChanged extends AmplificationEvent {
  /// true si auriculares conectados, false si desconectados.
  final bool connected;

  const HeadphonesStateChanged({required this.connected});

  @override
  List<Object?> get props => [connected];
}

/// Evento del sistema: cambio en el foco de audio.
///
/// Si hasFocus=false durante amplificación activa → Paused(audioFocusLost).
/// Si hasFocus=true durante pausa por foco → ofrecer reanudar.
///
/// Requisitos: 6.2, 6.3
class AudioFocusChanged extends AmplificationEvent {
  /// true si la app tiene foco de audio, false si lo perdió.
  final bool hasFocus;

  const AudioFocusChanged({required this.hasFocus});

  @override
  List<Object?> get props => [hasFocus];
}

/// Evento interno: actualización del nivel de entrada del micrófono.
///
/// Emitido ~10 Hz desde el stream del AudioBridge para actualizar
/// el indicador de nivel en la UI (Req 5.4).
class InputLevelUpdated extends AmplificationEvent {
  /// Nivel de entrada en dB SPL.
  final double levelDb;

  const InputLevelUpdated({required this.levelDb});

  @override
  List<Object?> get props => [levelDb];
}

/// Evento interno: solicita reanudar la amplificación tras una pausa.
///
/// Usado cuando el usuario acepta reanudar después de reconexión BT
/// o recuperación de foco de audio.
class ResumeAmplification extends AmplificationEvent {
  const ResumeAmplification();
}

/// Solicita actualizar las ganancias del EQ directamente (12 bandas).
///
/// Usado desde la pantalla de configuración avanzada para control manual.
class UpdateEqGains extends AmplificationEvent {
  /// Ganancias en dB para las 12 bandas [0, 50].
  final List<double> gains;

  /// Nombre del preset (null si es custom).
  final String? presetName;

  const UpdateEqGains({required this.gains, this.presetName});

  @override
  List<Object?> get props => [gains, presetName];
}

/// Solicita actualizar el nivel de reducción de ruido.
///
/// Usado desde la pantalla de configuración avanzada.
class UpdateNrLevel extends AmplificationEvent {
  /// Nivel de NR: 0=off, 1=bajo, 2=medio, 3=alto.
  final int level;

  const UpdateNrLevel({required this.level});

  @override
  List<Object?> get props => [level];
}

/// Solicita actualizar los parámetros WDRC (knees + ratios + attack/release).
///
/// FIX Causa C (smart-scene-diagnostico-chasquido.md):
/// Antes el preset Smart Scene persistía `compressionKnee/Ratio/expansionKnee`
/// en Hive pero NUNCA llegaba al engine. Mientras tanto el `EnvironmentClassifier`
/// automático seguía pisando esos parámetros en cada cambio de clase, dejando
/// el preset "a medias" y produciendo desbalance aleatorio del nivel de voz.
/// Este evento permite a `SceneEngine.apply()` despachar el preset WDRC completo.
class UpdateWdrcParams extends AmplificationEvent {
  /// Parámetros WDRC a aplicar al pipeline DSP nativo.
  final WdrcParams params;

  const UpdateWdrcParams({required this.params});

  @override
  List<Object?> get props => [params];
}

/// Habilita o deshabilita el Transient Noise Reducer (TNR).
///
/// FIX Causa C (smart-scene-diagnostico-chasquido.md):
/// El preset Smart Scene incluye `tnrEnabled` pero el `apply()` original
/// no lo despachaba al engine.
class SetTnrEnabled extends AmplificationEvent {
  /// true para habilitar el TNR, false para bypass.
  final bool enabled;

  const SetTnrEnabled({required this.enabled});

  @override
  List<Object?> get props => [enabled];
}

/// Solicita guardar la configuración actual del audiograma como un preset con nombre.
///
/// El preset se persiste en Hive y aparece en la lista de perfiles disponibles.
/// Puede ser eliminado posteriormente con [DeleteCustomPreset].
class SaveCustomPreset extends AmplificationEvent {
  /// Nombre del preset personalizado.
  final String name;

  /// Audiograma asociado al preset.
  final List<AudiogramPoint> audiogram;

  const SaveCustomPreset({required this.name, required this.audiogram});

  @override
  List<Object?> get props => [name, audiogram];
}

/// Solicita eliminar un preset personalizado por nombre.
///
/// Solo funciona con presets personalizados (no predefinidos).
class DeleteCustomPreset extends AmplificationEvent {
  /// Nombre del preset a eliminar.
  final String name;

  const DeleteCustomPreset({required this.name});

  @override
  List<Object?> get props => [name];
}
