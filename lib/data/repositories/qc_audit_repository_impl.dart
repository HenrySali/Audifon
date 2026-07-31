import 'dart:convert';
import 'dart:typed_data' show ByteData;

import 'package:flutter/services.dart' show rootBundle;
import 'package:hive/hive.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

import '../../domain/entities/qc_audit_record.dart';
import '../../domain/repositories/qc_audit_repository.dart';

/// Nombre canónico del Hive box de audit trail QC.
///
/// Documentado en Req 15.14: "operador, fecha, equipo de medición,
/// audiogramas probados, tabla de mediciones, pass/fail final".
const String qcAuditTrailBoxName = 'audit_trail_box';

/// Path del asset Regular de la fuente Unicode usada en el PDF.
///
/// Roboto está declarado bajo `flutter.fonts` en `pubspec.yaml`, lo que
/// permite cargarlo con `rootBundle.load(...)`. Se usa Roboto en vez de
/// la Helvetica por defecto del PDF estándar porque Helvetica es Type1
/// sin soporte Unicode — los acentos del español (á é í ó ú ñ ¿ ¡) se
/// renderizan como `?` o cuadrados vacíos. Roboto soporta Latin-1 y
/// Latin Extended-A completos. Licencia Apache-2.0
/// (https://github.com/googlefonts/roboto-2/blob/main/LICENSE).
const String _qcPdfFontRegularAsset = 'assets/fonts/Roboto-Regular.ttf';
const String _qcPdfFontBoldAsset = 'assets/fonts/Roboto-Bold.ttf';

/// Implementación Hive + `package:pdf` del repositorio de auditoría QC
/// (tarea 15.3 de `audiogram-driven-presets`).
///
/// - Persistencia: `audit_trail_box` con clave `record.storageKey`
///   (timestamp ISO-8601 UTC) y valor JSON-string.
/// - Listado: deserializa todos los records y los devuelve ordenados
///   ascendentemente por timestamp.
/// - PDF: genera un reporte A4 con header (operador + equipamiento +
///   fecha), tabla de mediciones (audiograma, frecuencia, input,
///   esperado, medido, Δ, pass/fail), summary y bloque de firma.
///
/// Los bytes del PDF empiezan con el magic header `%PDF-` (verificable
/// por los tests).
///
/// Uso típico:
/// ```dart
/// final box = await QcAuditRepositoryImpl.openBox();
/// final repo = QcAuditRepositoryImpl(box);
/// await repo.append(record);
/// final pdfBytes = await repo.generatePdf(record);
/// ```
class QcAuditRepositoryImpl implements QcAuditRepository {
  final Box<dynamic> _box;

  QcAuditRepositoryImpl(this._box);

  /// Abre el Hive box `audit_trail_box`. El caller es responsable de
  /// inicializar Hive antes (`Hive.init` o `Hive.initFlutter`).
  static Future<Box<dynamic>> openBox() async {
    return Hive.openBox<dynamic>(qcAuditTrailBoxName);
  }

  // ─── append / getAll ───────────────────────────────────────────────────

  @override
  Future<void> append(QcAuditRecord record) async {
    final key = record.storageKey;
    if (_box.containsKey(key)) {
      throw StateError(
        'audit_trail_box ya contiene un record con timestamp $key. '
        'Usá un timestamp distinto o borrá el record existente.',
      );
    }
    final encoded = jsonEncode(record.toJson());
    await _box.put(key, encoded);
  }

  @override
  Future<List<QcAuditRecord>> getAll() async {
    final keys = _box.keys.toList()..sort((a, b) => '$a'.compareTo('$b'));
    final records = <QcAuditRecord>[];
    for (final key in keys) {
      final raw = _box.get(key);
      if (raw == null) continue;
      try {
        final decoded = jsonDecode(raw as String) as Map<String, dynamic>;
        records.add(QcAuditRecord.fromJson(decoded));
      } catch (_) {
        // Saltamos records corruptos en lugar de explotar la lista
        // entera. Un release gate posterior puede flaggearlos.
        continue;
      }
    }
    return records;
  }

  // ─── PDF generation ────────────────────────────────────────────────────

