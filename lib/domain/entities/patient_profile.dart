import 'package:equatable/equatable.dart';

/// Perfil del paciente para ajustes de aclimatización y clasificación mixta.
///
/// Contiene la experiencia del usuario con amplificación (para determinar
/// si corresponde aplicar reducción de aclimatización), opcionalmente
/// un audiograma de conducción ósea (para detectar componente conductivo)
/// y opcionalmente la edad del paciente en años (para activar la regla
/// pediátrica del [MpoDeriver]).
///
/// Requisitos: 2.6, 8.2, audiogram-driven-presets §2.4 (regla pediátrica)
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

  /// Edad del paciente en años cumplidos (opcional).
  ///
  /// Se usa para discriminar entre la regla adulto y la regla pediátrica
  /// en el [MpoDeriver]. Cuando es null o ≥ 18 se aplica la regla
  /// adulto: `MPO[f] = min(UCL[f] - 5, 132)`. Cuando es estrictamente
  /// menor a 18 se aplica la regla pediátrica: `MPO[f] = min(UCL[f] - 10, 110)`.
  ///
  /// Fuente: DSL v5 (Bagatto et al. 2005), AAA Pediatric Amplification
  /// Guidelines (Bagatto et al. 2016).
  final int? ageYears;

  const PatientProfile({
    required this.experienceMonths,
    this.boneConduction,
    this.ageYears,
  });

  /// El usuario es nuevo (menos de 6 meses de experiencia con amplificación).
  ///
  /// Cuando es true, el prescriptor NL3 aplica una reducción de 3 dB
  /// en todas las bandas como ajuste de aclimatización.
  bool get isNewUser => experienceMonths < 6;

  @override
  List<Object?> get props => [experienceMonths, boneConduction, ageYears];
}
