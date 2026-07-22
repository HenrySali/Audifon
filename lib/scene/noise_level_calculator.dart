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
/// Requisito: Smart con detección automática de nivel de ruido (2026-06-27)
library;

import 'scene_snapshot.dart';

class NoiseLevelCalculator {
  /// Calcula el nivel de NR apropiado (0-3) basándose en las métricas del snapshot.
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
  /// 3. **Casos especiales:**
  ///    - Ambiente silencioso (input < 45 dB SPL) → NR=0 (evitar amplificar piso de ruido)
  ///    - Ambiente muy ruidoso (input > 75 dB SPL) → NR=3 (máxima protección)
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
    if (inputDb < 45.0) {
      return 0;
    }

    // Caso 2: Ambiente extremadamente ruidoso → NR=3 (máxima protección)
    if (inputDb > 75.0) {
      return 3;
    }

    // Decisión principal basada en SNR
    int nrLevel;
    
    if (snrDb > 20.0) {
      // Habla muy clara → NR mínimo
      nrLevel = 0;
    } else if (snrDb > 15.0) {
      // Habla clara con ruido leve → NR bajo
      nrLevel = 1;
    } else if (snrDb > 10.0) {
      // Habla con ruido moderado → NR medio
      nrLevel = 2;
    } else {
      // Habla con ruido intenso → NR máximo
      nrLevel = 3;
    }

    // Ajuste por noise floor absoluto (límites de seguridad)
    
    // Si el noise es muy bajo, no usar NR agresivo (preservar naturalidad)
    if (noiseDb < 40.0 && nrLevel > 1) {
      nrLevel = 1;
    }

    // Si el noise es muy alto, no usar NR bajo (proteger inteligibilidad)
    if (noiseDb > 65.0 && nrLevel < 2) {
      nrLevel = 2;
    }

    return nrLevel.clamp(0, 3);
  }

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

    return 'NR=$calculatedNr: SNR=${snrDb}dB, Noise=${noiseDb}dB SPL, Input=${inputDb}dB SPL';
  }
}
