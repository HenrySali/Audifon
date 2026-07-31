/// @file validator_orchestrator.dart
/// @brief Orquestador de la secuencia completa de validación.
///
/// Flujo (REQ-2 del spec):
///  1. Configura el ToneAnalyzer nativo.
///  2. Mide piso de ruido 1 s.
///  3. Si OK, recorre la lista de frecuencias:
///     a) setExpectedFrequency
///     b) playTone 2 s en paralelo con polling de snapshots
///     c) evaluate snapshot final → ToneTestResult
///  4. Calcula globalVerdict (PASS si todos PASS).
///
/// Cancelable. Maneja errores per-tono sin abortar la secuencia.

import 'dart:async';

import 'acceptance_criteria.dart';
import 'noise_floor_meter.dart';
import 'tone_emitter.dart';
import 'tone_method_channel.dart';
import 'tone_snapshot.dart';
import 'tone_test_result.dart';

/// Progreso de la secuencia hacia la UI.
class ToneTestProgress {
  final int currentToneIndex;       // 0-based
  final int totalTones;
  final double currentFreqHz;
  final ToneTestResult? lastResult; // null mientras el tono actual está en curso
  final bool isMeasuringNoiseFloor;

  const ToneTestProgress({
    required this.currentToneIndex,
    required this.totalTones,
    required this.currentFreqHz,
    this.lastResult,
    this.isMeasuringNoiseFloor = false,
  });
}

/// Reporte agregado de toda la secuencia.
class CalibrationSequenceReport {
  final List<ToneTestResult> tones;
  final NoiseFloorResult noiseFloor;
  final AcceptancePreset preset;
  final double targetLevelDbSpl;
  final double sampleRateHz;
  final int fftSize;
  final WindowType windowType;
  final ToneVerdict globalVerdict;
  final DateTime timestamp;

  const CalibrationSequenceReport({
    required this.tones,
    required this.noiseFloor,
    required this.preset,
    required this.targetLevelDbSpl,
    required this.sampleRateHz,
    required this.fftSize,
    required this.windowType,
    required this.globalVerdict,
    required this.timestamp,
  });
}

class ValidatorOrchestrator {
  final ToneMethodChannel _channel;
  final ToneEmitter _emitter;
  final NoiseFloorMeter _noiseMeter;

  bool _cancelled = false;

  ValidatorOrchestrator({
    ToneMethodChannel? channel,
    ToneEmitter? emitter,
    NoiseFloorMeter? noiseMeter,
  })  : _channel = channel ?? const ToneMethodChannel(),
        _emitter = emitter ?? ToneEmitter(),
        _noiseMeter = noiseMeter ?? NoiseFloorMeter();

