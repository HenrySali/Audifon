import 'dart:async';
import 'dart:typed_data';

import 'ble_repository.dart';
import '../serializers/calibration_serializer.dart';

/// Opcodes de calibración BLE (deben coincidir con firmware ble_types.h)
class CalibCommands {
  static const int triggerManual = 0x20;
  static const int getStatus = 0x21;
  static const int getLastResult = 0x22;
  static const int getHistory = 0x23;
  static const int getBaseline = 0x24;
  static const int setInterval = 0x25;
}

/// Opcodes de notificación de calibración
class CalibNotifications {
  static const int alert = 0x30;
  static const int progress = 0x31;
  static const int complete = 0x32;
}

/// Estado del engine de calibración
enum CalibrationEngineState {
  idle,
  measuring,
}

/// Alerta de calibración recibida del dispositivo
class CalibrationAlert {
  final int alertType; // 1=moderate, 2=severe, 3=under_compensated
  final double degradationIndex;
  final int affectedBands;

  CalibrationAlert({
    required this.alertType,
    required this.degradationIndex,
    required this.affectedBands,
  });

  bool get isSevere => alertType == 2;
  bool get isModerate => alertType == 1;
  bool get isUnderCompensated => alertType == 3;

  String get message {
    switch (alertType) {
      case 1:
        return 'Degradación moderada detectada. Compensación automática aplicada.';
      case 2:
        return 'Degradación severa detectada. Se recomienda servicio profesional.';
      case 3:
        return 'Algunas bandas exceden el límite de compensación de 10 dB.';
      default:
        return 'Alerta de calibración.';
    }
  }
}

/// Progreso de medición de calibración
class CalibrationProgress {
  final int percentComplete;
  final int currentState;

  CalibrationProgress({
    required this.percentComplete,
    required this.currentState,
  });
}

/// Estado completo de calibración del dispositivo
class CalibrationStatus {
  final CalibrationEngineState engineState;
  final bool compensationActive;
  final double lastDegradationIndex;
  final DateTime? lastMeasurementTime;
  final int intervalHours;
  final bool baselineValid;
  final bool pendingAlert;

  CalibrationStatus({
    required this.engineState,
    required this.compensationActive,
    required this.lastDegradationIndex,
    required this.lastMeasurementTime,
    required this.intervalHours,
    required this.baselineValid,
    required this.pendingAlert,
  });
}

/// Repositorio de calibración — extiende BleRepository con comandos ANSI S3.22
///
/// Proporciona métodos de alto nivel para:
/// - Disparar calibración manual
/// - Consultar estado y resultados
/// - Obtener historial de mediciones
/// - Configurar intervalo de self-check
/// - Recibir alertas y progreso vía notificaciones BLE
///
/// Requirements: 6.1, 6.2, 5.4
class CalibrationRepository {
  final BleRepository _bleRepository;

  final StreamController<CalibrationAlert> _alertController =
      StreamController<CalibrationAlert>.broadcast();
  final StreamController<CalibrationProgress> _progressController =
      StreamController<CalibrationProgress>.broadcast();
  final StreamController<CalibrationMeasurement> _completeController =
      StreamController<CalibrationMeasurement>.broadcast();

  /// Stream de alertas de calibración
  Stream<CalibrationAlert> get alerts => _alertController.stream;

  /// Stream de progreso de medición
  Stream<CalibrationProgress> get progress => _progressController.stream;

  /// Stream de mediciones completadas
  Stream<CalibrationMeasurement> get completedMeasurements =>
      _completeController.stream;

  CalibrationRepository(this._bleRepository);

  /// Dispara una calibración manual.
  ///
  /// Requiere autenticación de audiólogo en la UI antes de llamar.
  /// Retorna true si el comando fue aceptado por el firmware.
  Future<bool> triggerManualCalibration() async {
    final response = await _bleRepository.sendCommand(
      CalibCommands.triggerManual,
      Uint8List(0),
    );
    return response.isSuccess;
  }

  /// Obtiene el estado actual de calibración del dispositivo.
  Future<CalibrationStatus> getCalibrationStatus() async {
    final response = await _bleRepository.sendCommand(
      CalibCommands.getStatus,
      Uint8List(0),
    );

    if (!response.isSuccess || response.payload.length < 12) {
      throw Exception('Failed to get calibration status');
    }

    final data = ByteData.sublistView(response.payload);
    return CalibrationStatus(
      engineState: data.getUint8(0) == 0
          ? CalibrationEngineState.idle
          : CalibrationEngineState.measuring,
      compensationActive: data.getUint8(1) == 1,
      lastDegradationIndex: data.getUint16(2, Endian.little) / 1000.0,
      lastMeasurementTime: data.getUint32(4, Endian.little) > 0
          ? DateTime.fromMillisecondsSinceEpoch(
              data.getUint32(4, Endian.little) * 1000)
          : null,
      intervalHours: data.getUint16(8, Endian.little),
      baselineValid: data.getUint8(10) == 1,
      pendingAlert: data.getUint8(11) == 1,
    );
  }

