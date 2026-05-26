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
  /// Representa pérdida auditiva en frecuencias altas con audición normal
  /// en frecuencias bajas.
  static const Map<int, double> defaultThresholds = {
    250: 0,
    500: 0,
    750: 0,
    1000: 40,
    1500: 45,
    2000: 50,
    2500: 55,
    3000: 60,
    3500: 65,
    4000: 70,
    6000: 75,
    8000: 75,
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
