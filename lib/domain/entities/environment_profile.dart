import 'package:equatable/equatable.dart';

/// Perfil de entorno acústico con parámetros de procesamiento DSP.
///
/// Define la configuración de reducción de ruido (NR) y compresión (WDRC)
/// para diferentes situaciones de escucha. Incluye 3 perfiles predefinidos:
/// Silencioso, Conversación y Ruidoso.
///
/// Requisitos: 8.1, 6.4
class EnvironmentProfile extends Equatable {
  /// Nombre descriptivo del perfil.
  final String name;

  /// Nivel de reducción de ruido: 0=off, 1=bajo, 2=medio, 3=alto.
  final int nrLevel;

  /// Ratio de compresión del WDRC (input:output).
  final double compressionRatio;

  /// Kneepoint de expansión en dB SPL.
  final double expansionKnee;

  /// Kneepoint de compresión en dB SPL.
  final double compressionKnee;

  /// Override opcional sobre `bundle.nrLevel` derivado del audiograma.
  ///
  /// Rango válido: `[-3, +3]`. Se suma al `nrLevel` calculado por el
  /// `BundleBuilder` y luego se clampa a `[0, 3]` mediante
  /// `EnvironmentProfileMapper.adjustNr`.
  ///
  /// Permite que un perfil de entorno (por ejemplo, "Ruidoso") refuerce
  /// la NR sin reescribir la prescripción base; default `0` significa
  /// "respetar el nivel derivado del audiograma".
  ///
  /// Requisitos: 6.4
  final int nrDelta;

  const EnvironmentProfile({
    required this.name,
    required this.nrLevel,
    required this.compressionRatio,
    required this.expansionKnee,
    required this.compressionKnee,
    this.nrDelta = 0,
  });

  /// Perfil Silencioso: NR bajo, compresión suave.
  /// Para ambientes tranquilos donde se necesita máxima amplificación.
  static const quiet = EnvironmentProfile(
    name: 'Silencioso',
    nrLevel: 1,
    compressionRatio: 1.5,
    expansionKnee: 35,
    compressionKnee: 55,
    nrDelta: 0,
  );

  /// Perfil Conversación: NR moderado, compresión media.
  /// Para situaciones de habla normal con ruido de fondo moderado.
  static const conversation = EnvironmentProfile(
    name: 'Conversación',
    nrLevel: 2,
    compressionRatio: 2.0,
    expansionKnee: 35,
    compressionKnee: 50,
    nrDelta: 0,
  );

  /// Perfil Ruidoso: NR alto, compresión agresiva.
  /// Para ambientes con mucho ruido donde se prioriza la inteligibilidad.
  static const noisy = EnvironmentProfile(
    name: 'Ruidoso',
    nrLevel: 3,
    compressionRatio: 3.0,
    expansionKnee: 35,
    compressionKnee: 45,
    nrDelta: 0,
  );

  /// Lista de todos los perfiles predefinidos.
  static const List<EnvironmentProfile> predefinedProfiles = [
    quiet,
    conversation,
    noisy,
  ];

  @override
  List<Object?> get props => [
        name,
        nrLevel,
        compressionRatio,
        expansionKnee,
        compressionKnee,
        nrDelta,
      ];
}
