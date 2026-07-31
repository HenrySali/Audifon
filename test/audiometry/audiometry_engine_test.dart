/// Tests unitarios para [AudiometryEngine].
///
/// Verifica:
///   - Convergencia del algoritmo Hughson-Westlake adaptado a la escala dB HL
///     cuando el "paciente" responde de forma determinista contra un umbral
///     verdadero conocido (35 dB HL).
///   - Transición a [HwState.outOfRange] cuando el nivel HL solicitado por el
///     algoritmo se traduciría a un dBFS > -1 (techo del transductor) según
///     la calibración biológica.
///   - Transición a [HwState.outOfRange] cuando se solicita una frecuencia
///     que no está presente en la calibración biológica (sin umbral).
///
/// Estos tests usan un fake mínimo de [ToneEmitterDbfs] (basado en
/// `mocktail.Fake`) que solo registra las llamadas a `playToneAtDbFS` y
/// no toca `just_audio` para evitar acoplarse al binding de Flutter.
///
/// Requisitos validados: 2, 4 (algoritmo HW + conversión HL → dBFS).

import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

import 'package:hearing_aid_app/audiometry/core/audiometry_engine.dart';
import 'package:hearing_aid_app/biological_calibration/core/hughson_westlake_algorithm.dart';
import 'package:hearing_aid_app/biological_calibration/core/tone_emitter_dbfs.dart';
import 'package:hearing_aid_app/biological_calibration/models/biological_calibration_result.dart';
import 'package:hearing_aid_app/biological_calibration/models/catch_trial_stats.dart';
import 'package:hearing_aid_app/biological_calibration/models/eligibility_questionnaire.dart';
import 'package:hearing_aid_app/biological_calibration/models/frequency_threshold.dart';
import 'package:hearing_aid_app/biological_calibration/models/subject_session.dart';

/// Llamada registrada por [_FakeToneEmitter].
class _PlayCall {
  final double freqHz;
  final double levelDbFS;
  final int durationMs;
  const _PlayCall({
    required this.freqHz,
    required this.levelDbFS,
    required this.durationMs,
  });
}

/// Fake mínimo de [ToneEmitterDbfs] que solo registra llamadas y no toca
/// `just_audio`. Se basa en `mocktail.Fake` para evitar implementar métodos
/// que no son ejercitados en estos tests (ej: `dispose`, `stop`).
class _FakeToneEmitter extends Fake implements ToneEmitterDbfs {
  final List<_PlayCall> calls = [];

  @override
  Future<void> playToneAtDbFS({
    required double freqHz,
    required double levelDbFS,
    required int durationMs,
  }) async {
    calls.add(_PlayCall(
      freqHz: freqHz,
      levelDbFS: levelDbFS,
      durationMs: durationMs,
    ));
  }
}

