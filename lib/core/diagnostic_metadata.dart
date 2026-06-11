import 'dart:convert';

/// Parámetros WDRC capturados al momento de la grabación.
class WdrcMetadata {
  final double expansionKnee;
  final double expansionRatio;
  final double compressionKnee;
  final double compressionRatio;
  final double attackMs;
  final double releaseMs;

  const WdrcMetadata({
    required this.expansionKnee,
    required this.expansionRatio,
    required this.compressionKnee,
    required this.compressionRatio,
    required this.attackMs,
    required this.releaseMs,
  });

  Map<String, dynamic> toJson() => {
        'expansionKnee': expansionKnee,
        'expansionRatio': expansionRatio,
        'compressionKnee': compressionKnee,
        'compressionRatio': compressionRatio,
        'attackMs': attackMs,
        'releaseMs': releaseMs,
      };

  factory WdrcMetadata.fromJson(Map<String, dynamic> json) => WdrcMetadata(
        expansionKnee: (json['expansionKnee'] as num).toDouble(),
        expansionRatio: (json['expansionRatio'] as num).toDouble(),
        compressionKnee: (json['compressionKnee'] as num).toDouble(),
        compressionRatio: (json['compressionRatio'] as num).toDouble(),
        attackMs: (json['attackMs'] as num).toDouble(),
        releaseMs: (json['releaseMs'] as num).toDouble(),
      );
}

/// Estado del DNN denoiser al momento de la grabación.
class DnnMetadata {
  final bool enabled;
  final double intensity;

  const DnnMetadata({
    required this.enabled,
    required this.intensity,
  });

  Map<String, dynamic> toJson() => {
        'enabled': enabled,
        'intensity': intensity,
      };

  factory DnnMetadata.fromJson(Map<String, dynamic> json) => DnnMetadata(
        enabled: json['enabled'] as bool,
        intensity: (json['intensity'] as num).toDouble(),
      );
}

/// Información del dispositivo de audio al momento de la grabación.
class DeviceMetadata {
  final String inputDevice;
  final String outputDevice;
  final String bluetoothDevice;
  final String bluetoothConnectionType;

  const DeviceMetadata({
    required this.inputDevice,
    required this.outputDevice,
    required this.bluetoothDevice,
    required this.bluetoothConnectionType,
  });

  Map<String, dynamic> toJson() => {
        'inputDevice': inputDevice,
        'outputDevice': outputDevice,
        'bluetoothDevice': bluetoothDevice,
        'bluetoothConnectionType': bluetoothConnectionType,
      };

  factory DeviceMetadata.fromJson(Map<String, dynamic> json) => DeviceMetadata(
        inputDevice: json['inputDevice'] as String,
        outputDevice: json['outputDevice'] as String,
        bluetoothDevice: json['bluetoothDevice'] as String,
        bluetoothConnectionType: json['bluetoothConnectionType'] as String,
      );
}


/// Metadatos completos de una sesión de grabación de diagnóstico DSP.
///
/// Captura toda la configuración del pipeline DSP al momento de la
/// grabación, permitiendo a Ingeniería correlacionar la función de
/// transferencia medida con los parámetros prescritos en MATLAB.
class DiagnosticMetadata {
  // ─── Audio Parameters (constantes del formato) ────────────────────────
  static const int defaultSampleRate = 48000;
  static const int defaultBitDepth = 16;
  static const int defaultChannelCount = 2;
  static const double defaultDurationSeconds = 60.0;
  static const int defaultTotalSamplesPerChannel = 2880000;

  final int sampleRate;
  final int bitDepth;
  final int channelCount;
  final double durationSeconds;
  final int totalSamplesPerChannel;
  final int recordedSamples;

  // ─── DSP Configuration ────────────────────────────────────────────────
  final Map<int, double> audiogramThresholds;
  final String activePreset;
  final List<double> eqGainsDb;
  final WdrcMetadata wdrc;
  final double mpoThresholdDbSpl;
  final DnnMetadata dnn;
  final int nrLevel;
  final bool tnrEnabled;

  /// Nivel pre-DNN en dB SPL medido por el AudioEngine y pasado al WDRC.
  ///
  /// Permite a Ingeniería verificar Property 8 del design dsp-chain-optimization
  /// (compression ratio efectivo = preDnnLevelDb − postWdrcLevel).
  ///
  /// El valor sentinela `-1.0` indica "no disponible" — típicamente porque
  /// el AudioEngine midió RMS localmente desde el buffer post-DNN en lugar
  /// del nivel real de entrada (fallback de retrocompatibilidad).
  ///
  /// Spec: dsp-chain-optimization · Task 4.4 · Requirements 6.1, 6.2.
  final double preDnnLevelDb;

  /// Origen del nivel usado por el WDRC para decidir su región de compresión.
  ///
  /// - `"pre-dnn"`: el WDRC usó el nivel medido en el AudioEngine antes de
  ///   la DNN. Este es el modo correcto post spec dsp-chain-optimization.
  /// - `"local"`: el WDRC midió RMS localmente desde el buffer post-DNN
  ///   (modo legacy / fallback). Indica que la cadena no estaba pasando el
  ///   nivel externo, por ejemplo si el motor nativo es de versión anterior.
  ///
  /// Spec: dsp-chain-optimization · Task 4.4 · Requirements 6.1, 6.2.
  final String wdrcLevelSource;

