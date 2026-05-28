# Auditoría Completa del Pipeline DSP — PSK Hearing Aid

**Fecha:** 28 de mayo de 2026  
**Versión analizada:** Post-commits d60e41b (clasificador + headroom guard)  
**Archivos auditados:** dsp_pipeline.cpp, equalizer.cpp, wdrc_processor.cpp, mpo_limiter.cpp, noise_reduction.cpp, environment_classifier.cpp, audio_engine.cpp

---

## 1. Diagnóstico por Etapa del Pipeline

### Pipeline actual (orden real en processBlock):

```
HPF 150Hz → NR → Medir nivel → Env Classifier → Adaptive EQ Scale → EQ → WDRC → Headroom Guard → Volume → MPO
```

---

### Etapa 0.5: High-Pass Filter 150 Hz — ⚠️ RIESGO

| Aspecto | Evaluación |
|---------|-----------|
| Implementación | Correcta (Butterworth 2° orden, coeficientes bien calculados) |
| Problema | **150 Hz corta la fundamental de voces masculinas graves** |

**Análisis:**
- La fundamental de la voz masculina adulta está en 85-180 Hz (promedio ~125 Hz)
- Un HPF Butterworth 2° orden a 150 Hz tiene -3 dB a 150 Hz y -12 dB/octava de rolloff
- A 100 Hz: atenuación ≈ -7 dB. A 125 Hz: atenuación ≈ -4 dB
- **Esto reduce perceptiblemente la "cuerpo" de voces masculinas graves**
- Para un audífono pediátrico donde el padre habla al niño, esto es problemático

**Veredicto:** El HPF libera headroom pero sacrifica calidad vocal. Para un PSAP de uso general, 150 Hz es demasiado alto.

---

### Etapa 1: Noise Reduction — ⚠️ RIESGO (interacción con clasificador)

| Aspecto | Evaluación |
|---------|-----------|
| Implementación | Correcta (Wiener 8 sub-bandas, gain floor preserva consonantes) |
| Problema 1 | **Sample rate hardcodeado a 48000 Hz pero bandas diseñadas para 0-8000 Hz** |
| Problema 2 | **Transiciones graduales + clasificador = NR nunca converge** |

**Problema 1 — Sample rate mismatch:**
```cpp
// noise_reduction.h
static constexpr int kNrSampleRate = 48000;  // ← hardcodeado

// Pero las bandas cubren 0-8000 Hz con centros en 500, 1500, ..., 7500 Hz
// A 48 kHz, Nyquist = 24 kHz. Las bandas solo cubren 0-8 kHz.
// Esto es CORRECTO para el rango de habla, pero...
```

El NR usa `kNrSampleRate = 48000` para calcular coeficientes de filtro. Si el audio engine negocia un sample rate diferente (el avances.md dice "unificado a 48000 Hz" pero el pipeline se inicializa con `effectiveSampleRate` del stream), los coeficientes del NR podrían estar mal calculados si el stream negocia otro rate.

**Problema 2 — Transiciones graduales nunca convergen:**
```cpp
// dsp_pipeline.cpp — solo sube/baja 1 nivel por transición
if (targetNrLevel > currentNrLevel) {
    currentNrLevel_ = currentNrLevel + 1; // subir de a 1
} else if (targetNrLevel < currentNrLevel) {
    currentNrLevel_ = currentNrLevel - 1; // bajar de a 1
}
```

Con hold de 3 segundos entre transiciones del clasificador:
- Si el target es NR=3 y estamos en NR=0, necesitamos 3 transiciones × 3 segundos = **9 segundos** para llegar al nivel correcto
- Si el clasificador oscila (SPEECH→NOISE→SPEECH cada 3s), el NR sube 1, baja 1, sube 1... **nunca converge**

---

### Etapa 2: Medición de nivel PRE-EQ — ✅ OK

| Aspecto | Evaluación |
|---------|-----------|
| Implementación | Correcta |
| Fórmula | `20*log10(rms) + splOffset` — correcto |
| Protección | `kLevelFloor = 1e-10f` evita log(0) — correcto |

---

### Etapa 3: Environment Classifier — ❌ PROBLEMA PRINCIPAL

| Aspecto | Evaluación |
|---------|-----------|
| Histéresis | Implementada (5-12 dB zona muerta) — ✅ |
| Hold timer | 750 bloques × 4ms = 3 segundos — ✅ |
| **Problema crítico** | **La estimación de SNR es demasiado simplista** |