/// Construye un [BiologicalCalibrationResult] ficticio para tests con un
/// umbral configurable por frecuencia.
///
/// Por defecto usa `meanThresholdDbFS = -50` dBFS para todas las frecuencias
/// estándar de audiometría → la conversión HL → dBFS queda en
/// `dBFS = -50 + HL`. Esto da `maxHLAchievable = 49` dB HL (techo digital
/// en -1 dBFS).
///
/// Si [thresholdsDbFSByFreq] se proporciona, se usa exactamente ese mapa
/// (permite construir calibraciones parciales o con umbrales distintos por
/// frecuencia para forzar `outOfRange`).
BiologicalCalibrationResult _buildCalibration({
  Map<int, double>? thresholdsDbFSByFreq,
}) {
  final defaults = <int, double>{
    250: -50.0,
    500: -50.0,
    1000: -50.0,
    2000: -50.0,
    4000: -50.0,
    8000: -50.0,
  };
  final input = thresholdsDbFSByFreq ?? defaults;

  final freqs = <int, FrequencyThreshold>{};
  input.forEach((freq, mean) {
    // Con 1 solo valor el spread es 0 y la confianza queda 'high'.
    freqs[freq] = FrequencyThreshold.compute(
      freqHz: freq,
      values: [mean],
    );
  });

  const device = DeviceInfo(
    phoneModel: 'TestPhone',
    phoneOs: 'Android Test',
    bluetoothDeviceName: 'TestBT',
    bluetoothMac: 'AA:BB:CC:DD:EE:FF',
    bluetoothCodec: 'AAC',
    systemVolumeLevel: 15,
    systemVolumeMax: 15,
    audioStream: 'STREAM_MUSIC',
  );

  const protocol = ProtocolInfo(
    method: 'hughson_westlake_modified',
    stepUpDb: 5.0,
    stepDownDb: 10.0,
    toneDurationMs: 1000,
    rampMs: 25,
    rampType: 'raised_cosine',
    itiMinMs: 1500,
    itiMaxMs: 3000,
    thresholdCriterion: '2_of_3_ascending',
    sampleRate: 48000,
    bitDepth: 16,
    channels: 1,
  );

  final session = SubjectSession(
    id: 1,
    alias: 'Sujeto Test',
    testedAt: DateTime.utc(2025, 1, 1),
    questionnaire: const EligibilityQuestionnaire(
      ageInRange: true,
      normalHearingSelfReported: true,
      noActiveTinnitus: true,
      noCongestion: true,
    ),
    thresholdsDbFS: Map<int, double>.from(input),
    retest1000DbFS: null,
    retestDifferenceDb: null,
    catchTrials: const CatchTrialStats(total: 0, falsePositives: 0),
    valid: true,
  );

  const quality = QualityMetrics(
    overallSpreadMeanDb: 0.0,
    overallSpreadMaxDb: 0.0,
    totalCatchTrials: 0,
    totalFalsePositives: 0,
    overallFalsePositiveRate: 0.0,
    allRetestsWithin5Db: true,
    calibrationValid: true,
  );

  return BiologicalCalibrationResult(
    createdAt: DateTime.utc(2025, 1, 1),
    expiresAt: DateTime.utc(2025, 4, 1),
    device: device,
    protocol: protocol,
    sessions: [session],
    frequencies: freqs,
    quality: quality,
  );
}

