import 'dart:async';
import 'dart:developer' as developer;
import 'dart:math';

import 'package:flutter/services.dart';
import 'package:hive/hive.dart';

import 'tone_generator.dart';

/// Servicio de calibración de auriculares.
///
/// Emite tonos a amplitudes digitales conocidas por el auricular,
/// mide el nivel capturado por el micrófono del celular, y construye
/// una tabla de calibración que mapea amplitud digital → dB SPL real.
///
/// Esto permite que el test de audiometría emita niveles calibrados
/// en dB SPL, no amplitudes digitales arbitrarias.
class HeadphoneCalibrator {
  static const _channel = MethodChannel('com.psk.hearing_aid/audio');
  static const String _hiveBoxName = 'headphone_calibration';

  /// Offset de calibración del micrófono: dBFS + 120 = dB SPL.
  static const double micOffsetDbSpl = 120.0;

  /// Frecuencias a calibrar (Hz).
  static const List<int> calibrationFrequencies = [
    500, 1000, 2000, 3000, 4000, 8000,
  ];

  /// Amplitudes digitales de prueba (0.0 a 1.0).
  static const List<double> testAmplitudes = [0.05, 0.1, 0.2, 0.3, 0.5];

  /// Duración de cada tono de calibración en ms.
  static const int toneDurationMs = 1200;

  /// Tiempo de espera antes de medir (para estabilización) en ms.
  static const int stabilizationMs = 300;

  final ToneGenerator _toneGenerator = ToneGenerator();

  /// Tabla de calibración: {frecuencia: {amplitud_digital: dB_SPL_medido}}.
  Map<int, Map<double, double>> _calibrationTable = {};

  /// Timestamp de la última calibración.
  DateTime? _calibrationTimestamp;

  /// Callback de progreso: (frecuencia actual, amplitud actual, progreso 0-1).
  void Function(int freqHz, double amplitude, double progress)?
      onProgressUpdate;

  /// Callback de estabilidad: true si la medición es estable.
  void Function(bool isStable)? onStabilityUpdate;

  /// Verifica si ya existe una calibración guardada.
  Future<bool> isCalibrated() async {
    final box = await Hive.openBox(_hiveBoxName);
    final hasData = box.containsKey('calibration_table');
    return hasData;
  }

  /// Carga la calibración guardada desde Hive.
  Future<bool> loadCalibration() async {
    try {
      final box = await Hive.openBox(_hiveBoxName);
      final rawTable = box.get('calibration_table');
      final timestamp = box.get('calibration_timestamp');

      if (rawTable == null) return false;

      _calibrationTable = _deserializeTable(rawTable);
      if (timestamp != null) {
        _calibrationTimestamp = DateTime.tryParse(timestamp as String);
      }
      return _calibrationTable.isNotEmpty;
    } catch (e) {
      return false;
    }
  }

  /// Retorna el timestamp de la última calibración.
  DateTime? get calibrationTimestamp => _calibrationTimestamp;

  /// Retorna la tabla de calibración actual.
  Map<int, Map<double, double>> get calibrationTable => _calibrationTable;

