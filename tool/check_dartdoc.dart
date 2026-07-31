// ignore_for_file: avoid_print
//
// Tool: check_dartdoc.dart
// Spec: audiogram-driven-presets — Tarea 16.3
// Requisito: 12.2 (Dartdoc completeness check)
//
// Verifica que las funciones públicas de los 3 módulos clínicos
// (BundleBuilder, UclEstimator, MpoDeriver) tengan en su Dartdoc las
// 4 secciones obligatorias:
//
//   1. Parameters / Parámetros        (rango/unidad por param)
//   2. Returns    / Retorno / Retorna (rango/unidad)
//   3. References / Referencias       (link a docs/07-calibracion-audiograma)
//   4. Example    / Ejemplo           (snippet ejecutable, idealmente con
//                                      audiograma flat 30 dB HL)
//
// Si falta alguna sección en alguna función pública objetivo, imprime
// el detalle por consola y termina con `exit 1` para bloquear el merge
// en CI.
//
// Uso (local o CI):
//
//   dart run tool/check_dartdoc.dart
//
// El script recorre los archivos hardcodeados (los 3 módulos clínicos)
// y por cada función pública declarada en el archivo verifica las 4
// secciones aplicando una heurística regex tolerante a estilos
// distintos (header `###`, **bold:**, mayúsculas/minúsculas, ES/EN).
//
// Pureza: no escribe a disco, no toca red. Si el archivo fuente no
// existe el script falla en seco con `exit 2`.

import 'dart:io';

/// Resultado de verificar el Dartdoc de una sola función pública.
class _CheckResult {
  _CheckResult({
    required this.file,
    required this.symbol,
    required this.line,
    required this.missing,
  });

  final String file;
  final String symbol;
  final int line;
  final List<String> missing;

  bool get passed => missing.isEmpty;
}

/// Configuración del check para un archivo objetivo.
class _Target {
  const _Target({required this.path, required this.publicSymbols});

  /// Path relativo al root del paquete `hearing_aid_app/`.
  final String path;

  /// Nombres de funciones / métodos públicos que deben tener Dartdoc
  /// completo. Estos son los símbolos definidos por el spec en la
  /// tarea 16.3. Si en el futuro se agregan más métodos públicos al
  /// archivo, agregarlos aquí.
  final List<String> publicSymbols;
}

/// Las 4 secciones obligatorias y los patrones regex que se aceptan
/// para cada una. Los patrones son intencionalmente tolerantes:
/// aceptan `### Parameters`, `**Parameters:**`, `Parameters:`, etc.,
/// con o sin tildes y en español o inglés.
const Map<String, List<String>> _requiredSectionPatterns = <String, List<String>>{
  'Parameters': <String>[
    r'^\s*///\s*#{2,4}\s*par[áa]metros',
    r'^\s*///\s*#{2,4}\s*parameters',
    r'^\s*///\s*\*\*\s*par[áa]metros\s*:?\s*\*\*',
    r'^\s*///\s*\*\*\s*parameters\s*:?\s*\*\*',
    r'^\s*///\s*par[áa]metros\s*:',
    r'^\s*///\s*parameters\s*:',
  ],
  'Returns': <String>[
    r'^\s*///\s*#{2,4}\s*retorn[oa]',
    r'^\s*///\s*#{2,4}\s*returns?',
    r'^\s*///\s*\*\*\s*retorn[oa]\s*:?\s*\*\*',
    r'^\s*///\s*\*\*\s*returns?\s*:?\s*\*\*',
    r'^\s*///\s*retorn[oa]\s*:',
    r'^\s*///\s*returns?\s*:',
  ],
  'References': <String>[
    r'^\s*///\s*#{2,4}\s*referencias?',
    r'^\s*///\s*#{2,4}\s*references?',
    r'^\s*///\s*\*\*\s*referencias?\s*:?\s*\*\*',
    r'^\s*///\s*\*\*\s*references?\s*:?\s*\*\*',
    r'^\s*///\s*referencias?\s*:',
    r'^\s*///\s*references?\s*:',
  ],
  'Example': <String>[
    r'^\s*///\s*#{2,4}\s*ejemplo',
    r'^\s*///\s*#{2,4}\s*example',
    r'^\s*///\s*\*\*\s*ejemplo[^*]*\*\*',
    r'^\s*///\s*\*\*\s*example[^*]*\*\*',
    r'^\s*///\s*ejemplo\s*:',
    r'^\s*///\s*example\s*:',
  ],
};

/// Default targets: los 3 módulos clínicos del spec.
const List<_Target> _defaultTargets = <_Target>[
  _Target(
    path: 'lib/domain/audiogram_driven_presets/bundle_builder.dart',
    publicSymbols: <String>['buildFromAudiogram'],
  ),
  _Target(
    path: 'lib/domain/audiogram_driven_presets/ucl_estimator.dart',
    publicSymbols: <String>['estimate'],
  ),
  _Target(
    path: 'lib/domain/audiogram_driven_presets/mpo_deriver.dart',
    publicSymbols: <String>['derive'],
  ),
];

/// Compila los regex una sola vez (evita reparseo en cada línea).
final Map<String, List<RegExp>> _compiledPatterns = _requiredSectionPatterns
    .map((String section, List<String> patterns) {
  return MapEntry<String, List<RegExp>>(
    section,
    patterns
        .map((String p) => RegExp(p, caseSensitive: false, multiLine: false))
        .toList(growable: false),
  );
});

