/// @file audiometry_result.dart
/// @brief Resultado completo de una audiometría tonal del paciente.
///
/// Modelo raíz que se persiste en Hive (`patient_audiometry_box`) y que se
/// puede convertir directamente a un [Audiogram] para alimentar la
/// prescripción NAL-NL2 vía `UpdateAudiogram`.
///
/// Compatibilidad: Flutter 3.19.6 (sin `withValues`, sin `onPopInvokedWithResult`).
///
/// Referencias:
///  - design.md §"Modelos"
///  - requirements.md §"Requirement 5 — Audiograma autopoblado"
///  - requirements.md §"Requirement 7 — Persistencia y reporte"
library;

import '../../domain/entities/audiogram.dart';
import 'frequency_threshold_hl.dart';

/// Resultado completo de una audiometría tonal del paciente.
///
/// Contiene los umbrales encontrados por frecuencia, la fecha del test, una
/// referencia a la calibración usada (MAC + fecha) para poder verificar más
/// tarde su trazabilidad, un alias del paciente (sin datos personales) y el
/// delta del retest a 1000 Hz (si se ejecutó).
class AudiometryResult {
  /// Versión del esquema JSON. Se incrementa cuando el formato cambia de
  /// forma incompatible con versiones previas persistidas.
  static const String schemaVersion = '1.0.0';

  /// Marca temporal del momento en que se completó la audiometría.
  final DateTime testedAt;

  /// MAC del dispositivo Bluetooth de la calibración biológica que se usó
  /// durante esta audiometría. Permite detectar si la calibración cambió
  /// (otro dispositivo) cuando se vuelva a abrir el reporte.
  final String calibrationMac;

  /// Fecha de creación de la calibración biológica utilizada.
  final DateTime calibrationDate;

  /// Umbrales por frecuencia (Hz → [FrequencyThresholdHL]).
  final Map<int, FrequencyThresholdHL> thresholds;

  /// Diferencia (en dB HL) entre el umbral de la primera medición a 1000 Hz
  /// y el del retest. `null` si no se hizo retest. Si el valor absoluto
  /// excede 10 dB HL, el controller debería ofrecer repetir la frecuencia.
  final double? retest1000Diff;

  /// Alias del paciente (string corto, sin datos personales sensibles).
  final String patientAlias;

  const AudiometryResult({
    required this.testedAt,
    required this.calibrationMac,
    required this.calibrationDate,
    required this.thresholds,
    required this.retest1000Diff,
    required this.patientAlias,
  });

  /// Construye un [Audiogram] a partir de los umbrales encontrados.
  ///
  /// Comportamiento:
  ///  - Las frecuencias marcadas como [FrequencyThresholdHL.outOfRange] se
  ///    excluyen (no son umbrales reales).
  ///  - Las frecuencias del paciente medidas válidamente se transfieren con
  ///    su `thresholdHL`.
  ///  - Las frecuencias de [Audiogram.standardFrequencies] que no fueron
  ///    medidas (no están en [thresholds] o están en outOfRange) se
  ///    completan con `0.0` dB HL bajo el supuesto de audición normal.
  ///
  /// El audiograma resultante siempre tiene exactamente las 12 frecuencias
  /// estándar, lo que evita que la prescripción NAL-NL2 falte de datos.
  Audiogram toAudiogram() {
    final Map<int, double> result = {};

    for (final freq in Audiogram.standardFrequencies) {
      final t = thresholds[freq];
      if (t != null && !t.outOfRange) {
        result[freq] = t.thresholdHL;
      } else {
        // Sin medición válida → audición normal supuesta.
        result[freq] = 0.0;
      }
    }

    return Audiogram(thresholds: result);
  }

  /// Lista ordenada de [AudiogramPoint] derivada del audiograma resultante.
  /// Útil para alimentar widgets de gráfica.
  List<AudiogramPoint> toAudiogramPoints() => toAudiogram().toPoints();

  /// Serializa el resultado completo a un mapa JSON-friendly.
  Map<String, dynamic> toJson() => {
        'schema_version': schemaVersion,
        'tested_at': testedAt.toIso8601String(),
        'calibration_mac': calibrationMac,
        'calibration_date': calibrationDate.toIso8601String(),
        'thresholds': thresholds.map(
          (freq, t) => MapEntry(freq.toString(), t.toJson()),
        ),
        'retest_1000_diff': retest1000Diff,
        'patient_alias': patientAlias,
      };

  /// Reconstruye un [AudiometryResult] desde un mapa JSON.
  ///
  /// Tolera entradas mínimamente bien formadas: si falta `thresholds` lo
  /// trata como mapa vacío. Lanza `FormatException`/`TypeError` si los
  /// campos obligatorios (`tested_at`, `calibration_mac`, `calibration_date`)
  /// no están presentes con el tipo correcto.
  factory AudiometryResult.fromJson(Map<String, dynamic> j) {
    final rawThresholds = (j['thresholds'] as Map?)?.cast<String, dynamic>() ??
        const <String, dynamic>{};
    final thresholds = <int, FrequencyThresholdHL>{};
    rawThresholds.forEach((k, v) {
      final freq = int.tryParse(k);
      if (freq != null && v is Map) {
        final inner = v.cast<String, dynamic>();
        if (!inner.containsKey('freq_hz')) {
          inner['freq_hz'] = freq;
        }
        thresholds[freq] = FrequencyThresholdHL.fromJson(inner);
      }
    });

    return AudiometryResult(
      testedAt: DateTime.parse(j['tested_at'] as String),
      calibrationMac: j['calibration_mac'] as String,
      calibrationDate: DateTime.parse(j['calibration_date'] as String),
      thresholds: thresholds,
      retest1000Diff: (j['retest_1000_diff'] as num?)?.toDouble(),
      patientAlias: (j['patient_alias'] as String?) ?? '',
    );
  }
}
