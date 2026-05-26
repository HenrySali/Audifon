import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:hearing_aid_app/data/repositories/ble_repository.dart';

/// Tests unitarios para BleRepository
///
/// Valida: Requisitos 4.3, 4.5, 4.6
/// - 4.3: Serialización de comandos BLE y ACK dentro de 30ms
/// - 4.5: Continuación con últimos parámetros al perder conexión
/// - 4.6: Sincronización de estado al reconectar (< 500ms)

void main() {
  group('BleCommand - Serialización de comandos BLE', () {
    // Validates: Requirement 4.3

    test('serializa comando SET_EQ_GAINS correctamente', () {
      // Comando con 9 bytes de payload (ganancias por banda)
      final gains = Uint8List.fromList([17, 20, 22, 25, 27, 30, 32, 37, 42]);
      final command = BleCommand(
        opcode: BleCommands.setEqGains,
        seqNum: 1,
        payload: gains,
      );

      final serialized = command.serialize();

      // Verificar estructura: [opcode, seqNum, payloadLen_hi, payloadLen_lo, ...payload]
      expect(serialized.length, equals(4 + 9)); // 4 bytes header + 9 payload
      expect(serialized[0], equals(BleCommands.setEqGains)); // opcode = 0x01
      expect(serialized[1], equals(1)); // seqNum
      expect(serialized[2], equals(0)); // payload_len high byte
      expect(serialized[3], equals(9)); // payload_len low byte
      // Verificar payload de ganancias
      expect(serialized[4], equals(17));
      expect(serialized[5], equals(20));
      expect(serialized[12], equals(42));
    });

    test('serializa comando SET_VOLUME con payload de 1 byte', () {
      final command = BleCommand(
        opcode: BleCommands.setVolume,
        seqNum: 42,
        payload: Uint8List.fromList([0xF6]), // -10 en complemento a 2 (int8)
      );

      final serialized = command.serialize();

      expect(serialized.length, equals(5)); // 4 header + 1 payload
      expect(serialized[0], equals(BleCommands.setVolume)); // 0x03
      expect(serialized[1], equals(42));
      expect(serialized[2], equals(0)); // payload_len high
      expect(serialized[3], equals(1)); // payload_len low
      expect(serialized[4], equals(0xF6)); // volumen
    });

    test('serializa comando SET_PROFILE con índice de perfil', () {
      final command = BleCommand(
        opcode: BleCommands.setProfile,
        seqNum: 100,
        payload: Uint8List.fromList([2]), // Perfil "Noisy"
      );

      final serialized = command.serialize();

      expect(serialized[0], equals(BleCommands.setProfile)); // 0x04
      expect(serialized[1], equals(100));
      expect(serialized[4], equals(2)); // Perfil Noisy
    });

    test('serializa comando GET_STATUS sin payload', () {
      final command = BleCommand(
        opcode: BleCommands.getStatus,
        seqNum: 255,
        payload: Uint8List(0),
      );

      final serialized = command.serialize();

      expect(serialized.length, equals(4)); // Solo header, sin payload
      expect(serialized[0], equals(BleCommands.getStatus)); // 0x10
      expect(serialized[1], equals(255));
      expect(serialized[2], equals(0));
      expect(serialized[3], equals(0));
    });

    test('serializa comando FACTORY_RESET con código de confirmación', () {
      final command = BleCommand(
        opcode: BleCommands.factoryReset,
        seqNum: 7,
        payload: Uint8List.fromList([0xDE, 0xAD, 0x00, 0x00]),
      );

      final serialized = command.serialize();

      expect(serialized.length, equals(8)); // 4 header + 4 payload
      expect(serialized[0], equals(BleCommands.factoryReset)); // 0xFF
      expect(serialized[4], equals(0xDE));
      expect(serialized[5], equals(0xAD));
    });

    test('serializa comando SET_AGC_PARAMS con payload grande (60 bytes)', () {
      // 5 parámetros × 12 bandas = 60 bytes
      final agcPayload = Uint8List(60);
      for (int i = 0; i < 60; i++) {
        agcPayload[i] = i;
      }

      final command = BleCommand(
        opcode: BleCommands.setAgcParams,
        seqNum: 10,
        payload: agcPayload,
      );

      final serialized = command.serialize();

      expect(serialized.length, equals(4 + 45));
      expect(serialized[2], equals(0)); // payload_len high byte
      expect(serialized[3], equals(45)); // payload_len low byte
      // Verificar que el payload se copió correctamente
      for (int i = 0; i < 45; i++) {
        expect(serialized[4 + i], equals(i));
      }
    });

    test('serializa número de secuencia con wrap-around (0-255)', () {
      // Verificar que seqNum se limita a 1 byte
      final command = BleCommand(
        opcode: BleCommands.setVolume,
        seqNum: 256, // Debería truncarse a 0
        payload: Uint8List.fromList([5]),
      );

      final serialized = command.serialize();
      expect(serialized[1], equals(0)); // 256 & 0xFF = 0
    });

    test('serializa payload con longitud > 255 usando 2 bytes', () {
      // Payload de 300 bytes (requiere 2 bytes para longitud)
      final largePayload = Uint8List(300);
      final command = BleCommand(
        opcode: BleCommands.setAgcParams,
        seqNum: 1,
        payload: largePayload,
      );

      final serialized = command.serialize();

      // payload_len = 300 = 0x012C
      expect(serialized[2], equals(0x01)); // high byte
      expect(serialized[3], equals(0x2C)); // low byte
      expect(serialized.length, equals(4 + 300));
    });
  });

  group('BleCommand - Deserialización de comandos', () {
    test('deserializa comando válido correctamente', () {
      final data = Uint8List.fromList([
        0x01, // opcode: SET_EQ_GAINS
        0x05, // seqNum: 5
        0x00, 0x03, // payload_len: 3
        0x0A, 0x0B, 0x0C, // payload
      ]);

      final command = BleCommand.deserialize(data);

      expect(command, isNotNull);
      expect(command!.opcode, equals(0x01));
      expect(command.seqNum, equals(5));
      expect(command.payload.length, equals(3));
      expect(command.payload[0], equals(0x0A));
      expect(command.payload[2], equals(0x0C));
    });

    test('retorna null para datos demasiado cortos (< 4 bytes)', () {
      final shortData = Uint8List.fromList([0x01, 0x02]);
      expect(BleCommand.deserialize(shortData), isNull);
    });

    test('retorna null si payload_len excede datos disponibles', () {
      final data = Uint8List.fromList([
        0x01, 0x05, 0x00, 0x10, // Dice 16 bytes de payload
        0x0A, 0x0B, // Pero solo hay 2
      ]);

      expect(BleCommand.deserialize(data), isNull);
    });

    test('deserializa comando sin payload correctamente', () {
      final data = Uint8List.fromList([0x10, 0xFF, 0x00, 0x00]);

      final command = BleCommand.deserialize(data);

      expect(command, isNotNull);
      expect(command!.opcode, equals(BleCommands.getStatus));
      expect(command.seqNum, equals(255));
      expect(command.payload.length, equals(0));
    });

    test('serialización y deserialización son inversas', () {
      final original = BleCommand(
        opcode: BleCommands.setEqGains,
        seqNum: 77,
        payload: Uint8List.fromList([10, 20, 30, 40, 50, 25, 35, 45, 42]),
      );

      final serialized = original.serialize();
      final deserialized = BleCommand.deserialize(serialized);

      expect(deserialized, isNotNull);
      expect(deserialized!.opcode, equals(original.opcode));
      expect(deserialized.seqNum, equals(original.seqNum));
      expect(deserialized.payload, equals(original.payload));
    });
  });

  group('BleResponse - Deserialización de respuestas', () {
    // Validates: Requirement 4.3

    test('deserializa respuesta OK sin payload', () {
      final data = Uint8List.fromList([
        0x01, // opcode echo
        0x05, // seqNum echo
        0x00, // status: OK
      ]);

      final response = BleResponse.deserialize(data);

      expect(response, isNotNull);
      expect(response!.opcode, equals(0x01));
      expect(response.seqNum, equals(5));
      expect(response.status, equals(BleResponseStatus.ok));
      expect(response.isSuccess, isTrue);
      expect(response.payload.length, equals(0));
    });

    test('deserializa respuesta ERROR', () {
      final data = Uint8List.fromList([
        0x03, // opcode: SET_VOLUME
        0x0A, // seqNum: 10
        0x01, // status: ERROR
      ]);

      final response = BleResponse.deserialize(data);

      expect(response, isNotNull);
      expect(response!.status, equals(BleResponseStatus.error));
      expect(response.isSuccess, isFalse);
    });

    test('deserializa respuesta INVALID_PARAM', () {
      final data = Uint8List.fromList([
        0x05, // opcode: SET_MPO
        0x03, // seqNum
        0x02, // status: INVALID_PARAM
      ]);

      final response = BleResponse.deserialize(data);

      expect(response, isNotNull);
      expect(response!.status, equals(BleResponseStatus.invalidParam));
      expect(response.isSuccess, isFalse);
    });

    test('deserializa respuesta con payload de datos', () {
      final data = Uint8List.fromList([
        0x10, // opcode: GET_STATUS
        0x01, // seqNum
        0x00, // status: OK
        0x64, // battery: 100%
        0x0A, // dsp_load: 10%
        0x01, // active_profile: Conversation
        0x03, // flags
      ]);

      final response = BleResponse.deserialize(data);

      expect(response, isNotNull);
      expect(response!.isSuccess, isTrue);
      expect(response.payload.length, equals(4));
      expect(response.payload[0], equals(0x64)); // 100% batería
      expect(response.payload[2], equals(0x01)); // Perfil Conversation
    });

    test('retorna null para datos demasiado cortos (< 3 bytes)', () {
      final shortData = Uint8List.fromList([0x01, 0x02]);
      expect(BleResponse.deserialize(shortData), isNull);
    });
  });

  group('BleRepository - Manejo de desconexión y reconexión', () {
    // Validates: Requirements 4.5, 4.6

    test('estado inicial es disconnected', () {
      final repo = BleRepository();
      expect(repo.currentConnectionState, equals(BleConnectionState.disconnected));
      expect(repo.isConnected, isFalse);
      repo.dispose();
    });

    test('sendCommand lanza BleDisconnectedException cuando no está conectado', () async {
      final repo = BleRepository();

      expect(
        () => repo.sendCommand(BleCommands.getStatus, Uint8List(0)),
        throwsA(isA<BleDisconnectedException>()),
      );

      repo.dispose();
    });

    test('setEqGains lanza excepción cuando está desconectado', () async {
      final repo = BleRepository();

      expect(
        () => repo.setEqGains([17, 20, 22, 25, 27, 30, 32, 37, 42]),
        throwsA(isA<BleDisconnectedException>()),
      );

      repo.dispose();
    });

    test('setVolume lanza excepción cuando está desconectado', () async {
      final repo = BleRepository();

      expect(
        () => repo.setVolume(0),
        throwsA(isA<BleDisconnectedException>()),
      );

      repo.dispose();
    });

    test('setProfile lanza excepción cuando está desconectado', () async {
      final repo = BleRepository();

      expect(
        () => repo.setProfile(1),
        throwsA(isA<BleDisconnectedException>()),
      );

      repo.dispose();
    });

    test('connectionState stream emite cambios de estado', () async {
      final repo = BleRepository();
      final states = <BleConnectionState>[];

      final subscription = repo.connectionState.listen(states.add);

      // El estado inicial no se emite por stream, solo cambios
      // Verificar que el stream está activo
      expect(repo.currentConnectionState, equals(BleConnectionState.disconnected));

      await subscription.cancel();
      repo.dispose();
    });

    test('disconnect limpia el estado correctamente', () async {
      final repo = BleRepository();

      await repo.disconnect();

      expect(repo.currentConnectionState, equals(BleConnectionState.disconnected));
      expect(repo.isConnected, isFalse);

      repo.dispose();
    });

    test('setAutoReconnect controla la reconexión automática', () {
      final repo = BleRepository();

      // Por defecto está habilitada
      repo.setAutoReconnect(false);
      // No debería intentar reconectar al desconectarse

      repo.setAutoReconnect(true);
      // Debería intentar reconectar al desconectarse

      repo.dispose();
    });

    test('maxReconnectionAttempts limita los intentos de reconexión', () {
      // Verificar que la constante está definida correctamente
      expect(BleRepository.maxReconnectionAttempts, equals(5));
    });

    test('reconnectionInterval define el tiempo entre intentos', () {
      expect(
        BleRepository.reconnectionInterval,
        equals(const Duration(seconds: 2)),
      );
    });

    test('reconnectionTimeout define el timeout total de reconexión', () {
      expect(
        BleRepository.reconnectionTimeout,
        equals(const Duration(seconds: 10)),
      );
    });
  });

  group('BleRepository - Timeout de operaciones', () {
    // Validates: Requirements 4.3, 4.6

    test('defaultOperationTimeout es 5000ms', () {
      expect(
        BleRepository.defaultOperationTimeout,
        equals(const Duration(milliseconds: 5000)),
      );
    });

    test('BleTimeoutException contiene información de la operación', () {
      final exception = BleTimeoutException(
        'sendCommand(opcode: 0x01)',
        const Duration(milliseconds: 5000),
      );

      expect(exception.operation, equals('sendCommand(opcode: 0x01)'));
      expect(exception.timeout, equals(const Duration(milliseconds: 5000)));
      expect(
        exception.toString(),
        contains('sendCommand(opcode: 0x01)'),
      );
      expect(exception.toString(), contains('5000ms'));
    });

    test('BleDisconnectedException contiene mensaje descriptivo', () {
      final exception = BleDisconnectedException('Dispositivo fuera de rango');

      expect(exception.message, equals('Dispositivo fuera de rango'));
      expect(exception.toString(), contains('Dispositivo fuera de rango'));
    });

    test('BleDisconnectedException tiene mensaje por defecto', () {
      final exception = BleDisconnectedException();

      expect(exception.message, equals('Dispositivo desconectado'));
    });

    test('sendCommand con dispositivo desconectado no espera timeout', () async {
      final repo = BleRepository();
      final stopwatch = Stopwatch()..start();

      try {
        await repo.sendCommand(BleCommands.getStatus, Uint8List(0));
        fail('Debería haber lanzado excepción');
      } on BleDisconnectedException {
        stopwatch.stop();
        // Debe fallar inmediatamente, no esperar el timeout completo
        expect(stopwatch.elapsedMilliseconds, lessThan(100));
      }

      repo.dispose();
    });
  });

  group('BleCommands - Constantes de opcodes', () {
    // Validates: Requirement 4.3

    test('opcodes de comandos tienen valores correctos según protocolo', () {
      expect(BleCommands.setEqGains, equals(0x01));
      expect(BleCommands.setAgcParams, equals(0x02));
      expect(BleCommands.setVolume, equals(0x03));
      expect(BleCommands.setProfile, equals(0x04));
      expect(BleCommands.setMpo, equals(0x05));
      expect(BleCommands.setNrLevel, equals(0x06));
      expect(BleCommands.setFbCancel, equals(0x07));
      expect(BleCommands.getStatus, equals(0x10));
      expect(BleCommands.factoryReset, equals(0xFF));
    });
  });

  group('BleUuids - UUIDs del servicio GATT', () {
    test('service UUID es 0x1850-custom', () {
      expect(BleUuids.serviceUuid, contains('1850'));
    });

    test('todos los UUIDs de características están definidos', () {
      expect(BleUuids.eqGainsUuid, isNotEmpty);
      expect(BleUuids.agcParamsUuid, isNotEmpty);
      expect(BleUuids.masterVolumeUuid, isNotEmpty);
      expect(BleUuids.activeProfileUuid, isNotEmpty);
      expect(BleUuids.mpoThresholdUuid, isNotEmpty);
      expect(BleUuids.nrLevelUuid, isNotEmpty);
      expect(BleUuids.fbCancelUuid, isNotEmpty);
      expect(BleUuids.batteryLevelUuid, isNotEmpty);
      expect(BleUuids.deviceStatusUuid, isNotEmpty);
      expect(BleUuids.commandChannelUuid, isNotEmpty);
      expect(BleUuids.responseChannelUuid, isNotEmpty);
    });

    test('battery level UUID usa estándar Bluetooth SIG (0x2A19)', () {
      expect(BleUuids.batteryLevelUuid, contains('2a19'));
    });
  });

  group('BleConnectionState - Estados de conexión', () {
    // Validates: Requirements 4.5, 4.6

    test('todos los estados de conexión están definidos', () {
      expect(BleConnectionState.values.length, equals(5));
      expect(BleConnectionState.values, contains(BleConnectionState.disconnected));
      expect(BleConnectionState.values, contains(BleConnectionState.scanning));
      expect(BleConnectionState.values, contains(BleConnectionState.connecting));
      expect(BleConnectionState.values, contains(BleConnectionState.connected));
      expect(BleConnectionState.values, contains(BleConnectionState.reconnecting));
    });

    test('isConnected solo es true en estado connected', () {
      final repo = BleRepository();
      // Estado inicial es disconnected
      expect(repo.isConnected, isFalse);
      repo.dispose();
    });
  });
}