/// Verifica el Dartdoc de un símbolo concreto en el archivo dado.
///
/// La heurística de localización del símbolo es deliberadamente simple:
/// busca la primera línea que matchea
/// `<retorno?> <symbolName>(<args>)` o `<symbolName>(<args>)` con
/// indentación ≥ 2 (es decir, el símbolo es un método dentro de una
/// clase). Una vez encontrada, se agrupa hacia arriba el bloque de
/// líneas `///` contiguas y se aplica el matcher de secciones.
///
/// La heurística cubre los 3 archivos del spec sin falsos positivos.
/// Si el repo agrega métodos con firmas exóticas (decoradores,
/// `external`, returns multi-línea con generics anidados), revisar
/// y eventualmente migrar a `package:analyzer`.
_CheckResult _checkSymbol({
  required String filePath,
  required List<String> lines,
  required String symbol,
}) {
  // Busca la línea de declaración del símbolo. Ejemplos válidos:
  //   AudiogramDrivenBundle buildFromAudiogram(
  //   static List<double> estimate(
  //   static List<double> derive(
  //   void foo() {
  // El nombre de la función debe ser la última palabra antes del `(`.
  final RegExp declRe = RegExp(
    '^\\s+(?:static\\s+|external\\s+|@\\w+\\s+)*(?:[\\w<>,\\s\\?\\.]+\\s+)?'
    '\\b${RegExp.escape(symbol)}\\s*\\(',
  );

  int? declLineIdx;
  for (int i = 0; i < lines.length; i++) {
    if (declRe.hasMatch(lines[i])) {
      declLineIdx = i;
      break;
    }
  }

  if (declLineIdx == null) {
    return _CheckResult(
      file: filePath,
      symbol: symbol,
      line: -1,
      missing: <String>['<symbol-not-found>'],
    );
  }

  // Recoger el bloque de doc-comment justo encima (líneas `///`
  // contiguas). Saltar líneas en blanco o anotaciones `@` antes del
  // doc.
  int cursor = declLineIdx - 1;
  // Saltar anotaciones tipo `@override` o líneas vacías.
  while (cursor >= 0 &&
      (lines[cursor].trim().isEmpty ||
          lines[cursor].trim().startsWith('@'))) {
    cursor--;
  }

  final List<String> docLines = <String>[];
  while (cursor >= 0 && lines[cursor].trimLeft().startsWith('///')) {
    docLines.insert(0, lines[cursor]);
    cursor--;
  }

  if (docLines.isEmpty) {
    return _CheckResult(
      file: filePath,
      symbol: symbol,
      line: declLineIdx + 1,
      missing: _requiredSectionPatterns.keys.toList(growable: false),
    );
  }

  // Para cada sección requerida, buscar al menos una línea que matchee
  // alguno de sus patrones.
  final List<String> missing = <String>[];
  for (final MapEntry<String, List<RegExp>> entry
      in _compiledPatterns.entries) {
    final bool found = docLines.any(
      (String l) => entry.value.any((RegExp re) => re.hasMatch(l)),
    );
    if (!found) {
      missing.add(entry.key);
    }
  }

  return _CheckResult(
    file: filePath,
    symbol: symbol,
    line: declLineIdx + 1,
    missing: missing,
  );
}

/// Verifica un target completo (archivo + lista de símbolos públicos).
List<_CheckResult> _checkTarget(_Target target, {String? rootDir}) {
  final String fullPath = rootDir == null
      ? target.path
      : '${rootDir.replaceAll(r'\', '/').replaceAll(RegExp(r'/$'), '')}'
          '/${target.path}';

  final File f = File(fullPath);
  if (!f.existsSync()) {
    stderr.writeln('check_dartdoc: archivo no encontrado: $fullPath');
    exit(2);
  }

  final List<String> lines = f.readAsLinesSync();
  return target.publicSymbols
      .map((String s) =>
          _checkSymbol(filePath: target.path, lines: lines, symbol: s))
      .toList(growable: false);
}

/// Entry point. Devuelve `true` si todos los targets pasaron.
// ignore: library_private_types_in_public_api
bool runCheck({List<_Target>? targets, String? rootDir}) {
  final List<_Target> ts = targets ?? _defaultTargets;
  bool allPassed = true;

  for (final _Target t in ts) {
    final List<_CheckResult> results = _checkTarget(t, rootDir: rootDir);
    for (final _CheckResult r in results) {
      if (r.passed) {
        print('OK  ${r.file}::${r.symbol}  (line ${r.line})');
      } else {
        allPassed = false;
        print(
          'FAIL ${r.file}::${r.symbol}  (line ${r.line})  '
          'missing=${r.missing.join(", ")}',
        );
      }
    }
  }

  if (allPassed) {
    print('');
    print('check_dartdoc: PASS — todas las funciones públicas tienen las '
        '4 secciones obligatorias.');
  } else {
    print('');
    print('check_dartdoc: FAIL — agregar las secciones faltantes en los '
        'Dartdocs señalados arriba.');
  }
  return allPassed;
}

void main(List<String> args) {
  // `--root=<dir>` permite a los tests apuntar a un working dir
  // distinto al cwd (útil cuando dart test corre desde test/).
  String? rootDir;
  for (final String a in args) {
    if (a.startsWith('--root=')) {
      rootDir = a.substring('--root='.length);
    }
  }

  final bool ok = runCheck(rootDir: rootDir);
  exit(ok ? 0 : 1);
}
