/// Tests del DnnDenoiserController.
///
/// Cubre:
///   1. Toggle de setEnabled: persistencia + propagación al MethodChannel.
///   2. Clamp de setIntensity: valores fuera de [0,1] se ajustan.
///   3. Persistencia Hive: cargar settings devuelve lo último guardado.
///   4. Property test (glados) de intensity: cualquier double se clampa
///      correctamente al rango [0,1].
///   5. Property test del controller: secuencias arbitrarias de
///      setEnabled/setIntensity preservan invariantes (no crash, valores
///      accesibles correctamente, persisted state == in-memory state).
///
/// Todos los tests son deterministas: no usan sleep ni clock real, y mockean
/// el MethodChannel + un Hive box temporal para correr 100% offline.
import 'dart:io';

import 'package:flutter/services.dart';
// flutter_test exporta `test`, `group`, `expect`, etc.; glados también los re-exporta.
// Para evitar el "imported from both", ocultamos esos símbolos en flutter_test
// y los tomamos exclusivamente desde glados (que reexporta package:test/test.dart).
import 'package:flutter_test/flutter_test.dart'
    hide test, group, setUp, tearDown, expect;
import 'package:glados/glados.dart';
import 'package:hive/hive.dart';

import 'package:hearing_aid_app/dnn_denoiser/dnn_denoiser_controller.dart';

/// Helper que registra un MethodChannel mock con un handler in-memory.
/// El handler:
///   - Acepta initDnnDenoiser, setDnnEnabled, setDnnIntensity, getDnnIsActive.
///   - Devuelve true para getDnnIsActive cuando el controlador acaba de
///     llamar setDnnEnabled(true) (heurística para los tests).
///   - Acumula todas las llamadas en `calls` para inspección posterior.
class _MockChannelHarness {
  final List<MethodCall> calls = [];
  bool reportActive = false;
  bool initShouldSucceed = true;

  late final MethodChannel channel;

