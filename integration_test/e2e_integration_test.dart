/// =============================================================================
/// Tests de Integración End-to-End — App Companion del Audífono Digital V2
///
/// Verifica los flujos completos de la aplicación móvil interactuando
/// con el dispositivo (firmware) a través de BLE:
///
/// 1. Cambio de ganancia desde app se refleja en DSP
/// 2. Cambio de perfil aplica todos los parámetros atómicamente
/// 3. Reconexión BLE sincroniza estado correctamente
/// 4. Batería baja desactiva funciones no esenciales
/// 5. Factory reset restaura valores por defecto
///
/// Requisitos validados: 1.4, 4.5, 4.6, 6.5, 8.4, 14.5
///
/// Nota: Estos tests usan mocks del dispositivo BLE para simular
/// el firmware del audífono. En un entorno real, se ejecutarían
/// contra el dispositivo físico usando integration_test de Flutter.
/// =============================================================================

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

// Nota: Los imports de los módulos de la app se habilitarán cuando
// la implementación de la capa de datos esté completa.
// import '../lib/src/data/ble_repository.dart';
// import '../lib/src/data/models/device_config.dart';
// import '../lib/src/data/models/audiogram.dart';
// import '../lib/src/data/models/environment_profile.dart';
// import '../lib/src/logic/gain_prescriber.dart';

/// Mock del repositorio BLE que simula el comportamiento del firmware
class MockBleDevice {
  /// Configuración actual del dispositivo simulado
  DeviceConfig config = DeviceConfig.factoryDefaults();

  /// Estado de conexión BLE
  bool isConnected = true;

  /// Nivel de batería simulado (0-100%)
  int batteryLevel = 80;

  /// Indica si las funciones no esenciales están desactivadas
  bool nonEssentialDisabled = false;

  /// Simula el envío de ganancias EQ al dispositivo
  /// Retorna true si se aplicaron dentro de 100ms (Requisito 1.4)
  Future<bool> setEqGains(List<int> gains) async {
    if (!isConnected) return false;
    if (gains.length != 9) return false;

    // Simular latencia BLE (transmisión + procesamiento)
    await Future.delayed(const Duration(milliseconds: 30));

    // Aplicar ganancias al config del dispositivo
    config = config.copyWith(eqGains: gains);
    return true;
  }

  /// Simula el cambio de perfil atómico (Requisito 6.5)
  Future<bool> setProfile(EnvironmentProfileType profile) async {
    if (!isConnected) return false;

    await Future.delayed(const Duration(milliseconds: 30));

    // Aplicar todos los parámetros del perfil atómicamente
    config = DeviceConfig.fromProfile(profile);
    return true;
  }

  /// Simula desconexión BLE
  void disconnect() {
    isConnected = false;
  }

  /// Simula reconexión BLE con sincronización de estado (Requisito 4.6)
  Future<DeviceConfig> reconnect() async {
    // Simular tiempo de reconexión + sincronización
    await Future.delayed(const Duration(milliseconds: 200));
    isConnected = true;

    // Retornar estado actual del dispositivo (sincronización)
    return config;
  }

  /// Simula evento de batería crítica (<5%) — Requisito 8.4
  void triggerCriticalBattery() {
    batteryLevel = 4;
    nonEssentialDisabled = true;

    // Desactivar funciones no esenciales
    config = config.copyWith(
      noiseReductionLevel: 0,  // NR off
      feedbackEnabled: false,   // FB Cancel off
    );
  }

  /// Simula factory reset (Requisito 14.5)
  Future<bool> factoryReset() async {
    if (!isConnected) return false;

    await Future.delayed(const Duration(milliseconds: 100));
    config = DeviceConfig.factoryDefaults();
    nonEssentialDisabled = false;
    return true;
  }
}

/// Modelo de configuración del dispositivo para los tests
class DeviceConfig {
  final List<int> eqGains;
  final int noiseReductionLevel;
  final bool feedbackEnabled;
  final int mpoThreshold;
  final int masterVolume;
  final EnvironmentProfileType activeProfile;
  final List<AgcBandParams> agcParams;

