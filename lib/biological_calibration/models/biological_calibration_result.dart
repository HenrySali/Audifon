/// @file biological_calibration_result.dart
/// @brief Resultado final de una calibración biológica multi-sujeto.
///
/// Este archivo define los modelos de dominio que se persisten en Hive bajo
/// la clave `biological_calibration` y que se exportan como JSON conforme al
/// esquema descrito en
/// `investigaciones/calibracion-biologica-parametros-tecnicos.md` §8.5 y en
/// `design.md` (sección "Persistencia (Hive)").
///
/// El método [BiologicalCalibrationResult.hlToDbFS] es la conversión central
/// dB HL → dBFS que usarán las audiometrías posteriores para emitir tonos
/// con un nivel HL solicitado.

import 'frequency_threshold.dart';
import 'subject_session.dart';

/// Información del dispositivo (teléfono + Bluetooth) en el momento de la
/// calibración. Se usa para detectar cambios que invalidarían la calibración
/// (ej: cambio de auricular BT, cambio de volumen del sistema).
class DeviceInfo {
  /// Modelo del teléfono (ej: "Samsung SM-A546E").
  final String phoneModel;

  /// Versión del sistema operativo (ej: "Android 14").
  final String phoneOs;

  /// Nombre del dispositivo Bluetooth (ej: "Audífono BT v2.1").
  final String bluetoothDeviceName;

  /// MAC del dispositivo Bluetooth en formato AA:BB:CC:DD:EE:FF.
  final String bluetoothMac;

  /// Codec activo del enlace Bluetooth (SBC, AAC, aptX, ...).
  final String bluetoothCodec;

  /// Nivel de volumen del sistema en el momento de la calibración.
  final int systemVolumeLevel;

  /// Nivel máximo del stream de volumen del sistema.
  final int systemVolumeMax;

  /// Nombre del stream usado (típicamente `STREAM_MUSIC`).
  final String audioStream;

  const DeviceInfo({
    required this.phoneModel,
    required this.phoneOs,
    required this.bluetoothDeviceName,
    required this.bluetoothMac,
    required this.bluetoothCodec,
    required this.systemVolumeLevel,
    required this.systemVolumeMax,
    required this.audioStream,
  });

  Map<String, dynamic> toJson() => {
        'phone_model': phoneModel,
        'phone_os': phoneOs,
        'bluetooth_device_name': bluetoothDeviceName,
        'bluetooth_mac': bluetoothMac,
        'bluetooth_codec': bluetoothCodec,
        'system_volume_level': systemVolumeLevel,
        'system_volume_max': systemVolumeMax,
        'audio_stream': audioStream,
      };

  factory DeviceInfo.fromJson(Map<String, dynamic> j) {
    return DeviceInfo(
      phoneModel: j['phone_model'] as String,
      phoneOs: j['phone_os'] as String,
      bluetoothDeviceName: j['bluetooth_device_name'] as String,
      bluetoothMac: j['bluetooth_mac'] as String,
      bluetoothCodec: j['bluetooth_codec'] as String,
      systemVolumeLevel: (j['system_volume_level'] as num).toInt(),
      systemVolumeMax: (j['system_volume_max'] as num).toInt(),
      audioStream: j['audio_stream'] as String,
    );
  }
}

/// Parámetros del protocolo Hughson-Westlake usado durante la calibración.
class ProtocolInfo {
  /// Identificador del método (`hughson_westlake_modified`).
  final String method;

  /// Paso ascendente en dB (típico: 5).
  final double stepUpDb;

  /// Paso descendente en dB (típico: 10).
  final double stepDownDb;

  /// Duración del tono entre rampas en ms (típico: 1000).
  final int toneDurationMs;

  /// Duración de la rampa de onset/offset en ms (típico: 25-30).
  final int rampMs;

  /// Tipo de envelope (`raised_cosine`).
  final String rampType;

  /// ITI mínimo en ms.
  final int itiMinMs;

  /// ITI máximo en ms.
  final int itiMaxMs;

  /// Criterio de umbral usado (ej: `2_of_3_ascending`).
  final String thresholdCriterion;

  /// Frecuencia de muestreo en Hz.
  final int sampleRate;

  /// Profundidad de bit del WAV generado.
  final int bitDepth;

  /// Número de canales (1 = mono).
  final int channels;