  /// Obtiene la última medición de calibración.
  Future<CalibrationMeasurement> getLastResult() async {
    final response = await _bleRepository.sendCommand(
      CalibCommands.getLastResult,
      Uint8List(0),
    );

    if (!response.isSuccess || response.payload.length < bleCalibMeasurementSize) {
      throw Exception('Failed to get last calibration result');
    }

    return CalibrationMeasurement.deserialize(
      Uint8List.fromList(response.payload.sublist(0, bleCalibMeasurementSize)),
    );
  }

  /// Obtiene el historial de mediciones (paginado, 5 por página).
  ///
  /// [page] es el número de página (0-indexed).
  /// Retorna una lista de mediciones y el total disponible.
  Future<({List<CalibrationMeasurement> measurements, int totalCount})>
      getHistory(int page) async {
    final response = await _bleRepository.sendCommand(
      CalibCommands.getHistory,
      Uint8List.fromList([page]),
    );

    if (!response.isSuccess || response.payload.length < 3) {
      throw Exception('Failed to get calibration history');
    }

    final totalCount = response.payload[1];
    final entriesInPage = response.payload[2];

    final measurements = <CalibrationMeasurement>[];
    int offset = 3;

    for (int i = 0; i < entriesInPage; i++) {
      if (offset + bleCalibMeasurementSize > response.payload.length) break;
      final chunk = Uint8List.fromList(
        response.payload.sublist(offset, offset + bleCalibMeasurementSize),
      );
      measurements.add(CalibrationMeasurement.deserialize(chunk));
      offset += bleCalibMeasurementSize;
    }

    return (measurements: measurements, totalCount: totalCount);
  }

  /// Obtiene la línea base de fábrica.
  Future<CalibrationMeasurement> getBaseline() async {
    final response = await _bleRepository.sendCommand(
      CalibCommands.getBaseline,
      Uint8List(0),
    );

    if (!response.isSuccess || response.payload.length < bleCalibMeasurementSize) {
      throw Exception('Failed to get factory baseline');
    }

    return CalibrationMeasurement.deserialize(
      Uint8List.fromList(response.payload.sublist(0, bleCalibMeasurementSize)),
    );
  }

  /// Configura el intervalo de self-check periódico.
  ///
  /// [hours] debe estar entre 1 y 168 (1 hora a 1 semana).
  Future<bool> setInterval(int hours) async {
    if (hours < 1 || hours > 168) {
      throw ArgumentError.value(
        hours,
        'hours',
        'El intervalo debe estar entre 1 y 168 horas (1 hora a 1 semana)',
      );
    }
    final payload = Uint8List(2);
    payload[0] = hours & 0xFF;
    payload[1] = (hours >> 8) & 0xFF;

    final response = await _bleRepository.sendCommand(
      CalibCommands.setInterval,
      payload,
    );
    return response.isSuccess;
  }

  /// Procesa una notificación BLE de calibración.
  ///
  /// Debe ser llamado por el listener de notificaciones BLE cuando
  /// se recibe un opcode en el rango 0x30–0x32.
  void handleNotification(int opcode, Uint8List data) {
    switch (opcode) {
      case CalibNotifications.alert:
        if (data.length >= 4) {
          final bd = ByteData.sublistView(data);
          _alertController.add(CalibrationAlert(
            alertType: bd.getUint8(0),
            degradationIndex: bd.getUint16(1, Endian.little) / 1000.0,
            affectedBands: bd.getUint8(3),
          ));
        }
        break;

      case CalibNotifications.progress:
        if (data.length >= 2) {
          _progressController.add(CalibrationProgress(
            percentComplete: data[0],
            currentState: data[1],
          ));
        }
        break;

      case CalibNotifications.complete:
        if (data.length >= bleCalibMeasurementSize) {
          try {
            final measurement = CalibrationMeasurement.deserialize(
              Uint8List.fromList(data.sublist(0, bleCalibMeasurementSize)),
            );
            _completeController.add(measurement);
          } catch (_) {
            // Ignore malformed notifications
          }
        }
        break;
    }
  }

  /// Libera recursos.
  void dispose() {
    _alertController.close();
    _progressController.close();
    _completeController.close();
  }
}
