import 'dart:async';
import 'dart:typed_data';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';

/// Opcodes de comandos BLE para comunicación con el audífono
class BleCommands {
  static const int setEqGains = 0x01;
  static const int setAgcParams = 0x02;
  static const int setVolume = 0x03;
  static const int setProfile = 0x04;
  static const int setMpo = 0x05;
  static const int setNrLevel = 0x06;
  static const int setFbCancel = 0x07;
  static const int getStatus = 0x10;
  static const int factoryReset = 0xFF;
}

/// Códigos de estado de respuesta BLE
class BleResponseStatus {
  static const int ok = 0x00;
  static const int error = 0x01;
  static const int invalidParam = 0x02;
}

/// UUID del servicio personalizado del audífono
class BleUuids {
  static const String serviceUuid = '00001850-0000-1000-8000-00805f9b34fb';
  static const String eqGainsUuid = '00002b01-0000-1000-8000-00805f9b34fb';
  static const String agcParamsUuid = '00002b02-0000-1000-8000-00805f9b34fb';
  static const String masterVolumeUuid = '00002b03-0000-1000-8000-00805f9b34fb';
  static const String activeProfileUuid = '00002b04-0000-1000-8000-00805f9b34fb';
  static const String mpoThresholdUuid = '00002b05-0000-1000-8000-00805f9b34fb';
  static const String nrLevelUuid = '00002b06-0000-1000-8000-00805f9b34fb';
  static const String fbCancelUuid = '00002b07-0000-1000-8000-00805f9b34fb';
  static const String batteryLevelUuid = '00002a19-0000-1000-8000-00805f9b34fb';
  static const String deviceStatusUuid = '00002b09-0000-1000-8000-00805f9b34fb';
  static const String commandChannelUuid = '00002b0a-0000-1000-8000-00805f9b34fb';
  static const String responseChannelUuid = '00002b0b-0000-1000-8000-00805f9b34fb';
}

/// Estructura de comando BLE serializado
class BleCommand {
  final int opcode;
  final int seqNum;
  final Uint8List payload;

  BleCommand({
    required this.opcode,
    required this.seqNum,
    required this.payload,
  });

  /// Serializa el comando a bytes para transmisión BLE
  Uint8List serialize() {
    final payloadLen = payload.length;
    final buffer = Uint8List(4 + payloadLen);
    buffer[0] = opcode & 0xFF;
    buffer[1] = seqNum & 0xFF;
    buffer[2] = (payloadLen >> 8) & 0xFF; // payload_len high byte
    buffer[3] = payloadLen & 0xFF; // payload_len low byte
    for (int i = 0; i < payloadLen; i++) {
      buffer[4 + i] = payload[i];
    }
    return buffer;
  }

  /// Deserializa bytes recibidos a un BleCommand
  static BleCommand? deserialize(Uint8List data) {
    if (data.length < 4) return null;
    final opcode = data[0];
    final seqNum = data[1];
    final payloadLen = (data[2] << 8) | data[3];
    if (data.length < 4 + payloadLen) return null;
    final payload = Uint8List.sublistView(data, 4, 4 + payloadLen);
    return BleCommand(opcode: opcode, seqNum: seqNum, payload: payload);
  }
}

/// Estructura de respuesta BLE deserializada
class BleResponse {
  final int opcode;
  final int seqNum;
  final int status;
  final Uint8List payload;

  BleResponse({
    required this.opcode,
    required this.seqNum,
    required this.status,
    required this.payload,
  });

  /// Deserializa bytes de respuesta del dispositivo
  static BleResponse? deserialize(Uint8List data) {
    if (data.length < 3) return null;
    final opcode = data[0];
    final seqNum = data[1];
    final status = data[2];
    final payload =
        data.length > 3 ? Uint8List.sublistView(data, 3) : Uint8List(0);
    return BleResponse(
      opcode: opcode,
      seqNum: seqNum,
      status: status,
      payload: payload,
    );
  }

  /// Indica si la respuesta fue exitosa
  bool get isSuccess => status == BleResponseStatus.ok;
}

/// Estado de conexión BLE
enum BleConnectionState {
  disconnected,
  scanning,
  connecting,
  connected,
  reconnecting,
}

/// Excepción para timeout de operaciones BLE
class BleTimeoutException implements Exception {
  final String operation;
  final Duration timeout;

  BleTimeoutException(this.operation, this.timeout);

  @override
  String toString() =>
      'BleTimeoutException: Operación "$operation" excedió timeout de ${timeout.inMilliseconds}ms';
}

/// Excepción para desconexión durante operación
class BleDisconnectedException implements Exception {
  final String message;
  BleDisconnectedException([this.message = 'Dispositivo desconectado']);

