// Test del script `tool/check_dartdoc.dart` (tarea 16.3 del spec
// `audiogram-driven-presets`).
//
// Cubre dos casos:
//
// 1. **Happy path**: invoca el script contra los 3 archivos reales
//    (`bundle_builder.dart`, `ucl_estimator.dart`, `mpo_deriver.dart`)
//    y verifica que termine con exit code 0 (todas las funciones
//    públicas tienen las 4 secciones obligatorias).
//
// 2. **Smoke negativo**: crea un archivo temporal con una función
//    pública sin Dartdoc y verifica que el script lo detecta y
//    termina con exit code 1.
//
// El test invoca el script con `Process.run('dart', ['run', ...])`
// usando la misma toolchain que CI; no hace falta agregar deps al
// pubspec.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  // Resolver el cwd del paquete `hearing_aid_app/`. `flutter test`
  // lo lanza desde el root del paquete, así que `Directory.current`
  // ya es correcto, pero validamos por las dudas.
  final Directory pkgRoot = Directory.current;

  final File scriptFile = File('${pkgRoot.path}/tool/check_dartdoc.dart');
  if (!scriptFile.existsSync()) {
    fail('check_dartdoc.dart no encontrado en ${scriptFile.path}');
  }

  group('check_dartdoc tool', () {
    test('los 3 módulos clínicos pasan el check (exit 0)', () async {
      final ProcessResult result = await Process.run(
        'dart',
        <String>['run', 'tool/check_dartdoc.dart'],
        workingDirectory: pkgRoot.path,
        runInShell: true,
      );

      // Si falla, mostrar stdout/stderr en el mensaje del fail para
      // facilitar debug en CI.
      if (result.exitCode != 0) {
        fail(
          'check_dartdoc devolvió exit ${result.exitCode}.\n'
          'stdout:\n${result.stdout}\n'
          'stderr:\n${result.stderr}',
        );
      }

      // Verifica que el output liste las 3 funciones objetivo.
      final String stdout = result.stdout.toString();
      expect(stdout, contains('buildFromAudiogram'));
      expect(stdout, contains('estimate'));
      expect(stdout, contains('derive'));
      expect(stdout, contains('PASS'));
    },
        // El proceso `dart run` de un archivo standalone puede tardar
        // en máquinas frías; subimos el timeout a 90 s para evitar
        // flakes en CI.
        timeout: const Timeout(Duration(seconds: 90)));

    test('detecta una función pública sin Dartdoc (exit 1)', () async {
      // Crear un archivo temporal con un método público SIN Dartdoc.
      // Apuntamos el script a una copia del proyecto cuyos targets
      // estén ausentes para evitar enredo: en lugar de eso, creamos
      // un script wrapper que invoque el runner del check con un
      // único target inválido.
      final Directory tmp = await Directory.systemTemp.createTemp(
        'check_dartdoc_neg_',
      );
      addTearDown(() async {
        if (tmp.existsSync()) {
          await tmp.delete(recursive: true);
        }
      });

      // 1. Archivo Dart con método público sin doc.
      final File badFile = File('${tmp.path}/bad.dart');
      await badFile.writeAsString('''
class Bad {
  static int undocumented(int x) {
    return x + 1;
  }
}
''');

      // 2. Wrapper que reusa runCheck() del script principal con un
      //    target apuntando al archivo bad.dart. Para no exponer
      //    `runCheck` ni `_Target` (que son privadas) corremos el
      //    script contra un layout temporal que finja ser el repo:
      //    creamos `lib/domain/audiogram_driven_presets/<nombre>.dart`
      //    con el método público SIN doc.
      final Directory fakeRepo = Directory(
        '${tmp.path}/fake_repo/lib/domain/audiogram_driven_presets',
      );
      await fakeRepo.create(recursive: true);

      // bundle_builder.dart con buildFromAudiogram SIN doc.
      await File('${fakeRepo.path}/bundle_builder.dart').writeAsString('''
class BundleBuilder {
  static int buildFromAudiogram() {
    return 0;
  }
}
''');
      // ucl_estimator.dart con estimate SIN doc.
      await File('${fakeRepo.path}/ucl_estimator.dart').writeAsString('''
class UclEstimator {
  static int estimate() {
    return 0;
  }
}
''');
      // mpo_deriver.dart con derive SIN doc.
      await File('${fakeRepo.path}/mpo_deriver.dart').writeAsString('''
class MpoDeriver {
  static int derive() {
    return 0;
  }
}
''');

      final ProcessResult result = await Process.run(
        'dart',
        <String>[
          'run',
          scriptFile.path,
          '--root=${tmp.path}/fake_repo',
        ],
        workingDirectory: pkgRoot.path,
        runInShell: true,
      );

      // Esperamos exit 1 + mensaje FAIL en stdout.
      expect(result.exitCode, 1,
          reason: 'stdout=${result.stdout}\nstderr=${result.stderr}');
      final String stdout = result.stdout.toString();
      expect(stdout, contains('FAIL'));
      expect(stdout, contains('Parameters'));
      expect(stdout, contains('Returns'));
      expect(stdout, contains('References'));
      expect(stdout, contains('Example'));
    }, timeout: const Timeout(Duration(seconds: 90)));
  });
}
