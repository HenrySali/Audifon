/// Calculador automático de nivel de reducción de ruido (NR level).
///
/// Analiza las métricas acústicas del [SceneSnapshot] (noise floor, SNR,
/// input level) y sugiere un `nrLevel` óptimo (0-3) para el ambiente actual.
///
/// **Criterio:**
/// - **NR=0 (sin reducción):** Ambiente silencioso o habla clara (SNR > 20 dB, noise < 40 dB SPL)
/// - **NR=1 (reducción leve):** Ruido de fondo bajo (SNR 15-20 dB, noise 40-50 dB SPL)
/// - **NR=2 (reducción media):** Ruido moderado (SNR 10-15 dB, noise 50-60 dB SPL)
/// - **NR=3 (reducción máxima):** Ruido intenso (SNR < 10 dB, noise > 60 dB SPL)
///
/// El cálculo prioriza el SNR (relación señal/ruido) sobre el noise floor
/// absoluto, ya que el objetivo es preservar inteligibilidad del habla en
/// presencia de ruido, no solo reducir el ruido por sí mismo.
///
/// FIX MATRACA: Se agregó rampa temporal — el NR no puede subir más de
/// 1 nivel por ciclo de análisis (~2.5s). Esto evita el salto brusco de
/// NR=0 → NR=3 al entrar a un ambiente ruidoso, que causaba un cambio
/// abrupto en la cadena DSP (WDRC + MPO reaccionaban violentamente al
/// cambio instantáneo de parámetros). Se eliminó el override forzado de
/// `inputDb > 75 → NR=3` para que siempre fluya por el SNR con rampa.
///
/// Requisito: Smart con detección automática de nivel de ruido (2026-06-27)
library;

import 'scene_snapshot.dart';

class NoiseLevelCalculator {
  /// Último NR level calculado. Se usa para aplicar la rampa temporal.
  /// `null` antes del primer cálculo (sin restricción de rampa).
  static int? _previousNrLevel;

