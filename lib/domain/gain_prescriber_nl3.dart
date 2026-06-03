/// Prescriptor NAL-NL3-inspired — clase principal.
///
/// Calcula ganancias de inserción objetivo aplicando correcciones
/// inspiradas en NAL-NL3 sobre la base NAL-NL2 existente. Usa composición
/// (no herencia) del [GainPrescriber] para obtener la prescripción base.
///
/// El módulo es una función pura: mismos inputs → mismos outputs, sin
/// estado mutable ni dependencias externas. Esto permite testing unitario
/// y property-based testing en aislamiento.
///
/// Requisitos: 2.1, 2.7, 2.8, 8.1, 8.2, 8.4, 8.5, 8.6
library;

import 'entities/audiogram.dart';
import 'entities/loss_type.dart';
import 'entities/nl3_prescription_result.dart';
import 'entities/patient_profile.dart';
import 'entities/prescription_mode.dart';
import 'entities/wdrc_params.dart';
import 'gain_prescriber.dart';
import 'mhl_module.dart';

/// Prescriptor NAL-NL3-inspired.
///
/// Calcula ganancias de inserción objetivo para las 12 bandas del EQ
/// aplicando correcciones por tipo de pérdida auditiva sobre la base
/// NAL-NL2. Soporta tres modos de prescripción: quiet, comfortInNoise
/// y mhl.
///
/// Ejemplo de uso:
/// ```dart
/// final prescriber = GainPrescriberNL3();
/// final result = prescriber.prescribeFromAudiogram(
///   audiogram,
///   profile: PatientProfile(experienceMonths: 3),
///   mode: PrescriptionMode.quiet,
/// );
/// ```
///
/// Requisitos: 8.1, 8.4, 8.5, 8.6
class GainPrescriberNL3 {
  /// Prescriptor NL2 usado para la base de cálculo (composición).
  final GainPrescriber _nl2Prescriber;

  /// Crea una instancia del prescriptor NL3-inspired.
  ///
  /// [nl2Prescriber] Instancia opcional de [GainPrescriber] para
  /// obtener la prescripción base NAL-NL2. Si no se provee, se crea
  /// una instancia nueva internamente.
  GainPrescriberNL3({GainPrescriber? nl2Prescriber})
      : _nl2Prescriber = nl2Prescriber ?? GainPrescriber();

  /// Prescribe ganancias NL3 con compensación de auricular aplicada.
  ///
  /// Calcula la prescripción NL3 completa y luego aplica la compensación
  /// del auricular a las ganancias finales:
  /// `finalGain[i] = clamp(prescribed[i] + compensation[freq_i], 0, 50)`.
  ///
  /// Interfaz compatible con el [GainPrescriber.prescribeWithCompensation]
  /// de NL2 para integración transparente en el pipeline DSP.
  ///
  /// [audiogram] Audiograma con 12 umbrales (dB HL).
  /// [compensation] Mapa de frecuencia (Hz) a compensación (dB).
  ///   Valores positivos añaden ganancia, negativos la reducen.
  ///   Rango esperado: [-20, +20] dB por banda.
  /// [profile] Perfil del paciente (experiencia, conducción ósea). Opcional.
  /// [mode] Modo de prescripción: quiet (default), comfortInNoise, mhl.
  ///
  /// Retorna [NL3PrescriptionResult] con `finalGains` compensadas y
  /// `prescribedGains` sin compensación (para referencia clínica).
  ///
  /// Throws [ArgumentError] si el audiograma es vacío o incompleto.
  ///
  /// Requisitos: 7.3, 7.4
  NL3PrescriptionResult prescribeWithCompensation(
    Audiogram audiogram,
    Map<int, double> compensation, {
    PatientProfile? profile,
    PrescriptionMode mode = PrescriptionMode.quiet,
  }) {
    // Obtener prescripción NL3 completa (sin compensación de auricular).
    final result = prescribeFromAudiogram(
      audiogram,
      profile: profile,
      mode: mode,
    );

    // Aplicar compensación de auricular a las ganancias prescritas.
    final compensatedGains = _applyHeadphoneCompensation(
      result.prescribedGains,
      compensation,
    );

    // Retornar resultado con finalGains compensadas.
    return NL3PrescriptionResult(
      prescribedGains: result.prescribedGains,
      finalGains: compensatedGains,
      compressionRatios: result.compressionRatios,
      lossType: result.lossType,
      mode: result.mode,
      cinActive: result.cinActive,
      wdrcOverrides: result.wdrcOverrides,
      ptaWarning: result.ptaWarning,
      timestamp: result.timestamp,
    );
  }