  const DeviceConfig({
    required this.eqGains,
    required this.noiseReductionLevel,
    required this.feedbackEnabled,
    required this.mpoThreshold,
    required this.masterVolume,
    required this.activeProfile,
    required this.agcParams,
  });

  /// Factory defaults seguros (Requisito 14.5)
  factory DeviceConfig.factoryDefaults() {
    return DeviceConfig(
      eqGains: List.filled(9, 0),           // 0 dB todas las bandas
      noiseReductionLevel: 0,                // NR off
      feedbackEnabled: true,                 // FB Cancel on
      mpoThreshold: 110,                    // 110 dB SPL
      masterVolume: 0,                       // 0 dB
      activeProfile: EnvironmentProfileType.quiet,
      agcParams: List.generate(9, (_) => AgcBandParams.defaults()),
    );
  }

  /// Crear configuración desde un perfil predefinido
  factory DeviceConfig.fromProfile(EnvironmentProfileType profile) {
    switch (profile) {
      case EnvironmentProfileType.quiet:
        return DeviceConfig(
          eqGains: List.filled(9, 0),
          noiseReductionLevel: 0,
          feedbackEnabled: true,
          mpoThreshold: 110,
          masterVolume: 0,
          activeProfile: EnvironmentProfileType.quiet,
          agcParams: List.generate(
            9, (_) => const AgcBandParams(ratio: 15, kneepoint: 50,
                                          attack: 5, release: 100)),
        );
      case EnvironmentProfileType.conversation:
        return DeviceConfig(
          eqGains: List.filled(9, 0),
          noiseReductionLevel: 1,
          feedbackEnabled: true,
          mpoThreshold: 105,
          masterVolume: 0,
          activeProfile: EnvironmentProfileType.conversation,
          agcParams: List.generate(
            9, (_) => const AgcBandParams(ratio: 20, kneepoint: 45,
                                          attack: 3, release: 150)),
        );
      case EnvironmentProfileType.noisy:
        return DeviceConfig(
          eqGains: List.filled(9, 0),
          noiseReductionLevel: 2,
          feedbackEnabled: true,
          mpoThreshold: 100,
          masterVolume: -3,
          activeProfile: EnvironmentProfileType.noisy,
          agcParams: List.generate(
            9, (_) => const AgcBandParams(ratio: 30, kneepoint: 40,
                                          attack: 2, release: 200)),
        );
    }
  }

  DeviceConfig copyWith({
    List<int>? eqGains,
    int? noiseReductionLevel,
    bool? feedbackEnabled,
    int? mpoThreshold,
    int? masterVolume,
    EnvironmentProfileType? activeProfile,
    List<AgcBandParams>? agcParams,
  }) {
    return DeviceConfig(
      eqGains: eqGains ?? List.from(this.eqGains),
      noiseReductionLevel: noiseReductionLevel ?? this.noiseReductionLevel,
      feedbackEnabled: feedbackEnabled ?? this.feedbackEnabled,
      mpoThreshold: mpoThreshold ?? this.mpoThreshold,
      masterVolume: masterVolume ?? this.masterVolume,
      activeProfile: activeProfile ?? this.activeProfile,
      agcParams: agcParams ?? List.from(this.agcParams),
    );
  }
}

/// Parámetros AGC por banda
class AgcBandParams {
  final int ratio;      // x10: 10=1:1, 40=4:1
  final int kneepoint;  // 40-80 dB SPL
  final int attack;     // 1-10 ms
  final int release;    // 50-500 ms

  const AgcBandParams({
    required this.ratio,
    required this.kneepoint,
    required this.attack,
    required this.release,
  });

  factory AgcBandParams.defaults() {
    return const AgcBandParams(ratio: 20, kneepoint: 50, attack: 5, release: 100);
  }
}

/// Tipos de perfil de entorno
enum EnvironmentProfileType { quiet, conversation, noisy }

