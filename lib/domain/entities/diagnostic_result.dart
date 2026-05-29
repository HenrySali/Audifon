import 'package:equatable/equatable.dart';

/// Resultado completo del diagnóstico auditivo de 5 pasos.
///
/// Almacena:
/// - Respuestas del cuestionario de dificultad auditiva (paso 1)
/// - Umbrales de tonos puros por frecuencia y oído (paso 2)
/// - Resultado del test de reconocimiento de palabras (paso 3)
/// - Preset recomendado basado en los resultados (paso 5)
class DiagnosticResult extends Equatable {
  /// Fecha y hora del diagnóstico.
  final DateTime timestamp;

  /// Respuestas del cuestionario (0-3 por pregunta, 8 preguntas).
  final List<int> questionnaireAnswers;

  /// Score total del cuestionario (0-24).
  final int questionnaireScore;

  /// Umbrales de tonos puros para oído izquierdo (dB HL por frecuencia).
  /// Frecuencias: 500, 1000, 2000, 3000, 4000, 8000 Hz.
  final Map<int, double> leftEarThresholds;

  /// Umbrales de tonos puros para oído derecho (dB HL por frecuencia).
  final Map<int, double> rightEarThresholds;

  /// Porcentaje de aciertos en test de palabras (0-100).
  final double wordRecognitionScore;

  /// Nombre del preset EQ recomendado.
  final String recommendedPreset;

  /// Si se recomienda visitar un audiólogo.
  final bool shouldVisitAudiologist;

  /// Resumen textual del resultado.
  final String summary;

  const DiagnosticResult({
    required this.timestamp,
    required this.questionnaireAnswers,
    required this.questionnaireScore,
    required this.leftEarThresholds,
    required this.rightEarThresholds,
    required this.wordRecognitionScore,
    required this.recommendedPreset,
    required this.shouldVisitAudiologist,
    required this.summary,
  });

  /// Frecuencias evaluadas en el test de tonos puros.
  static const List<int> testFrequencies = [500, 1000, 2000, 3000, 4000, 8000];

  /// Preguntas del cuestionario de dificultad auditiva.
  static const List<String> questionnaireQuestions = [
    '¿Le piden que repita lo que dice?',
    '¿Sube el volumen de la TV más que otros?',
    '¿Tiene dificultad para escuchar en restaurantes?',
    '¿Le cuesta seguir conversaciones en grupo?',
    '¿Tiene que esforzarse para entender por teléfono?',
    '¿Le parece que la gente murmura o habla bajo?',
    '¿Tiene dificultad para escuchar en ambientes ruidosos?',
    '¿Se pierde partes de la conversación cuando no ve al hablante?',
  ];

  /// Opciones de respuesta del cuestionario.
  static const List<String> answerOptions = [
    'Nunca',
    'A veces',
    'Frecuentemente',
    'Siempre',
  ];

  /// Palabras para el test de reconocimiento.
  static const List<String> testWords = [
    'mesa',
    'casa',
    'perro',
    'gato',
    'libro',
    'agua',
    'mano',
    'pelo',
    'boca',
    'luna',
  ];

  /// Opciones distractoras para cada palabra del test.
  static const List<List<String>> wordOptions = [
    ['mesa', 'pesa', 'besa', 'reza'],
    ['casa', 'masa', 'pasa', 'taza'],
    ['perro', 'cerro', 'ferro', 'berro'],
    ['gato', 'pato', 'rato', 'dato'],
    ['libro', 'litro', 'fibra', 'libra'],
    ['agua', 'aguja', 'alba', 'aura'],
    ['mano', 'manto', 'mago', 'malo'],
    ['pelo', 'peso', 'pecho', 'pego'],
    ['boca', 'bola', 'bota', 'boda'],
    ['luna', 'cuna', 'duna', 'tuna'],
  ];

  /// Clasifica el grado de pérdida auditiva según el umbral en dB HL.
  static String classifyHearingLoss(double thresholdDb) {
    if (thresholdDb <= 25) return 'Normal';
    if (thresholdDb <= 40) return 'Leve';
    if (thresholdDb <= 55) return 'Moderada';
    if (thresholdDb <= 70) return 'Severa';
    return 'Profunda';
  }

  /// Determina el preset recomendado basado en el promedio de umbrales.
  static String getRecommendedPreset(
    Map<int, double> leftThresholds,
    Map<int, double> rightThresholds,
  ) {
    // Promedio de umbrales del peor oído
    final leftAvg = leftThresholds.values.isEmpty
        ? 0.0
        : leftThresholds.values.reduce((a, b) => a + b) /
            leftThresholds.values.length;
    final rightAvg = rightThresholds.values.isEmpty
        ? 0.0
        : rightThresholds.values.reduce((a, b) => a + b) /
            rightThresholds.values.length;
    final worstAvg = leftAvg > rightAvg ? leftAvg : rightAvg;

    if (worstAvg <= 25) return 'Normal';
    if (worstAvg <= 40) return 'Mild';
    if (worstAvg <= 55) return 'Moderate';
    if (worstAvg <= 70) return 'Severe';
    return 'Profound';
  }

