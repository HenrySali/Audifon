/// @file eligibility_questionnaire.dart
/// @brief Cuestionario de elegibilidad para sujetos normoyentes.
///
/// Un sujeto es elegible para participar en la calibración biológica si cumple
/// los cuatro criterios: edad en rango (18-35), audición normal auto-reportada,
/// sin tinnitus activo y sin congestión actual. Si cualquiera de estos es
/// falso, el sujeto no debe ser usado para la calibración.
///
/// Referencias: design.md §6 (Modelos), Requirement 3.

/// Cuestionario aplicado a cada sujeto antes de iniciar la prueba.
class EligibilityQuestionnaire {
  /// True si la edad del sujeto está entre 18 y 35 años.
  final bool ageInRange;

  /// True si el sujeto reporta no tener pérdida auditiva conocida.
  final bool normalHearingSelfReported;

  /// True si el sujeto NO tiene tinnitus activo.
  final bool noActiveTinnitus;

  /// True si el sujeto NO tiene congestión nasal/ótica al momento del test.
  final bool noCongestion;

  const EligibilityQuestionnaire({
    required this.ageInRange,
    required this.normalHearingSelfReported,
    required this.noActiveTinnitus,
    required this.noCongestion,
  });

  /// El sujeto es elegible solo si los cuatro criterios son verdaderos.
  bool get isEligible =>
      ageInRange &&
      normalHearingSelfReported &&
      noActiveTinnitus &&
      noCongestion;

  Map<String, dynamic> toJson() => {
        'age_in_range': ageInRange,
        'normal_hearing_self_reported': normalHearingSelfReported,
        'no_active_tinnitus': noActiveTinnitus,
        'no_congestion': noCongestion,
      };

  factory EligibilityQuestionnaire.fromJson(Map<String, dynamic> j) {
    return EligibilityQuestionnaire(
      ageInRange: j['age_in_range'] as bool,
      normalHearingSelfReported: j['normal_hearing_self_reported'] as bool,
      noActiveTinnitus: j['no_active_tinnitus'] as bool,
      noCongestion: j['no_congestion'] as bool,
    );
  }
}
