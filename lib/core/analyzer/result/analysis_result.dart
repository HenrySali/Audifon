// Feature: in-app-diagnostic-analyzer
// Module: result/analysis_result
//
// Top-level immutable result produced by the analyzer pipeline.

import '../../diagnostic_metadata.dart';
import '../io/wav_reader.dart';
import 'audiogram_comparison_result.dart';
import 'band_gain_result.dart';
import 'latency_result.dart';
import 'noise_reduction_result.dart';
import 'psd_result.dart';
import 'quality_result.dart';
import 'recommendations_result.dart';
import 'snr_result.dart';
import 'spectrogram_result.dart';
import 'thd_result.dart';
import 'wdrc_io_result.dart';

class AnalysisResult {
  /// Recording_Package base filename (without extension).
  final String wavBaseName;

  /// Parsed JSON metadata snapshot.
  final DiagnosticMetadata metadata;

  /// De-interleaved WAV samples (kept for replay / re-analysis).
  final WavData wavData;

  /// Welch_PSD of the pre channel.
  final PsdResult psdPre;

  /// Welch_PSD of the post channel.
  final PsdResult psdPost;

  final BandGainResult bandGain;
  final SpectrogramResult spectrogram;
  final SnrResult snr;
  final NoiseReductionResult noiseReduction;
  final WdrcIoResult wdrcIo;
  final LatencyResult latency;
  final ThdResult thd;
  final QualityResult quality;
  final AudiogramComparisonResult audiogram;
  final RecommendationsResult recommendations;

  const AnalysisResult({
    required this.wavBaseName,
    required this.metadata,
    required this.wavData,
    required this.psdPre,
    required this.psdPost,
    required this.bandGain,
    required this.spectrogram,
    required this.snr,
    required this.noiseReduction,
    required this.wdrcIo,
    required this.latency,
    required this.thd,
    required this.quality,
    required this.audiogram,
    required this.recommendations,
  });
}
