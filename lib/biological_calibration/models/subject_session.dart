/// @file subject_session.dart
/// @brief Resultado completo de una sesión de calibración de un sujeto.
///
/// Una `SubjectSession` representa la participación de un único sujeto
/// normoyente en la calibración: el cuestionario aplicado, los umbrales
/// medidos por frecuencia, el retest a 1000 Hz para verificar consistencia,
/// las estadísticas de catch trials y un flag global `valid` calculado por
/// el controller a partir de las reglas de validación.
///
/// Referencias: design.md §6, Requirements 2 y 3.

import 'catch_trial_stats.dart';
import 'eligibility_questionnaire.dart';

/// Datos persistidos de un sujeto que completó (o intentó completar) la
/// secuencia de frecuencias de la calibración biológica.
class SubjectSession {
  /// Identificador secuencial del sujeto dentro de la sesión (1, 2, 3, ...).
  final int id;

  /// Alias legible del sujeto (ej: "Sujeto A"). Sin datos personales.
  final String alias;

  /// Marca temporal del inicio del test del sujeto.
  final DateTime testedAt;

  /// Cuestionario de elegibilidad aplicado al sujeto.
  final EligibilityQuestionnaire questionnaire;

  /// Umbral en dBFS por frecuencia (Hz). Ej: { 1000: -52.0, 2000: -50.0 }.
  final Map<int, double> thresholdsDbFS;

  /// Umbral del retest a 1000 Hz. Null si el retest no se completó.
  final double? retest1000DbFS;

  /// Diferencia entre el umbral original a 1000 Hz y el retest. Null si el
  /// retest no se completó.
  final double? retestDifferenceDb;

  /// Estadísticas de catch trials acumuladas durante la sesión.
  final CatchTrialStats catchTrials;

  /// True si la sesión es válida y se incluirá en el promedio final.
  final bool valid;

  const SubjectSession({
    required this.id,
    required this.alias,
    required this.testedAt,
    required this.questionnaire,
    required this.thresholdsDbFS,
    required this.retest1000DbFS,
    required this.retestDifferenceDb,
    required this.catchTrials,
    required this.valid,
  });

  Map<String, dynamic> toJson() => {
        'id': id,
        'alias': alias,
        'tested_at': testedAt.toIso8601String(),
        'questionnaire': questionnaire.toJson(),
        'thresholds_dBFS': thresholdsDbFS.map(
          (freq, level) => MapEntry(freq.toString(), level),
        ),
        'retest_1000_dBFS': retest1000DbFS,
        'retest_difference_dB': retestDifferenceDb,
        'catch_trials': catchTrials.toJson(),
        'valid': valid,
      };

  factory SubjectSession.fromJson(Map<String, dynamic> j) {
    final rawThresholds =
        (j['thresholds_dBFS'] as Map?)?.cast<String, dynamic>() ??
            const <String, dynamic>{};
    final thresholds = <int, double>{};
    rawThresholds.forEach((k, v) {
      final freq = int.tryParse(k);
      if (freq != null && v is num) {
        thresholds[freq] = v.toDouble();
      }
    });

    return SubjectSession(
      id: (j['id'] as num).toInt(),
      alias: j['alias'] as String,
      testedAt: DateTime.parse(j['tested_at'] as String),
      questionnaire: EligibilityQuestionnaire.fromJson(
        (j['questionnaire'] as Map).cast<String, dynamic>(),
      ),
      thresholdsDbFS: thresholds,
      retest1000DbFS: (j['retest_1000_dBFS'] as num?)?.toDouble(),
      retestDifferenceDb: (j['retest_difference_dB'] as num?)?.toDouble(),
      catchTrials: CatchTrialStats.fromJson(
        (j['catch_trials'] as Map).cast<String, dynamic>(),
      ),
      valid: j['valid'] as bool,
    );
  }
}
