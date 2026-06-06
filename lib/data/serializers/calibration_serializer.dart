/// ANSI S3.22 Calibration Measurement Serializer
///
/// Handles binary serialization/deserialization of calibration measurement data
/// for BLE communication with the hearing aid firmware.
///
/// Wire format (75 bytes):
///   [version: 1 byte] [measurement_data: 70 bytes] [crc32: 4 bytes]
///
/// Requirements: 9.1, 9.2, 9.4, 9.5
library;

import 'dart:typed_data';

/// Number of frequency bands in the hearing aid DSP
const int numBands = 12;

/// BLE calibration measurement payload size
const int bleCalibMeasurementSize = 75;

/// Current format version
const int bleCalibFormatVersion = 0x01;

/// Degradation severity levels
enum DegradationSeverity {
  none(0),
  moderate(1),
  severe(2);

  const DegradationSeverity(this.value);
  final int value;

  static DegradationSeverity fromValue(int v) {
    switch (v) {
      case 0:
        return DegradationSeverity.none;
      case 1:
        return DegradationSeverity.moderate;
      case 2:
        return DegradationSeverity.severe;
      default:
        return DegradationSeverity.none;
    }
  }
}

/// Represents a complete ANSI S3.22 calibration measurement.
///
/// All dB values are stored as integers × 10 for 0.1 dB resolution.
/// THD values are stored as integers × 100 for 0.01% resolution.
/// Battery drain is stored as integer × 10 for 0.1 mA resolution.
/// Degradation index is stored as integer × 1000 for 0.001 resolution.
class CalibrationMeasurement {
  /// Unix timestamp of the measurement
  final int timestamp;

  /// OSPL90 per band in dB × 10 (12 bands)
  final List<int> ospl90;

  /// HFA-OSPL90 in dB × 10
  final int hfaOspl90;

  /// Full-On Gain per band in dB × 10 (12 bands)
  final List<int> fullOnGain;

  /// HFA Full-On Gain in dB × 10
  final int hfaFog;

  /// Equivalent Input Noise in dB SPL × 10
  final int ein;

  /// THD at 500, 800, 1600 Hz in % × 100 (3 values)
  final List<int> thd;

  /// Battery current drain in mA × 10
  final int batteryDrain;

  /// Degradation Index × 1000 (0–1000 representing 0.000–1.000)
  final int degradationIndex;

  /// Severity classification
  final DegradationSeverity severity;

  /// Bitmask of bands that exceed 10 dB compensation cap
  final int underCompensatedBands;

  CalibrationMeasurement({
    required this.timestamp,
    required this.ospl90,
    required this.hfaOspl90,
    required this.fullOnGain,
    required this.hfaFog,
    required this.ein,
    required this.thd,
    required this.batteryDrain,
    required this.degradationIndex,
    required this.severity,
    required this.underCompensatedBands,
  }) {
    if (ospl90.length != numBands) {
      throw ArgumentError.value(
        ospl90.length,
        'ospl90.length',
        'OSPL90 requiere $numBands bandas, recibido ${ospl90.length}',
      );
    }
    if (fullOnGain.length != numBands) {
      throw ArgumentError.value(
        fullOnGain.length,
        'fullOnGain.length',
        'fullOnGain requiere $numBands bandas, recibido ${fullOnGain.length}',
      );
    }
    if (thd.length != 3) {
      throw ArgumentError.value(
        thd.length,
        'thd.length',
        'THD requiere 3 valores, recibido ${thd.length}',
      );
    }
  }

  /// Degradation index as a double (0.0–1.0)
  double get degradationIndexDouble => degradationIndex / 1000.0;

  /// Battery drain in mA as a double
  double get batteryDrainMa => batteryDrain / 10.0;