  /// Aplica compensación de auricular a ganancias prescritas.
  ///
  /// Para cada banda i:
  ///   `finalGain[i] = clamp(prescribedGain[i] + compensation[freq_i], 0, 50)`
  ///
  /// Si la frecuencia no está en el mapa de compensación, se asume 0 dB.
  ///
  /// Requisitos: 7.3
  List<double> _applyHeadphoneCompensation(
    List<double> prescribedGains,
    Map<int, double> compensation,
  ) {
    const frequencies = Audiogram.standardFrequencies;
    final finalGains = <double>[];

    for (int i = 0; i < frequencies.length; i++) {
      final freq = frequencies[i];
      final comp = compensation[freq] ?? 0.0;
      final gain = (prescribedGains[i] + comp).clamp(
        GainPrescriber.minGainDb,
        GainPrescriber.maxGainDb,
      );
      finalGains.add(gain);
    }

    return finalGains;
  }

  /// Prescribe ganancias NL3-inspired a partir de un audiograma.
  ///
  /// Flujo:
  /// 1. Valida el audiograma (12 umbrales requeridos).
  /// 2. Obtiene ganancias base NAL-NL2 del prescriptor compuesto.
  /// 3. Clasifica la forma del audiograma.
  /// 4. Aplica correcciones NL3 por tipo de pérdida (stub en esta etapa).
  /// 5. Retorna [NL3PrescriptionResult] con ganancias y metadata.
  ///
  /// [audiogram] Audiograma con 12 umbrales (dB HL) en las frecuencias
  ///   estándar [250, 500, 750, 1000, 1500, 2000, 2500, 3000, 3500,
  ///   4000, 6000, 8000] Hz.
  /// [profile] Perfil del paciente (experiencia con amplificación,
  ///   conducción ósea). Opcional — si es null, se asume usuario
  ///   experimentado sin componente conductivo.
  /// [mode] Modo de prescripción: quiet (default), comfortInNoise, mhl.
  ///
  /// Retorna [NL3PrescriptionResult] con ganancias prescritas, ratios
  /// de compresión, tipo de pérdida detectada y metadata del modo.
  ///
  /// Throws [ArgumentError] si el audiograma es vacío o incompleto.
  ///
  /// Requisitos: 2.1, 2.7, 2.8, 8.2, 8.6
  NL3PrescriptionResult prescribeFromAudiogram(
    Audiogram audiogram, {
    PatientProfile? profile,
    PrescriptionMode mode = PrescriptionMode.quiet,
  }) {
    // Validar audiograma: rechazar vacío o incompleto.
    _validateAudiogram(audiogram);

    // Clasificar la forma del audiograma (se calcula incluso en MHL para
    // exponer el LossType en el resultado y mantener metadata consistente).
    final lossType = classifyAudiogram(
      audiogram,
      boneConduction: profile?.boneConduction,
    );

    // Modo MHL: delegar al MhlModule para unificar el path. Así, una llamada
    // standalone a prescribeFromAudiogram(audiogram, mode: mhl) devuelve la
    // misma prescripción que invocar MhlModule.prescribe(audiogram) directo
    // desde el bloc — ganancia flat 8 dB clamped a [5,10], compresión 1.0:1
    // y ptaWarning real según PTA del audiograma.
    if (mode == PrescriptionMode.mhl) {
      final mhlResult = MhlModule.prescribe(audiogram);
      return NL3PrescriptionResult(
        prescribedGains: mhlResult.gains,
        finalGains: mhlResult.gains,
        compressionRatios: mhlResult.compressionRatios,
        lossType: lossType,
        mode: mode,
        cinActive: false,
        wdrcOverrides: null,
        ptaWarning: mhlResult.ptaWarning,
        timestamp: DateTime.now(),
      );
    }

    // Obtener ganancias base NAL-NL2 del prescriptor compuesto.
    final nl2Gains = _nl2Prescriber.prescribeFromAudiogram(audiogram);

    // Aplicar correcciones NL3 por tipo de pérdida.
    final correctedGains = _applyNL3Corrections(
      nl2Gains,
      lossType,
      audiogram,
      profile,
    );

    // Ratios de compresión por banda según tipo de pérdida y severidad.
    final compressionRatios = computeCompressionRatios(
      audiogram,
      lossType,
      mode: mode,
    );

    // Determinar si CIN está activo.
    final cinActive = mode == PrescriptionMode.comfortInNoise;

    // WDRC overrides: ahora variables según tipo de pérdida y CIN.
    // CIN tiene prioridad si está activo (attack=10ms, release=150ms).
    final pta = _calculatePTA(audiogram);
    final WdrcParams? wdrcOverrides =
        _resolveWdrcOverrides(lossType, pta, cinActive);

    // ptaWarning solo aplica al modo MHL (en el branch de arriba). Para los
    // demás modos no corresponde emitir esta advertencia clínica.
    const ptaWarning = false;

    return NL3PrescriptionResult(
      prescribedGains: correctedGains,
      finalGains: correctedGains,
      compressionRatios: compressionRatios,
      lossType: lossType,
      mode: mode,
      cinActive: cinActive,
      wdrcOverrides: wdrcOverrides,
      ptaWarning: ptaWarning,
      timestamp: DateTime.now(),
    );
  }