  @override
  String toString() => 'BleDisconnectedException: $message';
}

/// Repositorio BLE para comunicación con el audífono digital
///
/// Maneja escaneo, conexión, reconexión automática, y transmisión
/// de comandos al dispositivo con timeout y manejo de errores.
class BleRepository {
  final FlutterBluePlus _flutterBluePlus;

  /// Timeout por defecto para operaciones BLE (ms)
  static const Duration defaultOperationTimeout = Duration(milliseconds: 5000);

  /// Timeout para reconexión automática
  static const Duration reconnectionTimeout = Duration(seconds: 10);

  /// Intervalo entre intentos de reconexión
  static const Duration reconnectionInterval = Duration(seconds: 2);

  /// Máximo de intentos de reconexión
  static const int maxReconnectionAttempts = 5;

  BluetoothDevice? _connectedDevice;
  BluetoothCharacteristic? _commandCharacteristic;
  BluetoothCharacteristic? _responseCharacteristic;

  int _sequenceNumber = 0;
  BleConnectionState _connectionState = BleConnectionState.disconnected;
  bool _autoReconnectEnabled = true;
  int _reconnectionAttempts = 0;

  final StreamController<BleConnectionState> _connectionStateController =
      StreamController<BleConnectionState>.broadcast();
  final StreamController<BleResponse> _responseController =
      StreamController<BleResponse>.broadcast();
  final StreamController<int> _batteryLevelController =
      StreamController<int>.broadcast();

  StreamSubscription? _deviceStateSubscription;
  StreamSubscription? _responseSubscription;
  Timer? _reconnectionTimer;

  BleRepository({FlutterBluePlus? flutterBluePlus})
      : _flutterBluePlus = flutterBluePlus ?? FlutterBluePlus();

  /// Stream del estado de conexión
  Stream<BleConnectionState> get connectionState =>
      _connectionStateController.stream;

  /// Stream de nivel de batería
  Stream<int> get batteryLevel => _batteryLevelController.stream;

  /// Estado actual de conexión
  BleConnectionState get currentConnectionState => _connectionState;

  /// Indica si está conectado al dispositivo
  bool get isConnected => _connectionState == BleConnectionState.connected;

  /// Obtiene el siguiente número de secuencia (0-255)
  int get _nextSeqNum {
    _sequenceNumber = (_sequenceNumber + 1) % 256;
    return _sequenceNumber;
  }

  /// Actualiza el estado de conexión y notifica a los listeners
  void _updateConnectionState(BleConnectionState state) {
    _connectionState = state;
    _connectionStateController.add(state);
  }

  /// Escanea y conecta al dispositivo audífono
  ///
  /// Busca dispositivos con el Service UUID del audífono y se conecta
  /// al primero encontrado. Lanza [BleTimeoutException] si no encuentra
  /// dispositivo dentro del timeout.
  Future<void> scanAndConnect({
    Duration timeout = const Duration(seconds: 10),
  }) async {
    _updateConnectionState(BleConnectionState.scanning);

    try {
      BluetoothDevice? targetDevice;

      // Escanear dispositivos con el service UUID del audífono
      final scanSubscription = FlutterBluePlus.scanResults.listen((results) {
        for (final result in results) {
          if (result.advertisementData.serviceUuids
              .contains(Guid(BleUuids.serviceUuid))) {
            targetDevice = result.device;
          }
        }
      });

      await FlutterBluePlus.startScan(
        timeout: timeout,
        withServices: [Guid(BleUuids.serviceUuid)],
      );

      await scanSubscription.cancel();

      if (targetDevice == null) {
        _updateConnectionState(BleConnectionState.disconnected);
        throw BleTimeoutException('scanAndConnect', timeout);
      }

      await _connectToDevice(targetDevice!);
    } catch (e) {
      if (e is! BleTimeoutException) {
        _updateConnectionState(BleConnectionState.disconnected);
      }
      rethrow;
    }
  }

  /// Conecta a un dispositivo BLE específico
  Future<void> _connectToDevice(BluetoothDevice device) async {
    _updateConnectionState(BleConnectionState.connecting);

    try {
      await device.connect(
        timeout: defaultOperationTimeout,
        autoConnect: false,
      );

      _connectedDevice = device;

      // Descubrir servicios y configurar características
      await _discoverAndSetupServices(device);

      // Suscribirse a cambios de estado de conexión
      _deviceStateSubscription =
          device.connectionState.listen(_handleDeviceStateChange);

      _reconnectionAttempts = 0;
      _updateConnectionState(BleConnectionState.connected);
    } catch (e) {
      _updateConnectionState(BleConnectionState.disconnected);
      rethrow;
    }
  }

