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

  /// Audiograma predeterminado del usuario:
  /// 0 dB HL (250-750 Hz), 40 dB HL (1000 Hz), +5 dB por frecuencia hasta 75 dB HL.
  ///
  /// Valores por defecto del audiograma antes de que el usuario configure uno.
  /// 10 dB HL en todas las frecuencias (pérdida mínima uniforme).
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

  @override
  List<Object?> get props => [thresholds];
}
