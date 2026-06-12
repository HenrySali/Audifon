import 'dart:io';

import 'package:share_plus/share_plus.dart';

import '../../core/diagnostic_metadata.dart';

/// Servicio de exportación de archivos de diagnóstico DSP para el técnico.
///
/// Portado del paciente (`PACIENTE/oir_pro_patient_app/lib/core/
/// diagnostic_export_service.dart`) con extensiones del técnico:
/// - `mhlPrescriptionEnabled`, `musicModeEnabled`, `smartEnabled` y
///   `effectiveComfort` se exigen como parámetros requeridos de
///   [generateMetadata].
/// - El llamador es responsable de calcular `wdrc.compressionRatio`
///   con `_effectiveCompressionRatio(bundle)` ANTES de invocar el
///   servicio. Este recibe el valor ya resuelto.
/// - `dnn.intensity` y `nrLevel` se leen desde Settings al momento
///   de la grabación y se pasan ya resueltos.
/// - El JSON se emite con `wdrc.compressionRatio` y `dnn.intensity`
///   redondeados a 2 decimales, y `nrLevel` como entero.
/// - [export] abre el share sheet del SO con ambos archivos
///   adjuntos vía `Share.shareXFiles`.
///
/// Spec: tecnico-paciente-feature-parity · Task 11.3 · Requirements
/// 6.5, 6.6, 6.7, 6.8, 6.9, 6.10.
class DiagnosticExportService {
  /// Mensaje de error cuando los archivos no se encuentran.
  static const String fileNotFoundError =
      'Los archivos de diagnóstico no se encuentran. Realice una nueva grabación.';

  /// Exporta el par WAV + JSON mediante el share sheet del SO.
  ///
  /// Valida que ambos archivos existan antes de invocar la hoja de
  /// compartir. Retorna `true` si el share concluyó (success o
  /// dismissed).
  ///
  /// Lanza [FileSystemException] con mensaje en español si alguno
  /// de los archivos no existe.
  ///
  /// Spec: Requirement 6.10.
  Future<bool> export(String wavPath, String jsonPath) async {
    final wavFile = File(wavPath);
    final jsonFile = File(jsonPath);

    if (!wavFile.existsSync()) {
      throw FileSystemException(fileNotFoundError, wavPath);
    }

    if (!jsonFile.existsSync()) {
      throw FileSystemException(fileNotFoundError, jsonPath);
    }

    final result = await Share.shareXFiles(
      [
        XFile(wavPath),
        XFile(jsonPath),
      ],
      subject: 'Diagnóstico DSP',
    );

    return result.status == ShareResultStatus.success ||
        result.status == ShareResultStatus.dismissed;
  }

  /// Genera el archivo JSON de metadatos junto al archivo WAV.
  ///
  /// Crea una instancia de [DiagnosticMetadata] con los parámetros
  /// proporcionados, lo serializa a JSON y lo escribe en disco.
  ///
  /// El llamador DEBE pasar:
  /// - [wdrc] con `compressionRatio` ya calculado vía
  ///   `_effectiveCompressionRatio(bundle)` (Req 6.7).
  /// - [dnn] con `intensity` leída de Settings al instante de la
  ///   grabación (Req 6.7, 6.8).
  /// - [nrLevel] leído de Settings al instante de la grabación
  ///   (Req 6.8).
  /// - Los 4 flags/valores de extensión del técnico
  ///   ([mhlPrescriptionEnabled], [musicModeEnabled], [smartEnabled],
  ///   [effectiveComfort]) que reproducen el estado runtime al
  ///   momento de la grabación (Req 6.5, 6.13).
  ///
  /// El servicio aplica redondeo a 2 decimales (`toStringAsFixed(2)`)
  /// para `wdrc.compressionRatio` y `dnn.intensity` antes de
  /// serializar (Req 6.9). `nrLevel` es entero y se serializa tal cual.
  ///
  /// Parámetros opcionales:
  /// - [preDnnLevelDb]: nivel pre-DNN en dB SPL del último bloque
  ///   (default `-1.0` = no disponible). Spec dsp-chain-optimization.
  /// - [wdrcLevelSource]: `"pre-dnn"` si el WDRC usó el nivel externo
  ///   del AudioEngine, `"local"` si midió RMS desde el buffer
  ///   (default `"local"`). Spec dsp-chain-optimization.
  ///
  /// Retorna la ruta absoluta del archivo JSON generado.
  Future<String> generateMetadata({
    required String directory,
    required String baseName,
    required int recordedSamples,
    required Map<int, double> audiogramThresholds,
    required String activePreset,
    required List<double> eqGainsDb,
    required WdrcMetadata wdrc,
    required double mpoThresholdDbSpl,
    required DnnMetadata dnn,
    required int nrLevel,
    required bool tnrEnabled,
    required DeviceMetadata device,
    required String appVersion,
    // ─── Extensiones del técnico (Req 6.5, 6.13) ───────────────────
    required bool mhlPrescriptionEnabled,
    required bool musicModeEnabled,
    required bool smartEnabled,
    required double effectiveComfort,
    double preDnnLevelDb = -1.0,
    String wdrcLevelSource = 'local',
  }) async {
    // Redondeo a 2 decimales para wdrc.compressionRatio y dnn.intensity
    // antes de pasar al modelo (Req 6.9). nrLevel ya es entero.
    final wdrcRounded = WdrcMetadata(
      expansionKnee: wdrc.expansionKnee,
      expansionRatio: wdrc.expansionRatio,
      compressionKnee: wdrc.compressionKnee,
      compressionRatio: _round2(wdrc.compressionRatio),
      attackMs: wdrc.attackMs,
      releaseMs: wdrc.releaseMs,
    );
    final dnnRounded = DnnMetadata(
      enabled: dnn.enabled,
      intensity: _round2(dnn.intensity),
    );

    final metadata = DiagnosticMetadata(
      recordedSamples: recordedSamples,
      audiogramThresholds: audiogramThresholds,
      activePreset: activePreset,
      eqGainsDb: eqGainsDb,
      wdrc: wdrcRounded,
      mpoThresholdDbSpl: mpoThresholdDbSpl,
      dnn: dnnRounded,
      nrLevel: nrLevel,
      tnrEnabled: tnrEnabled,
      device: device,
      recordingTimestamp: DateTime.now().toUtc().toIso8601String(),
      appVersion: appVersion,
      preDnnLevelDb: preDnnLevelDb,
      wdrcLevelSource: wdrcLevelSource,
      // Extensiones del técnico (Task 11.1 · Req 6.13).
      mhlPrescriptionEnabled: mhlPrescriptionEnabled,
      musicModeEnabled: musicModeEnabled,
      smartEnabled: smartEnabled,
      effectiveComfort: effectiveComfort,
    );

    final jsonContent = metadata.toJsonString();
    final jsonPath = '$directory/$baseName.json';
    final jsonFile = File(jsonPath);

    await jsonFile.writeAsString(jsonContent);

    return jsonPath;
  }

  /// Redondea a 2 decimales preservando el tipo `double`.
  ///
  /// `NaN` y `±Infinity` se devuelven sin modificar (no son
  /// representables como decimales fijos). El código upstream debe
  /// haber clampeado/saneado el valor antes de pasarlo, pero el
  /// servicio no aborta si se le pasa un valor patológico.
  static double _round2(double v) {
    if (v.isNaN || v.isInfinite) return v;
    return double.parse(v.toStringAsFixed(2));
  }
}
