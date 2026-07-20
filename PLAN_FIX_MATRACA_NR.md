# Plan de Corrección: Artefacto "Matraca" en Ambientes Ruidosos

**Fecha:** 2026-07-20  
**Problema:** En ambientes ruidosos (>65 dB SPL), el sistema de reducción de ruido produce un sonido de "matraca" (gain pumping audible). En ambientes silenciosos funciona correctamente.

---

## 1. Diagnóstico Raíz

El artefacto es causado por **modulación de ganancia cíclica** entre tres bloques del pipeline que se retroalimentan:

```
NR agresivo (NR=3 + DNN 0.65) → señal fluctúa rápido
        ↓
WDRC "transient fast-track" reacciona a los cambios bruscos
        ↓
MPO adaptive attack (overshoot ratio²) clampea picos creados por WDRC
        ↓
La señal baja → WDRC release suelta → señal sube → MPO vuelve a clampear
        ↓
CICLO = modulación de amplitud audible = "matraca"
```

### Cadena de causas específicas en el código:

| # | Archivo | Problema |
|---|---------|----------|
| A | `noise_level_calculator.dart` | `inputDb > 75` → fuerza NR=3 sin considerar si hay voz. `noiseDb > 65` → fuerza NR≥2. Escala demasiado agresiva. |
| B | `scene_preset_generator.dart` | Escenas `noiseLowDominant` y `voiceInNoiseLow` activan TNR=true + compression ratio 1.7 + knee=50 dB. Triple agresión simultánea. |
| C | `dsp-worklet-processor.js` L460 | WDRC "transient fast-track": `if (peakPostEqDb > envelope) → envelope += attackCoeff * delta`. Sube el envelope instantáneamente por picos que el NR no alcanzó a limpiar. |
| D | `dsp-worklet-processor.js` L502 | MPO adaptive attack: `adaptiveCoeff = attackCoeff * min(overshootRatio², 16)`. Factor ×16 produce un clamping extremadamente abrupto que genera el escalón audible. |
| E | `dnn_denoiser_controller.dart` | Intensity default 0.65 con cap C++ a 0.75. El comentario dice "0.65 evita artefactos" pero eso es para el DNN solo — en combo con WDRC agresivo no alcanza. |

### Por qué en silencio no pasa:
- NR=0, TNR=off, WDRC ratio=1.5, knee=60 dB
- El envelope del WDRC se mantiene estable (no hay transients)
- El MPO nunca se activa (señal muy por debajo del threshold)
- No hay ciclo de retroalimentación

---

## 2. Correcciones Propuestas (4 cambios)

### Corrección 1: Suavizar el NR Level Calculator

**Archivo:** `lib/scene/noise_level_calculator.dart`

**Problema:** Saltos discretos de NR (0→3) sin transición. Al entrar a un ambiente ruidoso, salta directo a NR=3.

**Solución:**
- Agregar **rampa temporal**: el NR no puede subir más de 1 nivel por ciclo de análisis (~2.5s)
- Quitar el override forzado `inputDb > 75 → NR=3` y dejarlo fluir por el SNR
- Agregar un campo `previousNrLevel` al calculator para comparar contra el último

```
Antes:  silencio(NR=0) → calle(NR=3) instantáneo
Después: silencio(NR=0) → calle(NR=1) → siguiente análisis(NR=2) → siguiente(NR=3)
```

---

### Corrección 2: Desacoplar NR del WDRC en escenas ruidosas

**Archivo:** `lib/scene/scene_preset_generator.dart`

**Problema:** Cuando hay NR=3 (calculado automáticamente), el tuning de escena ADEMÁS pone compression ratio 1.7 y knee=50. Son dos compresiones operando en la misma señal: el DNN comprime dinámicamente + el WDRC comprime sobre eso.

**Solución:** Regla de exclusión mutua parcial:
- Si `nrLevel >= 2` (NR calculado), relajar el WDRC automáticamente:
  - `compressionRatio = max(1.3, tuning.ratio - 0.3)`
  - `compressionKnee = tuning.knee + 5 dB` (más headroom)
- Desactivar TNR cuando el DNN está activo (hacen lo mismo, el DNN es mejor)

Lógica: "Si el NR ya está limpiando, el WDRC no necesita comprimir tan fuerte porque la señal que le llega ya está más limpia."

---

### Corrección 3: Eliminar el "transient fast-track" del WDRC

**Archivo:** `assets/simulator/dsp-worklet-processor.js` (y su equivalente nativo C++)

**Problema:** Líneas 458-460:
```javascript
// Transient fast-track
if (peakPostEqDb > state.envelope) {
    state.envelope += state.attackCoeff * (peakPostEqDb - state.envelope);
}
```

Esto fue diseñado para que el WDRC reaccione rápido a transients (aplausos, portazos). Pero cuando el NR está en NR=3, los residuos del denoising son PICOS CORTOS que el fast-track interpreta como transients. El WDRC sube el envelope → comprime → la señal baja → release → sube → "matraca".

**Solución:**
- Condicionar el fast-track al NR level activo:
  - `if (nrLevel == 0 && peakPostEqDb > envelope)` → fast-track normal
  - `if (nrLevel >= 1)` → desactivar fast-track, usar solo el envelope lento del bloque
- Alternativa mínima: reducir el coeficiente del fast-track de `attackCoeff` a `attackCoeff * 0.1` cuando NR≥2

---

### Corrección 4: Suavizar el MPO adaptive attack

**Archivo:** `assets/simulator/dsp-worklet-processor.js` (y nativo C++)

