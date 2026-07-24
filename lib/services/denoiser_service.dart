import 'package:flutter/services.dart';
import 'package:hive/hive.dart';

/// Tipos de motor de denoising disponibles.
enum DenoiserType {
  rnnoise,   // "Estándar" — bajo consumo
  dfn3,      // "Premium" — máxima calidad
  gtcrn,     // "Analítico" — modulación VAD + dual-mic
  dpdfnet,   // "Ultra" — DPDFNet-4, SOTA causal 2025
}

/// Servicio para controlar el selector de motor de denoising.
/// Comunica con el nativo via MethodChannel y persiste la selección en Hive.
class DenoiserService {
  static const _channel = MethodChannel('com.psk.hearing_aid/audio');
  static const _boxName = 'dsp_prefs';
  static const _key = 'selectedDenoiserType';

  DenoiserType _selected = DenoiserType.rnnoise;
  DenoiserType? _active = DenoiserType.rnnoise;
  bool _bypassed = false;

  DenoiserType get selected => _selected;

  /// Motor realmente activo, o `null` si el nativo reportó bypass
  /// (ningún motor disponible → el audio pasa sin limpieza de ruido).
  DenoiserType? get active => _active;

  /// true cuando el nativo no pudo activar NINGÚN motor (bypass total).
  bool get isBypassed => _bypassed;

  /// true cuando hay un motor procesando pero distinto al seleccionado
  /// (fallback real). El bypass total NO cuenta como fallback: se reporta
  /// aparte vía [isBypassed] para no mentir mostrando un motor que no corre.
  bool get isFallback => !_bypassed && _active != null && _active != _selected;

  /// Carga la selección persistida y la aplica al nativo.
  Future<void> initialize() async {
    try {
      final box = await Hive.openBox(_boxName);
      final idx = box.get(_key, defaultValue: 0) as int;
      if (idx >= 0 && idx < DenoiserType.values.length) {
        _selected = DenoiserType.values[idx];
      }
    } catch (_) {}
    await selectDenoiser(_selected);
  }

  /// Selecciona el motor de denoising. Persiste y propaga al nativo.
  Future<void> selectDenoiser(DenoiserType type) async {
    _selected = type;
    try {
      await _channel.invokeMethod('selectDenoiser', {'type': type.index});
      final box = await Hive.openBox(_boxName);
      await box.put(_key, type.index);
    } catch (_) {}
    await refreshActive();
  }

  /// Actualiza el estado del motor activo (puede diferir por fallback, o ser
  /// bypass si el nativo devuelve -1 porque ningún motor está disponible).
  Future<void> refreshActive() async {
    try {
      final int idx = await _channel.invokeMethod('getActiveDenoiser');
      if (idx < 0) {
        _bypassed = true;
        _active = null;
      } else if (idx < DenoiserType.values.length) {
        _bypassed = false;
        _active = DenoiserType.values[idx];
      }
    } catch (_) {}
  }

  // ─── Registro de "matraca" (crackle) y calidad de los 3 sistemas ──────

  /// Obtiene el registro completo de matraca/calidad como texto copiable.
  ///
  /// Incluye, por sesión: la matraca detectada en la ENTRADA a los sistemas
  /// de limpieza, en cada uno de los 3 sistemas (RNNoise/DFN3/GTCRN) y en la
  /// SALIDA FINAL que escucha el usuario, más un diagnóstico automático del
  /// origen (fuente previa vs. introducida por un sistema vs. etapa DSP
  /// posterior) y la calidad de cada etapa. Cadena vacía si el motor no
  /// está corriendo.
  Future<String> getArtifactReport() async {
    try {
      final String? report =
          await _channel.invokeMethod<String>('getDenoiserArtifactReport');
      return report ?? '';
    } catch (_) {
      return '';
    }
  }

  /// Reinicia el registro (inicia una nueva sesión de medición).
  Future<void> resetArtifactLog() async {
    try {
      await _channel.invokeMethod('resetDenoiserArtifactLog');
    } catch (_) {}
  }

  /// Obtiene el resumen estructurado del registro (para UI en vivo).
  /// Claves con prefijo por etapa: `input*`, `sys0*` (RNNoise), `sys1*`
  /// (DFN3), `sys2*` (GTCRN), `output*`; más `activeEngine` (int).
  Future<Map<String, dynamic>> getArtifactSummary() async {
    try {
      final Map<dynamic, dynamic>? raw =
          await _channel.invokeMethod<Map<dynamic, dynamic>>(
              'getDenoiserArtifactSummary');
      if (raw == null) return <String, dynamic>{};
      return raw.map((k, v) => MapEntry(k.toString(), v));
    } catch (_) {
      return <String, dynamic>{};
    }
  }

  /// Copia el registro de matraca/calidad al portapapeles.
  /// @return true si había un registro para copiar.
  Future<bool> copyArtifactReportToClipboard() async {
    final report = await getArtifactReport();
    if (report.isEmpty) return false;
    await Clipboard.setData(ClipboardData(text: report));
    return true;
  }
}