  /// Descubre servicios GATT y configura las características necesarias
  Future<void> _discoverAndSetupServices(BluetoothDevice device) async {
    final services = await device.discoverServices();

    for (final service in services) {
      if (service.uuid == Guid(BleUuids.serviceUuid)) {
        for (final characteristic in service.characteristics) {
          final uuid = characteristic.uuid.toString();
          if (uuid == BleUuids.commandChannelUuid) {
            _commandCharacteristic = characteristic;
          } else if (uuid == BleUuids.responseChannelUuid) {
            _responseCharacteristic = characteristic;
            // Suscribirse a notificaciones de respuesta
            await characteristic.setNotifyValue(true);
            _responseSubscription =
                characteristic.onValueReceived.listen(_handleResponse);
          }
        }
      }
    }
  }

  /// Maneja cambios en el estado de conexión del dispositivo
  void _handleDeviceStateChange(BluetoothConnectionState state) {
    if (state == BluetoothConnectionState.disconnected) {
      _handleDisconnection();
    }
  }

  /// Maneja la desconexión del dispositivo
  void _handleDisconnection() {
    _commandCharacteristic = null;
    _responseCharacteristic = null;
    _responseSubscription?.cancel();
    _responseSubscription = null;

    if (_autoReconnectEnabled) {
      _startReconnection();
    } else {
      _updateConnectionState(BleConnectionState.disconnected);
    }
  }

  /// Inicia el proceso de reconexión automática
  void _startReconnection() {
    _updateConnectionState(BleConnectionState.reconnecting);
    _reconnectionAttempts = 0;
    _attemptReconnection();
  }

  /// Intenta reconectar al dispositivo
  void _attemptReconnection() {
    if (_reconnectionAttempts >= maxReconnectionAttempts) {
      _updateConnectionState(BleConnectionState.disconnected);
      _reconnectionTimer?.cancel();
      return;
    }

    _reconnectionAttempts++;
    _reconnectionTimer = Timer(reconnectionInterval, () async {
      if (_connectedDevice != null &&
          _connectionState == BleConnectionState.reconnecting) {
        try {
          await _connectToDevice(_connectedDevice!);
          // Sincronizar estado post-reconexión
          await synchronizeState();
        } catch (e) {
          // Reintentar si aún no se alcanzó el máximo
          _attemptReconnection();
        }
      }
    });
  }

  /// Sincroniza el estado del dispositivo después de reconexión
  ///
  /// Lee todas las características actuales del dispositivo para
  /// actualizar el estado local. Debe completarse en < 500ms.
  Future<void> synchronizeState() async {
    if (!isConnected || _connectedDevice == null) return;

    final services = await _connectedDevice!.discoverServices();
    for (final service in services) {
      if (service.uuid == Guid(BleUuids.serviceUuid)) {
        for (final characteristic in service.characteristics) {
          if (characteristic.properties.read) {
            await characteristic.read();
          }
        }
      }
    }
  }

  /// Maneja respuestas recibidas del dispositivo
  void _handleResponse(List<int> value) {
    final data = Uint8List.fromList(value);
    final response = BleResponse.deserialize(data);
    if (response != null) {
      _responseController.add(response);
    }
  }

  /// Envía un comando al dispositivo y espera respuesta
  ///
  /// Serializa el comando, lo envía por la característica de comandos,
  /// y espera la respuesta con ACK. Lanza [BleTimeoutException] si
  /// no recibe respuesta dentro del timeout.
  /// Lanza [BleDisconnectedException] si el dispositivo está desconectado.
  Future<BleResponse> sendCommand(
    int opcode,
    Uint8List payload, {
    Duration timeout = defaultOperationTimeout,
  }) async {
    if (!isConnected || _commandCharacteristic == null) {
      throw BleDisconnectedException(
          'No se puede enviar comando: dispositivo desconectado');
    }

    final seqNum = _nextSeqNum;
    final command = BleCommand(
      opcode: opcode,
      seqNum: seqNum,
      payload: payload,
    );

    // Enviar comando serializado
    await _commandCharacteristic!.write(
      command.serialize(),
      withoutResponse: false,
    );

    // Esperar respuesta con el mismo seqNum
    try {
      final response = await _responseController.stream
          .where((r) => r.seqNum == seqNum && r.opcode == opcode)
          .first
          .timeout(timeout);
      return response;
    } on TimeoutException {
      throw BleTimeoutException('sendCommand(opcode: 0x${opcode.toRadixString(16)})', timeout);
    }
  }