void main() {
  group('AudiometryEngine — convergencia', () {
    test(
        'converge a ±5 dB HL del umbral simulado (HL=35 dB) usando paciente '
        'determinista', () async {
      final calibration = _buildCalibration();
      final emitter = _FakeToneEmitter();
      final engine = AudiometryEngine(
        calibration: calibration,
        emitter: emitter,
      );

      const trueThresholdHL = 35.0;
      const probedFreq = 1000;
      engine.startFrequency(probedFreq);

      // El engine empieza en familiarization @ 30 dB HL. Se itera hasta llegar
      // a un estado terminal o agotar el guardarraíl de pasos.
      const maxSteps = 200;
      var steps = 0;
      while (engine.state != HwState.thresholdFound &&
          engine.state != HwState.outOfRange &&
          engine.state != HwState.invalid) {
        // Emite el tono al nivel HL actual (debe ser exitoso porque la
        // calibración ficticia tiene maxHLAchievable = 49 dB HL).
        final played = await engine.playCurrentTone(durationMs: 200);
        expect(played, isTrue,
            reason: 'La calibración de -50 dBFS soporta cualquier HL ≤ 49');

        // Modelo determinista: el "paciente" oye sii el nivel actual ≥ umbral
        // verdadero.
        final heard = engine.currentLevelHL >= trueThresholdHL;
        engine.recordResponse(heard);

        steps++;
        if (steps > maxSteps) {
          fail('AudiometryEngine no convergió en $maxSteps pasos '
              '(state=${engine.state}, currentLevelHL=${engine.currentLevelHL})');
        }
      }

      expect(engine.state, HwState.thresholdFound);
      expect(engine.threshold, isNotNull);
      expect(
        (engine.threshold! - trueThresholdHL).abs(),
        lessThanOrEqualTo(5.0),
        reason: 'El umbral encontrado debe estar a ±5 dB HL del verdadero',
      );

      // Las llamadas registradas en el fake emitter deben corresponder a la
      // frecuencia probada y a la conversión HL → dBFS = -50 + HL.
      expect(emitter.calls, isNotEmpty);
      for (final c in emitter.calls) {
        expect(c.freqHz, equals(probedFreq.toDouble()));
        expect(c.durationMs, equals(200));
        // No verificamos el dBFS exacto contra todos los HL del trayecto,
        // pero sí que cae dentro del rango lógico de la calibración.
        expect(c.levelDbFS, lessThanOrEqualTo(-1.0));
      }
    });
  });

  group('AudiometryEngine — outOfRange por techo del transductor', () {
    test(
        'cuando el HL solicitado excede maxHLAchievable, state = outOfRange',
        () async {
      // Umbral biológico = -10 dBFS → maxHL = -1 - (-10) = 9 dB HL.
      // El engine arranca en 30 dB HL, que ya excede 9. Si el "paciente"
      // sigue sin oír, el algoritmo intenta subir, pero ya en el primer
      // playCurrentTone hlToDbFS retorna null y se marca outOfRange.
      final calibration = _buildCalibration(
        thresholdsDbFSByFreq: const {1000: -10.0},
      );
      final emitter = _FakeToneEmitter();
      final engine = AudiometryEngine(
        calibration: calibration,
        emitter: emitter,
      );

      engine.startFrequency(1000);
      // Forzar misses: simulamos que el paciente no responde a ningún tono.
      // Al primer playCurrentTone debe quedar outOfRange porque
      // -10 + 30 = +20 dBFS > -1.
      const maxSteps = 30;
      var steps = 0;
      while (engine.state != HwState.outOfRange &&
          engine.state != HwState.thresholdFound &&
          engine.state != HwState.invalid) {
        final played = await engine.playCurrentTone(durationMs: 100);
        if (!played) {
          // El engine ya marcó outOfRange; no se debe haber emitido tono.
          break;
        }
        // No oye nada → el algoritmo subirá, pero no debería llegar aquí
        // porque el primer call ya tendría que fallar.
        engine.recordResponse(false);
        steps++;
        if (steps > maxSteps) {
          fail('No se alcanzó outOfRange en $maxSteps pasos '
              '(state=${engine.state})');
        }
      }

      expect(engine.state, HwState.outOfRange,
          reason: 'Calibración con maxHL=9 y HL inicial=30 debe disparar '
              'outOfRange en el primer playCurrentTone.');
      // El fake no debe haber recibido llamadas (porque hlToDbFS retornó
      // null antes de llegar al emitter).
      expect(emitter.calls, isEmpty);
    });
  });

  group('AudiometryEngine — frecuencia sin calibrar', () {
    test(
        'startFrequency con freq fuera de la calibración → '
        'playCurrentTone devuelve false y state = outOfRange', () async {
      // Calibración SOLO con 1000 Hz; pedimos 1500 Hz.
      final calibration = _buildCalibration(
        thresholdsDbFSByFreq: const {1000: -50.0},
      );
      final emitter = _FakeToneEmitter();
      final engine = AudiometryEngine(
        calibration: calibration,
        emitter: emitter,
      );

      engine.startFrequency(1500);
      final played = await engine.playCurrentTone(durationMs: 200);

      expect(played, isFalse,
          reason: 'Sin umbral para la freq, hlToDbFS retorna null y '
              'playCurrentTone debe retornar false.');
      expect(engine.state, HwState.outOfRange);
      expect(emitter.calls, isEmpty,
          reason: 'No debe llegar al emitter si no hay calibración para la '
              'frecuencia.');
    });
  });
}
