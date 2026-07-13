// Test del script `tool/release_gate.dart` (tarea 16.4 del spec
// `audiogram-driven-presets`).
//
// **Estrategia: testing in-process, no subprocess.**
//
// El script ya expone `runReleaseGate({pdfBytes, releaseDate}) →
// ReleaseGateResult` como función pura (sin IO de archivo, sin
// `exit()`). Eso es lo que ejercitamos.
//
// **Por qué no spawneamos `dart run tool/release_gate.dart`.**
// Mismo razonamiento que `check_dartdoc_test.dart`: el subproceso bajo
// `flutter test` con workspace en path con espacios + paréntesis +
// subst Z:\ cuelga 90 s en la resolución de package_config; el
// in-process es ~10 ms. Ver el comment-block en
// `check_dartdoc_test.dart` para el detalle.
//
// **PDF sintético.**
//
// Para no acoplar el test a `package:pdf` (lento y genera bytes
// binarios reales), construimos los bytes a mano: header `%PDF-`
// seguido del texto plano necesario para que los marcadores y el
// regex de fecha matcheen. Esto es exactamente lo que verifica
// `runReleaseGate` (parser tolerante sobre el blob latin1).
//
// **Cobertura.**
//
//   1. PDF válido + reciente → `result.passed == true`.
//   2. PDF sin magic header → `result.passed == false`,
//      reason contiene "magic header".
//   3. PDF con marcadores OK pero audit > 7 días →
//      `result.passed == false`, reason contiene la antigüedad
//      en días + "excede el máximo".
//   4. PDF con `Resultado global: FAIL` → `result.passed == false`,
//      reason indica que falta el marcador `Resultado global: PASS`.

import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import '../../tool/release_gate.dart' as release_gate;

const String _pdfHeader = '%PDF-1.4\n';

/// Genera bytes que simulan un PDF mínimo con los marcadores que
/// `runReleaseGate` espera. La fecha del audit se inyecta como
/// ISO-8601 UTC para que el regex la encuentre.
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
  sb.writeln('Resultado global: ${overallPassed ? "PASS" : "FAIL"}');
  if (includeSignatureMarker) {
    sb.writeln('Firma del operador QC');
  }
  sb.writeln('%%EOF');
  return Uint8List.fromList(latin1.encode(sb.toString()));
}

void main() {
  group('release_gate tool (in-process)', () {
    test('PDF válido y reciente → passed=true (PASS)', () {
      final DateTime release = DateTime.utc(2026, 6, 15, 12);
      final DateTime audit = release.subtract(const Duration(days: 2));

      final result = release_gate.runReleaseGate(
        pdfBytes: _fakePdf(
          auditTimestamp: audit,
          overallPassed: true,
        ),
        releaseDate: release,
      );

      expect(result.passed, isTrue,
          reason: 'reasons=${result.reasons}');
      expect(result.reasons, isEmpty);
    });

    test('PDF sin magic header → passed=false con reason "magic header"', () {
      // Bytes que NO empiezan con `%PDF-`.
      final Uint8List bytes = Uint8List.fromList(
        latin1.encode('JUST_TEXT_NOT_PDF\nFecha: 2026-06-15T00:00:00Z'),
      );

      final result = release_gate.runReleaseGate(
        pdfBytes: bytes,
        releaseDate: DateTime.utc(2026, 6, 15),
      );

      expect(result.passed, isFalse);
      expect(
        result.reasons.any((r) => r.contains('magic header')),
        isTrue,
        reason: 'reasons=${result.reasons}',
      );
    });

    test('audit con antigüedad > 7 días → passed=false con días + "excede el m"',
        () {
      final DateTime release = DateTime.utc(2026, 6, 15, 12);
      final DateTime audit = release.subtract(const Duration(days: 14));

      final result = release_gate.runReleaseGate(
        pdfBytes: _fakePdf(
          auditTimestamp: audit,
          overallPassed: true,
        ),
        releaseDate: release,
      );

      expect(result.passed, isFalse);
      // El reason debe incluir tanto la antigüedad ("14") como el
      // texto "excede el m..." (ASCII-safe substring de "máximo").
      final String joined = result.reasons.join('\n');
      expect(joined, contains('14'));
      expect(joined, contains('excede el m'));
    });

    test('overallPassed=false → passed=false porque falta marker '
        '"Resultado global: PASS"', () {
      final DateTime release = DateTime.utc(2026, 6, 15);
      final DateTime audit = release.subtract(const Duration(days: 1));

      final result = release_gate.runReleaseGate(
        pdfBytes: _fakePdf(
          auditTimestamp: audit,
          overallPassed: false,
        ),
        releaseDate: release,
      );

      expect(result.passed, isFalse);
      expect(
        result.reasons.any((r) => r.contains('Resultado global: PASS')),
        isTrue,
        reason: 'reasons=${result.reasons}',
      );
    });
  });
}