  /// Calcula el nivel de NR apropiado (0-3) basándose en las métricas del
  /// snapshot, con rampa temporal que limita el cambio a ±1 nivel por ciclo.
  ///
  /// **Parámetros:**
  /// - [snapshot]: Snapshot con métricas acústicas del SceneAnalyzer C++
  ///
  /// **Lógica de decisión:**
  ///
  /// 1. **Prioridad al SNR (Signal-to-Noise Ratio):**
  ///    - SNR > 20 dB → habla muy clara → NR=0
  ///    - SNR 15-20 dB → habla clara con ruido leve → NR=1
  ///    - SNR 10-15 dB → habla con ruido moderado → NR=2
  ///    - SNR < 10 dB → habla con ruido intenso → NR=3
  ///
  /// 2. **Ajuste por noise floor absoluto:**
  ///    - Si noise < 40 dB SPL → nunca usar NR > 1 (preservar naturalidad)
  ///    - Si noise > 65 dB SPL → nunca usar NR < 2 (proteger inteligibilidad)
  ///
  /// 3. **Caso especial:**
  ///    - Ambiente silencioso (input < 45 dB SPL) → NR=0 (evitar amplificar
  ///      piso de ruido). Este caso salta la rampa (siempre seguro bajar a 0
  ///      en silencio).
  ///
  /// 4. **Rampa temporal (FIX MATRACA):**
  ///    - El NR no puede subir más de 1 nivel por ciclo de análisis.
  ///    - El NR puede bajar sin límite (bajar es siempre seguro para
  ///      artefactos, no genera gain pumping).
  ///
  /// **Valores de referencia:**
  /// - 40 dB SPL: biblioteca silenciosa
  /// - 50 dB SPL: oficina tranquila
  /// - 60 dB SPL: conversación normal
  /// - 70 dB SPL: calle con tráfico
  /// - 80 dB SPL: aspiradora, subte
  static int calculateNrLevel(SceneSnapshot snapshot) {
    final snrDb = snapshot.snrDb;
    final noiseDb = snapshot.noiseFloorDbSpl;
    final inputDb = snapshot.inputDbSpl;

    // Caso 1: Ambiente muy silencioso → NR=0 (no amplificar piso de ruido)
    // Salta la rampa: en silencio real, siempre es seguro ir a NR=0
    // inmediatamente (no hay señal que pueda causar artefactos).
    if (inputDb < 45.0) {
      _previousNrLevel = 0;
      return 0;
    }

    // FIX MATRACA: Eliminado el override forzado `inputDb > 75 → NR=3`.
    // Ese salto instantáneo a NR=3 causaba que toda la cadena DSP
    // recibiera parámetros agresivos de golpe (compression ratio alta,
    // TNR on, etc.) produciendo el artefacto de matraca. Ahora el
    // nivel se determina por SNR y sube gradualmente vía la rampa.

    // Decisión principal basada en SNR
    int targetNrLevel;

    if (snrDb > 20.0) {
      // Habla muy clara → NR mínimo
      targetNrLevel = 0;
    } else if (snrDb > 15.0) {
      // Habla clara con ruido leve → NR bajo
      targetNrLevel = 1;
    } else if (snrDb > 10.0) {
      // Habla con ruido moderado → NR medio
      targetNrLevel = 2;
    } else {
      // Habla con ruido intenso → NR máximo
      targetNrLevel = 3;
    }

    // Ajuste por noise floor absoluto (límites de seguridad)

    // Si el noise es muy bajo, no usar NR agresivo (preservar naturalidad)
    if (noiseDb < 40.0 && targetNrLevel > 1) {
      targetNrLevel = 1;
    }

    // Si el noise es muy alto, no usar NR bajo (proteger inteligibilidad)
    if (noiseDb > 65.0 && targetNrLevel < 2) {
      targetNrLevel = 2;
    }

    targetNrLevel = targetNrLevel.clamp(0, 3);

    // FIX MATRACA: Rampa temporal — máximo +1 nivel por ciclo de análisis.
    // Subir es restringido (máx +1 por ciclo) para evitar saltos bruscos.
    // Bajar es libre (sin restricción) porque reducir NR nunca causa
    // artefactos — es quitar procesamiento, no agregarlo.
    final previous = _previousNrLevel;
    int finalNrLevel;

    if (previous == null) {
      // Primer cálculo: sin restricción de rampa
      finalNrLevel = targetNrLevel;
    } else if (targetNrLevel > previous) {
      // Subiendo: máximo +1 por ciclo
      finalNrLevel = previous + 1;
    } else {
      // Bajando o igual: sin restricción
      finalNrLevel = targetNrLevel;
    }

    finalNrLevel = finalNrLevel.clamp(0, 3);
    _previousNrLevel = finalNrLevel;
    return finalNrLevel;
  }

  /// Reinicia el estado de la rampa. Útil en tests o al reiniciar la
  /// sesión de análisis.
  static void reset() {
    _previousNrLevel = null;
  }

  /// Devuelve el último NR level calculado (para diagnóstico).
  /// `null` si nunca se calculó.
  static int? get previousNrLevel => _previousNrLevel;

  /// Devuelve una etiqueta legible del nivel de NR para debugging/UI.
  static String labelFor(int nrLevel) {
    switch (nrLevel) {
      case 0:
        return 'Sin reducción';
      case 1:
        return 'Reducción leve';
      case 2:
        return 'Reducción media';
      case 3:
        return 'Reducción máxima';
      default:
        return 'Desconocido';
    }
  }

  /// Devuelve una descripción del por qué se eligió este NR level para debugging.
  static String reasonFor(SceneSnapshot snapshot, int calculatedNr) {
    final snrDb = snapshot.snrDb.toStringAsFixed(1);
    final noiseDb = snapshot.noiseFloorDbSpl.toStringAsFixed(1);
    final inputDb = snapshot.inputDbSpl.toStringAsFixed(1);
    final prev = _previousNrLevel;
    final rampNote = prev != null && calculatedNr < prev + 1
        ? '' : ' [ramped from target]';

    return 'NR=$calculatedNr: SNR=${snrDb}dB, Noise=${noiseDb}dB SPL, '
        'Input=${inputDb}dB SPL$rampNote';
  }
}
