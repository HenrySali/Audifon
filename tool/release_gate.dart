// ignore_for_file: avoid_print
//
// Tool: release_gate.dart
// Spec: audiogram-driven-presets — Tarea 16.4
// Requisitos: 15.14, 15.15
//
// Release gate de Tramo 3 (Prescription → Hearing aid).
//
// **Por qué este gate.** El audit_trail_box (Hive) que persiste los
// `QcAuditRecord` vive en el dispositivo del operador clínico, no en
// el runner de CI. Para que el release de producción no avance sin un
// QC firmado, exigimos al operador que adjunte el PDF generado por
// `QcAuditRepositoryImpl.generatePdf` como release asset, y este gate
// verifica que:
//
//   1. El PDF existe y es legible.
//   2. Empieza con el magic header `%PDF-` (sanity check de formato).
//   3. Contiene los marcadores textuales que escribe la plantilla de
//      `_buildPdfHeader` / `_buildPdfSummary` / `_buildPdfSignatureBlock`,
//      es decir el reporte fue generado por la app y no es un PDF
//      arbitrario:
//        - "QC Loopback - Audit Trail"
//        - "Spec: audiogram-driven-presets - Tramo 3"
//        - "Resultado global: PASS"
//        - "Firma del operador QC"
//   4. La fecha del audit (campo `Fecha:` del header) está dentro de
//      los últimos 7 días respecto a la `--release-date` (default: la
//      fecha actual UTC). Esto cumple Req 15.14: el QC debe ser fresco.
//
// **Salida.**
//   - exit 0 → gate aprobado, el release puede continuar.
//   - exit 1 → gate denegado, mensaje claro al operador con la causa.
//   - exit 2 → error de uso (PDF no encontrado, flag faltante, etc.).
//
// **Uso (CI).**
//
//   dart run tool/release_gate.dart --audit-pdf=qc_audit_report.pdf
//
// **Uso (operador, manual).**
//
//   dart run tool/release_gate.dart \
//     --audit-pdf=path/to/QC.pdf \
//     --release-date=2026-06-15
//
// **Limitación conocida.** El gate verifica la *plantilla* del PDF,
// no la firma criptográfica. La firma legal del PDF (huella digital
// certificada o sello de tiempo) queda como TODO para Tramo 4
// (release-management spec). Hasta entonces, este gate cumple el
// contrato del Req 15.14/15.15 verificando: existencia del registro,
// estructura del reporte y frescura temporal.

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

const Set<String> _requiredMarkers = <String>{
  'QC Loopback - Audit Trail',
  'Spec: audiogram-driven-presets - Tramo 3',
  'Resultado global: PASS',
  'Firma del operador QC',
};

const Duration _maxAuditAge = Duration(days: 7);

class _CliArgs {
  _CliArgs({required this.auditPdfPath, required this.releaseDate});

  final String auditPdfPath;
  final DateTime releaseDate;
}

/// Resultado del check; útil para tests.
class ReleaseGateResult {
  ReleaseGateResult({required this.passed, required this.reasons});

  final bool passed;
  final List<String> reasons;
}

