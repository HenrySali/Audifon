// Test del script `tool/check_dartdoc.dart` (tarea 16.4 del spec
// `audiogram-driven-presets`).
//
// **Estrategia: testing in-process, no subprocess.**
//
// El script `tool/check_dartdoc.dart` ya expone `runCheck({rootDir})`
// como API pura: lee archivos, escribe a `print()` y devuelve un
// `bool`. Eso es exactamente la superficie testeable que necesitamos,
// así que **importamos el script directamente** en lugar de
// spawneárlo con `Process.run(dart, ['run', ...])`.
//
// **Por qué evitar el subproceso `dart run`.**
//
//   1. `Process.run('dart', ...)` requiere que el SDK esté en PATH.
//      En este workspace, el Dart SDK vive embebido en
//      `flutter/bin/cache/dart-sdk/bin/dart.exe` y no se instala
//      globalmente, así que ese approach es frágil.
//   2. Reemplazarlo por `Process.run(Platform.resolvedExecutable, ...)`
//      arregla el PATH pero introduce un nuevo bug: bajo `flutter test`
//      con un workspace en path con espacios y paréntesis (más subst
//      Z:\), el VM child cuelga durante la resolución de
//      `package_config.json`, agotando el timeout de 90 s. Verificado
//      empíricamente.
//   3. El testing in-process — llamar `runCheck()` directo — es la
//      pattern canónica para CLIs cuyo core ya es puro
//      (Effective Dart > Testing > "Test pure functions, not
//      subprocesses"). Es ~100 ms vs ~5–60 s del fork+exec, no depende
//      de PATH, y los stack traces de fallos apuntan al código real.
//
// **Captura de stdout.**
//
// El script usa `print()` (Zone-aware), así que envolvemos la llamada
// en `runZoned` con un `ZoneSpecification.print` que redirige las
// líneas a un `StringBuffer`. Las aserciones `expect(stdout,
// contains(...))` se aplican sobre el buffer.
//
// **Cobertura.**
//
//   1. Happy path: `runCheck()` contra los 3 archivos reales del
//      paquete (`bundle_builder.dart`, `ucl_estimator.dart`,
//      `mpo_deriver.dart`) → debe devolver `true` y el stdout debe
//      listar los 3 símbolos + el marcador `PASS`.
//   2. Smoke negativo: armamos un fake-repo en un tmpdir con
//      `lib/domain/audiogram_driven_presets/<file>.dart` SIN docs y
//      llamamos `runCheck(rootDir: fake)` → debe devolver `false`,
//      con stdout listando las 4 secciones obligatorias faltantes.

import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

// Import relativo al script bajo test. `tool/check_dartdoc.dart` no es
// parte de `lib/`, así que no tiene URI `package:` — pero al ser un
// archivo Dart standalone se puede importar igual con path relativo.
// El script tiene un `main()` top-level que NO se ejecuta al importar
// (Dart sólo invoca `main` cuando el archivo es el entrypoint).
import '../../tool/check_dartdoc.dart' as check_dartdoc;

/// Ejecuta [body] capturando todas las llamadas a `print()` en el
/// `StringBuffer` retornado, en lugar de imprimirlas a la consola del
/// test runner. Usa [runZoned] + [ZoneSpecification] (mecanismo
/// estándar de `dart:async` para interceptar IO Zone-aware).
String _captureStdout(void Function() body) {
  final StringBuffer buffer = StringBuffer();
  runZoned<void>(
    body,
    zoneSpecification: ZoneSpecification(
      print: (Zone self, ZoneDelegate parent, Zone zone, String line) {
        buffer.writeln(line);
      },
    ),
  );
  return buffer.toString();
}

void main() {
  group('check_dartdoc tool (in-process)', () {
    test('los 3 módulos clínicos pasan el check (runCheck → true)', () {
      late bool ok;
      final String stdout = _captureStdout(() {
        ok = check_dartdoc.runCheck();
      });

      expect(ok, isTrue,
          reason: 'runCheck() devolvió false. stdout:\n$stdout');

      // Verifica que el output liste los 3 símbolos objetivo y el
      // marcador final PASS.
      expect(stdout, contains('buildFromAudiogram'));
      expect(stdout, contains('estimate'));
      expect(stdout, contains('derive'));
      expect(stdout, contains('PASS'));
    });

    test('detecta funciones públicas sin Dartdoc (runCheck → false)',
        () async {
      // Fake-repo con la estructura que `runCheck` espera por default
      // (`lib/domain/audiogram_driven_presets/<archivo>.dart`) pero con
      // funciones públicas SIN Dartdoc. `--root=<dir>` se inyecta vía
      // el parámetro `rootDir` de `runCheck`.
      final Directory tmp =
          await Directory.systemTemp.createTemp('check_dartdoc_neg_');
      addTearDown(() async {
        if (tmp.existsSync()) {
          await tmp.delete(recursive: true);
        }
      });

      final Directory targetDir = Directory(
        '${tmp.path}/lib/domain/audiogram_driven_presets',
      );
      await targetDir.create(recursive: true);

      // Los 3 archivos targeteados por _defaultTargets, todos con
      // funciones públicas SIN doc-comment.
      await File('${targetDir.path}/bundle_builder.dart').writeAsString('''
class BundleBuilder {
  static int buildFromAudiogram() {
    return 0;
  }
}
''');
      await File('${targetDir.path}/ucl_estimator.dart').writeAsString('''
class UclEstimator {
  static int estimate() {
    return 0;
  }
}
''');
      await File('${targetDir.path}/mpo_deriver.dart').writeAsString('''
class MpoDeriver {
  static int derive() {
    return 0;
  }
}
''');

      late bool ok;
      final String stdout = _captureStdout(() {
        ok = check_dartdoc.runCheck(rootDir: tmp.path);
      });

      expect(ok, isFalse,
          reason: 'runCheck() devolvió true sobre un repo sin docs. '
              'stdout:\n$stdout');

      // El reporte debe listar el marker FAIL y las 4 secciones
      // obligatorias que faltan en cada función.
      expect(stdout, contains('FAIL'));
      expect(stdout, contains('Parameters'));
      expect(stdout, contains('Returns'));
      expect(stdout, contains('References'));
      expect(stdout, contains('Example'));
    });
  });
}
