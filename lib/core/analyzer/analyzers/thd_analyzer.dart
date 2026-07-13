// Feature: in-app-diagnostic-analyzer
// Module: analyzers/thd_analyzer
//
// Hann FFT on the same best-signal segment used by the LatencyAnalyzer
// (post channel), find dominant `f_0` in [80, 4000] Hz, sum harmonics
// 2..6 magnitude squared within ±5 bins, compute THD%, flag S3.22-2024
// 5% compliance (Req. 11).

import 'dart:math' as math;
import 'dart:typed_data';

import '../constants.dart';
import '../dsp/fft.dart';
import '../dsp/window.dart';
import '../result/snr_result.dart';
import '../result/thd_result.dart';
import 'latency_analyzer.dart';

class ThdAnalyzer {
  /// 1-s segment length.
  final int segmentLength;

  ThdAnalyzer({int? segmentLength})
      : segmentLength = segmentLength ?? kSampleRate * kSegmentDurationSec;

  ThdResult analyze({
    required Float64List post,
    required SnrResult snr,
  }) {
    final segIdx = LatencyAnalyzer().bestSignalSegment(snr);
    if (segIdx == null) {
      return const ThdResult(
        fundamentalHz: double.nan,
        thdPercent: double.nan,
        compliantWithS322: false,
      );
    }
    final segStart = segIdx * segmentLength;
    final segEnd = math.min(segStart + segmentLength, post.length);
    final segLen = segEnd - segStart;
    if (segLen <= 0) {
      return const ThdResult(
        fundamentalHz: double.nan,
        thdPercent: double.nan,
        compliantWithS322: false,
      );
    }

    // Pick the largest power-of-two ≤ segLen for the FFT (so a 48 000-
    // sample segment uses 32 768).
    int nfft = 1;
    while (nfft * 2 <= segLen) {
      nfft *= 2;
    }
    if (nfft < 2) {
      return const ThdResult(
        fundamentalHz: double.nan,
        thdPercent: double.nan,
        compliantWithS322: false,
      );
    }
    final hann = Window.hann(nfft);
    final input = Float64List(nfft);
    for (int i = 0; i < nfft; i++) {
      input[i] = post[segStart + i] * hann[i];
    }
    final binCount = nfft ~/ 2 + 1;
    final reBuf = Float64List(binCount);
    final imBuf = Float64List(binCount);
    Fft(nfft).forwardReal(input, reBuf, imBuf);

    final mag = Float64List(binCount);
    for (int k = 0; k < binCount; k++) {
      mag[k] = math.sqrt(reBuf[k] * reBuf[k] + imBuf[k] * imBuf[k]);
    }

    final df = kSampleRate / nfft;
    final loBin = (80.0 / df).ceil();
    final hiBin = math.min(binCount - 1, (4000.0 / df).floor());
    int peakBin = loBin;
    double peakMag = -1.0;
    for (int k = loBin; k <= hiBin; k++) {
      if (mag[k] > peakMag) {
        peakMag = mag[k];
        peakBin = k;
      }
    }
    if (peakMag < kThdLowMagnitudeThreshold) {
      return const ThdResult(
        fundamentalHz: double.nan,
        thdPercent: double.nan,
        compliantWithS322: false,
      );
    }
    final f0 = peakBin * df;
    final p1 = peakMag * peakMag;

    double sumHarm = 0.0;
    for (int n = 2; n <= 6; n++) {
      final hf = n * f0;
      if (hf >= kSampleRate / 2.0) break; // above Nyquist
      final centerBin = (hf / df).round();
      if (centerBin >= binCount) break;
      double maxSq = 0.0;
      final from = math.max(0, centerBin - 5);
      final to = math.min(binCount - 1, centerBin + 5);
      for (int k = from; k <= to; k++) {
        final m2 = mag[k] * mag[k];
        if (m2 > maxSq) maxSq = m2;
      }
      sumHarm += maxSq;
    }

    final thdPct = math.sqrt(sumHarm / p1) * 100.0;
    return ThdResult(
      fundamentalHz: f0,
      thdPercent: thdPct,
      compliantWithS322: thdPct < kThdLimitPercent,
    );
  }
}