  /// Envía ganancias del ecualizador (12 bandas, 0-50 dB cada una)
  Future<BleResponse> setEqGains(List<int> gains) async {
    if (gains.length != 12) {
      throw ArgumentError.value(
        gains.length,
        'gains.length',
        'Must be exactly 12 bands (firmware protocol)',
      );
    }
    for (var i = 0; i < gains.length; i++) {
      final g = gains[i];
      if (g < 0 || g > 50) {
        throw ArgumentError.value(
          g,
          'gains[$i]',
          'Out of firmware range [0, 50] dB',
        );
      }
    }
    return sendCommand(BleCommands.setEqGains, Uint8List.fromList(gains));
  }

  /// Envía volumen maestro (-20 a +10 dB)
  Future<BleResponse> setVolume(int volumeDb) async {
    if (volumeDb < -20 || volumeDb > 10) {
      throw ArgumentError.value(
        volumeDb,
        'volumeDb',
        'Out of firmware range [-20, 10] dB',
      );
    }
    return sendCommand(
      BleCommands.setVolume,
      Uint8List.fromList([volumeDb & 0xFF]),
    );
  }

  /// Envía perfil activo (0=Quiet, 1=Conversation, 2=Noisy)
  Future<BleResponse> setProfile(int profileIndex) async {
    if (profileIndex < 0 || profileIndex > 2) {
      throw ArgumentError.value(
        profileIndex,
        'profileIndex',
        'Out of range [0, 2] (0=Quiet, 1=Conversation, 2=Noisy)',
      );
    }
    return sendCommand(
      BleCommands.setProfile,
      Uint8List.fromList([profileIndex]),
    );
  }

  /// Envía umbral MPO (rango clínico [80, 132] dB SPL)
  ///
  /// Rango documentado en `AudiogramDrivenBundle.mpoMaxDbSpl` (max 132)
  /// y aplicado por `MpoDeriver` (clamp pediátrico [80, 110], adulto [80, 132]).
  /// Se valida con `if/throw` (no `assert`) porque los `assert` se borran
  /// en builds release y un valor fuera de rango llegaría al firmware.
  Future<BleResponse> setMpoThreshold(int thresholdDb) async {
    if (thresholdDb < 80 || thresholdDb > 132) {
      throw ArgumentError.value(
        thresholdDb,
        'thresholdDb',
        'Out of clinical range [80, 132] dB SPL',
      );
    }
    return sendCommand(
      BleCommands.setMpo,
      Uint8List.fromList([thresholdDb]),
    );
  }

  /// Envía nivel de reducción de ruido (0=off, 1=mild, 2=moderate, 3=strong)
  Future<BleResponse> setNoiseReductionLevel(int level) async {
    if (level < 0 || level > 3) {
      throw ArgumentError.value(
        level,
        'level',
        'Out of range [0, 3] (0=off, 1=mild, 2=moderate, 3=strong)',
      );
    }
    return sendCommand(
      BleCommands.setNrLevel,
      Uint8List.fromList([level]),
    );
  }

  /// Envía estado de cancelación de feedback (0=off, 1=on)
  Future<BleResponse> setFeedbackCancel(bool enabled) async {
    return sendCommand(
      BleCommands.setFbCancel,
      Uint8List.fromList([enabled ? 1 : 0]),
    );
  }

  /// Solicita estado del dispositivo
  Future<BleResponse> getDeviceStatus() async {
    return sendCommand(BleCommands.getStatus, Uint8List(0));
  }

  /// Ejecuta factory reset (requiere código de confirmación)
  Future<BleResponse> factoryReset() async {
    // Código de confirmación: 0xDEAD (seguridad contra reset accidental)
    return sendCommand(
      BleCommands.factoryReset,
      Uint8List.fromList([0xDE, 0xAD, 0x00, 0x00]),
    );
  }

  /// Desconecta del dispositivo
  Future<void> disconnect() async {
    _autoReconnectEnabled = false;
    _reconnectionTimer?.cancel();
    _deviceStateSubscription?.cancel();
    _responseSubscription?.cancel();

    if (_connectedDevice != null) {
      await _connectedDevice!.disconnect();
    }

    _connectedDevice = null;
    _commandCharacteristic = null;
    _responseCharacteristic = null;
    _updateConnectionState(BleConnectionState.disconnected);
  }

  /// Habilita o deshabilita la reconexión automática
  void setAutoReconnect(bool enabled) {
    _autoReconnectEnabled = enabled;
  }

  /// Libera recursos del repositorio
  void dispose() {
    _reconnectionTimer?.cancel();
    _deviceStateSubscription?.cancel();
    _responseSubscription?.cancel();
    _connectionStateController.close();
    _responseController.close();
    _batteryLevelController.close();
  }
}
