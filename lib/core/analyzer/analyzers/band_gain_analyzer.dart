// Feature: in-app-diagnostic-analyzer
// Module: analyzers/band_gain_analyzer
//
// Computes Welch_PSD of the pre and post channels (with a single shared
// `WelchPsd` instance), derives the per-bin Spectral_Gain_Curve and
// averages it over ±100 Hz around each of the 12 audiometric bands.
// NaN propagates per band when no PSD bin falls in the window (Req. 5.5).

import 'dart:math' as math;
import 'dart:typed_data';

import '../constants.dart';
import '../dsp/welch_psd.dart';
import '../result/band_gain_result.dart';

class BandGainAnalyzer {
  final WelchPsd welch;

  BandGainAnalyzer({WelchPsd? welch}) : welch = welch ?? WelchPsd();

  BandGainResult analyze({
    required Float64List pre,
    required Float64List post,
    required int sampleRate,
    required Float64List prescribedGainsDb,
  }) {
    if (prescribedGainsDb.length != kAudiometricBandsHz.length) {
      throw ArgumentError(
        'prescribedGainsDb must have ${kAudiometricBandsHz.length} elements',
      );
    }
    final psdPre = welch.compute(pre, sampleRate);
    final psdPost = welch.compute(post, sampleRate);
    if (psdPre.power.length != psdPost.power.length) {
      throw StateError(
        'PSD length mismatch: ${psdPre.power.length} vs ${psdPost.power.length}',
      );
    }
    final n = psdPre.power.length;
    final gainCurve = Float64List(n);
    for (int k = 0; k < n; k++) {
      final pre10 = 10.0 *
          (math.log(psdPre.power[k] + kPsdEpsilon) / math.ln10);
      final post10 = 10.0 *
          (math.log(psdPost.power[k] + kPsdEpsilon) / math.ln10);
      gainCurve[k] = post10 - pre10;
    }
    final freqs = psdPre.frequencies;

    final measured = Float64List(kAudiometricBandsHz.length);
    final dev = Float64List(kAudiometricBandsHz.length);
    double sumSqDev = 0.0;
    int validBands = 0;
    for (int b = 0; b < kAudiometricBandsHz.length; b++) {
      final fc = kAudiometricBandsHz[b].toDouble();
      double sum = 0.0;
      int count = 0;
      for (int k = 0; k < n; k++) {
        if ((freqs[k] - fc).abs() <= kBandHalfBandwidthHz) {
          sum += gainCurve[k];
          count++;
        }
      }
      if (count == 0) {
        measured[b] = double.nan;
        dev[b] = double.nan;
      } else {
        final m = sum / count;
        measured[b] = m;
        final d = (m - prescribedGainsDb[b]).abs();
        dev[b] = d;
        sumSqDev += d * d;
        validBands++;
      }
    }
    final globalRms = validBands == 0
        ? double.nan
        : math.sqrt(sumSqDev / validBands);

    return BandGainResult(
      bandFrequencies: List<int>.unmodifiable(kAudiometricBandsHz),
      measuredGainsDb: measured,
      prescribedGainsDb: Float64List.fromList(prescribedGainsDb),
      absoluteDeviationsDb: dev,
      globalRmsDeviationDb: globalRms,
      psdPre: psdPre,
      psdPost: psdPost,
      spectralGainCurveDb: gainCurve,
    );
  }
}
