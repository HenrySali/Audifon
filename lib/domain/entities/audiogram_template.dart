/// Plantillas de audiograma predefinidas para casos clínicos típicos.
///
/// Estas plantillas permiten al usuario cargar rápidamente configuraciones
/// audiométricas comunes sin necesidad de ajustar manualmente los 12 sliders.
/// Son especialmente útiles para:
/// - Demostración clínica de cómo el sistema maneja casos atípicos
/// - Testing rápido con diferentes patrones de pérdida auditiva
/// - Educación del usuario sobre distintos tipos de hipoacusia
///
/// Cada plantilla incluye:
/// - Nombre descriptivo
/// - Descripción clínica breve
/// - Umbrales en las 12 frecuencias estándar (250-8000 Hz)
///
/// Las plantillas NO son presets de amplificación — son audiogramas de
/// entrada que el BundleBuilder usará para calcular ganancias específicas
/// mediante NAL-NL3.
class AudiogramTemplate {
  /// Nombre descriptivo de la plantilla.
  final String name;

  /// Descripción clínica breve del patrón de pérdida.
  final String description;

  /// Umbrales auditivos en dB HL por frecuencia (Hz).
  /// Las 12 frecuencias estándar: 250, 500, 750, 1000, 1500, 2000,
  /// 2500, 3000, 3500, 4000, 6000, 8000 Hz.
  final Map<int, double> thresholds;

  const AudiogramTemplate({
    required this.name,
    required this.description,
    required this.thresholds,
  });

  // =========================================================================
  // PLANTILLAS PREDEFINIDAS
  // =========================================================================

  /// Audición normal: 0 dB HL en todas las frecuencias.
  /// Referencia para testing sin amplificación.
  static const normal = AudiogramTemplate(
    name: 'Audición Normal',
    description: 'Sin pérdida auditiva (0 dB HL en todo)',
    thresholds: {
      250: 0, 500: 0, 750: 0, 1000: 0,
      1500: 0, 2000: 0, 2500: 0, 3000: 0,
      3500: 0, 4000: 0, 6000: 0, 8000: 0,
    },
  );

  /// Presbiacusia leve: pérdida suave en frecuencias altas (20-35 dB HL).
  /// Patrón "sloping" típico de envejecimiento temprano.
  /// El paciente tiene dificultad con consonantes agudas (s, f, th) en
  /// ambientes ruidosos.
  static const presbycusisMild = AudiogramTemplate(
    name: 'Presbiacusia Leve',
    description: 'Pérdida leve en agudos (sloping típico)',
    thresholds: {
      250: 10, 500: 10, 750: 15, 1000: 20,
      1500: 20, 2000: 25, 2500: 30, 3000: 30,
      3500: 35, 4000: 35, 6000: 35, 8000: 40,
    },
  );

  /// Presbiacusia moderada: pérdida moderada en altas (35-55 dB HL).
  /// Patrón más común en adultos mayores de 60 años.
  /// Dificultad significativa para entender habla en ruido.
  static const presbycusisModerate = AudiogramTemplate(
    name: 'Presbiacusia Moderada',
    description: 'Pérdida moderada en agudos (35-55 dB HL)',
    thresholds: {
      250: 15, 500: 20, 750: 25, 1000: 30,
      1500: 35, 2000: 40, 2500: 45, 3000: 50,
      3500: 50, 4000: 55, 6000: 55, 8000: 60,
    },
  );

  /// Presbiacusia severa: pérdida severa en altas (55-75 dB HL).
  /// Requiere amplificación significativa para acceder al habla.
  /// Beneficio máximo con audífonos digitales modernos.
  static const presbycusisSevere = AudiogramTemplate(
    name: 'Presbiacusia Severa',
    description: 'Pérdida severa en agudos (55-75 dB HL)',
    thresholds: {
      250: 25, 500: 30, 750: 35, 1000: 40,
      1500: 45, 2000: 50, 2500: 60, 3000: 65,
      3500: 70, 4000: 75, 6000: 75, 8000: 80,
    },
  );

  /// Otosclerosis: pérdida conductiva en bajas frecuencias.
  /// Patrón "inverso" al típico — MÁS pérdida en graves, MENOS en agudos.
  /// Causada por osificación del estribo en el oído medio.
  static const otosclerosis = AudiogramTemplate(
    name: 'Otosclerosis',
    description: 'Pérdida conductiva en graves (patrón inverso)',
    thresholds: {
      250: 60, 500: 55, 750: 50, 1000: 45,
      1500: 40, 2000: 35, 2500: 30, 3000: 25,
      3500: 20, 4000: 15, 6000: 10, 8000: 5,
    },
  );

  /// Trauma acústico: muesca (notch) característico en 4 kHz.
  /// Causado por exposición a ruido intenso (industria, música, disparos).
  /// La banda de 3.5-4 kHz es la más vulnerable por resonancia del conducto.
  static const acousticTrauma = AudiogramTemplate(
    name: 'Trauma Acústico',
    description: 'Notch característico en 4 kHz',
    thresholds: {
      250: 20, 500: 20, 750: 25, 1000: 30,
      1500: 35, 2000: 40, 2500: 45, 3000: 50,
      3500: 60, 4000: 70, 6000: 55, 8000: 40,
    },
  );

  /// Pérdida plana moderada: pérdida uniforme en todas las frecuencias.
  /// Puede ser congénita o por ototóxicos.
  /// Requiere amplificación balanceada en todo el espectro.
  static const flatModerate = AudiogramTemplate(
    name: 'Pérdida Plana Moderada',
    description: 'Pérdida uniforme 40-50 dB HL',
    thresholds: {
      250: 40, 500: 42, 750: 45, 1000: 45,
      1500: 48, 2000: 48, 2500: 50, 3000: 48,
      3500: 47, 4000: 45, 6000: 43, 8000: 40,
    },
  );

  /// Pérdida bilateral severa: pérdida severa en todo el espectro.
  /// Candidato para audífonos de alta potencia o implante coclear.
  /// Requiere verificación cuidadosa del MPO para evitar daño adicional.
  static const severeBilateral = AudiogramTemplate(
    name: 'Pérdida Bilateral Severa',
    description: 'Pérdida severa uniforme (70-80 dB HL)',
    thresholds: {
      250: 70, 500: 70, 750: 72, 1000: 75,
      1500: 75, 2000: 78, 2500: 80, 3000: 80,
      3500: 78, 4000: 75, 6000: 75, 8000: 75,
    },
  );

  /// Lista de todas las plantillas predefinidas.
  static const List<AudiogramTemplate> allTemplates = [
    normal,
    presbycusisMild,
    presbycusisModerate,
    presbycusisSevere,
    otosclerosis,
    acousticTrauma,
    flatModerate,
    severeBilateral,
  ];

  /// Busca una plantilla por nombre.
  /// Retorna null si no existe.
  static AudiogramTemplate? findByName(String name) {
    for (final template in allTemplates) {
      if (template.name == name) return template;
    }
    return null;
  }
}