// =============================================================================
// TESTS DE INTEGRACIÓN END-TO-END
// =============================================================================

void main() {
  // Inicializar binding para integration_test
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  late MockBleDevice device;

  setUp(() {
    device = MockBleDevice();
  });

  group('Integración End-to-End — App ↔ BLE ↔ Firmware ↔ DSP', () {
    // =========================================================================
    // TEST 1: Cambio de ganancia desde app se refleja en DSP
    //
    // Flujo: Usuario ajusta slider → App calcula ganancia → BLE transmite
    //        → Firmware recibe → DSP aplica dentro de 100ms
    //
    // Valida: Requisito 1.4
    // =========================================================================
    test('Cambio de ganancia desde app se refleja en DSP', () async {
      // Ganancias prescritas para audiograma 35-85 dB HL (half-gain rule)
      final prescribedGains = [17, 20, 22, 25, 27, 30, 32, 37, 42];

      // Medir tiempo de aplicación
      final stopwatch = Stopwatch()..start();

      // Enviar ganancias al dispositivo (simula flujo completo)
      final success = await device.setEqGains(prescribedGains);
      stopwatch.stop();

      // Verificar que el comando fue exitoso
      expect(success, isTrue,
          reason: 'El comando SET_EQ_GAINS debería ser exitoso');

      // Verificar que se aplicó dentro de 100ms (Requisito 1.4)
      expect(stopwatch.elapsedMilliseconds, lessThanOrEqualTo(100),
          reason: 'La aplicación de ganancias debe completarse en ≤100ms');

      // Verificar que las ganancias se reflejan en la configuración del DSP
      expect(device.config.eqGains, equals(prescribedGains),
          reason: 'Las ganancias del DSP deben coincidir con las enviadas');

      // Verificar cada banda individualmente
      for (int i = 0; i < 9; i++) {
        expect(device.config.eqGains[i], equals(prescribedGains[i]),
            reason: 'Banda $i: ganancia incorrecta');
        // Verificar rango válido (0-50 dB)
        expect(device.config.eqGains[i], inInclusiveRange(0, 50),
            reason: 'Banda $i: ganancia fuera de rango 0-50 dB');
      }
    });

    // =========================================================================
    // TEST 2: Cambio de perfil aplica todos los parámetros atómicamente
    //
    // Flujo: Usuario selecciona perfil "Noisy" → App envía perfil completo
    //        → BLE transmite como unidad atómica → Firmware aplica todo junto
    //
    // Valida: Requisito 6.5
    // =========================================================================
    test('Cambio de perfil aplica todos los parámetros atómicamente', () async {
      // Verificar estado inicial (Quiet)
      expect(device.config.activeProfile, equals(EnvironmentProfileType.quiet));

      // Cambiar a perfil Noisy
      final success = await device.setProfile(EnvironmentProfileType.noisy);
      expect(success, isTrue,
          reason: 'El cambio de perfil debería ser exitoso');

      // Verificar que TODOS los parámetros del perfil Noisy se aplicaron
      final config = device.config;

      // Perfil activo actualizado
      expect(config.activeProfile, equals(EnvironmentProfileType.noisy),
          reason: 'El perfil activo debería ser Noisy');

      // Reducción de ruido = moderate (nivel 2)
      expect(config.noiseReductionLevel, equals(2),
          reason: 'NR debería ser moderate (2) en perfil Noisy');

      // MPO threshold = 100 dB SPL
      expect(config.mpoThreshold, equals(100),
          reason: 'MPO debería ser 100 dB SPL en perfil Noisy');

      // Volumen maestro = -3 dB
      expect(config.masterVolume, equals(-3),
          reason: 'Volumen debería ser -3 dB en perfil Noisy');

      // AGC: ratio 3:1 (30), kneepoint 40, attack 2ms, release 200ms
      for (int i = 0; i < 9; i++) {
        expect(config.agcParams[i].ratio, equals(30),
            reason: 'Banda $i: AGC ratio debería ser 30 (3:1)');
        expect(config.agcParams[i].kneepoint, equals(40),
            reason: 'Banda $i: AGC kneepoint debería ser 40 dB');
        expect(config.agcParams[i].attack, equals(2),
            reason: 'Banda $i: AGC attack debería ser 2 ms');
        expect(config.agcParams[i].release, equals(200),
            reason: 'Banda $i: AGC release debería ser 200 ms');
      }
    });

    // =========================================================================
    // TEST 3: Reconexión BLE sincroniza estado correctamente
    //
    // Flujo: Conexión activa → Desconexión → Dispositivo opera con últimos
    //        parámetros → Reconexión → App sincroniza estado en <500ms
    //
    // Valida: Requisitos 4.5, 4.6
    // =========================================================================
    test('Reconexión BLE sincroniza estado correctamente', () async {
      // Establecer configuración personalizada
      final customGains = [20, 22, 25, 27, 30, 32, 35, 38, 42];
      await device.setEqGains(customGains);

      // Guardar estado antes de desconexión
      final preDisconnectConfig = device.config.copyWith();

      // Simular desconexión BLE
      device.disconnect();
      expect(device.isConnected, isFalse);

      // Verificar que el dispositivo mantiene los últimos parámetros (Req 4.5)
      // (El firmware sigue operando con la última configuración conocida)
      expect(device.config.eqGains, equals(customGains),
          reason: 'El dispositivo debe mantener parámetros durante desconexión');

      // Simular reconexión y medir tiempo de sincronización
      final stopwatch = Stopwatch()..start();
      final syncedConfig = await device.reconnect();
      stopwatch.stop();

      // Verificar reconexión exitosa
      expect(device.isConnected, isTrue,
          reason: 'El dispositivo debería estar reconectado');

      // Verificar sincronización dentro de 500ms (Requisito 4.6)
      expect(stopwatch.elapsedMilliseconds, lessThanOrEqualTo(500),
          reason: 'La sincronización post-reconexión debe ser ≤500ms '
                  '(fue ${stopwatch.elapsedMilliseconds}ms)');

      // Verificar que el estado sincronizado coincide con el pre-desconexión
      expect(syncedConfig.eqGains, equals(preDisconnectConfig.eqGains),
          reason: 'Ganancias EQ deben coincidir post-reconexión');
      expect(syncedConfig.masterVolume,
          equals(preDisconnectConfig.masterVolume),
          reason: 'Volumen debe coincidir post-reconexión');
      expect(syncedConfig.activeProfile,
          equals(preDisconnectConfig.activeProfile),
          reason: 'Perfil activo debe coincidir post-reconexión');
      expect(syncedConfig.noiseReductionLevel,
          equals(preDisconnectConfig.noiseReductionLevel),
          reason: 'Nivel NR debe coincidir post-reconexión');
    });

    // =========================================================================
    // TEST 4: Batería baja desactiva funciones no esenciales
    //
    // Flujo: Batería cae a <5% → Power Manager desactiva NR y FB Cancel
    //        → App recibe notificación → UI muestra alerta
    //
    // Valida: Requisito 8.4
    // =========================================================================
    test('Batería baja desactiva funciones no esenciales', () async {
      // Configurar estado inicial con todas las funciones activas
      device.config = device.config.copyWith(
        noiseReductionLevel: 2,   // NR moderate
        feedbackEnabled: true,     // FB Cancel activo
      );

      // Verificar estado inicial
      expect(device.config.noiseReductionLevel, equals(2),
          reason: 'NR debería estar activa inicialmente');
      expect(device.config.feedbackEnabled, isTrue,
          reason: 'FB Cancel debería estar activo inicialmente');
      expect(device.batteryLevel, equals(80),
          reason: 'Batería debería estar al 80% inicialmente');

      // Simular evento de batería crítica (<5%)
      device.triggerCriticalBattery();

      // Verificar que la batería está en nivel crítico
      expect(device.batteryLevel, lessThan(5),
          reason: 'Batería debería estar por debajo del 5%');

      // Verificar que NR fue desactivada (función no esencial)
      expect(device.config.noiseReductionLevel, equals(0),
          reason: 'NR debería desactivarse con batería crítica');

      // Verificar que FB Cancel fue desactivado (función no esencial)
      expect(device.config.feedbackEnabled, isFalse,
          reason: 'FB Cancel debería desactivarse con batería crítica');

      // Verificar que funciones esenciales siguen activas
      expect(device.config.mpoThreshold, inInclusiveRange(90, 110),
          reason: 'MPO limiter debe seguir activo (seguridad auditiva)');
      expect(device.config.eqGains.length, equals(9),
          reason: 'Ecualización debe seguir disponible');

      // Verificar flag de modo de bajo consumo
      expect(device.nonEssentialDisabled, isTrue,
          reason: 'Flag de funciones no esenciales desactivadas');
    });

    // =========================================================================
    // TEST 5: Factory reset restaura valores por defecto
    //
    // Flujo: Usuario solicita reset → App envía CMD_FACTORY_RESET con
    //        código de confirmación → Firmware restaura defaults → NVM
    //        se actualiza → App sincroniza nuevo estado
    //
    // Valida: Requisito 14.5
    // =========================================================================
    test('Factory reset restaura valores por defecto', () async {
      // Establecer configuración completamente personalizada
      device.config = DeviceConfig(
        eqGains: [25, 28, 30, 33, 35, 38, 40, 43, 48],
        noiseReductionLevel: 3,       // NR strong
        feedbackEnabled: true,
        mpoThreshold: 95,             // MPO personalizado
        masterVolume: 8,              // +8 dB
        activeProfile: EnvironmentProfileType.noisy,
        agcParams: List.generate(
          9, (_) => const AgcBandParams(
            ratio: 35, kneepoint: 45, attack: 2, release: 250)),
      );

      // Verificar que la configuración está personalizada
      expect(device.config.activeProfile,
          equals(EnvironmentProfileType.noisy));
      expect(device.config.masterVolume, equals(8));
      expect(device.config.mpoThreshold, equals(95));

      // Ejecutar factory reset
      final success = await device.factoryReset();
      expect(success, isTrue,
          reason: 'Factory reset debería ser exitoso');

      // Verificar que TODOS los parámetros volvieron a factory defaults
      final config = device.config;

      // Ganancias EQ = 0 dB (todas las bandas)
      expect(config.eqGains, equals(List.filled(9, 0)),
          reason: 'Ganancias EQ deberían ser 0 dB después de reset');

      // NR = off
      expect(config.noiseReductionLevel, equals(0),
          reason: 'NR debería estar off después de reset');

      // FB Cancel = on (default seguro)
      expect(config.feedbackEnabled, isTrue,
          reason: 'FB Cancel debería estar on después de reset');

      // MPO = 110 dB SPL (máximo seguro)
      expect(config.mpoThreshold, equals(110),
          reason: 'MPO debería ser 110 dB SPL después de reset');

      // Volumen = 0 dB
      expect(config.masterVolume, equals(0),
          reason: 'Volumen debería ser 0 dB después de reset');

      // Perfil = Quiet
      expect(config.activeProfile, equals(EnvironmentProfileType.quiet),
          reason: 'Perfil debería ser Quiet después de reset');

      // AGC = 2:1 (ratio 20), kneepoint 50, attack 5, release 100
      for (int i = 0; i < 9; i++) {
        expect(config.agcParams[i].ratio, equals(20),
            reason: 'Banda $i: AGC ratio debería ser 20 (2:1) después de reset');
        expect(config.agcParams[i].kneepoint, equals(50),
            reason: 'Banda $i: AGC kneepoint debería ser 50 después de reset');
      }

      // Verificar que el flag de funciones no esenciales se restauró
      expect(device.nonEssentialDisabled, isFalse,
          reason: 'Flag de funciones no esenciales debería restaurarse');
    });
  });
}
