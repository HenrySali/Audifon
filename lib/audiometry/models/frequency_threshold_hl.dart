/// @file frequency_threshold_hl.dart
/// @brief Umbral auditivo en dB HL para una frecuencia específica.
///
/// Representa el resultado de la búsqueda de umbral con Hughson-Westlake en
/// el dominio dB HL para una sola frecuencia. A diferencia del modelo de
/// calibración biológica (`FrequencyThreshold`), aquí el valor está en dB HL
/// (escala clínica) y se acompaña de dos flags:
///
///   - [outOfRange]: el umbral excedió el `maxHLAchievable` del transductor
///     calibrado. El paciente no respondió ni al nivel máximo posible.
///   - [normalLimit]: el paciente respondió al nivel mínimo (-10 dB HL),
///     por lo que la audición se considera normal y se reporta el umbral
///     como `<= -10 dB HL`.
///
/// Referencias:
///  - design.md §"Modelos"
///  - requirements.md §"Requirement 2 — Algoritmo Hughson-Westlake"
library;

/// Umbral auditivo en dB HL para una frecuencia.
class FrequencyThresholdHL {
  /// Frecuencia probada en Hz (ej: 250, 500, 1000, 2000, 4000, 8000).
  final int freqHz;

  /// Umbral encontrado en dB HL. Si [outOfRange] es true este valor es el
  /// `maxHLAchievable` del transductor (no es el umbral real del paciente).
  /// Si [normalLimit] es true vale -10 dB HL (suelo del protocolo).
  final double thresholdHL;

  /// True si el nivel a emitir excedió el techo del transductor para esta
  /// frecuencia. En ese caso `thresholdHL` no representa el umbral real.
  final bool outOfRange;

  /// True si el paciente respondió al nivel mínimo (-10 dB HL), lo que
  /// indica audición normal o mejor para esa frecuencia.
  final bool normalLimit;

  const FrequencyThresholdHL({
    required this.freqHz,
    required this.thresholdHL,
    this.outOfRange = false,
    this.normalLimit = false,
  });

  /// Serializa este umbral a un mapa JSON-friendly.
  Map<String, dynamic> toJson() => {
        'freq_hz': freqHz,
        'threshold_hl': thresholdHL,
        'out_of_range': outOfRange,
        'normal_limit': normalLimit,
      };

  /// Reconstruye un [FrequencyThresholdHL] desde un mapa JSON.
  ///
  /// Acepta tanto los nombres en snake_case (formato de persistencia) como
  /// las keys camelCase para mayor robustez ante reorganizaciones futuras.
  factory FrequencyThresholdHL.fromJson(Map<String, dynamic> j) {
    return FrequencyThresholdHL(
      freqHz: (j['freq_hz'] ?? j['freqHz']) as int,
      thresholdHL: ((j['threshold_hl'] ?? j['thresholdHL']) as num).toDouble(),
      outOfRange: (j['out_of_range'] ?? j['outOfRange'] ?? false) as bool,
      normalLimit: (j['normal_limit'] ?? j['normalLimit'] ?? false) as bool,
    );
  }

  @override
  String toString() =>
      'FrequencyThresholdHL(freqHz: $freqHz, thresholdHL: $thresholdHL, '
      'outOfRange: $outOfRange, normalLimit: $normalLimit)';
}
