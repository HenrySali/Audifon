import 'dart:async';

import 'package:flutter/services.dart';

import '../../domain/entities/audio_config.dart';
import '../../domain/entities/calibration_data.dart';
import '../../domain/entities/wdrc_params.dart';
import 'audio_bridge.dart';

/// Implementación de [AudioBridge] usando Platform Channels de Flutter.
///
/// Usa [MethodChannel] para enviar comandos al motor de audio nativo
/// y [EventChannel] para recibir streams de nivel de entrada y estado.
///
/// Canales:
/// - MethodChannel: 'com.psk.hearing_aid/audio' (comandos)
/// - EventChannel: 'com.psk.hearing_aid/level' (nivel de entrada ~10 Hz)
/// - EventChannel: 'com.psk.hearing_aid/state' (estado del engine)
///
/// Requisitos: 2.1, 5.4
class AudioBridgeImpl implements AudioBridge {
  /// Canal de métodos para enviar comandos al motor nativo.
  final MethodChannel _methodChannel;

  /// Canal de eventos para recibir nivel de entrada del micrófono.
  final EventChannel _levelEventChannel;

  /// Canal de eventos para recibir estado del motor de audio.
  final EventChannel _stateEventChannel;

  /// Stream cacheado de nivel de entrada.
  Stream<double>? _inputLevelStreamCache;

  /// Stream cacheado de estado del engine.
  Stream<AudioEngineState>? _stateStreamCache;

  /// Crea una instancia con los canales de plataforma por defecto.
  AudioBridgeImpl()
      : _methodChannel =
            const MethodChannel('com.psk.hearing_aid/audio'),
        _levelEventChannel =
            const EventChannel('com.psk.hearing_aid/level'),
        _stateEventChannel =
            const EventChannel('com.psk.hearing_aid/state');

  /// Constructor para testing con canales inyectados.
  AudioBridgeImpl.withChannels({
    required MethodChannel methodChannel,
    required EventChannel levelEventChannel,
    required EventChannel stateEventChannel,
  })  : _methodChannel = methodChannel,
        _levelEventChannel = levelEventChannel,
        _stateEventChannel = stateEventChannel;

  @override
  Future<void> startAudio(AudioConfig config) async {
    await _methodChannel.invokeMethod<void>('startAudio', {
      'sampleRate': config.sampleRate,
      'bufferSize': config.bufferSize,
      'channels': config.channels,
      'bitsPerSample': config.bitsPerSample,
      'eqGains': config.eqGains,
      'volumeDb': config.volumeDb,
      'nrLevel': config.nrLevel,
      'mpoThresholdDbSpl': config.mpoThresholdDbSpl,
      'expansionKnee': config.wdrcParams.expansionKnee,
      'expansionRatio': config.wdrcParams.expansionRatio,
      'compressionKnee': config.wdrcParams.compressionKnee,
      'compressionRatio': config.wdrcParams.compressionRatio,
      'attackMs': config.wdrcParams.attackMs,
      'releaseMs': config.wdrcParams.releaseMs,
    });
  }

  @override
  Future<void> stopAudio() async {
    await _methodChannel.invokeMethod<void>('stopAudio');
  }

  @override
  Future<void> updateEqGains(List<double> gains) async {
    assert(gains.length == 12, 'EQ gains must have exactly 12 values');
    await _methodChannel.invokeMethod<void>('updateEqGains', {
      'gains': gains,
    });
  }

  @override
  Future<void> updateVolume(double volumeDb) async {
    assert(
      volumeDb >= -20.0 && volumeDb <= 10.0,
      'Volume must be in range [-20, +10] dB',
    );
    await _methodChannel.invokeMethod<void>('updateVolume', {
      'volumeDb': volumeDb,
    });
  }

  @override
  Future<void> updateWdrcParams(WdrcParams params) async {
    await _methodChannel.invokeMethod<void>('updateWdrcParams', {
      'expansionKnee': params.expansionKnee,
      'expansionRatio': params.expansionRatio,
      'compressionKnee': params.compressionKnee,
      'compressionRatio': params.compressionRatio,
      'attackMs': params.attackMs,
      'releaseMs': params.releaseMs,
    });
  }

  @override
  Future<void> updateNrLevel(int level) async {
    assert(level >= 0 && level <= 3, 'NR level must be 0-3');
    await _methodChannel.invokeMethod<void>('updateNrLevel', {
      'level': level,
    });
  }