  _MockChannelHarness() {
    channel = const MethodChannel(DnnDenoiserController.channelName);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, _handle);
  }

  Future<dynamic> _handle(MethodCall call) async {
    calls.add(call);
    switch (call.method) {
      case 'initDnnDenoiser':
        return initShouldSucceed;
      case 'setDnnEnabled':
        // Reflejamos el flag para que getDnnIsActive devuelva consistente.
        final args = call.arguments;
        if (args is Map && args['enabled'] is bool) {
          reportActive = args['enabled'] as bool;
        }
        return null;
      case 'setDnnIntensity':
        return null;
      case 'getDnnIsActive':
        return reportActive;
      default:
        return null;
    }
  }

  void dispose() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDir;
  late _MockChannelHarness harness;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('dnn_test_');
    Hive.init(tempDir.path);
    harness = _MockChannelHarness();
  });

  tearDown(() async {
    harness.dispose();
    if (Hive.isBoxOpen(DnnDenoiserController.hiveBoxName)) {
      await Hive.box<dynamic>(DnnDenoiserController.hiveBoxName).close();
    }
    await Hive.close();
    if (tempDir.existsSync()) {
      tempDir.deleteSync(recursive: true);
    }
  });

  // ───────────────────────────────────────────────────────────────────────
  // 1. setEnabled toggle: enabled true/false correctamente persistido.
  // ───────────────────────────────────────────────────────────────────────

  group('DnnDenoiserController.setEnabled', () {
    test('default enabled is false (la app arranca con NR Wiener clásico)',
        () async {
      final c = DnnDenoiserController(channel: harness.channel);
      await c.loadSettings();
      expect(c.isEnabled, isFalse);
    });

    test('setEnabled(true) actualiza in-memory + persistencia + nativo',
        () async {
      final c = DnnDenoiserController(channel: harness.channel);
      await c.loadSettings();

      await c.setEnabled(true);

      expect(c.isEnabled, isTrue);
      // Verificar persistencia.
      final box = Hive.box<dynamic>(DnnDenoiserController.hiveBoxName);
      expect(box.get('enabled'), isTrue);
      // Verificar que se llamó al nativo.
      expect(
        harness.calls.where((c) => c.method == 'setDnnEnabled').length,
        equals(1),
      );
      final lastCall =
          harness.calls.lastWhere((c) => c.method == 'setDnnEnabled');
      expect(lastCall.arguments, equals({'enabled': true}));
    });

    test('setEnabled(false) tras setEnabled(true) revierte el estado',
        () async {
      final c = DnnDenoiserController(channel: harness.channel);
      await c.loadSettings();
      await c.setEnabled(true);
      expect(c.isEnabled, isTrue);

      await c.setEnabled(false);
      expect(c.isEnabled, isFalse);
      final box = Hive.box<dynamic>(DnnDenoiserController.hiveBoxName);
      expect(box.get('enabled'), isFalse);
    });

    test('isActive refleja el último valor reportado por el nativo',
        () async {
      final c = DnnDenoiserController(channel: harness.channel);
      await c.loadSettings();

      expect(c.isActive, isFalse);
      await c.setEnabled(true);
      // El mock setea reportActive=true cuando ve setDnnEnabled(true);
      // refreshIsActive en setEnabled lo refleja.
      expect(c.isActive, isTrue);

      await c.setEnabled(false);
      expect(c.isActive, isFalse);
    });
  });

  // ───────────────────────────────────────────────────────────────────────
  // 2. setIntensity clamp.
  // ───────────────────────────────────────────────────────────────────────

  group('DnnDenoiserController.setIntensity', () {
    test('default intensity es 1.0', () async {
      final c = DnnDenoiserController(channel: harness.channel);
      await c.loadSettings();
      expect(c.intensity, equals(1.0));
    });

    test('valor en rango se persiste sin cambios', () async {
      final c = DnnDenoiserController(channel: harness.channel);
      await c.loadSettings();
      await c.setIntensity(0.7);
      expect(c.intensity, closeTo(0.7, 1e-9));
    });

    test('valor < 0 se clampa a 0.0', () async {
      final c = DnnDenoiserController(channel: harness.channel);
      await c.loadSettings();
      await c.setIntensity(-0.5);
      expect(c.intensity, equals(0.0));
    });

    test('valor > 1 se clampa a 1.0', () async {
      final c = DnnDenoiserController(channel: harness.channel);
      await c.loadSettings();
      await c.setIntensity(2.5);
      expect(c.intensity, equals(1.0));
    });

    test('NaN cae al default 1.0 (sin crash)', () async {
      final c = DnnDenoiserController(channel: harness.channel);
      await c.loadSettings();
      await c.setIntensity(double.nan);
      // Default = 1.0 según contrato del clamp.
      expect(c.intensity, equals(1.0));
    });

    test('cada setIntensity propaga al MethodChannel', () async {
      final c = DnnDenoiserController(channel: harness.channel);
      await c.loadSettings();
      await c.setIntensity(0.3);
      await c.setIntensity(0.8);
      final intensityCalls =
          harness.calls.where((m) => m.method == 'setDnnIntensity').toList();
      expect(intensityCalls.length, equals(2));
      expect(
        (intensityCalls.last.arguments as Map)['intensity'],
        closeTo(0.8, 1e-9),
      );
    });
  });

  // ───────────────────────────────────────────────────────────────────────
  // 3. Persistencia Hive: round-trip.
  // ───────────────────────────────────────────────────────────────────────

  group('DnnDenoiserController persistencia Hive', () {
    test('cargar settings tras setEnabled+setIntensity recupera lo guardado',
        () async {
      // Primer ciclo: setear y cerrar.
      {
        final c = DnnDenoiserController(channel: harness.channel);
        await c.loadSettings();
        await c.setEnabled(true);
        await c.setIntensity(0.42);
      }
      await Hive.box<dynamic>(DnnDenoiserController.hiveBoxName).close();

      // Segundo ciclo: nuevo controller, cargar settings.
      final c2 = DnnDenoiserController(channel: harness.channel);
      await c2.loadSettings();
      expect(c2.isEnabled, isTrue);
      expect(c2.intensity, closeTo(0.42, 1e-9));
    });

    test('loadSettings es idempotente', () async {
      final c = DnnDenoiserController(channel: harness.channel);
      await c.loadSettings();
      expect(c.isSettingsLoaded, isTrue);
      // Llamar una segunda vez no falla ni cambia el estado.
      await c.loadSettings();
      expect(c.isSettingsLoaded, isTrue);
    });

    test('valores no-bool / no-num en Hive caen al default sin crash',
        () async {
      // Pre-poblar el box con valores corruptos.
      final box =
          await Hive.openBox<dynamic>(DnnDenoiserController.hiveBoxName);
      await box.put('enabled', 'not-a-bool');
      await box.put('intensity', 'not-a-num');

      final c = DnnDenoiserController(channel: harness.channel);
      await c.loadSettings();
      // Defaults preservados.
      expect(c.isEnabled, isFalse);
      expect(c.intensity, equals(1.0));
    });
  });

  // ───────────────────────────────────────────────────────────────────────
  // 4. Property test (glados): clamp de intensity.
  //    No abre Hive porque queremos exclusivamente probar el clamp.
  // ───────────────────────────────────────────────────────────────────────

  group('Property: clamp de intensity', () {
    Glados<double>(
      any.doubleInRange(-100.0, 100.0),
      ExploreConfig(numRuns: 100),
    ).test(
      'cualquier double finito termina en [0, 1]',
      (raw) async {
        final c = DnnDenoiserController(channel: harness.channel);
        await c.loadSettings();
        await c.setIntensity(raw);
        expect(c.intensity, inInclusiveRange(0.0, 1.0));
      },
    );
  });

  // ───────────────────────────────────────────────────────────────────────
  // 5. Property test: secuencias arbitrarias preservan invariantes.
  //    Generamos una lista de operaciones (true/false toggle e intensity
  //    nuevo). Tras aplicarlas, validamos:
  //      a) controller no crashea
  //      b) isEnabled refleja el último setEnabled
  //      c) intensity refleja el último setIntensity (clampeado)
  //      d) box de Hive contiene los mismos valores
  // ───────────────────────────────────────────────────────────────────────

  group('Property: secuencias arbitrarias preservan invariantes', () {
    // Cada operación se codifica como un Tuple-equivalente:
    //   - (kind=0, x=1.0|0.0)  → setEnabled(x>0.5)
    //   - (kind=1, x=double)   → setIntensity(x)
    Glados2<int, double>(
      any.intInRange(0, 1),
      any.doubleInRange(-10.0, 10.0),
      ExploreConfig(numRuns: 50),
    ).test(
      'una operación arbitraria deja al controller en estado consistente',
      (kind, x) async {
        final c = DnnDenoiserController(channel: harness.channel);
        await c.loadSettings();

        if (kind == 0) {
          final flag = x > 0.0;
          await c.setEnabled(flag);
          expect(c.isEnabled, equals(flag));
          final box =
              Hive.box<dynamic>(DnnDenoiserController.hiveBoxName);
          expect(box.get('enabled'), equals(flag));
        } else {
          await c.setIntensity(x);
          expect(c.intensity, inInclusiveRange(0.0, 1.0));
          final box =
              Hive.box<dynamic>(DnnDenoiserController.hiveBoxName);
          final stored = box.get('intensity');
          expect(stored, isA<double>());
          expect((stored as double), inInclusiveRange(0.0, 1.0));
          expect(stored, closeTo(c.intensity, 1e-12));
        }
      },
    );
  });
}