**Causa raíz de la oscilación:**

```cpp
// dsp_pipeline.cpp
float DspPipeline::estimateSnrSimple(float inputLevelDb) const {
    static constexpr float kNoiseFloorDbSpl = 30.0f;
    float snr = inputLevelDb - kNoiseFloorDbSpl;  // ← ESTO ES EL PROBLEMA
    ...
}
```

**El SNR se estima como `inputLevel - 30`**. Esto significa:
- Habla a 60 dB SPL → SNR = 30 dB → SPEECH ✓
- Ruido a 50 dB SPL → SNR = 20 dB → SPEECH (¡INCORRECTO! debería ser NOISE)
- Habla + ruido a 55 dB SPL → SNR = 25 dB → SPEECH (¡INCORRECTO!)

**El estimador NO distingue entre habla y ruido.** Solo mide nivel total. Cualquier señal > 42 dB SPL (42 - 30 = 12 dB SNR) se clasifica como SPEECH. Cualquier señal < 35 dB SPL (35 - 30 = 5 dB SNR) se clasifica como NOISE/SPEECH_IN_NOISE.

**Resultado:** El clasificador realmente solo clasifica por NIVEL, no por contenido. En un ambiente con nivel fluctuante (conversación con pausas), oscila entre SPEECH y QUIET/SPEECH_IN_NOISE.

---

### Etapa 3.5: Adaptive EQ Scaling — ⚠️ RIESGO (doble atenuación)

| Aspecto | Evaluación |
|---------|-----------|
| Implementación | Funcional pero problemática |
| **Problema** | **Doble atenuación con Headroom Guard** |

**Análisis del código:**
```cpp
// Ceiling = 0.9 para el adaptive scaling
float headroomDb = 20.0f * std::log10(0.9f / peakAmplitude);

// Si maxEqGain > headroomDb → escala todo el EQ proporcionalmente
if (maxEqGain > 0.1f && headroomDb < maxEqGain) {
    eqScale = std::max(0.1f, headroomDb / maxEqGain);
}
```

**Escenario problemático:**
1. Input peak = 0.3 → headroomDb = 20*log10(0.9/0.3) = 9.5 dB
2. Max EQ gain = 20 dB (preset Moderate)
3. eqScale = 9.5/20 = 0.475 → **EQ se reduce al 47.5% de su ganancia prescrita**
4. Después, el Headroom Guard TAMBIÉN escala si peak > 0.95
5. **Resultado: la amplificación prescrita se reduce drásticamente**

**Para un input de nivel normal (0.3 peak ≈ -10 dBFS ≈ 110 dB SPL con offset 120), el adaptive scaling reduce el EQ a menos de la mitad.** Esto explica por qué "el sistema ya no funciona tan bien como antes" — la amplificación efectiva es mucho menor.

---

### Etapa 4: Equalizer 12 bandas — ✅ OK

| Aspecto | Evaluación |
|---------|-----------|
| Implementación | Correcta (Audio EQ Cookbook, biquad peaking) |
| Thread-safety | Correcta (atómicos + flag de cambio) |
| Optimización | Bandas con gain=0 se saltan — correcto |
| processWithScale | Correcto pero ver problema de doble atenuación arriba |

---

### Etapa 5: WDRC 3 regiones — ✅ OK (con observación)

| Aspecto | Evaluación |
|---------|-----------|
| Modelo I/O | Correcto (3 regiones: expansión + lineal + compresión) |
| Envelope | Híbrido correcto (decisión block-rate, suavizado sample-by-sample) |
| Nivel PRE-EQ | Correcto (no reacciona a amplificación del EQ) |
| **Observación** | El clasificador modifica compressionKnee/Ratio en runtime |

**Interacción con clasificador:**
Cuando el clasificador cambia de SPEECH (knee=50, ratio=2.0) a NOISE (knee=40, ratio=3.0), el WDRC empieza a comprimir más agresivamente. Combinado con el adaptive EQ scaling que ya redujo la ganancia, el resultado es **triple atenuación**: adaptive scaling + WDRC más agresivo + headroom guard.

---

### Etapa 6: Headroom Guard (0.95) — ⚠️ RIESGO

| Aspecto | Evaluación |
|---------|-----------|
| Implementación | Correcta (escanea peak, escala si > 0.95) |
| **Problema** | **Redundante con MPO y causa doble atenuación** |

