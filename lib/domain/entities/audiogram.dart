import 'package:equatable/equatable.dart';

/// Punto de audiograma: frecuencia en Hz y umbral en dB HL.
class AudiogramPoint {
  final int frequencyHz;
  final double thresholdHL;

  const AudiogramPoint({
    required this.frequencyHz,
    required this.thresholdHL,
  });
}

/// Audiograma del usuario con umbrales por frecuencia.
///
/// Almacena el perfil de pérdida auditiva como un mapa de frecuencia (Hz)
/// a umbral en dB HL. Soporta las 12 frecuencias audiométricas estándar:
/// 250, 500, 750, 1000, 1500, 2000, 2500, 3000, 3500, 4000, 6000, 8000 Hz.
///
/// Requisitos: 4.1, 4.4
class Audiogram extends Equatable {
  /// Mapa de frecuencia (Hz) a umbral auditivo (dB HL).
  final Map<int, double> thresholds;

  /// Audiograma predeterminado del usuario: 10 dB HL plano en las 12
  /// frecuencias estándar.
  ///
  /// Decisión clínica: 10 dB HL es el límite superior de audición normal
  /// (rango 0-25 dB HL según ANSI S3.6 / ISO 8253-1). Usar un audiograma
  /// plano "casi normal" como default evita amplificar a un usuario antes
  /// de que se mida — la prescripción NAL-NL2 sobre HL=10 produce
  /// ganancias = 0 (extrapolación bajo el inicio de tabla en 20 dB HL,
  /// luego clamped). Solo amplifica una vez que el usuario configura un
  /// audiograma real.
  static const Map<int, double> defaultThresholds = {
    250: 10,
    500: 10,
    750: 10,
    1000: 10,
    1500: 10,
    2000: 10,
    2500: 10,
    3000: 10,
    3500: 10,
    4000: 10,
    6000: 10,
    8000: 10,
  };

  /// Frecuencias audiométricas estándar (Hz).
  static const List<int> standardFrequencies = [
    250, 500, 750, 1000, 1500, 2000, 2500, 3000, 3500, 4000, 6000, 8000,
  ];

  const Audiogram({required this.thresholds});

  /// Crea un audiograma con los valores predeterminados del usuario.
  factory Audiogram.defaultAudiogram() {
    return const Audiogram(thresholds: defaultThresholds);
  }

  /// Convierte el audiograma a una lista de AudiogramPoint.
  List<AudiogramPoint> toPoints() => thresholds.entries
      .map((e) => AudiogramPoint(frequencyHz: e.key, thresholdHL: e.value))
      .toList()
    ..sort((a, b) => a.frequencyHz.compareTo(b.frequencyHz));

  /// Serializa a Map JSON-compatible.
  ///
  /// Formato: `{ "thresholds": { "<freq>": <hl>, ... } }` — claves de
  /// frecuencia como String para preservar round-trip por JSON estándar.
  /// Coincide con el shape persistido por `AudiogramRepositoryImpl` y
  /// `CustomPresetRecord._audiogramToJson` (spec oir-pro-patient-mode,
  /// Fase 2 — bundle exporter).
  Map<String, dynamic> toJson() {
    final t = <String, double>{};
    for (final entry in thresholds.entries) {
      t[entry.key.toString()] = entry.value;
    }
    return {'thresholds': t};
  }

  /// Deserializa desde Map. Acepta claves String o int en `thresholds`.
  static Audiogram fromJson(Map<String, dynamic> json) {
    final raw = json['thresholds'];
    if (raw is! Map) {
      throw const FormatException(
        'Audiogram.fromJson: campo "thresholds" ausente o no Map.',
      );
    }
    final t = <int, double>{};
    raw.forEach((key, value) {
      final freq = key is int ? key : int.parse(key.toString());
      t[freq] = (value as num).toDouble();
    });
    return Audiogram(thresholds: t);
  }

  @override
  List<Object?> get props => [thresholds];
}
