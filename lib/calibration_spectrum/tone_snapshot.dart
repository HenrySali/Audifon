/// @file tone_snapshot.dart
/// @brief Modelo Dart del snapshot del ToneAnalyzer.
///
/// Parsea el ByteArray que retorna `nativeGetToneSnapshot()` (84 bytes,
/// little-endian). El layout debe coincidir exactamente con el que produce
/// `serializeToneSnapshot()` en `cpp/native_bridge.cpp`.

import 'dart:typed_data';

/// Tipo de ventana FFT.
enum WindowType { hann, blackmanHarris }

/// Veredicto del análisis del tono.
enum ToneVerdict { unknown, pass, fail }

/// Bits de la máscara de fallos.
class ToneFailureFlag {
  static const int freq = 1 << 0;
  static const int thd = 1 << 1;
  static const int snr = 1 << 2;
  static const int level = 1 << 3;
  static const int noSignal = 1 << 4;
  static const int nanInf = 1 << 5;
}

/// Snapshot del análisis de un tono.
class ToneSnapshot {
  final int timestampUs;
  final double sampleRateHz;
  final int fftSize;
  final WindowType windowType;
  final double expectedFreqHz;
  final double peakFreqHz;
  final double peakMagnitudeDbfs;
  final double peakMagnitudeDbspl;
  final double noiseFloorDbfs;
  final double snrDb;
  final double thdPercent;
  final List<double> harmonicsDbfs; // 8 elementos, NaN para no detectados.
  final int harmonicsCount;
  final ToneVerdict verdict;
  final int failureMask;

  const ToneSnapshot({
    required this.timestampUs,
    required this.sampleRateHz,
    required this.fftSize,
    required this.windowType,
    required this.expectedFreqHz,
    required this.peakFreqHz,
    required this.peakMagnitudeDbfs,
    required this.peakMagnitudeDbspl,
    required this.noiseFloorDbfs,
    required this.snrDb,
    required this.thdPercent,
    required this.harmonicsDbfs,
    required this.harmonicsCount,
    required this.verdict,
    required this.failureMask,
  });

  /// Snapshot vacío (cuando aún no hay datos).
  factory ToneSnapshot.empty() => ToneSnapshot(
    timestampUs: 0,
    sampleRateHz: 0,
    fftSize: 0,
    windowType: WindowType.hann,
    expectedFreqHz: 0,
    peakFreqHz: double.nan,
    peakMagnitudeDbfs: -200,
    peakMagnitudeDbspl: -200,
    noiseFloorDbfs: -120,
    snrDb: 0,
    thdPercent: double.nan,
    harmonicsDbfs: List.filled(8, double.nan),
    harmonicsCount: 0,
    verdict: ToneVerdict.unknown,
    failureMask: 0,
  );

  /// Tamaño del wire format en bytes.
  static const int wireSize = 84;

  /// Deserializa desde el ByteArray que produce `nativeGetToneSnapshot()`.
  /// Si los bytes son inválidos retorna `ToneSnapshot.empty()`.
  factory ToneSnapshot.fromBytes(Uint8List bytes) {
    if (bytes.length < wireSize) return ToneSnapshot.empty();
    final bd = ByteData.sublistView(bytes);

    final timestampUs = bd.getUint64(0, Endian.little);
    final sampleRate = bd.getFloat32(8, Endian.little);
    final fftSize = bd.getUint16(12, Endian.little);
    final windowByte = bd.getUint8(14);
    final expectedHz = bd.getFloat32(16, Endian.little);
    final peakHz = bd.getFloat32(20, Endian.little);
    final peakDbfs = bd.getFloat32(24, Endian.little);
    final peakDbspl = bd.getFloat32(28, Endian.little);
    final floorDbfs = bd.getFloat32(32, Endian.little);
    final snr = bd.getFloat32(36, Endian.little);
    final thd = bd.getFloat32(40, Endian.little);

    final harmonics = List<double>.filled(8, double.nan);
    for (var i = 0; i < 8; ++i) {
      harmonics[i] = bd.getFloat32(44 + i * 4, Endian.little);
    }
    final harmCount = bd.getUint8(76);
    final verdictByte = bd.getUint8(80);
    final failureMask = bd.getUint8(81);

    final window = (windowByte == 1) ? WindowType.blackmanHarris : WindowType.hann;
    final verdict = switch (verdictByte) {
      1 => ToneVerdict.pass,
      2 => ToneVerdict.fail,
      _ => ToneVerdict.unknown,
    };

    return ToneSnapshot(
      timestampUs: timestampUs,
      sampleRateHz: sampleRate,
      fftSize: fftSize,
      windowType: window,
      expectedFreqHz: expectedHz,
      peakFreqHz: peakHz,
      peakMagnitudeDbfs: peakDbfs,
      peakMagnitudeDbspl: peakDbspl,
      noiseFloorDbfs: floorDbfs,
      snrDb: snr,
      thdPercent: thd,
      harmonicsDbfs: harmonics,
      harmonicsCount: harmCount,
      verdict: verdict,
      failureMask: failureMask,
    );
  }

  bool get hasFailureFlag => failureMask != 0;
  bool hasFlag(int flag) => (failureMask & flag) != 0;
}