**Análisis:**
```cpp
void WdrcProcessor::applyHeadroomGuard(float* buffer, int blockSize) {
    // Si peak > 0.95, escala TODO el bloque
    static constexpr float kCeiling = 0.95f;
    if (peak > kCeiling) {
        float scale = kCeiling / peak;
        for (int i = 0; i < blockSize; ++i) {
            buffer[i] *= scale;
        }
    }
}
```

El Headroom Guard escala el bloque ENTERO si un solo pico excede 0.95. Luego el MPO TAMBIÉN limita picos. Esto causa:
1. Un pico transitorio de 0.98 → Headroom Guard escala todo el bloque por 0.95/0.98 = 0.969
2. Luego el MPO ve que todo está bajo su threshold (0.1 lineal = -20 dBFS) y no actúa
3. **Resultado: señales que estaban bien (0.5-0.9) se atenúan innecesariamente**

Además, el MPO threshold es 0.1 (100 dB SPL - 120 offset = -20 dBFS). Esto es **extremadamente bajo**. El Headroom Guard a 0.95 y el MPO a 0.1 están en conflicto total — el MPO debería estar limitando mucho antes que el Headroom Guard.

---

### Etapa 7: Volume Master — ✅ OK

| Aspecto | Evaluación |
|---------|-----------|
| Implementación | Correcta (factor lineal pre-calculado) |
| Rango | [-20, +10] dB — correcto |
| Thread-safety | Atómico — correcto |

---

### Etapa 8: MPO Peak Limiter — ❌ PROBLEMA (threshold demasiado bajo)

| Aspecto | Evaluación |
|---------|-----------|
| Implementación | Correcta (sample-by-sample, attack 0.5ms, release 10ms) |
| Hard-clamp | Correcto (garantía absoluta) |
| **PROBLEMA CRÍTICO** | **Threshold = 0.1 lineal (-20 dBFS) es absurdamente bajo** |

**Cálculo del threshold actual:**
```cpp
mpo_.setThreshold(config.mpoThresholdDbSpl, config.splOffset);
// config.mpoThresholdDbSpl = 100.0f
// config.splOffset = 120.0f
// thresholdDbFs = 100 - 120 = -20 dBFS
// thresholdLinear = 10^(-20/20) = 0.1
```

**Un threshold de 0.1 lineal significa que el MPO limita TODA señal por encima de 0.1 en amplitud.** Esto es el 10% del rango dinámico disponible. Cualquier señal con peak > 0.1 (que es prácticamente TODA señal audible) está siendo limitada por el MPO.

**Esto es la causa principal de la degradación de calidad.** El MPO está actuando como un compresor brutal que aplasta toda la señal a 0.1 de amplitud máxima.

**Corrección necesaria:** El threshold debería ser mucho más alto. Para un PSAP con auriculares:
- MPO = 110 dB SPL con offset 120 → -10 dBFS → 0.316 lineal (mínimo razonable)
- MPO = 115 dB SPL → -5 dBFS → 0.562 lineal (mejor)
- MPO = 118 dB SPL → -2 dBFS → 0.794 lineal (óptimo para auriculares)

---

## 2. Lista de Regresiones Probables (Causa Raíz)

| # | Regresión | Causa Raíz | Severidad |
|---|-----------|-----------|-----------|
| 1 | **Amplificación insuficiente** | MPO threshold a 0.1 aplasta toda la señal | 🔴 CRÍTICA |
| 2 | **Doble/triple atenuación** | Adaptive EQ Scale (0.9) + Headroom Guard (0.95) + MPO (0.1) | 🔴 CRÍTICA |
| 3 | **Cortes de audio** | Clasificador cambia NR/WDRC cada 3 segundos | 🟡 ALTA |
| 4 | **NR nunca converge** | Transiciones graduales (±1) + hold 3s = 9s para llegar al target | 🟡 ALTA |
| 5 | **Voces masculinas atenuadas** | HPF 150 Hz corta fundamental masculina | 🟡 MEDIA |
| 6 | **SNR estimation inútil** | `SNR = level - 30` no distingue habla de ruido | 🟡 MEDIA |
| 7 | **Clasificador no aporta valor real** | Sin SNR real, solo clasifica por nivel (redundante con WDRC) | 🟡 MEDIA |

---

## 3. Propuesta de Fix para Cada Problema

### Fix #1: MPO Threshold (CRÍTICO)

