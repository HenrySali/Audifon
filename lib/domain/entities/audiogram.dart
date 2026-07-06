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

  /// Audiograma predeterminado del usuario: pérdida descendente moderada
  /// configurada como seteo inicial de fábrica.
  ///
  /// Perfil: pérdida leve en graves (25 dB HL @ 250 Hz) progresando a
  /// moderada-severa en agudos (60 dB HL @ 8 kHz). Compatible con
  /// prescripción NAL-NL2 que produce ganancias significativas en
  /// frecuencias del habla (2-4 kHz). El usuario puede sobrescribir
  /// estos valores desde la pantalla "Configurar Audiograma".
  static const Map<int, double> defaultThresholds = {
    250: 25,
    500: 30,
    750: 35,
    1000: 40,
    1500: 40,
    2000: 45,
    2500: 45,
    3000: 50,
    3500: 50,
    4000: 55,
    6000: 55,
    8000: 60,
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