  /// Determina si debe visitar un audiólogo.
  static bool checkShouldVisitAudiologist(
    Map<int, double> leftThresholds,
    Map<int, double> rightThresholds,
  ) {
    for (final threshold in leftThresholds.values) {
      if (threshold > 40) return true;
    }
    for (final threshold in rightThresholds.values) {
      if (threshold > 40) return true;
    }
    return false;
  }

  /// Genera un resumen textual del resultado.
  static String generateSummary(
    Map<int, double> leftThresholds,
    Map<int, double> rightThresholds,
    double wordScore,
  ) {
    final buffer = StringBuffer();

    // Analizar frecuencias altas (>= 2000 Hz)
    final highFreqs = [2000, 3000, 4000, 8000];
    double leftHighAvg = 0;
    double rightHighAvg = 0;
    int leftCount = 0;
    int rightCount = 0;

    for (final freq in highFreqs) {
      if (leftThresholds.containsKey(freq)) {
        leftHighAvg += leftThresholds[freq]!;
        leftCount++;
      }
      if (rightThresholds.containsKey(freq)) {
        rightHighAvg += rightThresholds[freq]!;
        rightCount++;
      }
    }

    if (leftCount > 0) leftHighAvg /= leftCount;
    if (rightCount > 0) rightHighAvg /= rightCount;

    final worstHighAvg =
        leftHighAvg > rightHighAvg ? leftHighAvg : rightHighAvg;

    if (worstHighAvg > 40) {
      buffer.writeln(
          'Tu audición en sonidos agudos necesita ayuda.');
    } else if (worstHighAvg > 25) {
      buffer.writeln(
          'Tienes una pérdida leve en frecuencias altas.');
    } else {
      buffer.writeln('Tu audición en frecuencias altas es normal.');
    }

    // Analizar frecuencias bajas
    final lowFreqs = [500, 1000];
    double leftLowAvg = 0;
    double rightLowAvg = 0;
    int leftLowCount = 0;
    int rightLowCount = 0;

    for (final freq in lowFreqs) {
      if (leftThresholds.containsKey(freq)) {
        leftLowAvg += leftThresholds[freq]!;
        leftLowCount++;
      }
      if (rightThresholds.containsKey(freq)) {
        rightLowAvg += rightThresholds[freq]!;
        rightLowCount++;
      }
    }

    if (leftLowCount > 0) leftLowAvg /= leftLowCount;
    if (rightLowCount > 0) rightLowAvg /= rightLowCount;

    final worstLowAvg =
        leftLowAvg > rightLowAvg ? leftLowAvg : rightLowAvg;

    if (worstLowAvg > 40) {
      buffer.writeln(
          'También necesitas ayuda en frecuencias graves.');
    }

    // Reconocimiento de palabras
    if (wordScore < 60) {
      buffer.writeln(
          'Tu reconocimiento de palabras es bajo (${ wordScore.toStringAsFixed(0)}%). '
          'Esto sugiere dificultad para entender el habla.');
    } else if (wordScore < 80) {
      buffer.writeln(
          'Tu reconocimiento de palabras es moderado (${wordScore.toStringAsFixed(0)}%).');
    }

    return buffer.toString().trim();
  }

  /// Serializa a Map para persistencia en Hive/JSON.
  Map<String, dynamic> toJson() => {
        'timestamp': timestamp.toIso8601String(),
        'questionnaireAnswers': questionnaireAnswers,
        'questionnaireScore': questionnaireScore,
        'leftEarThresholds': leftEarThresholds.map(
          (k, v) => MapEntry(k.toString(), v),
        ),
        'rightEarThresholds': rightEarThresholds.map(
          (k, v) => MapEntry(k.toString(), v),
        ),
        'wordRecognitionScore': wordRecognitionScore,
        'recommendedPreset': recommendedPreset,
        'shouldVisitAudiologist': shouldVisitAudiologist,
        'summary': summary,
      };

  /// Deserializa desde Map.
  factory DiagnosticResult.fromJson(Map<String, dynamic> json) {
    return DiagnosticResult(
      timestamp: DateTime.parse(json['timestamp'] as String),
      questionnaireAnswers:
          (json['questionnaireAnswers'] as List<dynamic>).cast<int>(),
      questionnaireScore: json['questionnaireScore'] as int,
      leftEarThresholds:
          (json['leftEarThresholds'] as Map<String, dynamic>).map(
        (k, v) => MapEntry(int.parse(k), (v as num).toDouble()),
      ),
      rightEarThresholds:
          (json['rightEarThresholds'] as Map<String, dynamic>).map(
        (k, v) => MapEntry(int.parse(k), (v as num).toDouble()),
      ),
      wordRecognitionScore:
          (json['wordRecognitionScore'] as num).toDouble(),
      recommendedPreset: json['recommendedPreset'] as String,
      shouldVisitAudiologist: json['shouldVisitAudiologist'] as bool,
      summary: json['summary'] as String,
    );
  }

  @override
  List<Object?> get props => [
        timestamp,
        questionnaireAnswers,
        leftEarThresholds,
        rightEarThresholds,
        wordRecognitionScore,
        recommendedPreset,
      ];
}