  const ProtocolInfo({
    required this.method,
    required this.stepUpDb,
    required this.stepDownDb,
    required this.toneDurationMs,
    required this.rampMs,
    required this.rampType,
    required this.itiMinMs,
    required this.itiMaxMs,
    required this.thresholdCriterion,
    required this.sampleRate,
    required this.bitDepth,
    required this.channels,
  });

  Map<String, dynamic> toJson() => {
        'method': method,
        'step_up_dB': stepUpDb,
        'step_down_dB': stepDownDb,
        'tone_duration_ms': toneDurationMs,
        'ramp_ms': rampMs,
        'ramp_type': rampType,
        'iti_min_ms': itiMinMs,
        'iti_max_ms': itiMaxMs,
        'threshold_criterion': thresholdCriterion,
        'sample_rate': sampleRate,
        'bit_depth': bitDepth,
        'channels': channels,
      };

  factory ProtocolInfo.fromJson(Map<String, dynamic> j) {
    return ProtocolInfo(
      method: j['method'] as String,
      stepUpDb: (j['step_up_dB'] as num).toDouble(),
      stepDownDb: (j['step_down_dB'] as num).toDouble(),
      toneDurationMs: (j['tone_duration_ms'] as num).toInt(),
      rampMs: (j['ramp_ms'] as num).toInt(),
      rampType: j['ramp_type'] as String,
      itiMinMs: (j['iti_min_ms'] as num).toInt(),
      itiMaxMs: (j['iti_max_ms'] as num).toInt(),
      thresholdCriterion: j['threshold_criterion'] as String,
      sampleRate: (j['sample_rate'] as num).toInt(),
      bitDepth: (j['bit_depth'] as num).toInt(),
      channels: (j['channels'] as num).toInt(),
    );
  }
}

/// Métricas globales de calidad calculadas a partir de todas las sesiones.
class QualityMetrics {
  /// Promedio de los `spread_dB` de todas las frecuencias.
  final double overallSpreadMeanDb;

  /// Máximo `spread_dB` observado entre frecuencias.
  final double overallSpreadMaxDb;

  /// Total de catch trials sumados a lo largo de todos los sujetos.
  final int totalCatchTrials;

  /// Total de falsos positivos sumados a lo largo de todos los sujetos.
  final int totalFalsePositives;

  /// Tasa global de falsos positivos en [0, 1].
  final double overallFalsePositiveRate;

  /// True si todos los retests a 1000 Hz cayeron dentro de ±5 dB.
  final bool allRetestsWithin5Db;

  /// Flag global de validez de la calibración (combinación de criterios).
  final bool calibrationValid;

  const QualityMetrics({
    required this.overallSpreadMeanDb,
    required this.overallSpreadMaxDb,
    required this.totalCatchTrials,
    required this.totalFalsePositives,
    required this.overallFalsePositiveRate,
    required this.allRetestsWithin5Db,
    required this.calibrationValid,
  });

  Map<String, dynamic> toJson() => {
        'overall_spread_mean_dB': overallSpreadMeanDb,
        'overall_spread_max_dB': overallSpreadMaxDb,
        'total_catch_trials': totalCatchTrials,
        'total_false_positives': totalFalsePositives,
        'overall_false_positive_rate': overallFalsePositiveRate,
        'all_retests_within_5dB': allRetestsWithin5Db,
        'calibration_valid': calibrationValid,
      };

  factory QualityMetrics.fromJson(Map<String, dynamic> j) {
    return QualityMetrics(
      overallSpreadMeanDb: (j['overall_spread_mean_dB'] as num).toDouble(),
      overallSpreadMaxDb: (j['overall_spread_max_dB'] as num).toDouble(),
      totalCatchTrials: (j['total_catch_trials'] as num).toInt(),
      totalFalsePositives: (j['total_false_positives'] as num).toInt(),
      overallFalsePositiveRate:
          (j['overall_false_positive_rate'] as num).toDouble(),
      allRetestsWithin5Db: j['all_retests_within_5dB'] as bool,
      calibrationValid: j['calibration_valid'] as bool,
    );
  }
}