```cpp
// AudioConfig — cambiar mpoThresholdDbSpl
struct AudioConfig {
    float mpoThresholdDbSpl = 110.0f;  // ERA 100.0f → 0.1 lineal
                                        // AHORA 110.0f → 0.316 lineal
    // O mejor aún para auriculares:
    // float mpoThresholdDbSpl = 115.0f; // → 0.562 lineal
};
```

**Alternativa más segura:** Usar threshold lineal directamente:
```cpp
// En init():
mpo_.setThresholdLinear(0.85f);  // -1.4 dBFS — deja margen sin aplastar
```

### Fix #2: Eliminar Adaptive EQ Scaling (o hacerlo menos agresivo)

**Opción A — Eliminar completamente:**
```cpp
// dsp_pipeline.cpp — processBlock()
// ELIMINAR toda la sección "3.5. Adaptive EQ gain scaling"
// El MPO con threshold correcto (0.85) protege suficiente
eq_.process(buffer, blockSize);  // siempre sin scaling
```

**Opción B — Ceiling más alto:**
```cpp
// Si se mantiene, usar ceiling de 0.99 en vez de 0.9
float headroomDb = 20.0f * std::log10(0.99f / peakAmplitude);
```

### Fix #3: Eliminar Headroom Guard (redundante con MPO correcto)

```cpp
// dsp_pipeline.cpp — processBlock()
// ELIMINAR la línea:
// wdrc_.applyHeadroomGuard(buffer, blockSize);
// Con MPO threshold a 0.85, el headroom guard es innecesario
```

### Fix #4: HPF a 80 Hz en vez de 150 Hz

```cpp
// dsp_pipeline.cpp — init()
computeHighPassCoeffs(config.sampleRate, 80.0f);  // ERA 150.0f
```

80 Hz elimina rumble/vibración sin afectar la fundamental vocal (85+ Hz).

### Fix #5: Clasificador desactivado por defecto

```cpp
// dsp_pipeline.h
std::atomic<bool> autoClassifyEnabled_{false};  // ERA true
```

El usuario adulto prefiere control manual. El clasificador solo tiene sentido para niños que no pueden cambiar perfiles.

### Fix #6: NR transiciones inmediatas (no graduales)

```cpp
// dsp_pipeline.cpp — cuando el clasificador cambia:
if (envClassInt != lastEnvClass_) {
    lastEnvClass_ = envClassInt;
    int targetNrLevel = envClassifier_.getRecommendedNrLevel();
    currentNrLevel_ = targetNrLevel;  // DIRECTO, sin gradualidad
    nr_.setLevel(currentNrLevel_);
    // ...
}
```

El NR ya tiene suavizado temporal interno (attack/release en compositeGain). La gradualidad de nivel es redundante y causa que nunca converja.

---

## 4. Propuesta de "Modo Seguro" (Rollback Parcial)

### Pipeline simplificado que "funcionaba bien":

```
Input → NR → EQ → WDRC → Volume → MPO → Output
```

**Sin:** HPF, Adaptive EQ Scaling, Headroom Guard, Environment Classifier

### Implementación del modo seguro:

```cpp
void DspPipeline::processBlock(float* buffer, int blockSize) {
    if (buffer == nullptr || blockSize <= 0) return;

    // Spectrum analyzer input copy (si activo)
    float inputCopy[256];
    bool spectrumActive = spectrumAnalyzer_.isActive();
    if (spectrumActive) {
        std::memcpy(inputCopy, buffer, blockSize * sizeof(float));
    }

    // === MODO SEGURO: Pipeline simple sin features experimentales ===

    // 1. NR (nivel fijo, controlado por usuario)
    nr_.process(buffer, blockSize);

    // 2. Medir nivel PRE-EQ
    float inputLevelDb = measureRmsDb(buffer, blockSize);
    lastInputLevelDb_.store(inputLevelDb, std::memory_order_relaxed);

    // 3. EQ (sin adaptive scaling)
    eq_.process(buffer, blockSize);

    // 4. WDRC (parámetros fijos del preset, sin clasificador)
    wdrc_.process(buffer, blockSize, inputLevelDb);

    // 5. Volume
    float volLinear = volumeLinear_.load(std::memory_order_relaxed);
    applyVolume(buffer, blockSize, volLinear);

    // 6. MPO (con threshold correcto: 0.85 lineal)
    mpo_.process(buffer, blockSize);

    // Spectrum analyzer
    if (spectrumActive) {
        spectrumAnalyzer_.setEnvironmentClass(0);
        spectrumAnalyzer_.processBuffers(inputCopy, buffer, blockSize);
    }
}
```