  /// Ejecuta el proceso completo de calibración.
  ///
  /// Para cada frecuencia y amplitud de prueba:
  /// 1. Emite un tono por el auricular
  /// 2. Mide el nivel RMS capturado por el micrófono
  /// 3. Convierte a dB SPL
  /// 4. Almacena en la tabla
  ///
  /// Retorna true si la calibración fue exitosa.
  Future<bool> calibrate() async {
    _calibrationTable = {};

    final totalSteps =
        calibrationFrequencies.length * testAmplitudes.length;
    int currentStep = 0;

    for (final freq in calibrationFrequencies) {
      _calibrationTable[freq] = {};

      for (final amplitude in testAmplitudes) {
        currentStep++;
        final progress = currentStep / totalSteps;
        onProgressUpdate?.call(freq, amplitude, progress);

        // Emitir tono a la amplitud digital conocida
        final levelDb = _amplitudeToLevelDb(amplitude);
        await _toneGenerator.playTone(
          frequencyHz: freq,
          levelDb: levelDb,
          ear: 'both',
        );

        // Esperar estabilización
        await Future.delayed(
          const Duration(milliseconds: stabilizationMs),
        );

        // Medir nivel del micrófono
        final measuredDbSpl = await _measureMicLevel(freq, amplitude);

        // Verificar estabilidad de la medición
        final isStable = _checkStability(measuredDbSpl, amplitude);
        onStabilityUpdate?.call(isStable);

        // Almacenar en tabla
        _calibrationTable[freq]![amplitude] = measuredDbSpl;

        // Detener tono
        await _toneGenerator.stop();

        // Pausa entre mediciones
        await Future.delayed(const Duration(milliseconds: 200));
      }
    }

    // Guardar en Hive
    await _saveCalibration();
    _calibrationTimestamp = DateTime.now();

    return true;
  }

  /// Obtiene la amplitud digital necesaria para producir un nivel
  /// objetivo en dB SPL a una frecuencia dada.
  ///
  /// Usa interpolación lineal en la tabla de calibración.
  /// Si no hay calibración, retorna una estimación basada en la
  /// relación teórica.
  double getAmplitudeForLevel(int freqHz, double targetDbSpl) {
    final freqTable = _calibrationTable[freqHz];
    if (freqTable == null || freqTable.isEmpty) {
      // Sin calibración: estimación teórica
      // Asumimos que amplitud 0.5 ≈ 70 dB SPL (auricular típico)
      return _estimateAmplitude(targetDbSpl);
    }

    // Ordenar por dB SPL medido
    final entries = freqTable.entries.toList()
      ..sort((a, b) => a.value.compareTo(b.value));

    // Si el target está por debajo del mínimo medido
    if (targetDbSpl <= entries.first.value) {
      // Extrapolar hacia abajo
      if (entries.length >= 2) {
        return _extrapolateBelow(entries, targetDbSpl);
      }
      return entries.first.key * 0.5; // Reducir a la mitad
    }

    // Si el target está por encima del máximo medido
    if (targetDbSpl >= entries.last.value) {
      // Extrapolar hacia arriba (con límite de 0.9)
      if (entries.length >= 2) {
        return _extrapolateAbove(entries, targetDbSpl).clamp(0.001, 0.9);
      }
      return (entries.last.key * 1.5).clamp(0.001, 0.9);
    }

    // Interpolación lineal entre los dos puntos más cercanos
    for (int i = 0; i < entries.length - 1; i++) {
      final lower = entries[i];
      final upper = entries[i + 1];

      if (targetDbSpl >= lower.value && targetDbSpl <= upper.value) {
        final fraction =
            (targetDbSpl - lower.value) / (upper.value - lower.value);
        final amplitude =
            lower.key + fraction * (upper.key - lower.key);
        return amplitude.clamp(0.001, 0.9);
      }
    }

    // Fallback
    return _estimateAmplitude(targetDbSpl);
  }

  /// Retorna el nivel dB del ToneGenerator correspondiente a una amplitud.
  /// El ToneGenerator usa una escala 0-80 donde 80 = amplitud 0.9.
  double _amplitudeToLevelDb(double amplitude) {
    // Inversa de la fórmula del ToneGenerator:
    // amplitude = 0.9 * pow(10, (normalized - 1) * 2)
    // donde normalized = levelDb / 80
    //
    // Despejando: normalized = (log10(amplitude / 0.9) / 2) + 1
    // levelDb = normalized * 80
    if (amplitude <= 0) return 0;
    final normalized = (log(amplitude / 0.9) / ln10 / 2) + 1;
    return (normalized * 80).clamp(0.0, 80.0);
  }