  /// Carga las TTFs de Roboto desde el bundle. Se inyecta como callback
  /// en los tests para evitar tocar `rootBundle` (que sin
  /// `TestWidgetsFlutterBinding` no está disponible).
  ///
  /// Cuando el caller no provee un loader, se usa `rootBundle.load(...)`.
  /// El loader devuelve `(regularBytes, boldBytes)` ya como `ByteData`.
  static Future<(ByteData, ByteData)> _defaultFontLoader() async {
    final regular = await rootBundle.load(_qcPdfFontRegularAsset);
    final bold = await rootBundle.load(_qcPdfFontBoldAsset);
    return (regular, bold);
  }

  /// Loader inyectable de fuentes para los tests. Por defecto usa
  /// `rootBundle.load(...)`. Los tests pueden pasar una versión que lea
  /// las TTFs desde disco directamente (ver
  /// `test/data/repositories/qc_audit_repository_impl_test.dart`).
  Future<(ByteData, ByteData)> Function() fontLoader = _defaultFontLoader;

  @override
  Future<List<int>> generatePdf(QcAuditRecord record) async {
    final (regularData, boldData) = await fontLoader();
    final theme = pw.ThemeData.withFont(
      base: pw.Font.ttf(regularData),
      bold: pw.Font.ttf(boldData),
    );

    final doc = pw.Document(
      title: 'QC Loopback — ${record.appVersion}',
      author: record.operator,
      subject: 'Audiogram-driven presets — Tramo 3 (Prescription → Hearing aid)',
      theme: theme,
    );

    doc.addPage(
      pw.MultiPage(
        pageFormat: PdfPageFormat.a4,
        margin: const pw.EdgeInsets.all(28),
        theme: theme,
        build: (pw.Context ctx) => <pw.Widget>[
          _buildPdfHeader(record),
          pw.SizedBox(height: 12),
          _buildPdfEquipmentTable(record),
          pw.SizedBox(height: 12),
          _buildPdfMeasurementsTable(record),
          pw.SizedBox(height: 12),
          _buildPdfSummary(record),
          pw.SizedBox(height: 18),
          _buildPdfSignatureBlock(record),
          if (record.notes != null && record.notes!.isNotEmpty) ...[
            pw.SizedBox(height: 12),
            pw.Text('Notas:',
                style: pw.TextStyle(fontWeight: pw.FontWeight.bold)),
            pw.Text(record.notes!),
          ],
        ],
      ),
    );

    final bytes = await doc.save();
    return bytes;
  }

  // --- PDF helpers ---

  pw.Widget _buildPdfHeader(QcAuditRecord record) {
    return pw.Column(
      crossAxisAlignment: pw.CrossAxisAlignment.start,
      children: [
        pw.Text(
          'QC Loopback - Audit Trail',
          style: pw.TextStyle(fontSize: 18, fontWeight: pw.FontWeight.bold),
        ),
        pw.SizedBox(height: 4),
        pw.Text(
          'Spec: audiogram-driven-presets - Tramo 3 '
          '(Prescription -> Hearing aid)',
          style: const pw.TextStyle(fontSize: 9, color: PdfColors.grey700),
        ),
        pw.SizedBox(height: 8),
        pw.Row(
          mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
          children: [
            pw.Text('Operador: ${record.operator}',
                style: pw.TextStyle(fontWeight: pw.FontWeight.bold)),
            pw.Text(
              'Fecha: ${record.timestamp.toUtc().toIso8601String()}',
              style: const pw.TextStyle(fontSize: 10),
            ),
          ],
        ),
        pw.Text('Certificacion: ${record.operatorCertification}',
            style: const pw.TextStyle(fontSize: 10)),
        pw.Text(
          'App: ${record.appVersion} (commit ${record.appCommitHash})',
          style: const pw.TextStyle(fontSize: 10),
        ),
      ],
    );
  }

