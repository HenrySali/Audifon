import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:hive/hive.dart';

/// Tipos de motor de denoising disponibles.
enum DenoiserType {
  rnnoise,       // "Estándar" — bajo consumo
  dfn3,          // "Premium" — máxima calidad (retirado)
  gtcrn,         // "Analítico" — modulación VAD + dual-mic (retirado)
  dpdfnet,       // "Ultra" — DPDFNet-4, SOTA causal 2025
  dpdfnet2,      // "Inteligente" — DPDFNet-2 48kHz nativo, baja latencia
}

/// Servicio para controlar el selector de motor de denoising.
/// Comunica con el nativo via MethodChannel y persiste la selección en Hive.
/// Extiende ChangeNotifier para que widgets dependientes (panel de calidad)
/// se rebuilden automáticamente al cambiar el motor seleccionado.
class DenoiserService extends ChangeNotifier {
  static const _channel = MethodChannel('com.psk.hearing_aid/audio');
  static const _boxName = 'dsp_prefs';
  static const _key = 'selectedDenoiserType';

  DenoiserType _selected = DenoiserType.rnnoise;
  DenoiserType _active = DenoiserType.rnnoise;

  DenoiserType get selected => _selected;
  DenoiserType get active => _active;
  bool get isFallback => _active != _selected;

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
    // Los 3 motores disponibles (RNNoise/DPDFNet-4/DPDFNet-2) siempre cargan OK.
    // Asignar active = selected inmediatamente evita el flash de "fallback"
    // que ocurre por la race condition con el audio thread.
    _active = type;
    try {
      await _channel.invokeMethod('selectDenoiser', {'type': type.index});
      final box = await Hive.openBox(_boxName);
      await box.put(_key, type.index);
    } catch (_) {}
    // Confirmar con el nativo (por si hubo fallback real).
    await refreshActive();
    notifyListeners();
  }

  /// Actualiza el estado del motor activo (puede diferir por fallback).
  Future<void> refreshActive() async {
    try {
      final int idx = await _channel.invokeMethod('getActiveDenoiser');
      if (idx >= 0 && idx < DenoiserType.values.length) {
        _active = DenoiserType.values[idx];
      }
    } catch (_) {
      // Si falla, asumir que el activo es el seleccionado (ambos motores
      // disponibles siempre están online).
      _active = _selected;
    }
  }

  // ─── Registro de "matraca" (crackle) y calidad de los 3 sistemas ──────

  /// Obtiene el registro completo de matraca/calidad como texto copiable.
  ///
  /// Incluye, por sesión: la matraca detectada en la ENTRADA a los sistemas
  /// de limpieza, en cada uno de los sistemas y en la SALIDA FINAL que
  /// escucha el usuario, más un diagnóstico automático del origen y la
  /// calidad de cada etapa. Cadena vacía si el motor no está corriendo.
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

  // ─── BT bypass denoiser (reduce latencia ~10ms en modo SCO) ────────

  /// Habilita/deshabilita el bypass automático del denoiser en modo BT/SCO.
  /// Cuando activo y la app usa conversationMode (SCO), el denoiser se salta.
  Future<void> setBtBypassDenoiser(bool bypass) async {
    try {
      await _channel.invokeMethod('setBtBypassDenoiser', {'bypass': bypass});
    } catch (_) {}
    notifyListeners();
  }

  /// @return true si el bypass BT del denoiser está habilitado.
  Future<bool> getBtBypassDenoiser() async {
    try {
      return await _channel.invokeMethod<bool>('getBtBypassDenoiser') ?? true;
    } catch (_) {
      return true;
    }
  }
}