  /// Clasifica el audiograma en un tipo de pérdida auditiva.
  ///
  /// Delega al [AudiogramClassifier] estático para mantener la
  /// responsabilidad del clasificador separada.
  ///
  /// [audiogram] Audiograma con 12 umbrales.
  /// [boneConduction] Audiograma de conducción ósea opcional.
  ///
  /// Retorna exactamente un [LossType] del conjunto
  /// {flat, sloping, reverseSlope, cookieBite, notch, mixed}.
  ///
  /// Throws [ArgumentError] si el audiograma es vacío o incompleto.
  ///
  /// Requisitos: 8.3
  LossType classifyAudiogram(
    Audiogram audiogram, {
    Map<int, double>? boneConduction,
  }) {
    return AudiogramClassifier.classify(
      audiogram,
      boneConduction: boneConduction,
    );
  }

  /// Aplica correcciones NL3 por tipo de pérdida sobre las ganancias NL2.
  ///
  /// Lógica de corrección según el tipo de pérdida clasificada:
  /// - Mixed: reduce ganancia por la mitad del air-bone gap.
  /// - Reverse slope: boost en LF (≤1000 Hz), cut en HF (>3000 Hz).
  /// - Sloping + HL > 80: cap a NL2 - 3 dB en esas frecuencias.
  /// - Notch: -2 dB en la frecuencia de la muesca, +1 dB en adyacentes.
  /// - Cookie bite / flat: sin correcciones adicionales.
  /// - Usuarios nuevos: -3 dB en todas las bandas (aclimatización).
  /// - Clamp final a [0, 50] dB.
  ///
  /// Requisitos: 2.2, 2.3, 2.4, 2.5, 2.6, 2.7
  List<double> _applyNL3Corrections(
    List<double> nl2Gains,
    LossType lossType,
    Audiogram audiogram,
    PatientProfile? profile,
  ) {
    final gains = List<double>.from(nl2Gains);
    final frequencies = Audiogram.standardFrequencies;

    switch (lossType) {
      case LossType.mixed:
        // Reducir ganancia por la mitad del air-bone gap en cada frecuencia.
        // Si no hay boneConduction, el gap es 0 (sin corrección).
        for (int i = 0; i < frequencies.length; i++) {
          final freq = frequencies[i];
          final airThreshold = audiogram.thresholds[freq]!;
          final boneThreshold =
              profile?.boneConduction?[freq] ?? airThreshold;
          final airBoneGap = airThreshold - boneThreshold;
          // Reducir por la mitad del gap, sin que la ganancia baje de 0.
          gains[i] = (gains[i] - airBoneGap / 2.0).clamp(0.0, double.infinity);
        }
        break;

      case LossType.reverseSlope:
        // Boost en frecuencias bajas (≤1000 Hz) hasta +4 dB.
        // Cut en frecuencias altas (>3000 Hz) hasta -3 dB.
        for (int i = 0; i < frequencies.length; i++) {
          final freq = frequencies[i];
          if (freq <= 1000) {
            gains[i] += _lfBoost(freq);
          } else if (freq > 3000) {
            gains[i] -= _hfCut(freq);
          }
        }
        break;

      case LossType.sloping:
        // HF roll-off: cap ganancia donde HL > 80 dB.
        for (int i = 0; i < frequencies.length; i++) {
          final freq = frequencies[i];
          final hl = audiogram.thresholds[freq]!;
          if (hl > 80) {
            gains[i] = gains[i].clamp(0.0, nl2Gains[i] - 3.0);
          }
        }
        break;

      case LossType.notch:
        // Smoothing: -2 dB en la frecuencia de la muesca, +1 dB en adyacentes.
        final notchIdx = _findNotchIndex(audiogram);
        if (notchIdx != null) {
          gains[notchIdx] -= 2.0;
          if (notchIdx > 0) gains[notchIdx - 1] += 1.0;
          if (notchIdx < frequencies.length - 1) gains[notchIdx + 1] += 1.0;
        }
        break;

      case LossType.cookieBite:
      case LossType.flat:
        // Sin correcciones adicionales para flat y cookie_bite.
        break;
    }

    // Ajuste de aclimatización para usuarios nuevos (-3 dB en todas las bandas).
    if (profile?.isNewUser ?? false) {
      for (int i = 0; i < frequencies.length; i++) {
        gains[i] -= 3.0;
      }
    }

    // Clamp final a [0, 50] dB.
    return gains
        .map((g) => g.clamp(GainPrescriber.minGainDb, GainPrescriber.maxGainDb))
        .toList();
  }

