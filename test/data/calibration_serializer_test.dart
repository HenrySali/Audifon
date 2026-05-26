import 'dart:math';
import 'dart:typed_data';
import 'package:test/test.dart';
import '../../lib/data/serializers/calibration_serializer.dart';

/// Property 9: Calibration Data Serialization Round-Trip
///
/// For any valid CalibrationMeasurement M:
///   deserialize(serialize(M)) == M
///
/// Also validates:
/// - CRC32 corruption detection
/// - Version byte validation
/// - Exact 75-byte output size
///
/// Requirements: 9.1, 9.2, 9.3
void main() {
  final random = Random(42); // Deterministic seed for reproducibility

  /// Generate a random valid CalibrationMeasurement
  CalibrationMeasurement generateRandom() {
    return CalibrationMeasurement(
      timestamp: random.nextInt(0xFFFFFFFF),
      ospl90: List.generate(numBands, (_) => 800 + random.nextInt(500)),
      hfaOspl90: 900 + random.nextInt(300),
      fullOnGain: List.generate(numBands, (_) => 100 + random.nextInt(500)),
      hfaFog: 200 + random.nextInt(300),
      ein: 150 + random.nextInt(250),
      thd: List.generate(3, (_) => 10 + random.nextInt(490)),
      batteryDrain: 5 + random.nextInt(45),
      degradationIndex: random.nextInt(1001),
      severity: DegradationSeverity.fromValue(random.nextInt(3)),
      underCompensatedBands: random.nextInt(256),
    );
  }

  group('Property 9: Calibration Data Serialization Round-Trip', () {
    test('serialize produces exactly 75 bytes', () {
      for (int i = 0; i < 100; i++) {
        final measurement = generateRandom();
        final bytes = measurement.serialize();
        expect(bytes.length, equals(bleCalibMeasurementSize));
      }
    });

    test('first byte is format version', () {
      for (int i = 0; i < 100; i++) {
        final measurement = generateRandom();
        final bytes = measurement.serialize();
        expect(bytes[0], equals(bleCalibFormatVersion));
      }
    });

    test('round-trip preserves all fields for random inputs', () {
      for (int i = 0; i < 200; i++) {
        final original = generateRandom();
        final bytes = original.serialize();
        final restored = CalibrationMeasurement.deserialize(bytes);

        expect(restored.timestamp, equals(original.timestamp),
            reason: 'timestamp mismatch at iteration $i');
        expect(restored.ospl90, equals(original.ospl90),
            reason: 'ospl90 mismatch at iteration $i');
        expect(restored.hfaOspl90, equals(original.hfaOspl90),
            reason: 'hfaOspl90 mismatch at iteration $i');
        expect(restored.fullOnGain, equals(original.fullOnGain),
            reason: 'fullOnGain mismatch at iteration $i');
        expect(restored.hfaFog, equals(original.hfaFog),
            reason: 'hfaFog mismatch at iteration $i');
        expect(restored.ein, equals(original.ein),
            reason: 'ein mismatch at iteration $i');
        expect(restored.thd, equals(original.thd),
            reason: 'thd mismatch at iteration $i');
        expect(restored.batteryDrain, equals(original.batteryDrain),
            reason: 'batteryDrain mismatch at iteration $i');
        expect(restored.degradationIndex, equals(original.degradationIndex),
            reason: 'degradationIndex mismatch at iteration $i');
        expect(restored.severity, equals(original.severity),
            reason: 'severity mismatch at iteration $i');
        expect(
            restored.underCompensatedBands, equals(original.underCompensatedBands),
            reason: 'underCompensatedBands mismatch at iteration $i');
      }
    });

    test('CRC32 corruption is detected', () {
      for (int i = 0; i < 100; i++) {
        final measurement = generateRandom();
        final bytes = measurement.serialize();

        // Corrupt a random byte in the data region (not the version byte)
        final corruptIdx = 1 + random.nextInt(bytes.length - 5);
        final corrupted = Uint8List.fromList(bytes);
        corrupted[corruptIdx] ^= (1 << random.nextInt(8));

        expect(
          () => CalibrationMeasurement.deserialize(corrupted),
          throwsA(isA<FormatException>()),
          reason: 'corrupted byte at index $corruptIdx should be detected',
        );
      }
    });

    test('invalid version byte is rejected', () {
      final measurement = generateRandom();
      final bytes = measurement.serialize();

      // Change version to unsupported value
      final modified = Uint8List.fromList(bytes);
      modified[0] = 0xFF;

      expect(
        () => CalibrationMeasurement.deserialize(modified),
        throwsA(isA<FormatException>()),
      );
    });

    test('wrong data length is rejected', () {
      expect(
        () => CalibrationMeasurement.deserialize(Uint8List(10)),
        throwsA(isA<FormatException>()),
      );

      expect(
        () => CalibrationMeasurement.deserialize(Uint8List(74)),
        throwsA(isA<FormatException>()),
      );

      expect(
        () => CalibrationMeasurement.deserialize(Uint8List(76)),
        throwsA(isA<FormatException>()),
      );
    });

    test('edge case: all zeros', () {
      final measurement = CalibrationMeasurement(
        timestamp: 0,
        ospl90: List.filled(numBands, 0),
        hfaOspl90: 0,
        fullOnGain: List.filled(numBands, 0),
        hfaFog: 0,
        ein: 0,
        thd: [0, 0, 0],
        batteryDrain: 0,
        degradationIndex: 0,
        severity: DegradationSeverity.none,
        underCompensatedBands: 0,
      );

      final bytes = measurement.serialize();
      final restored = CalibrationMeasurement.deserialize(bytes);
      expect(restored.timestamp, equals(0));
      expect(restored.degradationIndex, equals(0));
    });

    test('edge case: maximum values', () {
      final measurement = CalibrationMeasurement(
        timestamp: 0xFFFFFFFF,
        ospl90: List.filled(numBands, 32767), // max int16
        hfaOspl90: 32767,
        fullOnGain: List.filled(numBands, 32767),
        hfaFog: 32767,
        ein: 32767,
        thd: [65535, 65535, 65535], // max uint16
        batteryDrain: 65535,
        degradationIndex: 1000,
        severity: DegradationSeverity.severe,
        underCompensatedBands: 255,
      );

      final bytes = measurement.serialize();
      final restored = CalibrationMeasurement.deserialize(bytes);
      expect(restored.timestamp, equals(0xFFFFFFFF));
      expect(restored.degradationIndex, equals(1000));
      expect(restored.severity, equals(DegradationSeverity.severe));
    });
  });
}