  /// Ejecuta la secuencia completa.
  ///
  /// @param frequenciesHz Lista de frecuencias a probar.
  /// @param targetLevelDbSpl Nivel objetivo (default 50 dB SPL).
  /// @param preset Clínico o premium.
  /// @param sampleRateHz Sample rate del AudioEngine (default 48000).
  /// @param fftSize Tamaño de FFT (default 4096).
  /// @param windowType Hann o Blackman-Harris.
  /// @param dbfsToDbsplOffset Offset de calibración (default 76 mic celular WAV).
  /// @param toneDuration Duración por tono (default 2 s).
  /// @param onProgress Callback opcional para actualizar UI.
  Future<CalibrationSequenceReport> runSequence({
    required List<double> frequenciesHz,
    double targetLevelDbSpl = 50.0,
    AcceptancePreset preset = AcceptancePreset.clinical,
    int sampleRateHz = 48000,
    int fftSize = 4096,
    WindowType windowType = WindowType.hann,
    double dbfsToDbsplOffset = 76.0,
    Duration toneDuration = const Duration(seconds: 2),
    void Function(ToneTestProgress)? onProgress,
  }) async {
    _cancelled = false;
    final criteria = AcceptanceCriteria.fromPreset(preset);
    final results = <ToneTestResult>[];

    // 1) Configurar el ToneAnalyzer.
    final harmonicsCount = preset == AcceptancePreset.premium ? 7 : 4;
    final ok = await _channel.configure(
      sampleRate: sampleRateHz,
      fftSize: fftSize,
      windowType: windowType,
      harmonicsCount: harmonicsCount,
      dbfsToDbsplOffset: dbfsToDbsplOffset,
    );
    if (!ok) {
      throw StateError('No se pudo configurar el ToneAnalyzer nativo. '
          'Verificá que el AudioEngine esté activo.');
    }

    await _channel.setActive(true);

    // 2) Medir piso de ruido.
    onProgress?.call(ToneTestProgress(
      currentToneIndex: 0,
      totalTones: frequenciesHz.length,
      currentFreqHz: 0,
      isMeasuringNoiseFloor: true,
    ));

    final noiseFloor = await _noiseMeter.measure();
    if (!noiseFloor.isAcceptable) {
      // Cancelar y devolver reporte vacío con globalVerdict = unknown.
      await _channel.setActive(false);
      return CalibrationSequenceReport(
        tones: const [],
        noiseFloor: noiseFloor,
        preset: preset,
        targetLevelDbSpl: targetLevelDbSpl,
        sampleRateHz: sampleRateHz.toDouble(),
        fftSize: fftSize,
        windowType: windowType,
        globalVerdict: ToneVerdict.unknown,
        timestamp: DateTime.now(),
      );
    }

    await _channel.setNoiseFloor(
      amplitudeLin: noiseFloor.noiseFloorAmplitudeLin,
      dbfs: noiseFloor.noiseFloorDbFs,
    );

    // 3) Recorrer la secuencia de tonos.
    for (var i = 0; i < frequenciesHz.length; ++i) {
      if (_cancelled) break;

      final freq = frequenciesHz[i];

      onProgress?.call(ToneTestProgress(
        currentToneIndex: i,
        totalTones: frequenciesHz.length,
        currentFreqHz: freq,
      ));

      final result = await _measureSingleTone(
        freqHz: freq,
        targetLevelDbSpl: targetLevelDbSpl,
        criteria: criteria,
        toneDuration: toneDuration,
      );
      results.add(result);

      onProgress?.call(ToneTestProgress(
        currentToneIndex: i,
        totalTones: frequenciesHz.length,
        currentFreqHz: freq,
        lastResult: result,
      ));
    }

    await _channel.setActive(false);

    // 4) Veredicto global.
    final globalVerdict = _cancelled
        ? ToneVerdict.unknown
        : (results.every((r) => r.isPass) ? ToneVerdict.pass : ToneVerdict.fail);

    return CalibrationSequenceReport(
      tones: List.unmodifiable(results),
      noiseFloor: noiseFloor,
      preset: preset,
      targetLevelDbSpl: targetLevelDbSpl,
      sampleRateHz: sampleRateHz.toDouble(),
      fftSize: fftSize,
      windowType: windowType,
      globalVerdict: globalVerdict,
      timestamp: DateTime.now(),
    );
  }

  /// Cancela la secuencia en curso.
  Future<void> cancel() async {
    _cancelled = true;
    await _emitter.stop();
    await _channel.setActive(false);
  }

  /// Libera recursos del emitter.
  Future<void> dispose() async {
    await _emitter.dispose();
  }

  // ───────────────────────────────────────────────────────────────────────

  Future<ToneTestResult> _measureSingleTone({
    required double freqHz,
    required double targetLevelDbSpl,
    required AcceptanceCriteria criteria,
    required Duration toneDuration,
  }) async {
    await _channel.reset();
    await _channel.setExpectedFrequency(freqHz);

    // Reproducir el tono y, en paralelo, esperar a que se acumule al menos
    // una FFT completa antes de leer snapshots.
    unawaited(_emitter.playTone(
      freqHz: freqHz,
      levelDbSpl: targetLevelDbSpl,
      durationMs: toneDuration.inMilliseconds,
    ));

    // Esperamos un margen para que el ToneAnalyzer acumule la primera FFT.
    await Future<void>.delayed(const Duration(milliseconds: 200));

    // Polling durante el tono.
    ToneSnapshot? lastSnapshot;
    final pollEvery = const Duration(milliseconds: 100);
    final pollsTotal = (toneDuration.inMilliseconds / pollEvery.inMilliseconds).floor();
    for (var p = 0; p < pollsTotal; ++p) {
      if (_cancelled) break;
      await Future<void>.delayed(pollEvery);
      try {
        lastSnapshot = await _channel.getSnapshot();
      } catch (_) {
        // ignoramos lecturas inválidas
      }
    }

    // Detener emisión por las dudas.
    await _emitter.stop();

    final snap = lastSnapshot ?? ToneSnapshot.empty();
    return evaluate(
      snapshot: snap,
      criteria: criteria,
      targetLevelDbSpl: targetLevelDbSpl,
    );
  }
}