  pw.Widget _buildPdfEquipmentTable(QcAuditRecord record) {
    final rows = <List<String>>[
      ['Audifono', '${record.hearingAidModel} - S/N ${record.hearingAidSerial}'],
      ['Firmware', record.hearingAidFirmware],
      ['Microfono', '${record.micModel} - S/N ${record.micSerial}'],
      [
        'Calibracion mic',
        record.micCalibrationDate.toUtc().toIso8601String().split('T').first,
      ],
      ['Coupler', record.couplerModel],
      [
        'SPL meter',
        '${record.splMeterModel} - S/N ${record.splMeterSerial}',
      ],
    ];

    return pw.Column(
      crossAxisAlignment: pw.CrossAxisAlignment.start,
      children: [
        pw.Text('Equipamiento',
            style: pw.TextStyle(fontWeight: pw.FontWeight.bold)),
        pw.SizedBox(height: 4),
        pw.TableHelper.fromTextArray(
          headers: const <String>['Equipo', 'Detalle'],
          data: rows,
          headerStyle: pw.TextStyle(fontWeight: pw.FontWeight.bold),
          cellStyle: const pw.TextStyle(fontSize: 9),
          cellAlignment: pw.Alignment.centerLeft,
          headerDecoration: const pw.BoxDecoration(color: PdfColors.grey300),
          columnWidths: const <int, pw.TableColumnWidth>{
            0: pw.FlexColumnWidth(1),
            1: pw.FlexColumnWidth(3),
          },
        ),
      ],
    );
  }

  pw.Widget _buildPdfMeasurementsTable(QcAuditRecord record) {
    final headers = <String>[
      'Audiograma',
      'Freq (Hz)',
      'Input (dB SPL)',
      'Esperado (dB SPL)',
      'Medido (dB SPL)',
      'Delta (dB)',
      'Veredicto',
    ];

    final rows = record.measurements
        .map<List<String>>((m) => <String>[
              m.audiogramName,
              m.frequencyHz.toString(),
              m.inputLevelDbSpl.toStringAsFixed(1),
              m.expectedDbSpl.toStringAsFixed(1),
              m.measuredDbSpl.toStringAsFixed(1),
              (m.deltaDb >= 0 ? '+' : '') + m.deltaDb.toStringAsFixed(1),
              m.passed ? 'PASS' : 'FAIL',
            ])
        .toList(growable: false);

    return pw.Column(
      crossAxisAlignment: pw.CrossAxisAlignment.start,
      children: [
        pw.Text(
          'Mediciones (${record.measurements.length})',
          style: pw.TextStyle(fontWeight: pw.FontWeight.bold),
        ),
        pw.SizedBox(height: 4),
        pw.TableHelper.fromTextArray(
          headers: headers,
          data: rows,
          headerStyle: pw.TextStyle(fontWeight: pw.FontWeight.bold),
          cellStyle: const pw.TextStyle(fontSize: 8),
          headerDecoration: const pw.BoxDecoration(color: PdfColors.grey300),
          cellAlignment: pw.Alignment.center,
        ),
      ],
    );
  }

  pw.Widget _buildPdfSummary(QcAuditRecord record) {
    final passed = record.measurements.where((m) => m.passed).length;
    final failed = record.measurements.length - passed;
    return pw.Container(
      padding: const pw.EdgeInsets.all(8),
      decoration: pw.BoxDecoration(
        color: record.overallPassed ? PdfColors.green50 : PdfColors.red50,
        border: pw.Border.all(
          color: record.overallPassed ? PdfColors.green : PdfColors.red,
        ),
      ),
      child: pw.Row(
        mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
        children: [
          pw.Text(
            'Resultado global: '
            '${record.overallPassed ? 'PASS' : 'FAIL'}',
            style: pw.TextStyle(
              fontSize: 12,
              fontWeight: pw.FontWeight.bold,
              color:
                  record.overallPassed ? PdfColors.green900 : PdfColors.red900,
            ),
          ),
          pw.Text(
            'PASS: $passed / FAIL: $failed / Total: '
            '${record.measurements.length}',
            style: const pw.TextStyle(fontSize: 10),
          ),
        ],
      ),
    );
  }

  pw.Widget _buildPdfSignatureBlock(QcAuditRecord record) {
    return pw.Column(
      crossAxisAlignment: pw.CrossAxisAlignment.start,
      children: [
        pw.Text(
          'Firma del operador QC',
          style: pw.TextStyle(fontWeight: pw.FontWeight.bold),
        ),
        pw.SizedBox(height: 36),
        pw.Container(
          width: 220,
          decoration: const pw.BoxDecoration(
            border: pw.Border(top: pw.BorderSide()),
          ),
          padding: const pw.EdgeInsets.only(top: 4),
          child: pw.Text(
            '${record.operator} - ${record.operatorCertification}',
            style: const pw.TextStyle(fontSize: 10),
          ),
        ),
      ],
    );
  }
}
