import 'package:equatable/equatable.dart';

/// Perfil del paciente para ajustes de aclimatización y clasificación mixta.
///
/// Contiene la experiencia del usuario con amplificación (para determinar
/// si corresponde aplicar reducción de aclimatización) y opcionalmente
/// un audiograma de conducción ósea (para detectar componente conductivo).
///
/// Requisitos: 2.6, 8.2
class PatientProfile extends Equatable {
  /// Experiencia con amplificación en meses.
  ///
  /// Se usa para determinar si el usuario es nuevo (< 6 meses) y aplicar
  /// el ajuste de aclimatización (-3 dB en todas las bandas).
  final int experienceMonths;

  /// Audiograma de conducción ósea (opcional).
  ///
  /// Mapa de frecuencia (Hz) → umbral (dB HL).
  /// Se usa para calcular el air-bone gap y clasificar pérdida como mixta.
  /// Si es null, se asume que no hay componente conductivo.
  final Map<int, double>? boneConduction;

  const PatientProfile({
    required this.experienceMonths,
    this.boneConduction,
  });

  /// El usuario es nuevo (menos de 6 meses de experiencia con amplificación).
  ///
  /// Cuando es true, el prescriptor NL3 aplica una reducción de 3 dB
  /// en todas las bandas como ajuste de aclimatización.
  bool get isNewUser => experienceMonths < 6;

  @override
  List<Object?> get props => [experienceMonths, boneConduction];
}
