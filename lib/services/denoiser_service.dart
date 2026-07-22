import 'package:flutter/services.dart';
import 'package:hive/hive.dart';

/// Tipos de motor de denoising disponibles.
enum DenoiserType {
  rnnoise,   // "Estándar" — bajo consumo
  dfn3,      // "Premium" — máxima calidad
  gtcrn,     // "Analítico" — modulación VAD + dual-mic
}

/// Servicio para controlar el selector de motor de denoising.
/// Comunica con el nativo via MethodChannel y persiste la selección en Hive.
class DenoiserService {
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
    try {
      await _channel.invokeMethod('selectDenoiser', {'type': type.index});
      final box = await Hive.openBox(_boxName);
      await box.put(_key, type.index);
    } catch (_) {}
    await refreshActive();
  }

  /// Actualiza el estado del motor activo (puede diferir por fallback).
  Future<void> refreshActive() async {
    try {
      final int idx = await _channel.invokeMethod('getActiveDenoiser');
      if (idx >= 0 && idx < DenoiserType.values.length) {
        _active = DenoiserType.values[idx];
      }
    } catch (_) {}
  }
}