---

## 5. Toggles Recomendados para la UI

| Toggle | Default | Efecto |
|--------|---------|--------|
| **Auto-Classify** | OFF | Habilita/deshabilita clasificador automático de ambiente |
| **HPF (Anti-rumble)** | OFF | Habilita/deshabilita high-pass filter 150 Hz |
| **Adaptive EQ** | OFF | Habilita/deshabilita scaling automático del EQ |
| **Headroom Guard** | OFF | Habilita/deshabilita protección post-WDRC 0.95 |

Todos OFF = "modo seguro" = pipeline simple que funcionaba bien.

---

## 6. Resumen de Cadena de Atenuación Actual (El Problema Real)

Con una señal de entrada típica (habla a 0.05 peak, ~-26 dBFS):

```
Señal entrada: peak = 0.05 (habla normal)

1. HPF 150 Hz: -3 dB en fundamental → peak ≈ 0.035
2. NR nivel 1: compositeGain ≈ 0.7 → peak ≈ 0.025
3. EQ +20 dB (Moderate): peak ≈ 0.25
4. Adaptive EQ Scale: headroom = 20*log10(0.9/0.025) = 31 dB
   maxEqGain = 20 dB < 31 dB → eqScale = 1.0 (NO actúa aquí) ✓
5. WDRC: inputLevel ≈ 50 dB SPL (0.025 → -32 dBFS + 120 = 88 dB SPL)
   ¡ESPERA! 88 dB SPL > compressionKnee (50-55) → COMPRIME
   reductionDb = (88-55) × (1 - 1/2) = 16.5 dB → gainFactor = 0.15
   peak ≈ 0.25 × 0.15 = 0.037
6. Headroom Guard: 0.037 < 0.95 → no actúa ✓
7. Volume 0 dB: peak = 0.037
8. MPO threshold 0.1: 0.037 < 0.1 → no actúa ✓

Ganancia efectiva: 0.037 / 0.05 = 0.74 = -2.6 dB
¡¡¡ATENUACIÓN en vez de amplificación!!!
```

**¡El problema es que con offset 120, una señal de mic a 0.05 peak se interpreta como 88 dB SPL!** Esto dispara compresión agresiva del WDRC.

### El verdadero problema: OFFSET DE CALIBRACIÓN

Con offset 120:
- Señal de mic peak 0.05 → RMS ≈ 0.02 → -34 dBFS → -34 + 120 = **86 dB SPL**
- Esto está MUY por encima del compression knee (50-55 dB SPL)
- El WDRC comprime agresivamente TODA señal de habla normal

**El offset de 120 asume un micrófono MEMS calibrado (ICS-43434).** El micrófono del celular Android con AGC del sistema operativo NO tiene esa sensibilidad. El nivel real de habla conversacional debería ser ~60-65 dB SPL, no 86.

**Fix:** El offset para micrófono de celular Android debería ser ~93-100, no 120.

---

## 7. Plan de Acción Priorizado

### Prioridad 1 — INMEDIATO (restaurar funcionalidad):

1. **Subir MPO threshold a 0.85 lineal** (o 115 dB SPL con offset correcto)
2. **Reducir splOffset a 93-100** para micrófono de celular (no es un MEMS calibrado)
3. **Desactivar Adaptive EQ Scaling** (eqScale siempre = 1.0)
4. **Desactivar Headroom Guard** (MPO con threshold correcto es suficiente)
5. **Desactivar clasificador por defecto** (autoClassifyEnabled_ = false)

### Prioridad 2 — CORTO PLAZO (mejorar calidad):

6. **Bajar HPF a 80 Hz** (o hacerlo toggle desactivado por defecto)
7. **NR transiciones directas** (sin gradualidad de ±1 nivel)
8. **Recalibrar WDRC knees** para el offset corregido

### Prioridad 3 — MEDIO PLAZO (features opcionales):

9. **Mejorar estimación de SNR** (usar potencia de ruido del NR, no heurística)
10. **Clasificador como feature opt-in** con toggle en UI
11. **Adaptive EQ como feature opt-in** con ceiling más alto (0.99)

---

## 8. Código de Fix Inmediato