/// Resultado completo de una calibración biológica.
///
/// Es el objeto raíz que se serializa a JSON para persistir en Hive y para
/// exportar al portapapeles. Las audiometrías posteriores cargan esta
/// estructura y usan [hlToDbFS] para convertir niveles HL a niveles dBFS
/// emitibles en el dispositivo calibrado.
class BiologicalCalibrationResult {
  /// Versión del esquema JSON. Cambia cuando el formato de los datos no es
  /// retrocompatible.
  static const String schemaVersion = '1.0.0';

  /// Tipo de calibración (constante para distinguirla de la electroacústica).
  static const String calibrationType = 'biological';

  /// Marca temporal de creación de la calibración.
  final DateTime createdAt;

  /// Marca temporal a partir de la cual la calibración debe considerarse
  /// expirada (típicamente createdAt + 90 días).
  final DateTime expiresAt;

  /// Información del dispositivo en el momento de la calibración.
  final DeviceInfo device;

  /// Parámetros del protocolo aplicado.
  final ProtocolInfo protocol;

  /// Sesiones de los sujetos participantes (válidas e inválidas).
  final List<SubjectSession> sessions;

  /// Umbrales promediados por frecuencia (Hz → FrequencyThreshold).
  final Map<int, FrequencyThreshold> frequencies;

  /// Métricas globales de calidad de la calibración.
  final QualityMetrics quality;

  const BiologicalCalibrationResult({
    required this.createdAt,
    required this.expiresAt,
    required this.device,
    required this.protocol,
    required this.sessions,
    required this.frequencies,
    required this.quality,
  });

  /// Convierte un nivel HL solicitado en dBFS emitible para una frecuencia
  /// específica. Devuelve `null` si:
  ///
  ///   - La frecuencia no está calibrada (no existe en [frequencies]), o
  ///   - El nivel resultante excede el techo digital de -1 dBFS.
  ///
  /// Fórmula: `amplitude_dBFS = mean_threshold_dBFS + levelHL`.
  double? hlToDbFS(double levelHL, int freqHz) {
    final threshold = frequencies[freqHz];
    if (threshold == null) return null;
    final result = threshold.meanThresholdDbFS + levelHL;
    if (result > -1.0) return null;
    return result;
  }

  Map<String, dynamic> toJson() => {
        'schema_version': schemaVersion,
        'calibration_type': calibrationType,
        'created_at': createdAt.toIso8601String(),
        'expires_at': expiresAt.toIso8601String(),
        'device': device.toJson(),
        'protocol': protocol.toJson(),
        'subjects': sessions.map((s) => s.toJson()).toList(),
        'calibration_result': frequencies.map(
          (freq, threshold) => MapEntry(freq.toString(), threshold.toJson()),
        ),
        'quality_metrics': quality.toJson(),
      };

  factory BiologicalCalibrationResult.fromJson(Map<String, dynamic> j) {
    final rawSubjects =
        (j['subjects'] as List?)?.cast<dynamic>() ?? const <dynamic>[];
    final sessions = rawSubjects
        .map((e) => SubjectSession.fromJson((e as Map).cast<String, dynamic>()))
        .toList();

    final rawFreqs =
        (j['calibration_result'] as Map?)?.cast<String, dynamic>() ??
            const <String, dynamic>{};
    final frequencies = <int, FrequencyThreshold>{};
    rawFreqs.forEach((k, v) {
      final freq = int.tryParse(k);
      if (freq != null && v is Map) {
        // Inyectamos `freq_hz` si el JSON serializado por sección no lo trae
        // (el schema lo coloca como clave del mapa).
        final inner = v.cast<String, dynamic>();
        if (!inner.containsKey('freq_hz')) {
          inner['freq_hz'] = freq;
        }
        if (!inner.containsKey('individual_values')) {
          inner['individual_values'] = const <double>[];
        }
        frequencies[freq] = FrequencyThreshold.fromJson(inner);
      }
    });

    return BiologicalCalibrationResult(
      createdAt: DateTime.parse(j['created_at'] as String),
      expiresAt: DateTime.parse(j['expires_at'] as String),
      device: DeviceInfo.fromJson(
        (j['device'] as Map).cast<String, dynamic>(),
      ),
      protocol: ProtocolInfo.fromJson(
        (j['protocol'] as Map).cast<String, dynamic>(),
      ),
      sessions: sessions,
      frequencies: frequencies,
      quality: QualityMetrics.fromJson(
        (j['quality_metrics'] as Map).cast<String, dynamic>(),
      ),
    );
  }
}
