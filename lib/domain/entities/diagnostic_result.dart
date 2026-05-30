import 'dart:math' as math;

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

  /// Determina el preset recomendado basado en el patrón de pérdida.
  ///
  /// Analiza:
  ///  - Promedio de bajas (500, 1000 Hz)
  ///  - Promedio de altas (2000, 3000, 4000, 8000 Hz)
  ///  - Diferencia (sloping vs flat)
  ///  - Severidad
  ///
  /// Mapea a uno de los 10 presets disponibles.
  static String getRecommendedPreset(
    Map<int, double> leftThresholds,
    Map<int, double> rightThresholds,
  ) {
    // Tomamos el peor oído por banda como referencia conservadora.
    final worst = <int, double>{};
    for (final freq in testFrequencies) {
      final l = leftThresholds[freq] ?? 0;
      final r = rightThresholds[freq] ?? 0;
      worst[freq] = l > r ? l : r;
    }

    // Promedios por rango.
    final lowFreqs = [500, 1000];
    final highFreqs = [2000, 3000, 4000, 8000];
    double lowAvg = 0;
    int lowCount = 0;
    double highAvg = 0;
    int highCount = 0;
    for (final f in lowFreqs) {
      if (worst.containsKey(f)) {
        lowAvg += worst[f]!;
        lowCount++;
      }
    }
    for (final f in highFreqs) {
      if (worst.containsKey(f)) {
        highAvg += worst[f]!;
        highCount++;
      }
    }
    if (lowCount > 0) lowAvg /= lowCount;
    if (highCount > 0) highAvg /= highCount;

    final overallAvg = (lowAvg + highAvg) / 2;
    final slopeDb = highAvg - lowAvg; // positivo = pérdida en agudos
    final isSloping = slopeDb >= 10;

    // Audición normal — sin amplificación necesaria.
    if (overallAvg <= 20) return 'Normal';

    // Pérdida leve.
    if (overallAvg <= 35) {
      return isSloping ? 'Mild High' : 'Mild Flat';
    }

    // Pérdida moderada.
    if (overallAvg <= 55) {
      return isSloping ? 'Moderate High' : 'Moderate Flat';
    }

    // Pérdida moderada-severa o severa: usar preset más fuerte disponible.
    return 'Moderate+';
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

  /// Construye un mapa con los umbrales del peor oído por banda audiométrica
  /// estándar (250 a 8000 Hz). Si no se midió cierta frecuencia se completa
  /// por interpolación / extrapolación lineal para uso con NAL-NL2.
  ///
  /// Las 12 frecuencias finales son las del audiograma estándar:
  /// 250, 500, 750, 1000, 1500, 2000, 2500, 3000, 3500, 4000, 6000, 8000 Hz.
  static Map<int, double> buildAudiogramThresholds(
    Map<int, double> leftThresholds,
    Map<int, double> rightThresholds,
  ) {
    // Tomar el peor oído por frecuencia medida.
    final worst = <int, double>{};
    for (final f in testFrequencies) {
      final l = leftThresholds[f] ?? 0;
      final r = rightThresholds[f] ?? 0;
      worst[f] = l > r ? l : r;
    }
    if (worst.isEmpty) return const {};

    // Frecuencias estándar del audiograma de la app.
    const standardFrequencies = [
      250, 500, 750, 1000, 1500, 2000, 2500, 3000, 3500, 4000, 6000, 8000,
    ];

    final sortedMeasured = worst.keys.toList()..sort();
    final out = <int, double>{};

    for (final f in standardFrequencies) {
      if (worst.containsKey(f)) {
        out[f] = worst[f]!;
        continue;
      }
      // Interpolar / extrapolar log-frecuencia.
      if (f <= sortedMeasured.first) {
        // Por debajo del mínimo medido — usar el mínimo (250 Hz suele ser
        // similar a 500 Hz en presbiacusia).
        out[f] = worst[sortedMeasured.first]!;
        continue;
      }
      if (f >= sortedMeasured.last) {
        out[f] = worst[sortedMeasured.last]!;
        continue;
      }
      // Buscar bracket.
      for (int i = 0; i < sortedMeasured.length - 1; i++) {
        final a = sortedMeasured[i];
        final b = sortedMeasured[i + 1];
        if (f >= a && f <= b) {
          // Interpolar lineal en log-frecuencia.
          final logA = math.log(a.toDouble()) / math.ln10;
          final logB = math.log(b.toDouble()) / math.ln10;
          final logF = math.log(f.toDouble()) / math.ln10;
          final ratio = (logF - logA) / (logB - logA);
          out[f] = worst[a]! + ratio * (worst[b]! - worst[a]!);
          break;
        }
      }
    }
    return out;
  }

  /// Sugerencia de volumen inicial en dB respecto del default (0 dB).
  /// Más pérdida → arrancar con un poco más de volumen.
  static double suggestInitialVolumeDb(
    Map<int, double> leftThresholds,
    Map<int, double> rightThresholds,
  ) {
    if (leftThresholds.isEmpty && rightThresholds.isEmpty) return 0;
    final allValues = [
      ...leftThresholds.values,
      ...rightThresholds.values,
    ];
    final avg = allValues.reduce((a, b) => a + b) / allValues.length;
    if (avg <= 20) return 0;
    if (avg <= 35) return 2;
    if (avg <= 55) return 4;
    return 6;
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