  // ─── Device Info ──────────────────────────────────────────────────────
  final DeviceMetadata device;

  // ─── Timestamps & Versions ────────────────────────────────────────────
  final String recordingTimestamp; // ISO 8601 UTC
  final String appVersion;
  final String schemaVersion;

  DiagnosticMetadata({
    this.sampleRate = defaultSampleRate,
    this.bitDepth = defaultBitDepth,
    this.channelCount = defaultChannelCount,
    this.durationSeconds = defaultDurationSeconds,
    this.totalSamplesPerChannel = defaultTotalSamplesPerChannel,
    required this.recordedSamples,
    required this.audiogramThresholds,
    required this.activePreset,
    required this.eqGainsDb,
    required this.wdrc,
    required this.mpoThresholdDbSpl,
    required this.dnn,
    required this.nrLevel,
    required this.tnrEnabled,
    required this.device,
    required this.recordingTimestamp,
    required this.appVersion,
    this.schemaVersion = '1.0',
    this.preDnnLevelDb = -1.0,
    this.wdrcLevelSource = 'local',
  });

  /// Serializa a un mapa JSON compatible con el schema v1.0.
  Map<String, dynamic> toJson() => {
        'schemaVersion': schemaVersion,
        'appVersion': appVersion,
        'recordingTimestamp': recordingTimestamp,
        'audio': {
          'sampleRate': sampleRate,
          'bitDepth': bitDepth,
          'channelCount': channelCount,
          'channelMapping': {
            'left': 'pre_dsp_raw_mic',
            'right': 'post_dsp_processed',
          },
          'durationSeconds': durationSeconds,
          'totalSamplesPerChannel': totalSamplesPerChannel,
          'recordedSamples': recordedSamples,
        },
        'dspConfiguration': {
          'audiogramThresholds': audiogramThresholds.map(
            (freq, threshold) => MapEntry(freq.toString(), threshold),
          ),
          'activePreset': activePreset,
          'eqGainsDb': eqGainsDb,
          'wdrc': wdrc.toJson(),
          'mpoThresholdDbSpl': mpoThresholdDbSpl,
          'dnn': dnn.toJson(),
          'nrLevel': nrLevel,
          'tnrEnabled': tnrEnabled,
          // Verificación del compression ratio efectivo
          // (spec dsp-chain-optimization · Task 4.4 · Property 8).
          'preDnnLevelDb': preDnnLevelDb,
          'wdrcLevelSource': wdrcLevelSource,
        },
        'device': device.toJson(),
      };

  /// Serializa a una cadena JSON con formato legible (pretty-printed).
  String toJsonString() {
    const encoder = JsonEncoder.withIndent('  ');
    return encoder.convert(toJson());
  }

  /// Reconstruye un [DiagnosticMetadata] desde un mapa JSON.
  factory DiagnosticMetadata.fromJson(Map<String, dynamic> json) {
    final audio = json['audio'] as Map<String, dynamic>;
    final dspConfig = json['dspConfiguration'] as Map<String, dynamic>;
    final thresholdsRaw =
        dspConfig['audiogramThresholds'] as Map<String, dynamic>;

    return DiagnosticMetadata(
      sampleRate: audio['sampleRate'] as int,
      bitDepth: audio['bitDepth'] as int,
      channelCount: audio['channelCount'] as int,
      durationSeconds: (audio['durationSeconds'] as num).toDouble(),
      totalSamplesPerChannel: audio['totalSamplesPerChannel'] as int,
      recordedSamples: audio['recordedSamples'] as int,
      audiogramThresholds: thresholdsRaw.map(
        (key, value) => MapEntry(int.parse(key), (value as num).toDouble()),
      ),
      activePreset: dspConfig['activePreset'] as String,
      eqGainsDb: (dspConfig['eqGainsDb'] as List<dynamic>)
          .map((e) => (e as num).toDouble())
          .toList(),
      wdrc: WdrcMetadata.fromJson(dspConfig['wdrc'] as Map<String, dynamic>),
      mpoThresholdDbSpl: (dspConfig['mpoThresholdDbSpl'] as num).toDouble(),
      dnn: DnnMetadata.fromJson(dspConfig['dnn'] as Map<String, dynamic>),
      nrLevel: dspConfig['nrLevel'] as int,
      tnrEnabled: dspConfig['tnrEnabled'] as bool,
      // Campos opcionales agregados en spec dsp-chain-optimization · Task 4.4.
      // Si el JSON proviene de una versión anterior que no los emite, caer a
      // los valores sentinela para preservar compatibilidad de lectura.
      preDnnLevelDb: dspConfig['preDnnLevelDb'] is num
          ? (dspConfig['preDnnLevelDb'] as num).toDouble()
          : -1.0,
      wdrcLevelSource: dspConfig['wdrcLevelSource'] as String? ?? 'local',
      device: DeviceMetadata.fromJson(json['device'] as Map<String, dynamic>),
      recordingTimestamp: json['recordingTimestamp'] as String,
      appVersion: json['appVersion'] as String,
      schemaVersion: json['schemaVersion'] as String,
    );
  }
}