  @override
  Stream<double> get inputLevelStream {
    _inputLevelStreamCache ??= _levelEventChannel
        .receiveBroadcastStream()
        .map<double>((dynamic event) => (event as num).toDouble());
    return _inputLevelStreamCache!;
  }

  @override
  Stream<AudioEngineState> get stateStream {
    _stateStreamCache ??= _stateEventChannel
        .receiveBroadcastStream()
        .map<AudioEngineState>((dynamic event) => _parseState(event));
    return _stateStreamCache!;
  }

  @override
  Future<MicCalibrationResult> calibrateMicrophone({
    required double referenceSplLevel,
  }) async {
    final result = await _methodChannel
        .invokeMapMethod<String, dynamic>('calibrateMicrophone', {
      'referenceSplLevel': referenceSplLevel,
    });

    if (result == null) {
      throw PlatformException(
        code: 'CALIBRATION_FAILED',
        message: 'Microphone calibration returned null',
      );
    }

    return MicCalibrationResult(
      splOffset: (result['splOffset'] as num).toDouble(),
      confidenceLevel: (result['confidenceLevel'] as num).toDouble(),
      method: result['method'] as String,
      calibratedAt: DateTime.fromMillisecondsSinceEpoch(
        result['calibratedAtMs'] as int,
      ),
      deviceModel: result['deviceModel'] as String,
    );
  }

  @override
  Future<HeadphoneCalibrationResult> calibrateHeadphones({
    required String headphoneId,
  }) async {
    final result = await _methodChannel
        .invokeMapMethod<String, dynamic>('calibrateHeadphones', {
      'headphoneId': headphoneId,
    });

    if (result == null) {
      throw PlatformException(
        code: 'CALIBRATION_FAILED',
        message: 'Headphone calibration returned null',
      );
    }

    final frequencyResponse = (result['frequencyResponse'] as Map)
        .map((key, value) => MapEntry(
              int.parse(key.toString()),
              (value as num).toDouble(),
            ));

    final compensation = (result['compensation'] as Map).map((key, value) =>
        MapEntry(int.parse(key.toString()), (value as num).toDouble()));

    return HeadphoneCalibrationResult(
      frequencyResponse: frequencyResponse,
      compensation: compensation,
      headphoneId: result['headphoneId'] as String,
      headphoneName: result['headphoneName'] as String,
      calibratedAt: DateTime.fromMillisecondsSinceEpoch(
        result['calibratedAtMs'] as int,
      ),
      isBluetooth: result['isBluetooth'] as bool,
    );
  }

  @override
  Future<void> applyCalibration(CalibrationData calibration) async {
    final micOffset = calibration.effectiveSplOffset;

    // Send all headphone calibrations so native side can switch
    final headphoneCompensations = <String, Map<String, double>>{};
    for (final entry in calibration.headphoneCalibrations.entries) {
      headphoneCompensations[entry.key] = entry.value.compensation
          .map((key, value) => MapEntry(key.toString(), value));
    }

    await _methodChannel.invokeMethod<void>('applyCalibration', {
      'micSplOffset': micOffset,
      'headphoneCompensations': headphoneCompensations,
    });
  }

  /// Obtiene información de diagnóstico del engine nativo.
  /// Útil para debugging sin ADB.
  Future<String> getDebugInfo() async {
    final result = await _methodChannel.invokeMethod<String>('getDebugInfo');
    return result ?? 'No debug info available';
  }

  @override
  Future<Map<String, dynamic>> getDeviceInfo() async {
    final result = await _methodChannel
        .invokeMapMethod<String, dynamic>('getDeviceInfo');
    return result ?? <String, dynamic>{
      'inputDeviceName': 'Desconocido',
      'outputDeviceName': 'Desconocido',
      'bluetoothConnected': false,
      'bluetoothName': '',
      'bluetoothIsA2dp': false,
    };
  }

  /// Convierte un valor dinámico del EventChannel a [AudioEngineState].
  AudioEngineState _parseState(dynamic event) {
    if (event is int) {
      return AudioEngineState.values[event.clamp(0, AudioEngineState.values.length - 1)];
    }
    if (event is String) {
      switch (event) {
        case 'idle':
          return AudioEngineState.idle;
        case 'starting':
          return AudioEngineState.starting;
        case 'active':
          return AudioEngineState.active;
        case 'paused':
          return AudioEngineState.paused;
        case 'error':
          return AudioEngineState.error;
        default:
          return AudioEngineState.idle;
      }
    }
    return AudioEngineState.idle;
  }
}