/// Lee los bytes del PDF y devuelve el resultado del gate.
///
/// El parser de fechas es deliberadamente simple: el helper
/// `_buildPdfHeader` escribe el campo "Fecha: <ISO-8601 UTC>", así que
/// extraemos el string ISO-8601 con un regex sobre el contenido
/// extraído. Algunos engines de PDF empaquetan el texto en streams
/// comprimidos (FlateDecode) — en ese caso el regex no encuentra
/// match contra el blob raw, y el gate pide al operador instalar
/// `pdftotext` o usar la app del cliente que genera el PDF en texto
/// plano legible (la versión actual de `package:pdf` 3.12 no comprime
/// los strings por default cuando el documento es chico, así que el
/// happy path funciona end-to-end).
ReleaseGateResult runReleaseGate({
  required Uint8List pdfBytes,
  required DateTime releaseDate,
}) {
  final List<String> reasons = <String>[];

  // 1. Magic header `%PDF-`.
  if (pdfBytes.length < 5 ||
      pdfBytes[0] != 0x25 || // %
      pdfBytes[1] != 0x50 || // P
      pdfBytes[2] != 0x44 || // D
      pdfBytes[3] != 0x46 || // F
      pdfBytes[4] != 0x2D) {
    reasons.add('PDF inválido: falta magic header "%PDF-".');
    return ReleaseGateResult(passed: false, reasons: reasons);
  }

  // 2. Parsing tolerante: tratar los bytes como Latin-1 (preserva
  //    todos los bytes 0..255) y buscar los marcadores textuales.
  //    `package:pdf` escribe el contenido en streams, pero los
  //    strings literales suelen aparecer en un Tj-operator que es
  //    legible si el stream no está comprimido. Si está comprimido,
  //    el operador debe regenerar el PDF con la versión actual de
  //    la app (que NO comprime por default).
  final String content = latin1.decode(pdfBytes, allowInvalid: true);

  for (final String marker in _requiredMarkers) {
    if (!content.contains(marker)) {
      reasons.add(
        'PDF no contiene el marcador requerido: "$marker" — '
        'verificar que el reporte fue generado con '
        'QcAuditRepositoryImpl.generatePdf y que el resultado global '
        'sea PASS.',
      );
    }
  }

  // 3. Extraer la fecha del audit. El header escribe
  //    `Fecha: <ISO-8601 UTC>`. Aceptamos tanto `T` como `(T)` por si
  //    el operador del PDF escapa caracteres especiales; el regex
  //    captura el string completo hasta el siguiente whitespace o
  //    paréntesis.
  final RegExp dateRe = RegExp(
    r'Fecha:\s*\(?\s*(\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d+)?Z?)',
  );
  final Match? m = dateRe.firstMatch(content);
  DateTime? auditDate;
  if (m != null) {
    try {
      auditDate = DateTime.parse(m.group(1)!).toUtc();
    } on FormatException {
      auditDate = null;
    }
  }
  if (auditDate == null) {
    reasons.add(
      'No se pudo extraer la fecha del audit del PDF '
      '(esperado: "Fecha: <ISO-8601>" en el header).',
    );
  } else {
    final Duration age = releaseDate.toUtc().difference(auditDate);
    if (age.isNegative) {
      reasons.add(
        'Fecha del audit (${auditDate.toIso8601String()}) es '
        'posterior a la release date (${releaseDate.toIso8601String()}).'
        ' Verificar reloj del operador o release date.',
      );
    } else if (age > _maxAuditAge) {
      reasons.add(
        'Audit con antigüedad ${age.inDays} días excede el máximo '
        'permitido (${_maxAuditAge.inDays} días). '
        'El operador debe ejecutar QC fresco antes de releasear '
        '(audit fecha: ${auditDate.toIso8601String()}, release fecha: '
        '${releaseDate.toIso8601String()}).',
      );
    }
  }

  return ReleaseGateResult(passed: reasons.isEmpty, reasons: reasons);
}

_CliArgs _parseArgs(List<String> args) {
  String? auditPdfPath;
  DateTime releaseDate = DateTime.now().toUtc();
  for (final String a in args) {
    if (a.startsWith('--audit-pdf=')) {
      auditPdfPath = a.substring('--audit-pdf='.length);
    } else if (a.startsWith('--release-date=')) {
      try {
        releaseDate = DateTime.parse(
          a.substring('--release-date='.length),
        ).toUtc();
      } on FormatException catch (e) {
        stderr.writeln('release_gate: --release-date inválido ($e).');
        exit(2);
      }
    } else if (a == '--help' || a == '-h') {
      _printUsage();
      exit(0);
    }
  }
  if (auditPdfPath == null) {
    stderr.writeln('release_gate: falta --audit-pdf=<path>.');
    _printUsage();
    exit(2);
  }
  return _CliArgs(auditPdfPath: auditPdfPath, releaseDate: releaseDate);
}

void _printUsage() {
  print('release_gate.dart — verifica QC firmado para release de Tramo 3.');
  print('');
  print('Uso:');
  print('  dart run tool/release_gate.dart --audit-pdf=<path> '
      '[--release-date=<ISO-8601>]');
  print('');
  print('Flags:');
  print('  --audit-pdf=<path>     Path al PDF generado por '
      'QcAuditRepositoryImpl.generatePdf. Requerido.');
  print('  --release-date=<iso>   Fecha del release (UTC). Default: ahora.');
}

void main(List<String> args) {
  final _CliArgs cli = _parseArgs(args);
  final File pdfFile = File(cli.auditPdfPath);
  if (!pdfFile.existsSync()) {
    stderr.writeln('release_gate: PDF no encontrado: ${cli.auditPdfPath}');
    exit(2);
  }

  final Uint8List bytes = pdfFile.readAsBytesSync();
  final ReleaseGateResult result = runReleaseGate(
    pdfBytes: bytes,
    releaseDate: cli.releaseDate,
  );

  if (result.passed) {
    print('release_gate: PASS — QC PDF válido y dentro de la ventana '
        'de ${_maxAuditAge.inDays} días.');
    exit(0);
  } else {
    print('release_gate: FAIL — el release de producción NO puede '
        'continuar. Causa(s):');
    for (final String r in result.reasons) {
      print('  - $r');
    }
    print('');
    print('Acción requerida del operador clínico:');
    print('  1. Ejecutar la rutina de QC loopback en la app '
        '(Modo Diagnóstico → Configuración → "Ejecutar QC Tramo 3").');
    print('  2. Exportar el PDF firmado desde audit_trail_box.');
    print('  3. Adjuntar el PDF como release asset y re-disparar el '
        'workflow de release.');
    exit(1);
  }
}
