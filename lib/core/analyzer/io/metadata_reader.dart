// Feature: in-app-diagnostic-analyzer
// Module: io/metadata_reader
//
// Wraps the existing `DiagnosticMetadata.fromJson` factory with strict
// missing-field detection. The factory throws `TypeError` /
// `FormatException` on missing keys; we catch those and re-throw as
// `MetadataFormatException` with a Spanish message naming the field.

import 'dart:convert';
import 'dart:io';

import '../../diagnostic_metadata.dart';

/// Thrown when the JSON does not contain a required field, or when an
/// invariant (e.g. `eqGainsDb.length == 12`) is violated.
class MetadataFormatException implements Exception {
  /// The missing or invalid field path (e.g. `dspConfiguration.eqGainsDb`).
  final String missingField;

  /// Spanish-language description.
  final String message;

  const MetadataFormatException({
    required this.missingField,
    required this.message,
  });

  @override
  String toString() =>
      'MetadataFormatException($missingField): $message';
}

/// Reads and validates a `DiagnosticMetadata` JSON file.
class MetadataReader {
  /// Reads `path` from disk.
  Future<DiagnosticMetadata> read(String path) async {
    final raw = await File(path).readAsString();
    return parse(raw);
  }

  /// Parses an in-memory JSON string. Surfaced separately for property
  /// tests (Property 2).
  DiagnosticMetadata parse(String jsonString) {
    final dynamic decoded;
    try {
      decoded = jsonDecode(jsonString);
    } on FormatException catch (e) {
      throw MetadataFormatException(
        missingField: 'json',
        message: 'JSON inválido: ${e.message}',
      );
    }
    if (decoded is! Map<String, dynamic>) {
      throw const MetadataFormatException(
        missingField: 'root',
        message: 'El JSON raíz debe ser un objeto.',
      );
    }
    return parseMap(decoded);
  }

  /// Parses an already-decoded JSON map.
  DiagnosticMetadata parseMap(Map<String, dynamic> json) {
    // Top-level required fields.
    _requireKey(json, 'schemaVersion', 'schemaVersion');
    _requireKey(json, 'appVersion', 'appVersion');
    _requireKey(json, 'recordingTimestamp', 'recordingTimestamp');
    _requireKey(json, 'audio', 'audio');
    _requireKey(json, 'dspConfiguration', 'dspConfiguration');
    _requireKey(json, 'device', 'device');

    final audio = _requireMap(json, 'audio', 'audio');
    for (final k in const [
      'sampleRate',
      'bitDepth',
      'channelCount',
      'durationSeconds',
      'totalSamplesPerChannel',
      'recordedSamples',
    ]) {
      _requireKey(audio, k, 'audio.$k');
    }

    final dsp = _requireMap(json, 'dspConfiguration', 'dspConfiguration');
    for (final k in const [
      'audiogramThresholds',
      'activePreset',
      'eqGainsDb',
      'wdrc',
      'mpoThresholdDbSpl',
      'dnn',
      'nrLevel',
      'tnrEnabled',
    ]) {
      _requireKey(dsp, k, 'dspConfiguration.$k');
    }

    final eqGains = dsp['eqGainsDb'];
    if (eqGains is! List || eqGains.length != 12) {
      throw const MetadataFormatException(
        missingField: 'dspConfiguration.eqGainsDb',
        message: 'El arreglo eqGainsDb debe contener 12 valores',
      );
    }

    final wdrc = _requireMap(dsp, 'wdrc', 'dspConfiguration.wdrc');
    for (final k in const [
      'expansionKnee',
      'expansionRatio',
      'compressionKnee',
      'compressionRatio',
      'attackMs',
      'releaseMs',
    ]) {
      _requireKey(wdrc, k, 'dspConfiguration.wdrc.$k');
    }

    final dnn = _requireMap(dsp, 'dnn', 'dspConfiguration.dnn');
    _requireKey(dnn, 'enabled', 'dspConfiguration.dnn.enabled');
    _requireKey(dnn, 'intensity', 'dspConfiguration.dnn.intensity');

    final device = _requireMap(json, 'device', 'device');
    for (final k in const [
      'inputDevice',
      'outputDevice',
      'bluetoothDevice',
      'bluetoothConnectionType',
    ]) {
      _requireKey(device, k, 'device.$k');
    }

    // Delegate to the model's existing fromJson; defaults for
    // `preDnnLevelDb` and `wdrcLevelSource` are handled there.
    try {
      return DiagnosticMetadata.fromJson(json);
    } catch (e, st) {
      // Surface unexpected parsing issues as MetadataFormatException so
      // the UI banner shows a Spanish message.
      throw MetadataFormatException(
        missingField: 'fromJson',
        message: 'Error al parsear DiagnosticMetadata: $e\n$st',
      );
    }
  }

  static void _requireKey(
    Map<String, dynamic> map,
    String key,
    String fieldPath,
  ) {
    if (!map.containsKey(key) || map[key] == null) {
      throw MetadataFormatException(
        missingField: fieldPath,
        message: 'Falta el campo obligatorio "$fieldPath" en el JSON.',
      );
    }
  }

  static Map<String, dynamic> _requireMap(
    Map<String, dynamic> map,
    String key,
    String fieldPath,
  ) {
    final v = map[key];
    if (v is! Map<String, dynamic>) {
      throw MetadataFormatException(
        missingField: fieldPath,
        message: 'El campo "$fieldPath" debe ser un objeto JSON.',
      );
    }
    return v;
  }
}
