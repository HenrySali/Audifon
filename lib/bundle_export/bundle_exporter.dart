// Spec oir-pro-patient-mode — Fase 2 (R3.1, R3.2, R4.1, R4.3, R4.4, R4.5).
//
// Genera el bundle `.oirpro.json` firmado con HMAC-SHA256 que el paciente
// importa en su APK. Acá viaja la configuración clínica completa
// (audiograma, presets, WDRC, MPO, MHL, default preset) más metadata
// del paciente.
//
// La firma se calcula con un secret hardcoded en build (`HMAC_SECRET`
// vía `--dart-define`). Si el secret no está configurado, el exporter
// rechaza la operación para evitar generar bundles inválidos por error
// de configuración del CI.

import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import '../domain/entities/audiogram.dart';
import '../domain/entities/eq_preset.dart';
import '../domain/entities/wdrc_params.dart';

/// Genera bundles `.oirpro.json` firmados con HMAC-SHA256 para enviar
/// al paciente.
///
/// Uso típico desde la pantalla `BundleExportScreen`:
///
/// ```dart
/// final exporter = BundleExporter();
/// final file = await exporter.exportBundle(
///   audiogram: audiogram,
///   presets: presets,
///   wdrc: wdrc,
///   mpoThresholdDbSpl: 95.0,
///   mhlEnabled: false,
///   defaultPresetName: 'Smart NL3',
///   patientName: 'Juan Pérez',
///   notes: 'Hipoacusia bilateral simétrica',
/// );
/// ```
///
/// Errores:
/// - [StateError] si `HMAC_SECRET` no fue inyectado en build.
/// - Cualquier error de IO al escribir el archivo se propaga al caller.
class BundleExporter {
  /// Versión del schema del bundle. Si rompe compatibilidad con
  /// paciente, subir mayor (ver design.md "Bundle JSON — Schema").
  static const String _kSchemaVersion = '1.0.0';

  /// Versión de la clave HMAC. Se incrementa cuando rotamos el secret
  /// para que el paciente pueda detectar bundles firmados con la clave
  /// vieja.
  static const int _kKeyVersion = 1;

  /// Inyectado en build con `--dart-define=HMAC_SECRET=...`.
  /// Si está vacío, exportar tira excepción para no generar bundles
  /// inválidos por error de configuración.
  static const String _hmacSecret = String.fromEnvironment(
    'HMAC_SECRET',
    defaultValue: '',
  );

  /// Genera un bundle `.oirpro.json` firmado con HMAC-SHA256 y dispara
  /// el share sheet de Android. Devuelve el [File] generado.
  ///
  /// El JSON contiene los campos definidos en `design.md` ("Bundle JSON
  /// — Schema") más una sección `signature` con el HMAC-SHA256 del
  /// payload canonicalizado (claves ordenadas alfabéticamente en cada
  /// nivel) en base64.
  Future<File> exportBundle({
    required Audiogram audiogram,
    required List<EqPreset> presets,
    required WdrcParams wdrc,
    required double mpoThresholdDbSpl,
    required bool mhlEnabled,
    required String defaultPresetName,
    String? patientName,
    String? notes,
  }) async {
    if (_hmacSecret.isEmpty) {
      throw StateError(
        'HMAC_SECRET no configurado. Build con --dart-define=HMAC_SECRET=...',
      );
    }

    final body = <String, dynamic>{
      'schemaVersion': _kSchemaVersion,
      'keyVersion': _kKeyVersion,
      'createdAt': DateTime.now().toUtc().toIso8601String(),
      'patient': {
        'name': patientName ?? '',
        'notes': notes ?? '',
      },
      'audiogram': audiogram.toJson(),
      'presets': presets.map((p) => p.toJson()).toList(),
      'wdrc': wdrc.toJson(),
      'mpo': {'thresholdDbSpl': mpoThresholdDbSpl},
      'mhl': {'enabled': mhlEnabled},
      'defaults': {'presetName': defaultPresetName},
    };

    final canonical = _canonicalJson(body);
    final signature = _hmacSha256(canonical, _hmacSecret);
    final wrapped = <String, dynamic>{
      ...body,
      'signature': {'algo': 'HMAC-SHA256', 'value': signature},
    };

    final json = jsonEncode(wrapped);
    final file = await _saveToDownloads(json, _buildFilename(patientName));
    await Share.shareXFiles(
      [XFile(file.path)],
      text: 'Configuración Oír Pro para ${patientName ?? "paciente"}',
    );
    return file;
  }

  // --- helpers ---

  /// JSON con claves ordenadas alfabéticamente en cada nivel para que
  /// la firma sea estable. Es el contrato compartido con la APK
  /// paciente (`bundle_importer.dart`) — cualquier cambio acá rompe la
  /// validación del lado paciente.
  @visibleForTesting
  static String canonicalJsonForTest(Map<String, dynamic> body) =>
      _canonicalJson(body);

  static String _canonicalJson(dynamic value) {
    if (value is Map) {
      final keys = value.keys.cast<String>().toList()..sort();
      final out = <String, dynamic>{};
      for (final k in keys) {
        out[k] = _canonicalize(value[k]);
      }
      return jsonEncode(out);
    }
    return jsonEncode(value);
  }

  static dynamic _canonicalize(dynamic v) {
    if (v is Map) {
      final keys = v.keys.cast<String>().toList()..sort();
      final out = <String, dynamic>{};
      for (final k in keys) {
        out[k] = _canonicalize(v[k]);
      }
      return out;
    }
    if (v is List) {
      return v.map(_canonicalize).toList();
    }
    return v;
  }

  static String _hmacSha256(String text, String secret) {
    final hmac = Hmac(sha256, utf8.encode(secret));
    final digest = hmac.convert(utf8.encode(text));
    return base64Encode(digest.bytes);
  }

  static String _buildFilename(String? name) {
    final safe = (name ?? 'paciente')
        .replaceAll(RegExp(r'[^a-zA-Z0-9_-]'), '_');
    final now = DateTime.now();
    final yyyymmdd = '${now.year}'
        '${now.month.toString().padLeft(2, "0")}'
        '${now.day.toString().padLeft(2, "0")}';
    return 'oirpro_${safe}_$yyyymmdd.oirpro.json';
  }

  Future<File> _saveToDownloads(String json, String filename) async {
    // Guarda en Downloads/ del dispositivo. Si no hay acceso, cae al
    // directorio temporal y dispara share igual.
    Directory? dir;
    try {
      dir = await getDownloadsDirectory();
    } catch (_) {}
    dir ??= await getTemporaryDirectory();
    final file = File('${dir.path}/$filename');
    await file.writeAsString(json, flush: true);
    return file;
  }
}
