import '../entities/eq_preset.dart';
import '../../data/services/preset_learning_service.dart';

/// Asesor de presets — mapea ambiente acústico detectado a preset recomendado
/// y calcula loudness compensation entre presets para que cambiar de preset
/// no produzca saltos abruptos de volumen percibido.
///
/// Las clases de ambiente son las del clasificador C++:
///  - 0 QUIET            → ambiente silencioso (< 45 dB SPL típicos)
///  - 1 SPEECH           → conversación (45–65 dB SPL)
///  - 2 SPEECH_IN_NOISE  → habla con ruido de fondo
///  - 3 NOISE            → ruido fuerte (subte, calle pesada)
///
/// Ver: `environment_classifier.cpp`.
class PresetAdvisor {
  /// Etiqueta humana de la clase de ambiente.
  static String labelFor(int envClass) {
    switch (envClass) {
      case 0:
        return 'Silencioso';
      case 1:
        return 'Conversación';
      case 2:
        return 'Conversación con ruido';
      case 3:
        return 'Ruidoso';
      default:
        return 'Desconocido';
    }
  }

  /// Sugiere un preset apropiado para la clase de ambiente actual.
  ///
  /// Política:
  ///  - QUIET            → Voice Clarity (ganancia mediana, kneepoint bajo).
  ///  - SPEECH           → Mild Flat (amplificación uniforme).
  ///  - SPEECH_IN_NOISE  → Voice Clarity (refuerza 1–4 kHz para consonantes).
  ///  - NOISE            → Outdoor (graves bajos, NR fuerte implícito).
  ///
  /// Si no se reconoce, devuelve `Mild Flat` como default seguro.
  static EqPreset suggestFor(int envClass) {
    switch (envClass) {
      case 0:
        return EqPreset.voiceClarity;
      case 1:
        return EqPreset.mildFlat;
      case 2:
        return EqPreset.voiceClarity;
      case 3:
        return EqPreset.outdoor;
      default:
        return EqPreset.mildFlat;
    }
  }

  /// Sugiere también un ajuste delta de master volume en dB para el ambiente.
  ///
  /// En ambientes ruidosos el usuario tiende a poner mucho volumen y satura;
  /// en silencio suele excederse de ganancia. Estos valores son delta a aplicar
  /// sobre el volumen actual (sumar al master volume).
  static double volumeDeltaFor(int envClass) {
    switch (envClass) {
      case 0:
        return -2.0; // silencioso → bajar para evitar amplificar piso de ruido
      case 1:
        return 0.0; // conversación → sin cambio
      case 2:
        return -1.0; // conversación con ruido → bajar 1 dB
      case 3:
        return -3.0; // ruidoso → bajar 3 dB para no saturar
      default:
        return 0.0;
    }
  }

  /// Calcula la ganancia "broadband" promedio del preset, ponderada en las
  /// bandas del rango del habla (500 Hz – 4 kHz, índices 1..9 inclusive).
  ///
  /// Esto sirve como proxy del nivel de salida percibido. Permite calcular
  /// un offset de master volume entre presets para que el cambio de preset
  /// no resulte en un salto de loudness perceptible.
  static double speechBandMeanGainDb(EqPreset preset) {
    // Bandas: 250, 500, 750, 1000, 1500, 2000, 2500, 3000, 3500, 4000, 6000, 8000
    // Habla: 500–4000 Hz → índices 1..9.
    const startIdx = 1;
    const endIdx = 9; // inclusive
    double sum = 0;
    int count = 0;
    for (int i = startIdx; i <= endIdx && i < preset.gains.length; i++) {
      sum += preset.gains[i];
      count++;
    }
    return count > 0 ? sum / count : 0.0;
  }

  /// Calcula el offset de master volume (en dB) necesario para igualar
  /// loudness percibido entre [from] y [to].
  ///
  /// Si [to] tiene 8 dB más de ganancia promedio en banda de habla que
  /// [from], hay que restar 8 dB al master volume al cambiar de preset.
  ///
  /// El resultado puede ser positivo o negativo. Se clampea a [-10, +10] dB
  /// para evitar saltos extremos.
  static double loudnessOffsetBetween(EqPreset from, EqPreset to) {
    final fromGain = speechBandMeanGainDb(from);
    final toGain = speechBandMeanGainDb(to);
    final delta = -(toGain - fromGain);
    return delta.clamp(-10.0, 10.0);
  }

  /// Calcula el offset de volume necesario para que [preset] suene a
  /// loudness "neutral" (como `Normal`). Para usar durante el "Run All Tests"
  /// donde queremos comparar presets sin cambio de volumen percibido.
  static double loudnessNormalizationOffsetDb(EqPreset preset) {
    final mean = speechBandMeanGainDb(preset);
    final neutralOffset = -mean;
    return neutralOffset.clamp(-10.0, 0.0);
  }

  /// Sugiere un preset para [envClass] consultando primero el aprendizaje
  /// local del usuario via [learning].
  ///
  /// Si el usuario ya votó suficientes veces y prefirió un preset alternativo
  /// al default, devuelve ese alternativo. Si no, devuelve el default
  /// hardcodeado de [suggestFor].
  ///
  /// Devuelve un `({EqPreset preset, bool fromLearning})` para que la UI
  /// pueda indicar al usuario que la sugerencia surge del aprendizaje.
  static ({EqPreset preset, bool fromLearning}) suggestForUser({
    required int envClass,
    required PresetLearningService learning,
  }) {
    final defaultPreset = suggestFor(envClass);
    final altName = learning.suggestAlternative(
      envClass: envClass,
      defaultName: defaultPreset.name,
    );
    if (altName != null) {
      final alt = EqPreset.findByName(altName);
      if (alt != null) {
        return (preset: alt, fromLearning: true);
      }
    }
    return (preset: defaultPreset, fromLearning: false);
  }
}