  /// Calcula el boost para frecuencias bajas en reverse slope.
  ///
  /// Retorna un valor entre 0 y 4 dB, proporcional a qué tan baja
  /// es la frecuencia (máximo boost en 250 Hz, disminuye hacia 1000 Hz).
  double _lfBoost(int freq) {
    // Boost lineal: 4 dB en 250 Hz → 0 dB en 1000 Hz.
    // Interpolación: boost = 4 * (1 - (freq - 250) / (1000 - 250))
    final normalized = (freq - 250).clamp(0, 750) / 750.0;
    return 4.0 * (1.0 - normalized);
  }

  /// Calcula el cut para frecuencias altas en reverse slope.
  ///
  /// Retorna un valor entre 0 y 3 dB, proporcional a qué tan alta
  /// es la frecuencia (crece de 0 dB justo sobre 3000 Hz hasta 3 dB en 8000 Hz).
  double _hfCut(int freq) {
    // Cut lineal: 0 dB en 3001 Hz → 3 dB en 8000 Hz.
    // Interpolación: cut = 3 * (freq - 3000) / (8000 - 3000)
    final normalized = (freq - 3000).clamp(0, 5000) / 5000.0;
    return 3.0 * normalized;
  }

  /// Encuentra el índice de la frecuencia con muesca (notch) en el audiograma.
  ///
  /// Busca en el rango 3000–6000 Hz la frecuencia cuyo umbral excede
  /// el promedio de sus adyacentes por al menos 15 dB. Retorna el índice
  /// en la lista de frecuencias estándar, o null si no se detecta muesca.
  int? _findNotchIndex(Audiogram audiogram) {
    final frequencies = Audiogram.standardFrequencies;
    // Frecuencias candidatas a notch: 3000, 3500, 4000, 6000 Hz.
    const notchCandidates = [3000, 3500, 4000, 6000];
    const notchProminence = 15.0;

    int? bestIdx;
    double maxProminence = 0.0;

    for (final freq in notchCandidates) {
      final freqIdx = frequencies.indexOf(freq);
      if (freqIdx <= 0 || freqIdx >= frequencies.length - 1) continue;

      final threshold = audiogram.thresholds[freq]!;
      final prevThreshold = audiogram.thresholds[frequencies[freqIdx - 1]]!;
      final nextThreshold = audiogram.thresholds[frequencies[freqIdx + 1]]!;
      final adjacentAvg = (prevThreshold + nextThreshold) / 2.0;
      final prominence = threshold - adjacentAvg;

      if (prominence >= notchProminence && prominence > maxProminence) {
        maxProminence = prominence;
        bestIdx = freqIdx;
      }
    }

    return bestIdx;
  }

