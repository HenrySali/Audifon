// Feature: psk-mobile-hearing-aid, Property 10: Mic calibration offset produces correct SPL levels

/// Property-based test for microphone calibration offset.
///
/// Property 10: For any offset in [90, 140] dB and any signal with known
/// RMS in dBFS, the reported SPL level SHALL be equal to RMS_dBFS + offset
/// with tolerance ±0.1 dB.
///
/// **Validates: Calibración del micrófono**
import 'dart:math';

import 'package:glados/glados.dart';

import 'dsp_models.dart';

void main() {
  group('Property 10: Mic calibration offset produces correct SPL levels', () {
    Glados2(any.doubleInRange(90, 140), any.doubleInRange(-90, 0),
        ExploreConfig(numRuns: 100)).test(
      'SPL = dBFS + offset ±0.1 dB',
      (offset, rmsDbFs) {
        final reportedSpl = computeSpl(rmsDbFs: rmsDbFs, offset: offset);
        final expectedSpl = rmsDbFs + offset;

        expect(
          reportedSpl,
          closeTo(expectedSpl, 0.1),
          reason: 'SPL = $rmsDbFs dBFS + $offset offset = $expectedSpl, '
              'but got $reportedSpl',
        );
      },
    );

    Glados2(any.doubleInRange(90, 140), any.doubleInRange(-90, -1),
        ExploreConfig(numRuns: 100)).test(
      'SPL from buffer measurement matches formula',
      (offset, targetRmsDbFs) {
        // Generate a buffer with known RMS level
        // RMS of a sine wave with amplitude A is A/sqrt(2)
        // dBFS = 20*log10(RMS) → A = sqrt(2) * 10^(dBFS/20)
        final amplitude = sqrt(2) * pow(10.0, targetRmsDbFs / 20.0).toDouble();

        // Generate a sine wave buffer
        const sampleRate = 16000;
        const frequency = 1000.0;
        const bufferSize = 64;
        final buffer = List<double>.generate(bufferSize, (i) {
          return amplitude * sin(2 * pi * frequency * i / sampleRate);
        });

        // Measure RMS from buffer
        final measuredRmsDbFs = measureRmsDbFs(buffer);

        // Compute SPL using the offset
        final reportedSpl = computeSpl(rmsDbFs: measuredRmsDbFs, offset: offset);
        final expectedSpl = measuredRmsDbFs + offset;

        expect(
          reportedSpl,
          closeTo(expectedSpl, 0.1),
          reason: 'Buffer-based SPL measurement: '
              'measured=$measuredRmsDbFs dBFS + offset=$offset = $expectedSpl, '
              'got $reportedSpl',
        );
      },
    );

    Glados(any.doubleInRange(90, 140), ExploreConfig(numRuns: 100)).test(
      'default offset 120 maps -26 dBFS to 94 dB SPL (MEMS reference)',
      (offset) {
        // Verify the formula works for the standard MEMS calibration point
        const memsRefDbFs = -26.0;
        const standardOffset = 120.0;

        final spl = computeSpl(rmsDbFs: memsRefDbFs, offset: standardOffset);
        expect(spl, closeTo(94.0, 0.1));

        // For any offset, the formula should be consistent
        final splWithOffset = computeSpl(rmsDbFs: memsRefDbFs, offset: offset);
        expect(splWithOffset, closeTo(memsRefDbFs + offset, 0.1));
      },
    );
  });
}
