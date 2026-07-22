/// @file audiometry_engine.dart
/// @brief Motor de búsqueda de umbral por frecuencia para la audiometría del
///        paciente, operando en escala dB HL.
///
/// Reusa [HughsonWestlakeAlgorithm] cambiando la interpretación de las
/// constantes: aunque la API del algoritmo se llama `dBFS`, internamente sólo
/// trabaja con incrementos/decrementos en una escala genérica. Aquí se la
/// alimenta con valores en dB HL (initial = 30, min = -10, max = 80,
/// stepUp = 5, stepDown = 10) y la conversión a dBFS se hace justo antes de
/// emitir el tono usando [BiologicalCalibrationResult.hlToDbFS].
///
/// Si la calibración no permite alcanzar el nivel HL solicitado en una
/// frecuencia (por ejemplo HL muy alto que se traduciría a un dBFS > -1),
/// el motor marca esa frecuencia como [HwState.outOfRange] sin emitir tono.
library;

import '../../biological_calibration/core/hughson_westlake_algorithm.dart';
import '../../biological_calibration/core/tone_emitter_dbfs.dart';
import '../../biological_calibration/models/biological_calibration_result.dart';

/// Wrapper de Hughson-Westlake parametrizado en dB HL para audiometría clínica.
class AudiometryEngine {
  /// Calibración biológica del dispositivo concreto (mapea HL → dBFS por freq).
  final BiologicalCalibrationResult calibration;

  /// Emisor de tonos puros parametrizado en dBFS.
  final ToneEmitterDbfs emitter;

  /// Algoritmo Hughson-Westlake operando en escala HL.
  ///
  /// Las constantes están elegidas para audiometría tonal (ASHA / IEC 60645-1):
  ///   - inicio en 30 dB HL (audible para normoyentes)
  ///   - rango [-10, +80] dB HL
  ///   - paso ascendente de 5 dB, paso descendente de 10 dB
  final HughsonWestlakeAlgorithm _algorithm = HughsonWestlakeAlgorithm(
    initialDbFS: 30.0,
    minDbFS: -10.0,
    maxDbFS: 80.0,
    stepUp: 5.0,
    stepDown: 10.0,
  );

  /// Frecuencia actual en Hz (se fija por [startFrequency]).
  int? _currentFreqHz;

  /// Bandera de "fuera del techo del transductor" para la frecuencia actual.
  bool _outOfRange = false;

  AudiometryEngine({
    required this.calibration,
    required this.emitter,
  });

  /// Comienza la búsqueda de umbral en una nueva frecuencia. Resetea el
  /// algoritmo y limpia la bandera [_outOfRange].
  void startFrequency(int freqHz) {
    _currentFreqHz = freqHz;
    _outOfRange = false;
    _algorithm.reset();
  }

  /// Estado actual de la búsqueda. Devuelve [HwState.outOfRange] si la
  /// calibración no permite emitir el nivel HL solicitado, aunque el algoritmo
  /// interno aún no haya terminado.
  HwState get state {
    if (_outOfRange) return HwState.outOfRange;
    return _algorithm.state;
  }

  /// Nivel HL que se debe presentar a continuación. La API del algoritmo lo
  /// expone como `currentLevelDbFS`, pero aquí lo interpretamos como dB HL.
  double get currentLevelHL => _algorithm.currentLevelDbFS;

  /// Umbral en dB HL una vez que el algoritmo ha llegado a
  /// [HwState.thresholdFound]. `null` si todavía no se encontró.
  double? get threshold => _algorithm.threshold;

  /// Emite el tono al nivel HL actual para la frecuencia activa.
  ///
  /// Devuelve `true` si el tono se emitió correctamente y `false` si la
  /// calibración no soporta el nivel solicitado (en cuyo caso se marca
  /// la frecuencia como fuera de rango). Lanza [StateError] si no se ha
  /// llamado primero a [startFrequency].
  Future<bool> playCurrentTone({required int durationMs}) async {
    final freq = _currentFreqHz;
    if (freq == null) {
      throw StateError(
        'AudiometryEngine.playCurrentTone: no hay frecuencia activa. '
        'Llamar primero a startFrequency().',
      );
    }
    final levelHL = currentLevelHL;
    final dbfs = calibration.hlToDbFS(levelHL, freq);
    if (dbfs == null) {
      _outOfRange = true;
      return false;
    }
    await emitter.playToneAtDbFS(
      freqHz: freq.toDouble(),
      levelDbFS: dbfs,
      durationMs: durationMs,
    );
    return true;
  }

  /// Registra la respuesta del paciente (`true` = "lo escuchó") y avanza la
  /// máquina de estados del algoritmo.
  void recordResponse(bool heard) {
    _algorithm.recordResponse(heard);
  }
}