  /// Calcula ratios de compresión por banda según tipo de pérdida y severidad.
  ///
  /// La lógica varía según el [lossType] detectado:
  /// - Flat con PTA < 40 (mild): ratios reducidos en [1.0, 1.4].
  /// - Sloping: alta compresión (1.5–2.5) donde HL > 50 dB, baja (1.0–1.4)
  ///   en frecuencias con umbral normal o cercano a normal.
  /// - Default (otros tipos): compresión proporcional al umbral HL.
  /// - En modo CIN: se restan 0.2 a todos los ratios con piso en 1.0.
  /// - Clamp final a [1.0, 3.0] para todas las bandas.
  ///
  /// [audiogram] Audiograma con 12 umbrales (dB HL).
  /// [lossType] Tipo de pérdida clasificada previamente.
  /// [mode] Modo de prescripción activo. Default: quiet.
  ///
  /// Retorna lista de 12 doubles representando el ratio de compresión por banda.
  ///
  /// Requisitos: 10.1, 10.2, 10.3, 10.4, 10.5
  List<double> computeCompressionRatios(
    Audiogram audiogram,
    LossType lossType, {
    PrescriptionMode mode = PrescriptionMode.quiet,
  }) {
    final frequencies = Audiogram.standardFrequencies;
    final ratios = List<double>.filled(12, 1.5);

    switch (lossType) {
      case LossType.flat:
        // Flat + mild (PTA < 40): compresión reducida, rango [1.0, 1.4].
        final pta = _calculatePTA(audiogram);
        if (pta < 40) {
          for (int i = 0; i < 12; i++) {
            // Escala lineal: PTA=0 → 1.0, PTA=40 → 1.4.
            ratios[i] = 1.0 + (pta / 40.0) * 0.4;
          }
        }
        break;

      case LossType.sloping:
        // Alta compresión donde HL > 50, baja donde HL es normal/leve.
        for (int i = 0; i < 12; i++) {
          final freq = frequencies[i];
          final hl = audiogram.thresholds[freq] ?? 0.0;
          if (hl > 50) {
            // Rango [1.5, 2.5] proporcional a (hl - 50) / 30.
            ratios[i] = 1.5 + ((hl - 50) / 30.0) * 1.0;
            ratios[i] = ratios[i].clamp(1.5, 2.5);
          } else {
            // Rango [1.0, 1.4] proporcional a hl / 50.
            ratios[i] = 1.0 + (hl / 50.0) * 0.4;
            ratios[i] = ratios[i].clamp(1.0, 1.4);
          }
        }
        break;

      default:
        // Default: compresión proporcional al umbral HL.
        // ratio = 1.0 + (HL / 80) clamped.
        for (int i = 0; i < 12; i++) {
          final freq = frequencies[i];
          final hl = audiogram.thresholds[freq] ?? 0.0;
          ratios[i] = 1.0 + hl / 80.0;
        }
    }

    // CIN mode: reducir 0.2 con piso en 1.0.
    if (mode == PrescriptionMode.comfortInNoise) {
      for (int i = 0; i < 12; i++) {
        ratios[i] = (ratios[i] - 0.2).clamp(1.0, double.infinity);
      }
    }

    // Clamp global a [1.0, 3.0].
    return ratios.map((r) => r.clamp(1.0, 3.0)).toList();
  }