  /// Mide el nivel del micrófono.
  ///
  /// Lee el nivel de entrada (dBFS) desde el canal nativo
  /// `com.psk.hearing_aid/audio#getInputLevel` y lo convierte a dB SPL.
  ///
  /// El handler nativo retorna un Map con:
  ///   - `dbfs` (Double, RMS dBFS de los últimos 100 ms).
  ///   - `dbSpl` (Double | null, igual a `dbfs + micOffsetDb` cuando el
  ///     handler recibió `micOffsetDb` como argumento; null en caso
  ///     contrario).
  ///   - `calibrated` (Bool).
  ///
  /// Si el caller no provee un offset persistido, el handler retorna
  /// `dbSpl=null` y el Dart-side cae al default histórico
  /// [micOffsetDbSpl] (120 dB) sumado al `dbfs`.
  ///
  /// Si el canal nativo no está disponible o falla, **aborta la
  /// calibración con `StateError`**. NO se inventan mediciones: una
  /// calibración basada en datos sintéticos contaminaría toda la
  /// prescripción NAL-NL2 sumando ganancias falsas a la receta real.
  Future<double> _measureMicLevel(int freqHz, double amplitude) async {
    try {
      // Leer el offset persistido (si existe) para pasarlo al handler.
      final persistedOffset = await _readPersistedMicOffset();
      final result = await _channel.invokeMapMethod<String, dynamic>(
        'getInputLevel',
        <String, dynamic>{
          if (persistedOffset != null) 'micOffsetDb': persistedOffset,
        },
      );
      if (result == null) {
        throw StateError(
          'Calibración abortada: el canal nativo `getInputLevel` retornó null. '
          'Implementación pendiente en android/app/src/main/kotlin/com/psk/hearing_aid_app/AudioMethodChannel.kt.',
        );
      }
      final dbfs = (result['dbfs'] as num?)?.toDouble();
      final dbSpl = (result['dbSpl'] as num?)?.toDouble();
      final calibrated = (result['calibrated'] as bool?) ?? false;
      if (calibrated && dbSpl != null) {
        developer.log(
          'getInputLevel: usado offset calibrado (dbfs=$dbfs, dbSpl=$dbSpl)',
          name: 'HeadphoneCalibrator',
          level: 800,
        );
        return dbSpl;
      }
      if (dbfs == null) {
        throw StateError(
          'Calibración abortada: `getInputLevel` no retornó dbfs.',
        );
      }
      developer.log(
        'getInputLevel: sin offset persistido, usando default $micOffsetDbSpl '
        'dB (dbfs=$dbfs)',
        name: 'HeadphoneCalibrator',
        level: 800,
      );
      return dbfs + micOffsetDbSpl;
    } on MissingPluginException catch (e, st) {
      developer.log(
        'Canal nativo `getInputLevel` no registrado en esta plataforma',
        name: 'HeadphoneCalibrator',
        level: 1000, // SEVERE
        error: e,
        stackTrace: st,
      );
      throw StateError(
        'Calibración abortada: el canal nativo `getInputLevel` no está disponible en esta plataforma. '
        'Implementación pendiente en android/app/src/main/kotlin/com/psk/hearing_aid_app/AudioMethodChannel.kt. '
        'Causa subyacente: $e',
      );
    } on PlatformException catch (e, st) {
      developer.log(
        'Error en canal nativo `getInputLevel`',
        name: 'HeadphoneCalibrator',
        level: 1000, // SEVERE
        error: e,
        stackTrace: st,
      );
      throw StateError(
        'Calibración abortada: el canal nativo `getInputLevel` falló. '
        'Implementación pendiente en android/app/src/main/kotlin/com/psk/hearing_aid_app/AudioMethodChannel.kt. '
        'Causa subyacente: $e',
      );
    }
  }

  /// Lee `mic_offset_db` del Hive box de calibración nativa, si existe.
  /// Retorna `null` si el box no está abierto o la clave no existe.
  Future<double?> _readPersistedMicOffset() async {
    try {
      // El box `calibration_box` lo administra
      // `CalibrationAuditRepository`. Si nunca se abrió, no hay offset
      // persistido aún.
      if (!Hive.isBoxOpen('calibration_box')) {
        return null;
      }
      final box = Hive.box('calibration_box');
      final raw = box.get('mic_offset_db');
      if (raw is num) return raw.toDouble();
      return null;
    } catch (_) {
      return null;
    }
  }

