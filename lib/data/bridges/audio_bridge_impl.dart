import 'dart:async';

import 'package:flutter/services.dart';

import '../../domain/entities/audio_config.dart';
import '../../domain/entities/calibration_audit_record.dart';
import '../../domain/entities/calibration_data.dart';
import '../../domain/entities/wdrc_params.dart';
import '../services/calibration_audit_repository.dart';
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
    if (gains.length != 12) {
      throw ArgumentError.value(
        gains.length,
        'gains.length',
        'EQ requires exactly 12 bands, got ${gains.length}',
      );
    }
    await _methodChannel.invokeMethod<void>('updateEqGains', {
      'gains': gains,
    });
  }

  @override
  Future<void> updateVolume(double volumeDb) async {
    if (volumeDb < -20.0 || volumeDb > 10.0) {
      throw ArgumentError.value(
        volumeDb,
        'volumeDb',
        'Volume must be in range [-20.0, +10.0] dB, got $volumeDb',
      );
    }
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
    if (level < 0 || level > 3) {
      throw ArgumentError.value(
        level,
        'level',
        'NR level must be in range [0, 3], got $level',
      );
    }
    await _methodChannel.invokeMethod<void>('updateNrLevel', {
      'level': level,
    });
  }

  @override
  Future<void> updateTnrEnabled(bool enabled) async {
    await _methodChannel.invokeMethod<void>('updateTnrEnabled', {
      'enabled': enabled,
    });
  }

  @override
  Future<void> setMpoThresholdDbSpl(double thresholdDbSpl) async {
    if (thresholdDbSpl.isNaN || thresholdDbSpl.isInfinite) {
      throw ArgumentError(
        'MPO threshold debe ser un número finito, recibido: $thresholdDbSpl',
      );
    }
    if (thresholdDbSpl < 80.0 || thresholdDbSpl > 132.0) {
      throw ArgumentError(
        'MPO threshold fuera de rango [80.0, 132.0] dB SPL, '
        'recibido: $thresholdDbSpl',
      );
    }
    await _methodChannel.invokeMethod<void>('setMpoThresholdDbSpl', {
      'thresholdDbSpl': thresholdDbSpl,
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

  /// Auto-injected `CalibrationAuditRepository` para persistir audit
  /// trail al recibir resultados positivos del handler nativo. Si es
  /// `null` (default), la persistencia se hace abriendo el box bajo
  /// demanda. Para tests inyectables, ver constructor `withChannels`.
  CalibrationAuditRepository? _auditRepoOverride;

  /// Permite a los tests inyectar un repositorio de audit trail
  /// preconstruido sobre un Hive box temporal.
  set auditRepository(CalibrationAuditRepository repo) {
    _auditRepoOverride = repo;
  }

  Future<CalibrationAuditRepository> _auditRepo() async {
    if (_auditRepoOverride != null) return _auditRepoOverride!;
    final box = await CalibrationAuditRepository.openBox();
    return CalibrationAuditRepository(box);
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

    final calibratedAt = DateTime.fromMillisecondsSinceEpoch(
      result['calibratedAtMs'] as int,
      isUtc: true,
    );
    // Audit trail: construir record con SHA-256 verificable y persistirlo
    // antes de retornar al caller. Cualquier falla de persistencia
    // propaga PlatformException sin descartar el offset medido.
    final repo = await _auditRepo();
    final base = <String, dynamic>{
      'type': 'mic',
      'timestampUtc': calibratedAt.toIso8601String(),
      'referenceSplLevel': (result['referenceSplLevel'] as num?)?.toDouble() ??
          referenceSplLevel,
      'rmsAvgDbfs': (result['rmsAvgDbfs'] as num?)?.toDouble() ?? 0.0,
      'rmsStdDbfs': (result['rmsStdDbfs'] as num?)?.toDouble() ?? 0.0,
      'micOffsetDb': (result['splOffset'] as num).toDouble(),
      'calibratorModel': (result['calibratorModel'] as String?) ?? 'unknown',
      'operatorId': (result['operatorId'] as String?) ?? 'unknown',
      'deviceModel': (result['deviceModel'] as String?) ?? 'unknown',
      'expectedFreqHz':
          (result['expectedFreqHz'] as num?)?.toDouble() ?? 1000.0,
      'windowsUsed': (result['windowsUsed'] as num?)?.toInt() ?? 0,
    };
    final hash = CalibrationAuditRepository.computeSha256(base);
    final audit = MicCalibrationAudit(
      timestampUtc: calibratedAt,
      referenceSplLevel: (base['referenceSplLevel'] as num).toDouble(),
      rmsAvgDbfs: (base['rmsAvgDbfs'] as num).toDouble(),
      rmsStdDbfs: (base['rmsStdDbfs'] as num).toDouble(),
      micOffsetDb: (base['micOffsetDb'] as num).toDouble(),
      calibratorModel: base['calibratorModel'] as String,
      operatorId: base['operatorId'] as String,
      deviceModel: base['deviceModel'] as String,
      expectedFreqHz: (base['expectedFreqHz'] as num).toDouble(),
      windowsUsed: (base['windowsUsed'] as num).toInt(),
      sha256: hash,
    );
    try {
      await repo.appendMicCalibration(audit);
    } catch (e) {
      throw PlatformException(
        code: 'PERSIST_FAILED',
        message: 'No se pudo persistir el audit de calibración mic: $e',
      );
    }

    return MicCalibrationResult(
      splOffset: (result['splOffset'] as num).toDouble(),
      confidenceLevel: (result['confidenceLevel'] as num).toDouble(),
      method: result['method'] as String,
      calibratedAt: calibratedAt,
      deviceModel: result['deviceModel'] as String,
    );
  }

  @override
  Future<HeadphoneCalibrationResult> calibrateHeadphones({
    required String headphoneId,
  }) async {
    // Cargar el offset persistido del mic; el handler nativo lo
    // necesita como argumento para calcular `target_dbspl`.
    final repo = await _auditRepo();
    final latestMic = await repo.getLatestMic();
    if (latestMic == null) {
      throw PlatformException(
        code: 'MIC_NOT_CALIBRATED',
        message:
            'El micrófono no está calibrado. Calibrá el micrófono primero.',
      );
    }
    final result = await _methodChannel
        .invokeMapMethod<String, dynamic>('calibrateHeadphones', {
      'headphoneId': headphoneId,
      'micOffsetDb': latestMic.micOffsetDb,
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

    final calibratedAt = DateTime.fromMillisecondsSinceEpoch(
      result['calibratedAtMs'] as int,
      isUtc: true,
    );

    // Audit trail HP.
    final freqsList = (result['frequenciesHz'] as List?)
            ?.map((e) => (e as num).toInt())
            .toList() ??
        frequencyResponse.keys.toList()
      ..sort();
    final splList = (result['splDbspl'] as List?)
            ?.map((e) => (e as num).toDouble())
            .toList() ??
        freqsList.map((f) => frequencyResponse[f] ?? 0.0).toList();
    final hpOffsetList = (result['hpOffsetDb'] as List?)
            ?.map((e) => (e as num).toDouble())
            .toList() ??
        freqsList.map((f) => -(compensation[f] ?? 0.0)).toList();

    final hpBase = <String, dynamic>{
      'type': 'hp',
      'timestampUtc': calibratedAt.toIso8601String(),
      'headphoneId': headphoneId,
      'headphoneName': (result['headphoneName'] as String?) ?? headphoneId,
      'couplerModel': (result['couplerModel'] as String?) ?? 'HA-2',
      'operatorId': (result['operatorId'] as String?) ?? 'unknown',
      'deviceModel': (result['deviceModel'] as String?) ?? 'unknown',
      'micOffsetDb':
          (result['micOffsetDb'] as num?)?.toDouble() ?? latestMic.micOffsetDb,
      'targetDbspl': (result['targetDbspl'] as num?)?.toDouble() ?? 0.0,
      'frequenciesHz': freqsList,
      'splDbspl': splList,
      'hpOffsetDb': hpOffsetList,
    };
    final hpHash = CalibrationAuditRepository.computeSha256(hpBase);
    final hpAudit = HpCalibrationAudit(
      timestampUtc: calibratedAt,
      headphoneId: headphoneId,
      headphoneName: hpBase['headphoneName'] as String,
      couplerModel: hpBase['couplerModel'] as String,
      operatorId: hpBase['operatorId'] as String,
      deviceModel: hpBase['deviceModel'] as String,
      micOffsetDb: (hpBase['micOffsetDb'] as num).toDouble(),
      targetDbspl: (hpBase['targetDbspl'] as num).toDouble(),
      frequenciesHz: freqsList,
      splDbspl: splList,
      hpOffsetDb: hpOffsetList,
      sha256: hpHash,
    );
    try {
      await repo.appendHpCalibration(hpAudit);
    } catch (e) {
      throw PlatformException(
        code: 'PERSIST_FAILED',
        message: 'No se pudo persistir el audit de calibración hp: $e',
      );
    }

    return HeadphoneCalibrationResult(
      frequencyResponse: frequencyResponse,
      compensation: compensation,
      headphoneId: result['headphoneId'] as String,
      headphoneName: result['headphoneName'] as String,
      calibratedAt: calibratedAt,
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