  /// Serializes this measurement into the 75-byte BLE binary format.
  ///
  /// Format: [version(1)] [data(70)] [crc32(4)]
  Uint8List serialize() {
    final buffer = ByteData(bleCalibMeasurementSize);
    int offset = 0;

    // Version byte
    buffer.setUint8(offset, bleCalibFormatVersion);
    offset += 1;

    // timestamp (4 bytes, little-endian)
    buffer.setUint32(offset, timestamp, Endian.little);
    offset += 4;

    // ospl90_db[12] (24 bytes, int16 LE each)
    for (int i = 0; i < numBands; i++) {
      buffer.setInt16(offset, ospl90[i], Endian.little);
      offset += 2;
    }

    // hfa_ospl90_x10 (2 bytes)
    buffer.setInt16(offset, hfaOspl90, Endian.little);
    offset += 2;

    // full_on_gain_db[12] (24 bytes)
    for (int i = 0; i < numBands; i++) {
      buffer.setInt16(offset, fullOnGain[i], Endian.little);
      offset += 2;
    }

    // hfa_fog_x10 (2 bytes)
    buffer.setInt16(offset, hfaFog, Endian.little);
    offset += 2;

    // ein_db_x10 (2 bytes)
    buffer.setInt16(offset, ein, Endian.little);
    offset += 2;

    // thd_percent_x100[3] (6 bytes, uint16 LE each)
    for (int i = 0; i < 3; i++) {
      buffer.setUint16(offset, thd[i], Endian.little);
      offset += 2;
    }

    // battery_drain_x10 (2 bytes)
    buffer.setUint16(offset, batteryDrain, Endian.little);
    offset += 2;

    // degradation_index_x1000 (2 bytes)
    buffer.setUint16(offset, degradationIndex, Endian.little);
    offset += 2;

    // severity (1 byte)
    buffer.setUint8(offset, severity.value);
    offset += 1;

    // under_compensated_bands (1 byte)
    buffer.setUint8(offset, underCompensatedBands);
    offset += 1;

    // CRC32 over version + data (offset is 71 here: 1 version + 70 data)
    assert(offset == bleCalibMeasurementSize - 4,
        'Calibration payload size mismatch: offset=$offset, expected=${bleCalibMeasurementSize - 4}');
    final dataBytes = buffer.buffer.asUint8List(0, offset);
    final crc = _computeCrc32(dataBytes);
    buffer.setUint32(offset, crc, Endian.little);

    return buffer.buffer.asUint8List();
  }

  /// Deserializes a 75-byte BLE binary payload into a CalibrationMeasurement.
  ///
  /// Validates version byte and CRC32 checksum.
  /// Throws [FormatException] if version is unsupported or CRC32 is invalid.
  static CalibrationMeasurement deserialize(Uint8List data) {
    if (data.length != bleCalibMeasurementSize) {
      throw FormatException(
        'Invalid calibration data length: ${data.length}, expected $bleCalibMeasurementSize',
      );
    }

    final buffer = ByteData.sublistView(data);
    int offset = 0;

    // Version check
    final version = buffer.getUint8(offset);
    offset += 1;
    if (version != bleCalibFormatVersion) {
      throw FormatException(
        'Unsupported calibration format version: $version',
      );
    }

    // CRC32 validation
    final dataForCrc = data.sublist(0, bleCalibMeasurementSize - 4);
    final expectedCrc = buffer.getUint32(bleCalibMeasurementSize - 4, Endian.little);
    final actualCrc = _computeCrc32(dataForCrc);
    if (expectedCrc != actualCrc) {
      throw FormatException(
        'CRC32 mismatch: expected 0x${expectedCrc.toRadixString(16)}, '
        'got 0x${actualCrc.toRadixString(16)}',
      );
    }

    // Parse fields
    final timestamp = buffer.getUint32(offset, Endian.little);
    offset += 4;

    final ospl90 = <int>[];
    for (int i = 0; i < numBands; i++) {
      ospl90.add(buffer.getInt16(offset, Endian.little));
      offset += 2;
    }

    final hfaOspl90 = buffer.getInt16(offset, Endian.little);
    offset += 2;

    final fullOnGain = <int>[];
    for (int i = 0; i < numBands; i++) {
      fullOnGain.add(buffer.getInt16(offset, Endian.little));
      offset += 2;
    }

    final hfaFog = buffer.getInt16(offset, Endian.little);
    offset += 2;

    final ein = buffer.getInt16(offset, Endian.little);
    offset += 2;

    final thd = <int>[];
    for (int i = 0; i < 3; i++) {
      thd.add(buffer.getUint16(offset, Endian.little));
      offset += 2;
    }

    final batteryDrain = buffer.getUint16(offset, Endian.little);
    offset += 2;

    final degradationIndex = buffer.getUint16(offset, Endian.little);
    offset += 2;

    final severity = DegradationSeverity.fromValue(buffer.getUint8(offset));
    offset += 1;

    final underCompensatedBands = buffer.getUint8(offset);

    return CalibrationMeasurement(
      timestamp: timestamp,
      ospl90: ospl90,
      hfaOspl90: hfaOspl90,
      fullOnGain: fullOnGain,
      hfaFog: hfaFog,
      ein: ein,
      thd: thd,
      batteryDrain: batteryDrain,
      degradationIndex: degradationIndex,
      severity: severity,
      underCompensatedBands: underCompensatedBands,
    );
  }

  /// CRC32 computation (same algorithm as firmware)
  static int _computeCrc32(Uint8List data) {
    int crc = 0xFFFFFFFF;
    for (int i = 0; i < data.length; i++) {
      crc ^= data[i];
      for (int j = 0; j < 8; j++) {
        if ((crc & 1) != 0) {
          crc = (crc >> 1) ^ 0xEDB88320;
        } else {
          crc = crc >> 1;
        }
      }
    }
    return (~crc) & 0xFFFFFFFF;
  }
}
