// Test del script `tool/release_gate.dart` (tarea 16.4 del spec
// `audiogram-driven-presets`).
//
// Cubre los caminos críticos del gate:
//
//   1. PDF válido + reciente → exit 0.
//   2. PDF sin magic header → exit 1 con mensaje accionable.
//   3. PDF con marcadores OK pero audit > 7 días → exit 1.
//   4. PDF con `Resultado global: FAIL` → exit 1.
//
// Para no acoplar el test a `package:pdf` (lento y genera PDFs
// binarios reales), construimos los bytes a mano: un header `%PDF-`
// seguido del texto plano necesario para que los marcadores
// regex-matcheen.

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

const String _pdfHeader = '%PDF-1.4\n';

/// Genera bytes que simulan un PDF mínimo con los marcadores que
/// `release_gate.dart` espera. La fecha del audit se inyecta como
/// ISO-8601 para que el regex la encuentre.
Uint8List _fakePdf({
  required DateTime auditTimestamp,
  required bool overallPassed,
  bool includeSignatureMarker = true,
  bool includeSpecMarker = true,
  bool includeHeaderMarker = true,
}) {
  final StringBuffer sb = StringBuffer()..write(_pdfHeader);
  if (includeHeaderMarker) {
    sb.writeln('QC Loopback - Audit Trail');
  }
  if (includeSpecMarker) {
    sb.writeln('Spec: audiogram-driven-presets - Tramo 3 '
        '(Prescription -> Hearing aid)');
  }
  sb.writeln('Operador: Test Operator');
  sb.writeln('Fecha: ${auditTimestamp.toUtc().toIso8601String()}');
  sb.writeln(
    'Resultado global: ${overallPassed ? "PASS" : "FAIL"}',
  );
  if (includeSignatureMarker) {
    sb.writeln('Firma del operador QC');
  }
  sb.writeln('%%EOF');
  return Uint8List.fromList(latin1.encode(sb.toString()));
}

void main() {
  final Directory pkgRoot = Directory.current;
  final File scriptFile = File('${pkgRoot.path}/tool/release_gate.dart');
  if (!scriptFile.existsSync()) {
    fail('release_gate.dart no encontrado en ${scriptFile.path}');
  }

  late Directory tmp;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('release_gate_');
  });
  tearDown(() async {
    if (tmp.existsSync()) {
      await tmp.delete(recursive: true);
    }
  });

  Future<ProcessResult> runGate({
    required Uint8List pdfBytes,
    required DateTime releaseDate,
  }) async {
    final File pdf = File('${tmp.path}/audit.pdf');
    await pdf.writeAsBytes(pdfBytes);
    return Process.run(
      'dart',
      <String>[
        'run',
        scriptFile.path,
        '--audit-pdf=${pdf.path}',
        '--release-date=${releaseDate.toUtc().toIso8601String()}',
      ],
      workingDirectory: pkgRoot.path,
      runInShell: true,
    );
  }

  group('release_gate tool', () {
    test('PDF válido y reciente → exit 0 (PASS)', () async {
      final DateTime release = DateTime.utc(2026, 6, 15, 12);
      final DateTime audit = release.subtract(const Duration(days: 2));
      final ProcessResult r = await runGate(
        pdfBytes: _fakePdf(
          auditTimestamp: audit,
          overallPassed: true,
        ),
        releaseDate: release,
      );
      expect(r.exitCode, 0,
          reason: 'stdout=${r.stdout}\nstderr=${r.stderr}');
      expect(r.stdout.toString(), contains('PASS'));
    }, timeout: const Timeout(Duration(seconds: 90)));

    test('PDF sin magic header → exit 1', () async {
      // `JUST_TEXT_NOT_PDF` no empieza con `%PDF-`.
      final Uint8List bytes = Uint8List.fromList(
        latin1.encode('JUST_TEXT_NOT_PDF\nFecha: 2026-06-15T00:00:00Z'),
      );
      final ProcessResult r = await runGate(
        pdfBytes: bytes,
        releaseDate: DateTime.utc(2026, 6, 15),
      );
      expect(r.exitCode, 1);
      expect(r.stdout.toString(), contains('magic header'));
    }, timeout: const Timeout(Duration(seconds: 90)));

    test('audit con antiguedad > 7 dias → exit 1', () async {
      final DateTime release = DateTime.utc(2026, 6, 15, 12);
      final DateTime audit = release.subtract(const Duration(days: 14));
      final ProcessResult r = await runGate(
        pdfBytes: _fakePdf(
          auditTimestamp: audit,
          overallPassed: true,
        ),
        releaseDate: release,
      );
      expect(r.exitCode, 1);
      // ASCII-safe substring (Windows console encoding may mojibake the
      // UTF-8 stdout, so we assert on a phrase that only contains ASCII).
      final String stdout = r.stdout.toString();
      expect(stdout, contains('14'));
      expect(stdout, contains('excede el m'));
    }, timeout: const Timeout(Duration(seconds: 90)));

    test('overallPassed = false → exit 1 (falta marker PASS)', () async {
      final DateTime release = DateTime.utc(2026, 6, 15);
      final DateTime audit = release.subtract(const Duration(days: 1));
      final ProcessResult r = await runGate(
        pdfBytes: _fakePdf(
          auditTimestamp: audit,
          overallPassed: false,
        ),
        releaseDate: release,
      );
      expect(r.exitCode, 1);
      expect(r.stdout.toString(), contains('Resultado global: PASS'));
    }, timeout: const Timeout(Duration(seconds: 90)));
  });
}