  /// Calcula el Pure Tone Average (PTA) del audiograma.
  ///
  /// PTA = promedio de umbrales en 500, 1000, 2000, 4000 Hz.
  /// Estas son las frecuencias estándar para determinar severidad de pérdida.
  double _calculatePTA(Audiogram audiogram) {
    const ptaFrequencies = [500, 1000, 2000, 4000];
    double sum = 0.0;
    for (final freq in ptaFrequencies) {
      sum += audiogram.thresholds[freq] ?? 0.0;
    }
    return sum / ptaFrequencies.length;
  }

  /// Resuelve los overrides WDRC (attack/release) según tipo de pérdida,
  /// severidad y estado del modo CIN.
  ///
  /// Reglas:
  /// - **CIN activo**: attack=10 ms, release=150 ms (siempre tiene prioridad
  ///   sobre el ajuste por loss type — esto unifica el comportamiento con
  ///   `CinModule.apply` que también setea estos valores).
  /// - **Sloping con HL severo (PTA > 60)**: attack=8 ms, release=80 ms.
  ///   Compresión rápida para pérdidas severas en agudos: minimiza distorsión
  ///   de transientes y mejora inteligibilidad consonántica.
  /// - **Reverse slope**: attack=15 ms, release=200 ms. Tiempos más lentos
  ///   para preservar formantes en LF y evitar pumping en vocales.
  /// - **Notch**: attack=12 ms, release=120 ms. Compromiso intermedio que
  ///   suaviza la asimetría espectral alrededor de la muesca.
  /// - **Resto** (flat, cookieBite, mixed, sloping leve, etc.): null,
  ///   de modo que el WDRC base use sus defaults (attack=5 ms, release=100 ms).
  ///
  /// Retorna [WdrcParams] con los tiempos a forzar, o null si corresponde
  /// usar los defaults del compresor base.
  ///
  /// Requisitos: 3.4 (CIN WDRC overrides), 10.x (parámetros por loss type).
  WdrcParams? _resolveWdrcOverrides(
    LossType lossType,
    double pta,
    bool cinActive,
  ) {
    // CIN siempre tiene prioridad: si está activo, fijar attack=10/release=150
    // sin importar el tipo de pérdida.
    if (cinActive) {
      return const WdrcParams(attackMs: 10.0, releaseMs: 150.0);
    }

    switch (lossType) {
      case LossType.sloping:
        // Solo override para HL severo (PTA > 60 dB): compresión más rápida.
        if (pta > 60.0) {
          return const WdrcParams(attackMs: 8.0, releaseMs: 80.0);
        }
        return null;
      case LossType.reverseSlope:
        // Tiempos más lentos para preservar formantes en LF.
        return const WdrcParams(attackMs: 15.0, releaseMs: 200.0);
      case LossType.notch:
        // Compromiso intermedio para suavizar la asimetría del notch.
        return const WdrcParams(attackMs: 12.0, releaseMs: 120.0);
      case LossType.flat:
      case LossType.cookieBite:
      case LossType.mixed:
        // Sin override: usar defaults del WDRC base.
        return null;
    }
  }

  /// Valida que el audiograma tenga las 12 frecuencias estándar requeridas.
  ///
  /// Throws [ArgumentError] si el audiograma es vacío o incompleto.
  void _validateAudiogram(Audiogram audiogram) {
    if (audiogram.thresholds.isEmpty) {
      throw ArgumentError(
        'Audiograma vacío o nulo: se requieren 12 umbrales.',
      );
    }

    final requiredFreqs = Audiogram.standardFrequencies;
    final missingCount =
        requiredFreqs.where((f) => !audiogram.thresholds.containsKey(f)).length;

    if (missingCount > 0) {
      final foundCount = requiredFreqs.length - missingCount;
      throw ArgumentError(
        'Audiograma incompleto: se encontraron $foundCount de 12 '
        'frecuencias requeridas.',
      );
    }
  }
}