### Cambios mínimos para restaurar funcionalidad:

**dsp_pipeline.h:**
```cpp
std::atomic<bool> autoClassifyEnabled_{false};  // Desactivar por defecto
```

**dsp_pipeline.cpp — init():**
```cpp
void DspPipeline::init(const AudioConfig& config) {
    splOffset_.store(config.splOffset, std::memory_order_relaxed);
    eq_.init(config.sampleRate);
    wdrc_.init(config.sampleRate);
    mpo_.init(config.sampleRate);
    
    // MPO con threshold alto para auriculares (no aplastar señal)
    mpo_.setThresholdLinear(0.85f);  // ← FIX: era 0.1
    
    volumeDb_.store(0.0f, std::memory_order_relaxed);
    volumeLinear_.store(1.0f, std::memory_order_relaxed);
    spectrumAnalyzer_.init(config.sampleRate, config.splOffset);
    computeHighPassCoeffs(config.sampleRate, 80.0f);  // ← FIX: era 150
}
```

**dsp_pipeline.cpp — processBlock() simplificado:**
```cpp
void DspPipeline::processBlock(float* buffer, int blockSize) {
    if (buffer == nullptr || blockSize <= 0) return;

    float inputCopy[256];
    bool spectrumActive = spectrumAnalyzer_.isActive();
    if (spectrumActive) {
        std::memcpy(inputCopy, buffer, blockSize * sizeof(float));
    }

    // HPF (toggle — desactivado por defecto, activar con flag)
    // [mantener si se baja a 80 Hz, o hacer toggle]
    for (int i = 0; i < blockSize; ++i) {
        float x = buffer[i];
        float y = hpB0_ * x + hpB1_ * hpX1_ + hpB2_ * hpX2_
                - hpA1_ * hpY1_ - hpA2_ * hpY2_;
        hpX2_ = hpX1_; hpX1_ = x;
        hpY2_ = hpY1_; hpY1_ = y;
        buffer[i] = y;
    }

    // NR
    nr_.process(buffer, blockSize);

    // Medir nivel PRE-EQ
    float inputLevelDb = measureRmsDb(buffer, blockSize);
    lastInputLevelDb_.store(inputLevelDb, std::memory_order_relaxed);

    // Clasificador (solo si habilitado)
    if (autoClassifyEnabled_.load(std::memory_order_relaxed)) {
        // ... código existente del clasificador ...
    }

    // EQ — SIN adaptive scaling
    eq_.process(buffer, blockSize);

    // WDRC
    wdrc_.process(buffer, blockSize, inputLevelDb);

    // SIN headroom guard (MPO con threshold correcto es suficiente)
    // wdrc_.applyHeadroomGuard(buffer, blockSize);  ← REMOVIDO

    // Volume
    float volLinear = volumeLinear_.load(std::memory_order_relaxed);
    applyVolume(buffer, blockSize, volLinear);

    // MPO (threshold = 0.85 lineal)
    mpo_.process(buffer, blockSize);

    // Spectrum
    if (spectrumActive) {
        spectrumAnalyzer_.setEnvironmentClass(lastEnvClass_);
        spectrumAnalyzer_.processBuffers(inputCopy, buffer, blockSize);
    }
}
```

**AudioConfig (o donde se configure el offset):**
```cpp
// Para micrófono de celular Android (con AGC del OS):
dspConfig.splOffset = 93.0f;  // ERA 120.0f
// Justificación: mic de celular con AGC produce ~-26 dBFS para habla a 65 dB SPL
// Offset = 65 - (-26) ≈ 91-95. Usar 93 como punto medio.
```

---

## 9. Verificación Post-Fix

Después de aplicar los fixes, verificar:

| Test | Criterio | Cómo verificar |
|------|----------|---------------|
| Amplificación audible | Salida más fuerte que entrada | Hablar al mic, escuchar en auricular |
| Sin distorsión | Audio limpio sin clipping | Hablar fuerte, verificar que no distorsiona |
| Sin cortes | Audio continuo sin interrupciones | Usar 30 segundos sin cortes |
| Presets funcionan | Normal < Mild < Moderate < Severe | Cambiar presets, verificar diferencia |
| Silencio = silencio | Sin ruido amplificado en silencio | Tapar mic, verificar silencio |
| MPO protege | Sonidos fuertes no distorsionan | Aplaudir cerca del mic |

---

*Auditoría realizada el 28 de mayo de 2026.*