**Problema:** Línea 502:
```javascript
const adaptiveCoeff = Math.min(state.attackCoeff * Math.min(overshootRatio * overshootRatio, 16.0), 1.0);
```

El `overshootRatio²` con cap en 16 significa que cuando un pico excede el threshold por 4×, el MPO aplica clamping con coeficiente ×16. Esto genera un **escalón de ganancia** que es audible como click/matraca.

**Solución:**
- Reducir el exponente de 2 a 1.5: `overshootRatio^1.5` en vez de `overshootRatio²`
- Reducir el cap de 16 a 4: `Math.min(overshootRatio ** 1.5, 4.0)`
- Agregar un **hold time** de 1-2 ms antes del release del MPO para que no oscile

```javascript
// Antes:
const adaptiveCoeff = Math.min(state.attackCoeff * Math.min(overshootRatio * overshootRatio, 16.0), 1.0);

// Después:
const adaptiveCoeff = Math.min(state.attackCoeff * Math.min(Math.pow(overshootRatio, 1.5), 4.0), 1.0);
```

---

## 3. Orden de Implementación

| Paso | Corrección | Impacto | Riesgo |
|------|-----------|---------|--------|
| **1** | Corrección 3 (quitar fast-track) | Alto — elimina el trigger principal | Bajo — transients se manejan por el envelope normal |
| **2** | Corrección 4 (suavizar MPO) | Alto — elimina los escalones audibles | Bajo — el hard ceiling ±0.99 sigue protegiendo |
| **3** | Corrección 2 (desacoplar NR/WDRC) | Medio — previene la doble compresión | Medio — requiere validar que la voz siga siendo inteligible |
| **4** | Corrección 1 (rampa NR) | Medio — previene el salto brusco al entrar a ruido | Bajo — mejora UX sin riesgo técnico |

**Justificación del orden:** Las correcciones 3 y 4 atacan la causa directa del artefacto en el DSP sample-by-sample. Las correcciones 1 y 2 atacan la causa indirecta (parámetros demasiado agresivos que disparan el ciclo). Hacer 3+4 primero permite validar si el artefacto desaparece sin tocar la lógica de alto nivel.

---

## 4. Métricas de Validación

### Test de regresión: Escenario "matraca"
1. Audio de entrada: ruido rosa + conversación a SNR=5 dB, 70 dB SPL
2. Procesar con pipeline completo (NR=3 + WDRC + MPO)
3. Medir **AM modulation depth** en la salida (banda 1-4 kHz)
   - **Criterio PASS:** modulation depth < 3 dB pico-a-pico
   - **Criterio FAIL actual:** modulation depth > 10 dB (la "matraca")

### Test de seguridad: MPO sigue protegiendo
1. Impulso de 100 dB SPL (palmada)
2. Verificar que la salida no exceda MPO threshold + 3 dB en ningún sample
3. Verificar que el tiempo de convergencia del MPO sea < 5 ms

### Test de inteligibilidad: Voz no se degrada
1. Audio: habla con ruido de calle a SNR=8 dB
2. Medir PESQ o STOI antes/después del fix
3. **Criterio:** delta STOI ≥ -0.02 (no empeorar inteligibilidad)

### Test subjetivo
1. 3 escenarios: calle, cafetería, subte
2. Escucha con usuario real
3. **Criterio:** "no se escucha matraca/vibración/traqueteo"

---

## 5. Relación con lo que hace JBL Wave Beam 2

El concepto clave tomado del enfoque JBL:

> **El JBL separa la cancelación de ruido (ANC feedforward) del control de ganancia (amplificación fija).** No hay interacción dinámica entre ambos — el ANC opera en un dominio (anti-ruido acústico) y la reproducción opera en otro (señal limpia amplificada).

Nosotros no podemos hacer ANC feedforward (no es nuestro caso de uso — somos audífono, no auricular), pero **sí podemos aplicar el principio de separación:**

- El NR (DNN/Wiener) limpia la señal → produce señal "ya limpia"
- El WDRC recibe la señal limpia y la comprime como si no hubiera habido ruido
- El WDRC NO debe reaccionar a los artefactos residuales del NR

Eso es exactamente lo que logran las correcciones 2 y 3: **desacoplar la reacción del WDRC de las fluctuaciones que introduce el NR.**

---

## 6. Archivos a Modificar

| Archivo | Tipo de cambio |
|---------|---------------|
| `lib/scene/noise_level_calculator.dart` | Agregar rampa temporal, quitar override forzado |
| `lib/scene/scene_preset_generator.dart` | Regla de exclusión mutua NR↔WDRC, desactivar TNR con DNN |
| `assets/simulator/dsp-worklet-processor.js` | Condicionar fast-track, suavizar MPO |
| Equivalente nativo C++ (a identificar en `android/app/src/main/cpp/`) | Mismos cambios que el worklet |
| `lib/dnn_denoiser/dnn_denoiser_controller.dart` | Sin cambios (el DNN en sí está bien) |

---

## 7. Resumen Ejecutivo

**Problema:** Gain pumping cíclico entre NR3 → WDRC fast-track → MPO adaptive → "matraca".  
**Causa raíz:** El WDRC reacciona a los residuos del NR como si fueran transients reales.  
**Solución core:** Desacoplar el WDRC del NR (no fast-track cuando NR≥1, MPO más suave).  
**Inspiración JBL:** Separar reducción de ruido de control de ganancia — dominios independientes.  
**Esfuerzo estimado:** 2-3 días de implementación + 1 día de validación con audio real.