  /// Verifica si la medición es estable (no fluctúa demasiado).
  bool _checkStability(double measuredDbSpl, double amplitude) {
    // Una medición es "estable" si el nivel medido está dentro
    // del rango esperado para la amplitud dada
    final expectedMin = 20 * log(amplitude) / ln10 + 85;
    final expectedMax = 20 * log(amplitude) / ln10 + 103;
    return measuredDbSpl >= expectedMin && measuredDbSpl <= expectedMax;
  }

  /// Estimación teórica de amplitud sin calibración.
  double _estimateAmplitude(double targetDbSpl) {
    // Basado en: dB SPL ≈ 20*log10(amplitude) + 94
    // amplitude = 10^((targetDbSpl - 94) / 20)
    final amplitude = pow(10, (targetDbSpl - 94) / 20).toDouble();
    return amplitude.clamp(0.001, 0.9);
  }

  /// Extrapola por debajo del rango medido.
  double _extrapolateBelow(
    List<MapEntry<double, double>> entries,
    double targetDbSpl,
  ) {
    final p1 = entries[0];
    final p2 = entries[1];
    // Pendiente en el espacio amplitud vs dB SPL
    final slope =
        (p2.key - p1.key) / (p2.value - p1.value);
    final amplitude = p1.key + slope * (targetDbSpl - p1.value);
    return amplitude.clamp(0.001, 0.9);
  }

  /// Extrapola por encima del rango medido.
  double _extrapolateAbove(
    List<MapEntry<double, double>> entries,
    double targetDbSpl,
  ) {
    final p1 = entries[entries.length - 2];
    final p2 = entries[entries.length - 1];
    final slope =
        (p2.key - p1.key) / (p2.value - p1.value);
    final amplitude = p2.key + slope * (targetDbSpl - p2.value);
    return amplitude.clamp(0.001, 0.9);
  }

  /// Guarda la tabla de calibración en Hive.
  Future<void> _saveCalibration() async {
    final box = await Hive.openBox(_hiveBoxName);
    await box.put('calibration_table', _serializeTable(_calibrationTable));
    await box.put(
      'calibration_timestamp',
      DateTime.now().toIso8601String(),
    );
  }

  /// Serializa la tabla para almacenamiento en Hive.
  Map<String, dynamic> _serializeTable(
    Map<int, Map<double, double>> table,
  ) {
    final result = <String, dynamic>{};
    for (final freqEntry in table.entries) {
      final ampMap = <String, double>{};
      for (final ampEntry in freqEntry.value.entries) {
        ampMap[ampEntry.key.toString()] = ampEntry.value;
      }
      result[freqEntry.key.toString()] = ampMap;
    }
    return result;
  }

  /// Deserializa la tabla desde Hive.
  Map<int, Map<double, double>> _deserializeTable(dynamic raw) {
    final table = <int, Map<double, double>>{};
    if (raw is Map) {
      for (final freqEntry in raw.entries) {
        final freq = int.tryParse(freqEntry.key.toString());
        if (freq == null) continue;
        final ampMap = <double, double>{};
        if (freqEntry.value is Map) {
          for (final ampEntry in (freqEntry.value as Map).entries) {
            final amp = double.tryParse(ampEntry.key.toString());
            final spl = ampEntry.value is num
                ? (ampEntry.value as num).toDouble()
                : double.tryParse(ampEntry.value.toString());
            if (amp != null && spl != null) {
              ampMap[amp] = spl;
            }
          }
        }
        table[freq] = ampMap;
      }
    }
    return table;
  }

  /// Libera recursos.
  Future<void> dispose() async {
    await _toneGenerator.dispose();
  }
}
