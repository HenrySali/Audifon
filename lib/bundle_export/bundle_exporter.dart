// Spec oir-pro-patient-mode — Fase 2 (R3.1, R3.2, R4.1, R4.3, R4.4, R4.5).
// Spec tecnico-paciente-feature-parity — Task 13.1 (Req 5.6, 5.7).
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
import 'dart:developer' as developer;
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import '../data/services/local_downloads_service.dart';
import '../domain/entities/audiogram.dart';
import '../domain/entities/eq_preset.dart';
import '../domain/entities/wdrc_params.dart';
import '../domain/gain_prescriber.dart';

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
  ///
  /// **Re-derivación de presets legacy (Req 5.6, 5.7)** — la lista
  /// [presets] puede contener `null` para presets que el caller (típi-
  /// camente [normalizePresetForExport]) no pudo re-derivar. Esos
  /// `null` se filtran acá antes de serializar; el resto de los presets
  /// se exporta normalmente sin abortar la operación.
  Future<File> exportBundle({
    required Audiogram audiogram,
    required List<EqPreset?> presets,
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

    // Req 5.7: filtrar presets `null` (omitidos por
    // [normalizePresetForExport]) y continuar con los demás sin abortar.
    final exportablePresets = <EqPreset>[
      for (final p in presets)
        if (p != null) p,
    ];

    final body = <String, dynamic>{
      'schemaVersion': _kSchemaVersion,
      'keyVersion': _kKeyVersion,
      'createdAt': DateTime.now().toUtc().toIso8601String(),
      'patient': {
        'name': patientName ?? '',
        'notes': notes ?? '',
      },
      'audiogram': audiogram.toJson(),
      'presets': exportablePresets.map((p) => p.toJson()).toList(),
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

  /// Genera el bundle igual que [exportBundle] pero lo escribe
  /// directamente al directorio público `Download/` del dispositivo
  /// usando `MediaStore.Downloads` (Android 10+) o el filesystem
  /// (Android 9 y anteriores) **sin abrir el share sheet**.
  ///
  /// Útil cuando el técnico solo quiere dejar el `.oirpro.json`
  /// guardado en el celular para enviarlo después por el medio que
  /// prefiera (WhatsApp, Drive, USB), sin depender de `share_plus`
  /// (que actualmente está roto en builds release por reglas ProGuard
  /// incompletas).
  ///
  /// Devuelve un [String] con la ubicación visible al usuario
  /// (ej. `"Descargas/oirpro_juan_20260612.oirpro.json"`).
  ///
  /// Errores:
  /// - [StateError] si `HMAC_SECRET` no fue inyectado en build.
  /// - [LocalDownloadsException] si el canal nativo falla.
  Future<String> exportBundleToLocalDownloads({
    required Audiogram audiogram,
    required List<EqPreset?> presets,
    required WdrcParams wdrc,
    required double mpoThresholdDbSpl,
    required bool mhlEnabled,
    required String defaultPresetName,
    String? patientName,
    String? notes,
    LocalDownloadsService? service,
  }) async {
    if (_hmacSecret.isEmpty) {
      throw StateError(
        'HMAC_SECRET no configurado. Build con --dart-define=HMAC_SECRET=...',
      );
    }

    final exportablePresets = <EqPreset>[
      for (final p in presets)
        if (p != null) p,
    ];

    final body = <String, dynamic>{
      'schemaVersion': _kSchemaVersion,
      'keyVersion': _kKeyVersion,
      'createdAt': DateTime.now().toUtc().toIso8601String(),
      'patient': {
        'name': patientName ?? '',
        'notes': notes ?? '',
      },
      'audiogram': audiogram.toJson(),
      'presets': exportablePresets.map((p) => p.toJson()).toList(),
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
    final filename = _buildFilename(patientName);
    final downloads = service ?? LocalDownloadsService();
    final savedAt = await downloads.saveJsonToDownloads(
      filename: filename,
      content: json,
    );
    return savedAt;
  }

  // --- helpers ---

  /// Re-deriva las ganancias de un preset legacy cuyo `gains=[0,...,0]`
  /// (con tolerancia `1e-6`) y cuyo nombre es distinto a
  /// `"Sin amplificación"` (Req 5.6).
  ///
  /// Comportamiento (alineado con
  /// `AmplificationBloc._resolveGainsForPreset`, que cubre la ruta
  /// runtime — Task 2.3):
  ///
  /// - Si el preset NO es all-zero, o si su nombre es exactamente
  ///   `"Sin amplificación"` (case-sensitive, sin trim), se devuelve el
  ///   preset tal cual.
  /// - Si es all-zero y el nombre es distinto, se invoca
  ///   [GainPrescriber.prescribeFromAudiogram] con el [audiogram]
  ///   recibido y se devuelve un nuevo [EqPreset] con las ganancias
  ///   re-derivadas (resto de campos preservados bit a bit).
  /// - Si el prescriptor lanza, se loguea SEVERE con la causa y se
  ///   devuelve `null`. El preset queda omitido del bundle exportado;
  ///   [exportBundle] filtra `null`s y continúa con los demás presets
  ///   sin abortar la operación (Req 5.7).
  ///
  /// El [prescriber] se inyecta para facilitar tests; el caller real
  /// usa la instancia por defecto que la screen ya construye.
  static EqPreset? normalizePresetForExport(
    EqPreset preset,
    Audiogram audiogram, {
    GainPrescriber? prescriber,
  }) {
    const tolerance = 1e-6;
    final allZero = preset.gains.every((g) => g.abs() <= tolerance);

    // Req 5.6: comparación case-sensitive sin trim contra el string
    // canónico "Sin amplificación".
    if (!allZero || preset.name == 'Sin amplificación') {
      return preset;
    }

    final p = prescriber ?? GainPrescriber();
    try {
      final derived = p.prescribeFromAudiogram(audiogram);
      developer.log(
        'normalizePresetForExport: re-derivación exitosa para preset='
        '"${preset.name}". Gains=$derived',
        name: 'BundleExporter',
        level: 800, // INFO
      );
      // EqPreset no expone copyWith; reconstruimos preservando los
      // demás campos bit a bit.
      return EqPreset(
        name: preset.name,
        description: preset.description,
        gains: derived,
        compressionRatio: preset.compressionRatio,
        compressionKnee: preset.compressionKnee,
        expansionKnee: preset.expansionKnee,
      );
    } catch (e, st) {
      // Req 5.7: log SEVERE con la causa, devolver null para que
      // [exportBundle] omita el preset y continúe con los demás.
      developer.log(
        'normalizePresetForExport: re-derivación de preset='
        '"${preset.name}" falló: $e — preset omitido del bundle.',
        name: 'BundleExporter',
        level: 1000, // SEVERE
        error: e,
        stackTrace: st,
      );
      return null;
    }
  }

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
