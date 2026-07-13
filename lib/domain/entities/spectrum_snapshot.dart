import 'dart:convert';
import 'dart:typed_data';

/// Snapshot inmutable del espectro en un instante de tiempo.
///
/// Contiene magnitud y fase para input y output (64 bins cada uno),
/// agrupamiento en 12 bandas EQ, niveles RMS, clase de entorno y timestamp.
///
/// El struct C++ tiene layout:
///   64 floats inputMag + 64 floats inputPhase +
///   64 floats outputMag + 64 floats outputPhase +
///   12 floats inputBands + 12 floats outputBands +
///   1 float inputLevelDb + 1 float outputLevelDb +
///   1 int32 environmentClass + 1 uint32 timestampMs
///
/// Total: (64+64+64+64+12+12+1+1) * 4 + 4 + 4 = 1136 bytes
class SpectrumSnapshot {
  /// Magnitud por bin de entrada (64 bins, dB SPL).
  final List<double> inputMagnitude;

  /// Fase por bin de entrada (64 bins, grados [-180, +180]).
  final List<double> inputPhase;

  /// Magnitud por bin de salida (64 bins, dB SPL).
  final List<double> outputMagnitude;

  /// Fase por bin de salida (64 bins, grados [-180, +180]).
  final List<double> outputPhase;

  /// Magnitud promedio por banda EQ de entrada (12 bandas, dB SPL).
  final List<double> inputBands;

  /// Magnitud promedio por banda EQ de salida (12 bandas, dB SPL).
  final List<double> outputBands;

  /// Nivel RMS de entrada (dB SPL).
  final double inputLevelDb;

  /// Nivel RMS de salida (dB SPL).
  final double outputLevelDb;

  /// Clase de entorno: 0=QUIET, 1=SPEECH, 2=SPEECH_IN_NOISE, 3=NOISE.
  final int environmentClass;

  /// Milisegundos desde inicio de grabación.
  final int timestampMs;

  /// Tamaño en bytes del struct C++ serializado.
  static const int sizeInBytes = 1136;

  /// Nombres de las clases de entorno.
  static const List<String> environmentClassNames = [
    'QUIET',
    'SPEECH',
    'SPEECH_IN_NOISE',
    'NOISE',
  ];

  const SpectrumSnapshot({
    required this.inputMagnitude,
    required this.inputPhase,
    required this.outputMagnitude,
    required this.outputPhase,
    required this.inputBands,
    required this.outputBands,
    required this.inputLevelDb,
    required this.outputLevelDb,
    required this.environmentClass,
    required this.timestampMs,
  });

  /// Deserializa un snapshot desde bytes (float32 little-endian).
  ///
  /// [bytes] es el buffer completo de datos.
  /// [offset] es la posición inicial dentro del buffer.
  ///
  /// Layout del struct C++:
  ///   - 64 float32: inputMagnitude
  ///   - 64 float32: inputPhase
  ///   - 64 float32: outputMagnitude
  ///   - 64 float32: outputPhase
  ///   - 12 float32: inputBands
  ///   - 12 float32: outputBands
  ///   - 1 float32: inputLevelDb
  ///   - 1 float32: outputLevelDb
  ///   - 1 int32: environmentClass
  ///   - 1 uint32: timestampMs
  factory SpectrumSnapshot.fromBytes(Uint8List bytes, int offset) {
    final byteData = ByteData.sublistView(bytes, offset, offset + sizeInBytes);
    int pos = 0;

    // Helper to read N float32 values
    List<double> readFloats(int count) {
      final list = List<double>.generate(count, (i) {
        final value = byteData.getFloat32(pos, Endian.little);
        pos += 4;
        return value;
      });
      return list;
    }

    final inputMag = readFloats(64);
    final inputPh = readFloats(64);
    final outputMag = readFloats(64);
    final outputPh = readFloats(64);
    final inBands = readFloats(12);
    final outBands = readFloats(12);
    final inLevel = byteData.getFloat32(pos, Endian.little);
    pos += 4;
    final outLevel = byteData.getFloat32(pos, Endian.little);
    pos += 4;
    final envClass = byteData.getInt32(pos, Endian.little);
    pos += 4;
    final timestamp = byteData.getUint32(pos, Endian.little);

    return SpectrumSnapshot(
      inputMagnitude: inputMag,
      inputPhase: inputPh,
      outputMagnitude: outputMag,
      outputPhase: outputPh,
      inputBands: inBands,
      outputBands: outBands,
      inputLevelDb: inLevel,
      outputLevelDb: outLevel,
      environmentClass: envClass,
      timestampMs: timestamp,
    );
  }

  /// Serializa a Map para exportación JSON.
  Map<String, dynamic> toJson() {
    return {
      't': timestampMs,
      'env': environmentClass,
      'inLevel': _round2(inputLevelDb),
      'outLevel': _round2(outputLevelDb),
      'inMag': inputMagnitude.map(_round1).toList(),
      'inPhase': inputPhase.map(_round1).toList(),
      'outMag': outputMagnitude.map(_round1).toList(),
      'outPhase': outputPhase.map(_round1).toList(),
      'inBands': inputBands.map(_round1).toList(),
      'outBands': outputBands.map(_round1).toList(),
    };
  }

  /// Formato compacto JSON para copiar al clipboard.
  String toClipboardString() {
    final data = {
      'timestamp_ms': timestampMs,
      'environment': environmentClassName,
      'input_level_db': _round2(inputLevelDb),
      'output_level_db': _round2(outputLevelDb),
      'effective_gain_db': _round2(outputLevelDb - inputLevelDb),
      'input_magnitude': inputMagnitude.map(_round1).toList(),
      'input_phase': inputPhase.map(_round1).toList(),
      'output_magnitude': outputMagnitude.map(_round1).toList(),
      'output_phase': outputPhase.map(_round1).toList(),
      'input_bands': inputBands.map(_round1).toList(),
      'output_bands': outputBands.map(_round1).toList(),
    };
    return const JsonEncoder().convert(data);
  }

  /// Nombre legible de la clase de entorno.
  String get environmentClassName {
    if (environmentClass >= 0 && environmentClass < environmentClassNames.length) {
      return environmentClassNames[environmentClass];
    }
    return 'UNKNOWN';
  }

  /// Ganancia efectiva (output - input) en dB.
  double get effectiveGainDb => outputLevelDb - inputLevelDb;

  /// Redondea a 1 decimal.
  static double _round1(double v) => (v * 10).roundToDouble() / 10;

  /// Redondea a 2 decimales.
  static double _round2(double v) => (v * 100).roundToDouble() / 100;
}
