# Calibración Biológica para Audiometría Móvil (Smartphone-Based)
## Parámetros Técnicos de Implementación — Investigación Bibliográfica

**Fecha:** 2025-01-27  
**Investigador:** Kiro AI (búsqueda sistemática)  
**Objetivo:** Recopilar parámetros técnicos validados para implementar calibración biológica en app de audiometría móvil

---

## 1. Fuentes Consultadas

### Papers Principales (Peer-Reviewed)

| # | Autor(es) | Año | Título | Revista/Fuente | URL |
|---|-----------|-----|--------|----------------|-----|
| 1 | Masalski M, Grysiński T, Kręcicki T | 2014 | Biological Calibration for Web-Based Hearing Tests: Evaluation of the Methods | J Med Internet Res 16(1):e11 | https://www.jmir.org/2014/1/e11/ |
| 2 | Masalski M, Kipiński L, Grysiński T, Kręcicki T | 2016 | Hearing Tests on Mobile Devices: Evaluation of the Reference Sound Level by Means of Biological Calibration | J Med Internet Res 18(5):e130 | https://pmc.ncbi.nlm.nih.gov/articles/PMC4906240/ |
| 3 | Masalski M, Grysiński T, Kręcicki T | 2018 | Hearing Tests Based on Biologically Calibrated Mobile Devices: Comparison With Pure-Tone Audiometry | JMIR mHealth uHealth 6(1):e10 | https://pmc.ncbi.nlm.nih.gov/articles/PMC5784183/ |
| 4 | Swanepoel DW, Myburgh HC, Howe DM, et al. | 2014 | Smartphone hearing screening with integrated quality control and data management | Int J Audiol 53(12):841-9 | https://pubmed.ncbi.nlm.nih.gov/24998412/ |
| 5 | ASHA Working Group | 2005 | Guidelines for Manual Pure-Tone Threshold Audiometry | ASHA Policy Documents | https://www.asha.org/policy/gl2005-00014/ |
| 6 | Oremule B, et al. | 2024 | Mobile audiometry for hearing threshold assessment: A systematic review and meta-analysis | Clinical Otolaryngology | https://onlinelibrary.wiley.com/doi/10.1111/coa.14107 |
| 7 | Wallaert N, et al. | 2025 | Performance and reliability evaluation of an improved ML-based pure-tone audiometry with automated masking | World J Otorhinolaryngol Head Neck Surg | https://pmc.ncbi.nlm.nih.gov/articles/PMC12172120/ |
| 8 | Interacoustics | 2024 | Hughson-Westlake Procedure (AC40 Audiometer) | Documentación técnica | https://www.interacoustics.com/audiometers/ac40/support/hughson-westlake-procedure |
| 9 | Schlittenlacher J, et al. | 2021 | Utilizing True Wireless Stereo Earbuds in Automated Pure-Tone Audiometry | PubMed 34796771 | https://pubmed.ncbi.nlm.nih.gov/34796771/ |
| 10 | Wasmann JW, et al. | 2024 | Development and verification of non-supervised smartphone-based methods for assessing pure-tone thresholds | Int J Audiol | https://doi.org/10.1080/14992027.2024.2424876 |

### Estándares Normativos Referenciados

| Estándar | Descripción |
|----------|-------------|
| ANSI S3.6-2018 (R2023) | Specification for Audiometers |
| ANSI S3.21-2004 (R2019) | Methods for Manual Pure-Tone Threshold Audiometry |
| ANSI S3.1-1999 (R2023) | Maximum Permissible Ambient Noise Levels for Audiometric Test Rooms |
| ISO 8253-1:2010 | Acoustics — Audiometric test methods Part 1 |
| ISO 389-1:1998 | Reference equivalent threshold sound pressure levels |
| IEC 60645-1 | Electroacoustics - Audiometric equipment |

---

## 2. Parámetros Técnicos Encontrados

### 2.1 Duración del Tono de Prueba

**Fuente principal:** ASHA Guidelines for Manual Pure-Tone Threshold Audiometry (2005)

> "Pure-tone stimuli of **1 to 2 seconds' duration**."

**Fuentes complementarias:**
- Schlittenlacher et al. (2021): Duración del estímulo distribuida uniformemente entre **0.7 y 1.3 veces** el tiempo de reacción promedio del participante (adaptativo).
- Wasmann et al. (2024): Duración de **1 segundo** con rampas de 50 ms de subida y bajada.
- Método Békésy (Masalski 2014): Tono continuo con modulación de amplitud, frecuencia cambiando a 1 octava/60 segundos.

**Parámetro recomendado para implementación:**
- **Duración del tono: 1000-2000 ms** (1-2 segundos)
- Para método ascendente automatizado: **1000 ms** es el valor más común
- Para Békésy automatizado: tono continuo modulado

### 2.2 Rampa de Onset/Offset (Rise/Fall Time)

**Fuente principal:** Wasmann et al. (2024), Int J Audiol

> "The duration for all signals was 1 s with **50 ms rise and fall ramps**."

**Fuentes complementarias:**
- ANSI S3.6 especifica requisitos de rise/fall time para audiometros calibrados. Los valores típicos son:
  - **20-50 ms** para tonos puros en audiometría convencional
  - Mínimo **20 ms** para evitar clicks espectrales (transitorios de banda ancha)
- IEC 60645-1: Rise time nominal de **20 ms** (±50%) para audiometros tipo 1-4
- Para ABR (potenciales evocados): 3-10 ms (no aplica a audiometría conductual)

**Parámetro recomendado para implementación:**
- **Rise time: 20-50 ms** (rampa coseno elevado o lineal)
- **Fall time: 20-50 ms** (simétrico al rise)
- Valor óptimo para smartphone: **30 ms** (compromiso entre evitar clicks y mantener duración efectiva)
- Tipo de rampa: **coseno elevado (raised cosine)** — produce la menor dispersión espectral

### 2.3 Intervalo Entre Presentaciones de Tono

**Fuente principal:** ASHA Guidelines (2005)

> "The interval between successive tone presentations shall be **varied but not shorter than the test tone**."

**Fuentes complementarias:**
- Masalski (2014), método ascendente: Señal presentada por duración aleatoria de **2 a 7 segundos**, con ventana de respuesta de hasta 2 segundos.
- Schlittenlacher et al. (2021): Intervalo de respuesta entre **100 ms después del onset** y **1 segundo después del offset** del estímulo.
- Método Hughson-Westlake automatizado: Intervalos típicos de **1-3 segundos** entre presentaciones.

**Parámetro recomendado para implementación:**
- **Intervalo mínimo: igual a la duración del tono** (≥1000 ms)
- **Intervalo recomendado: 1000-3000 ms** (aleatorizado)
- **Ventana de respuesta: 100 ms post-onset hasta 1000-2000 ms post-offset**
- La variación aleatoria del intervalo es CRÍTICA para evitar respuestas rítmicas (falsos positivos)

### 2.4 Nivel Inicial de Presentación

**Fuente principal:** ASHA Guidelines (2005)

> "The level of the first presentation of the test tone shall be **well below the expected threshold**."

**Procedimiento de familiarización (ASHA):**
> "Present a 1000-Hz tone at **30 dB HL**. If no response occurs, present at **50 dB HL** and at successive additional increments of **10 dB** until a response is obtained."

**Fuentes complementarias:**
- Método Hughson-Westlake clásico: Comienza a nivel audible estimado de **30-40 dB HL** para adultos típicos.
- Masalski (2016), calibración biológica: El nivel más bajo teóricamente generado se asume a **-40 dB** (relativo al máximo digital).
- Para calibración biológica con sujetos normoyentes: El umbral esperado es ~0 dB HL, por lo que se inicia a **~30 dB HL** y se desciende.

**Parámetro recomendado para implementación:**
- **Familiarización: 30 dB HL** (o equivalente en dBFS según calibración del dispositivo)
- **Inicio de búsqueda de umbral: 10-20 dB por encima del umbral esperado**
- Para calibración biológica (sujetos normoyentes): Iniciar a **~30 dB HL equivalente**
- En dBFS: depende del dispositivo, pero típicamente entre **-40 y -60 dBFS** para el nivel de familiarización

### 2.5 Paso de Incremento/Decremento

**Fuente principal:** ASHA Guidelines (2005) — Método Ascendente Modificado Hughson-Westlake

> "After each failure to respond to a signal, the level is increased in **5-dB steps** until the first response occurs. After the response, the intensity is decreased **10 dB**, and another ascending series is begun."

**Fuentes complementarias:**
- Interacoustics AC40 (Hughson-Westlake automatizado): "Intensity increases occur in **5 dB steps**, while intensity decreases happen in **10 dB steps**."
- Masalski (2014), método ascendente con paso fino: **4 dB down, 2 dB up** (mayor precisión, SD test-retest = 5.00 dB)
- Masalski (2014), método ascendente estándar: **10 dB down, 5 dB up** (SD test-retest = 6.05 dB)
- Método Békésy (Masalski 2014): Cambio continuo de **2 dB/segundo** (ascendente cuando inaudible, descendente cuando audible)

**Parámetro recomendado para implementación:**
- **Protocolo estándar (Hughson-Westlake modificado):**
  - Descenso: **10 dB** tras respuesta positiva
  - Ascenso: **5 dB** tras no-respuesta
- **Protocolo de alta precisión (para calibración biológica):**
  - Descenso: **4 dB** tras respuesta positiva  
  - Ascenso: **2 dB** tras no-respuesta
- **Protocolo Békésy (recomendado por Masalski para calibración):**
  - Cambio continuo: **2 dB/segundo** en ambas direcciones

### 2.6 Criterio de Umbral

**Fuente principal:** ASHA Guidelines (2005) / ANSI S3.21-2004

> "Threshold is defined as the lowest decibel hearing level at which responses occur in at least **one half of a series of ascending trials**. The minimum number of responses needed to determine the threshold of hearing is **two responses out of three presentations** at a single level."

**Fuentes complementarias:**
- Interacoustics AC40: "The patient needs to respond to the same intensity **2 out of 3 or 3 out of 5 times**."
- Wallaert et al. (2025): ~74% de estudios publicados en la última década utilizan el procedimiento Hughson-Westlake modificado.
- Masalski (2014), método ascendente: "El coeficiente de calibración se definió como el nivel más bajo en el que las respuestas ocurrieron en al menos la mitad de las series ascendentes con un mínimo de 2 respuestas requeridas."
- Método Békésy: No usa criterio discreto; el umbral es la **media de los puntos de cruce** (donde el sujeto cambia de "oigo" a "no oigo" y viceversa), excluyendo outliers con test de Grubbs.

**Parámetro recomendado para implementación:**
- **Criterio estándar: 2 de 3 respuestas positivas** en series ascendentes al mismo nivel
- **Criterio alternativo: 3 de 5 respuestas positivas** (más conservador)
- **Para Békésy: media de reversiones** (puntos de cruce audible/inaudible) dentro de ±0.5 octava

### 2.7 Frecuencias de Prueba y Orden de Presentación

**Fuente principal:** ASHA Guidelines (2005)

> Diagnóstico: "Threshold assessment should be made at **250, 500, 1000, 2000, 3000, 4000, 6000, and 8000 Hz**."

> Orden: "The initial test frequency should be **1000 Hz**. Following: **2000, 3000, 4000, 6000, 8000 Hz**, followed by retest of 1000 Hz before testing **500, 250, and 125 Hz**."

**Fuentes complementarias:**
- Masalski (2016), calibración biológica móvil: Coeficientes determinados para **250, 500, 1000, 2000, 4000, 6000, y 8000 Hz**.
- Honeth et al. (2010): Calibración biológica a **500, 1000, 2000, 6000, y 8000 Hz**.
- Masalski (2014), método Békésy: Frecuencia cambiando continuamente de **62.5 Hz a 16 kHz** a velocidad de 1 octava/60 segundos.
- hearTest/hearScreen (Swanepoel): Frecuencias de **500, 1000, 2000, 4000 Hz** (screening) o set completo para diagnóstico.

**Parámetro recomendado para implementación:**
- **Para calibración biológica (mínimo):** 500, 1000, 2000, 4000 Hz
- **Para calibración biológica (completa):** 250, 500, 1000, 2000, 4000, 6000, 8000 Hz
- **Orden de presentación:** 1000 → 2000 → 4000 → 8000 → 500 → 250 Hz
- **Inicio siempre en 1000 Hz** (frecuencia de referencia, menor variabilidad inter-sujeto)

### 2.8 Requisitos de Ruido Ambiental Máximo Permitido

**Fuente principal:** ANSI S3.1-1999 (R2023) — Maximum Permissible Ambient Noise Levels

> Especifica niveles máximos de ruido ambiental que producen enmascaramiento despreciable (**≤2 dB**) de señales de prueba presentadas a niveles de referencia equivalentes.

**Fuentes complementarias:**
- hearTest (Swanepoel, hearX Group): Cumple con ISO/SANS 8253-1 para audiometría de screening. Usa auriculares insert cubiertos por orejeras circumaurales para atenuación equivalente a cabina de pared simple.
- Masalski (2014): "Se asumió que los exámenes en casa no están afectados por ruido de fondo distinto al ruido del ventilador... en tablets o smartphones, el error puede ser menor por ausencia de ruido de ventilador."
- Para audiometría sin cabina (boothless): Se requiere monitoreo continuo del ruido ambiental.

**Niveles máximos permisibles (ANSI S3.1) para auriculares supra-aurales (dB SPL):**

| Frecuencia | Oídos cubiertos (supra-aural) | Oídos cubiertos (insert) |
|------------|-------------------------------|--------------------------|
| 250 Hz | 32.0 dB SPL | 53.5 dB SPL |
| 500 Hz | 21.5 dB SPL | 42.5 dB SPL |
| 1000 Hz | 26.5 dB SPL | 42.0 dB SPL |
| 2000 Hz | 34.5 dB SPL | 47.0 dB SPL |
| 4000 Hz | 37.0 dB SPL | 52.5 dB SPL |
| 8000 Hz | 37.0 dB SPL | 56.0 dB SPL |

**Parámetro recomendado para implementación:**
- **Monitoreo continuo de ruido ambiental** usando el micrófono del smartphone
- **Umbral de ruido máximo para screening:** ~40 dB(A) ambiente general
- **Pausa automática** si el ruido ambiental excede el MPANL para la frecuencia bajo prueba
- **Uso de auriculares insert** (mayor atenuación pasiva, ~25-30 dB) preferido sobre supra-aurales
- **Auriculares circumaurales sobre inserts** para máxima atenuación (~35-40 dB combinado)

### 2.9 Tipo de Transductor y Sus Implicaciones

**Fuente principal:** ASHA Guidelines (2005) / ANSI S3.6

> "Supra-aural and insert earphones are appropriate for air-conduction threshold measurements from 125 Hz through 8000 Hz."

**Fuentes complementarias:**
- Masalski (2016): Usa **auriculares bundled** (incluidos con el dispositivo móvil). La variabilidad intra-modelo fue SD = 4.03 dB.
- Swanepoel (hearScreen): Usa **auriculares calibrados específicos** (supra-aurales o insert) con el smartphone.
- Foulad et al. (2013): Para dispositivos iOS, diferencias entre sets dentro de **4 dB**.

**Tipos de transductor y consideraciones:**

| Tipo | Atenuación Pasiva | Ventajas | Desventajas |
|------|-------------------|----------|-------------|
| Insert (foam tip) | 25-30 dB | Mayor atenuación, menor colapso canal, menor variabilidad | Requiere inserción correcta |
| Supra-aural | 10-15 dB | Fácil colocación | Menor atenuación, posible colapso canal |
| Circumaural | 15-25 dB | Cómodo, buena atenuación | Voluminoso, costoso |
| Earbuds bundled | 0-5 dB | Disponibilidad universal | Mínima atenuación, alta variabilidad |
| TWS (True Wireless) | 20-30 dB (ANC) | Moderno, buena atenuación con ANC | Latencia Bluetooth, variabilidad |

**Parámetro recomendado para implementación:**
- **Ideal:** Auriculares insert calibrados (tipo ER-3A o equivalente)
- **Práctico para app móvil:** Auriculares bundled del dispositivo + calibración biológica por modelo
- **Alternativa moderna:** TWS con tips de silicona (buena atenuación pasiva)
- **NUNCA usar parlante/altavoz** para audiometría de umbral (sin control de campo sonoro)

### 2.10 Validación Estadística

**Fuente principal:** Masalski et al. (2016), PMC4906240

**Estudio de calibración biológica en dispositivos móviles:**
- **Grupo no controlado:** 8988 calibraciones en 8620 dispositivos (2040 modelos)
- **Grupo controlado:** 158 calibraciones (test y retest) en 79 dispositivos (50 modelos)
- **Diferencia entre grupos:** 1.50 dB (SD 4.42)
- **Variabilidad intra-modelo:** SD = 4.03 dB (95% CI 3.93-4.11)
- **Mínimo de calibraciones por modelo:** 16 calibraciones para error < 5 dB

**Masalski et al. (2014), JMIR — Evaluación de métodos:**
- **Sujetos:** 25 participantes, edad 22-35 años (mediana 27)
- **Mejor método (Békésy modulado):** SD test-retest = 3.87 dB (95% CI 3.52-4.29)
- **Método simple (ajuste de volumen):** SD test-retest = 4.97 dB (95% CI 4.53-5.51)
- **Error estimado vs audiometría clínica:** SD = 7.27 dB (95% CI 6.71-7.93) para el mejor método

**Masalski et al. (2018), JMIR mHealth — Comparación con audiometría:**
- Comparación directa de umbral medido por dispositivo móvil calibrado biológicamente vs audiometría tonal pura clínica.
- Validación del uso de nivel de referencia predefinido por modelo de dispositivo.

**Criterios de validación encontrados en la literatura:**

| Métrica | Valor Aceptable | Fuente |
|---------|-----------------|--------|
| SD test-retest calibración | < 5 dB | Masalski 2014 |
| Diferencia media vs PTA clínica | < 10 dB SD | Masalski 2014 |
| Variabilidad intra-modelo | < 5 dB SD | Masalski 2016 |
| Mínimo sujetos para calibración | 10-16 por modelo | Masalski 2016 |
| Edad sujetos calibración | 18-35 años | Masalski 2016 |
| Criterio audición normal | ≤ 20 dB HL (125-8000 Hz) | ASHA/ISO |
| Sensibilidad screening | > 0.75 | Honeth 2010 |
| Especificidad screening | > 0.89 | Masalski 2013 |

---

## 3. Tabla Resumen de Parámetros para Implementación

| Parámetro | Valor Recomendado | Rango Aceptable | Fuente Principal |
|-----------|-------------------|-----------------|------------------|
| **Duración del tono** | 1000 ms | 1000-2000 ms | ASHA 2005 |
| **Rise/Fall time (rampa)** | 30 ms (coseno elevado) | 20-50 ms | ANSI S3.6 / Wasmann 2024 |
| **Intervalo entre tonos** | 1500 ms (aleatorio) | 1000-3000 ms (variable) | ASHA 2005 |
| **Nivel inicial** | 30 dB HL equivalente | 20-40 dB HL | ASHA 2005 |
| **Paso ascendente** | 5 dB | 2-5 dB | ANSI S3.21 / ASHA 2005 |
| **Paso descendente** | 10 dB | 4-10 dB | ANSI S3.21 / ASHA 2005 |
| **Criterio de umbral** | 2 de 3 ascendentes | 2/3 o 3/5 | ANSI S3.21-2004 |
| **Frecuencias (screening)** | 500, 1000, 2000, 4000 Hz | — | hearScreen / ASHA |
| **Frecuencias (diagnóstico)** | 250-8000 Hz (octavas) | + 3000, 6000 Hz | ASHA 2005 |
| **Orden de frecuencias** | 1000→2000→4000→8000→500→250 | — | ASHA 2005 |
| **Ruido ambiental máx** | < 40 dB(A) general | Según ANSI S3.1 por freq | ANSI S3.1-1999 |
| **Transductor preferido** | Insert earphone | Insert > Supra-aural > Earbud | ASHA 2005 |
| **Sujetos para calibración** | ≥ 16 por modelo | 10-25 mínimo | Masalski 2016 |
| **Edad sujetos calibración** | 18-35 años | Sin historia de pérdida | Masalski 2016 |
| **Tolerancia vs PTA clínica** | SD < 10 dB | SD 7-10 dB típico | Masalski 2014 |
| **Error calibración biológica** | SD ≈ 4-5 dB | 3.87-4.97 dB | Masalski 2014 |

---

## 4. Protocolo de Calibración Biológica Recomendado (Síntesis)

Basado en la evidencia recopilada, el protocolo óptimo para calibración biológica en smartphone es:

### Método Recomendado: Békésy Modulado (Masalski 2014)

```
Tipo de señal:     Tono puro modulado en amplitud (AM)
                   Envolvente sinusoidal, frecuencia 2 Hz, profundidad 100%
Barrido:           Frecuencia ascendente, 1 octava/60 segundos
                   Rango: 125 Hz → 8000 Hz (o 250 → 8000 Hz)
Cambio intensidad: 2 dB/segundo (sube cuando inaudible, baja cuando audible)
Duración total:    ~7 minutos
Interacción:       Sujeto presiona botón mientras oye, suelta cuando no oye
Umbral:            Media de puntos de cruce (audible↔inaudible) por frecuencia
                   Calculado en ventana de ±0.5 octava por frecuencia objetivo
Precisión:         SD test-retest = 3.87 dB (mejor de 7 métodos evaluados)
```

### Método Alternativo Rápido: Ascendente Modificado (ASHA/Hughson-Westlake)

```
Tipo de señal:     Tono puro pulsado (o continuo)
Duración tono:     1000 ms
Rise/Fall:         30 ms (coseno elevado)
Intervalo:         1000-3000 ms (aleatorio)
Inicio:            30 dB HL (familiarización)
Descenso:          -10 dB tras respuesta positiva
Ascenso:           +5 dB tras no-respuesta
Criterio umbral:   2 de 3 respuestas al mismo nivel ascendente
Frecuencias:       1000, 2000, 4000, 8000, 500, 250 Hz (en ese orden)
Duración total:    ~3-5 minutos (screening) o ~10-15 min (completo)
Precisión:         SD test-retest = 5.37 dB (audiometría clínica bilateral)
```

### Requisitos del Sujeto de Calibración

```
Edad:              18-35 años
Audición:          Normal verificada (≤ 20 dB HL en 125-8000 Hz)
                   O auto-reportada sin historia de problemas auditivos
Ambiente:          Silencioso (< 40 dB(A) ambiental)
                   Idealmente sin ruido de ventilador ni tráfico
Auriculares:       Los bundled del dispositivo (para calibración por modelo)
                   O auriculares específicos calibrados
Instrucciones:     Claras, en idioma del sujeto
                   Demostración previa del procedimiento
```

### Determinación del Nivel de Referencia

```
Nivel de referencia = Coeficiente de calibración - Umbral auditivo del sujeto

Para grupo no controlado (auto-calibración):
  Nivel de referencia = Moda de coeficientes - Mediana poblacional de umbral

Para grupo controlado (clínica):
  Nivel de referencia = Media de coeficientes - Umbral PTA medido

Mínimo calibraciones por modelo: 16 (para error < 5 dB)
Estadístico recomendado: Moda (más robusto a outliers que mediana)
Percentil alternativo: 37° percentil (más estable con pocas muestras)
```

---

## 5. Notas Sobre lo que NO se Encontró

### Información no disponible o parcialmente disponible:

1. **Especificación exacta de rise/fall time en ANSI S3.6 para smartphones:** El estándar ANSI S3.6 especifica requisitos para audiometros certificados, pero no hay un estándar específico para apps de smartphone. Los valores de 20-50 ms son extrapolados de la norma para audiometros tipo 4.

2. **Nivel inicial exacto en dBFS para cada modelo de smartphone:** Cada modelo tiene diferente ganancia de salida. No existe una tabla universal de niveles dBFS equivalentes a dB HL para todos los smartphones. Esto es precisamente lo que la calibración biológica resuelve.

3. **Tesis de maestría/doctorado específicas de universidades de EEUU:** No se encontraron tesis accesibles públicamente con los parámetros técnicos exactos de implementación. La investigación principal proviene de:
   - Universidad Médica de Wroclaw, Polonia (Masalski et al.)
   - Universidad de Pretoria, Sudáfrica (Swanepoel et al.)
   - Estos son los grupos de investigación líderes mundiales en el tema.

4. **Valores RETSPL específicos para auriculares de smartphone:** Los valores RETSPL (Reference Equivalent Threshold Sound Pressure Level) de ANSI S3.6 están definidos para transductores audiométricos específicos (TDH-39, HDA-200, ER-3A), no para auriculares comerciales de consumo.

5. **Protocolo estandarizado ISO/ANSI para audiometría móvil:** No existe aún un estándar internacional específico para audiometría basada en smartphone. hearTest cumple con IEC 60645-1 como audiometro tipo 4, pero es un producto comercial específico.

6. **Validación con más de 100 sujetos en grupo controlado:** El estudio más grande en grupo controlado (Masalski 2016) usó 79 dispositivos/158 calibraciones. El grupo no controlado sí tuvo >8000 calibraciones.

7. **Especificación de latencia máxima aceptable del sistema de audio del smartphone:** No se encontró un valor específico publicado. La latencia de audio en Android varía de 10-200 ms según el dispositivo y API usada (Oboe/AAudio reduce esto a <10 ms).

---

## 6. Consideraciones Adicionales para Implementación

### Modulación del Tono (Pulsado vs Continuo)

- **Tonos pulsados** mejoran la detección del estímulo por el sujeto (Burk & Wiley, 2004)
- Para calibración Békésy: usar **modulación AM sinusoidal a 2 Hz, profundidad 100%**
- Para método ascendente: usar **tono pulsado** (on/off con rampas de 30 ms)

### Presentación Monaural vs Binaural

- Masalski (2014): Calibración presentada **bilateralmente** (ambos oídos simultáneamente)
- ASHA (2005): Audiometría diagnóstica es **monaural** (un oído a la vez)
- **Para calibración biológica:** bilateral es aceptable (más rápido, menor error por promediado)
- **Para test de umbral post-calibración:** monaural obligatorio

### Verificación de Calidad de Respuestas

- Monitorear **falsos positivos** (respuesta sin tono): Si > 20%, reinstuir al sujeto
- Monitorear **latencia de respuesta**: Respuestas > 2 segundos post-offset son sospechosas
- **Catch trials** (presentaciones sin tono): Incluir ~10% para detectar respondedores compulsivos
- Verificar consistencia: Si retest a 1000 Hz difiere > 5 dB del primer test, repetir

### Calibración por Modelo vs Individual

| Enfoque | Precisión | Escalabilidad | Uso |
|---------|-----------|---------------|-----|
| Calibración individual | ±5 dB | Baja (cada usuario calibra) | Diagnóstico |
| Calibración por modelo | ±8 dB | Alta (una vez por modelo) | Screening |
| Calibración de laboratorio | ±3 dB | Muy baja (equipo especial) | Referencia |

---

## 7. Referencias Bibliográficas Completas

1. Masalski M, Grysiński T, Kręcicki T. Biological calibration for web-based hearing tests: evaluation of the methods. J Med Internet Res. 2014;16(1):e11. doi:10.2196/jmir.2798. PMID: 24429353. PMC3906690.

2. Masalski M, Kipiński L, Grysiński T, Kręcicki T. Hearing tests on mobile devices: evaluation of the reference sound level by means of biological calibration. J Med Internet Res. 2016;18(5):e130. doi:10.2196/jmir.4987. PMID: 27241793. PMC4906240.

3. Masalski M, Grysiński T, Kręcicki T. Hearing tests based on biologically calibrated mobile devices: comparison with pure-tone audiometry. JMIR Mhealth Uhealth. 2018;6(1):e10. doi:10.2196/mhealth.7800. PMID: 29321124. PMC5784183.

4. American Speech-Language-Hearing Association. Guidelines for manual pure-tone threshold audiometry. 2005. Available: https://www.asha.org/policy/gl2005-00014/

5. ANSI S3.21-2004 (R2019). Methods for Manual Pure-Tone Threshold Audiometry. American National Standards Institute.

6. ANSI S3.6-2018 (R2023). Specification for Audiometers. American National Standards Institute.

7. ANSI S3.1-1999 (R2023). Maximum Permissible Ambient Noise Levels for Audiometric Test Rooms.

8. Swanepoel DW, Myburgh HC, Howe DM, Mahomed F, Eikelboom RH. Smartphone hearing screening with integrated quality control and data management. Int J Audiol. 2014;53(12):841-9. PMID: 24998412.

9. Schlittenlacher J, et al. Utilizing true wireless stereo earbuds in automated pure-tone audiometry. Ear Hear. 2022;43(4):1235-1246. PMID: 34796771.

10. Wasmann JW, et al. Development and verification of non-supervised smartphone-based methods for assessing pure-tone thresholds and loudness perception. Int J Audiol. 2024. doi:10.1080/14992027.2024.2424876.

11. Honeth L, et al. An internet-based hearing test for simple audiometry in nonclinical settings. Otol Neurotol. 2010;31(5):708-14. PMID: 20458255.

12. Oremule B, et al. Mobile audiometry for hearing threshold assessment: A systematic review and meta-analysis. Clin Otolaryngol. 2024. doi:10.1111/coa.14107.

---

*Documento generado mediante búsqueda sistemática en Brave Search, PubMed/PMC, JMIR, y documentación ASHA/ANSI.*  
*Todo contenido de fuentes externas fue parafraseado para cumplimiento de licencias de contenido.*  
*Las citas textuales (en bloques >) se limitan a menos de 30 palabras consecutivas por fuente.*


---

## 8. Revisión y Complementos para Implementación

**Fecha de revisión:** 2025-01-28
**Objetivo:** Identificar gaps en el plan actual, resolver problemas técnicos pendientes, y proveer pseudocódigo completo para implementación.

---

### 8.1 Lo que Falta en el Plan Actual

#### 8.1.1 Conversión dB HL → dBFS para Auricular No Calibrado

Este es el **problema central** que la calibración biológica resuelve. La relación es:

```
dBFS_para_nivel_HL = offset_biologico[freq] + nivel_HL_deseado

Donde:
  offset_biologico[freq] = nivel dBFS al cual el normoyente APENAS escucha
                         = "0 dB HL" expresado en dBFS para ESE auricular
```

**El problema concreto:**
- No sabemos cuántos dB SPL produce el auricular BT a un nivel dBFS dado.
- No tenemos RETSPL para auriculares comerciales (solo existen para TDH-39, ER-3A).
- La respuesta en frecuencia del auricular BT NO es plana (varía ±10 dB entre frecuencias).

**La solución (calibración biológica):**
1. Emitir tono a freq F partiendo de nivel bajo (ej: -70 dBFS).
2. Subir hasta que el normoyente dice "lo escucho" → ese nivel = `threshold_dBFS[F]`.
3. Promediar 3 sujetos → `mean_threshold_dBFS[F]`.
4. Ese valor ES el "0 dB HL" para esa freq con ese auricular.
5. Para emitir X dB HL: `amplitude_dBFS = mean_threshold_dBFS[F] + X`.

**Ejemplo numérico:**
```
Frecuencia: 2000 Hz
Sujeto 1 umbral: -52 dBFS
Sujeto 2 umbral: -48 dBFS
Sujeto 3 umbral: -50 dBFS
Promedio: -50 dBFS → esto es "0 dB HL a 2 kHz" para este auricular

Para emitir 40 dB HL a 2 kHz:
  amplitude_dBFS = -50 + 40 = -10 dBFS
  amplitude_lineal = 10^(-10/20) = 0.316
```

**Corrección por mediana poblacional (Masalski 2016):**

El umbral de un normoyente NO es exactamente 0 dB HL — tiene variabilidad.
La mediana poblacional para 18-35 años es ~2-5 dB HL según frecuencia.
Para mayor precisión:

```
offset_corregido[F] = mean_threshold_dBFS[F] - mediana_poblacional_HL[F]

Medianas poblacionales (Engdahl 2005, Nord-Trøndelag):
  250 Hz:  3.0 dB HL
  500 Hz:  2.5 dB HL
  1000 Hz: 2.0 dB HL
  2000 Hz: 1.5 dB HL
  4000 Hz: 3.0 dB HL
  6000 Hz: 5.0 dB HL
  8000 Hz: 5.5 dB HL
```

**Para nuestra implementación con 3 sujetos:** la corrección por mediana es opcional.
Con solo 3 sujetos, el error estadístico (~5 dB SD) domina sobre la corrección
de 2-5 dB. Se recomienda implementar pero marcar como "ajuste fino opcional".

#### 8.1.2 Rango Dinámico del Transductor (Auricular BT)

**Problema:** ¿El auricular BT puede cubrir 0-80 dB HL en todas las frecuencias?

**Análisis del rango disponible:**

```
Rango digital disponible:     96 dB (16-bit PCM: -96 dBFS a 0 dBFS)
Piso de ruido del DAC:        ~-90 dBFS (típico para smartphone)
Máximo sin distorsión:        0 dBFS (clipping digital)
Rango útil real:              ~85 dB (de -85 dBFS a 0 dBFS)

Rango audiométrico necesario: 0 a 80 dB HL = 80 dB de rango dinámico

¿Alcanza? Depende de dónde cae el umbral biológico:
  Si threshold_dBFS[F] = -50 dBFS (caso típico):
    0 dB HL = -50 dBFS ✓ (audible, sobre piso de ruido)
    80 dB HL = -50 + 80 = +30 dBFS ✗ (¡EXCEDE 0 dBFS! → CLIPPING)
    Máximo alcanzable: 0 - (-50) = 50 dB HL ← INSUFICIENTE

  Si threshold_dBFS[F] = -80 dBFS (auricular sensible):
    0 dB HL = -80 dBFS ✓ (apenas sobre piso de ruido)
    80 dB HL = -80 + 80 = 0 dBFS ✓ (justo en el máximo)
    Máximo alcanzable: 80 dB HL ← SUFICIENTE
```

**Datos reales de auriculares BT (investigación):**
- Sensibilidad típica auriculares in-ear: 95-110 dB SPL/mW
- Salida máxima smartphone a 0 dBFS: 85-105 dB SPL (varía por modelo)
- Umbral auditivo normal: ~0-10 dB SPL (varía por frecuencia)
- Rango dinámico efectivo: 75-95 dB (desde umbral hasta máximo)

**Conclusión:** La mayoría de auriculares BT in-ear con tips de silicona
pueden cubrir 0-70 dB HL cómodamente. Para 80 dB HL puede haber limitación
en frecuencias extremas (250 Hz, 8000 Hz) donde la sensibilidad del
auricular es menor.

**Mitigación implementada:**
1. Durante calibración, registrar el `threshold_dBFS[F]` para cada frecuencia.
2. Calcular `max_HL_alcanzable[F] = 0 dBFS - threshold_dBFS[F]` (con margen de -1 dB).
3. Si `max_HL_alcanzable[F] < 70 dB HL` → advertir al usuario que el auricular
   tiene rango insuficiente para esa frecuencia.
4. En la audiometría posterior, nunca intentar emitir por encima de -1 dBFS
   (hard limit para evitar clipping/distorsión).

#### 8.1.3 Ventana de Respuesta y Latencia Bluetooth

**El plan actual no especifica cómo manejar la latencia BT.**

**Latencias típicas Bluetooth audio (investigación 2024):**

| Codec/Protocolo | Latencia típica | Rango |
|-----------------|-----------------|-------|
| SBC (Android default) | 150-250 ms | 100-300 ms |
| AAC (iOS/Android) | 120-200 ms | 80-250 ms |
| aptX | 60-80 ms | 40-100 ms |
| aptX Low Latency | 32-40 ms | 30-50 ms |
| LC3 (LE Audio) | 10-30 ms | 5-40 ms |
| Wired (referencia) | 5-15 ms | 3-20 ms |

Fuente: SoundGuys 2021, PCWorld 2024, CEVA Bluetooth 2024.

**Impacto en la ventana de respuesta:**

```
Tiempo de reacción humano promedio (estímulo auditivo): 200-300 ms
Latencia BT (SBC worst case): 250 ms
Latencia total onset-a-percepción: 250 ms (BT) + 0 ms (procesamiento) = 250 ms

Ventana de respuesta actual: 100 ms post-onset hasta 2000 ms post-offset
Con latencia BT de 250 ms:
  - El sujeto percibe el tono 250 ms DESPUÉS de que la app lo emitió
  - Su respuesta llega 200-300 ms después de percibirlo
  - Total: 450-550 ms después del onset programado
  - Esto CAE DENTRO de la ventana [100ms, offset+2000ms] → OK

Problema real: el OFFSET también se percibe 250 ms tarde
  - Si tono dura 1000 ms, el sujeto lo percibe de t=250 a t=1250 ms
  - Ventana post-offset debería ser: offset_real + 250ms + 2000ms
```

**Solución pragmática:**
- La latencia BT NO afecta la DETECCIÓN del umbral (el sujeto oye o no oye).
- Solo afecta el TIMING de la respuesta.
- Solución: usar ventana de respuesta generosa (desde onset hasta offset + 3000 ms).
- NO intentar medir latencia BT (es variable e impredecible).
- El criterio de umbral (2/3 ascendentes) no depende del timing exacto.

#### 8.1.4 Volumen del Sistema Operativo

**Problema crítico no abordado en el plan:**

El volumen del sistema Android/iOS modifica la ganancia DESPUÉS del DAC digital.
Si el usuario cambia el volumen durante o después de la calibración, toda la
tabla de offsets queda INVALIDADA.

```
Cadena de audio real:
  App (dBFS) → Android AudioFlinger → Volume Control (OS) → BT Codec → DAC → Auricular

El "volume control" del OS aplica una ganancia adicional que NO controlamos.
Si durante calibración el volumen estaba al 80%, y después lo baja al 50%,
los offsets ya no son válidos.
```

**Mitigaciones:**
1. **Fijar volumen al máximo (100%)** durante calibración Y durante uso posterior.
   - Usar `AudioManager.setStreamVolume(STREAM_MUSIC, maxVolume)` en Android.
   - Documentar que el volumen debe estar al máximo.
   - Verificar volumen antes de cada sesión de audiometría.
2. **Registrar el nivel de volumen** en el JSON de calibración.
3. **Verificar antes de usar:** si el volumen actual ≠ volumen de calibración → advertir.
4. **Alternativa:** usar `FLAG_SHOW_UI = false` para evitar que el usuario lo cambie.

**Nota:** El `ToneEmitter` existente ya usa `_player.setVolume(1.0)` (volumen del
player al máximo), pero esto NO controla el volumen del stream del sistema.

#### 8.1.5 Falta de Especificación de Nivel Inicial en dBFS

El plan dice "30 dB HL equivalente" como nivel inicial, pero no especifica
cómo convertir eso a dBFS ANTES de tener la calibración.

**Solución:** Usar un nivel inicial FIJO en dBFS que sea "claramente audible
para un normoyente con cualquier auricular razonable":

```
Nivel inicial de familiarización: -30 dBFS
Justificación:
  - Auricular típico a -30 dBFS produce ~60-70 dB SPL
  - Esto es ~55-65 dB HL (claramente audible para normoyente)
  - Si no responde: subir a -20 dBFS, luego -10 dBFS
  - Si sigue sin responder a -10 dBFS: auricular defectuoso o no normoyente

Nivel mínimo de búsqueda: -80 dBFS
Justificación:
  - Por debajo de -80 dBFS, el piso de ruido del DAC/BT domina
  - No tiene sentido buscar umbrales por debajo de esto
  - Si el umbral cae a -80 dBFS: registrar como "floor" y advertir

Nivel máximo de búsqueda: -5 dBFS
Justificación:
  - Nunca emitir a 0 dBFS (riesgo de clipping)
  - -5 dBFS da margen de seguridad
  - Si el umbral está por encima de -5 dBFS: auricular inadecuado
```

---

### 8.2 Problemas Técnicos que Hay que Resolver

#### 8.2.1 Problema: Reproducción de Tonos Cortos vía BT con just_audio

El `ToneEmitter` actual genera un WAV completo en memoria y lo reproduce con
`just_audio`. Esto tiene un problema para el protocolo Hughson-Westlake:

```
Problema: Cada presentación de tono requiere:
  1. Generar WAV (rápido, ~1ms para 1000ms de audio)
  2. Cargar en AudioPlayer (setAudioSource) → 50-200 ms
  3. Iniciar reproducción (play) → 10-50 ms
  4. Latencia BT → 100-250 ms
  Total overhead por presentación: 160-500 ms

Para Hughson-Westlake con ITI de 1000-3000 ms, esto es aceptable.
El overhead se absorbe dentro del intervalo entre tonos.
```

**Solución:** Mantener el enfoque actual del `ToneEmitter` (generar WAV por
presentación). El overhead es tolerable para el protocolo ascendente.

**Optimización opcional:** Pre-generar WAVs para todos los niveles posibles
de una frecuencia dada (ej: -80 a -5 dBFS en pasos de 5 dB = 15 WAVs).
Cargarlos al inicio de cada frecuencia para reducir latencia inter-tono.

#### 8.2.2 Problema: Detección de Respuesta del Usuario

El plan dice "presiona botón cuando escucha" pero no especifica:
- ¿Qué pasa si presiona ANTES de que suene el tono? (falso positivo)
- ¿Qué pasa si presiona DURANTE el intervalo? (falso positivo)
- ¿Cómo se distingue respuesta válida de toque accidental?

**Solución: Ventana de respuesta estricta + catch trials**

```
RESPUESTA VÁLIDA:
  - Presión del botón dentro de [onset + 100ms, offset + 2500ms]
  - onset + 100ms: mínimo tiempo de reacción humano (descarta anticipación)
  - offset + 2500ms: máximo considerando latencia BT + reacción lenta

RESPUESTA INVÁLIDA (falso positivo):
  - Presión fuera de la ventana de respuesta
  - Presión durante catch trial (sin tono)
  - Se registra pero NO cuenta como "escuchó"

RESPUESTA TARDÍA:
  - Presión entre offset+2500ms y onset del siguiente tono
  - Se registra como "tardía" → no cuenta, pero no penaliza
```

#### 8.2.3 Problema: Variabilidad del Volumen BT por Codec

Diferentes codecs BT (SBC, AAC, aptX, LDAC) pueden aplicar diferentes
niveles de ganancia/compresión a la señal. Además, algunos auriculares BT
tienen su propio control de volumen interno.

**Mitigación:**
- Registrar en el JSON de calibración: nombre del dispositivo BT, codec si es
  detectable (Android API 28+ permite consultar codec activo).
- Si el auricular BT cambia (diferente MAC address): invalidar calibración.
- Si el codec cambia: advertir (no invalidar, la diferencia suele ser <3 dB).

#### 8.2.4 Problema: Absolute Volume vs Fixed Volume en Android

Android tiene "Absolute Bluetooth Volume" que sincroniza el volumen del
teléfono con el del auricular BT. Si está desactivado, el auricular tiene
su propio control de volumen independiente.

**Mitigación:**
- Verificar que Absolute Volume esté ACTIVADO (es el default en Android 6+).
- Instruir al usuario: "Sube el volumen del teléfono al máximo".
- Registrar el volumen del stream en el momento de calibración.
- Antes de audiometría: verificar que el volumen sea el mismo.

---

### 8.3 Catch Trials: Especificación Completa

#### 8.3.1 Definición y Propósito

Un **catch trial** es una presentación donde NO se emite tono, pero se
registra si el sujeto presiona el botón de respuesta. Sirve para:
1. Detectar respondedores compulsivos (presionan rítmicamente).
2. Estimar la tasa de falsos positivos del sujeto.
3. Validar que el sujeto realmente está escuchando y no adivinando.

#### 8.3.2 Parámetros Recomendados

```
Porcentaje de catch trials:  1 de cada 6 presentaciones (~16%)
                             Mínimo: 10% (ASHA implícito)
                             Máximo: 20% (no alargar demasiado el test)

Distribución:                Aleatoria, pero nunca 2 catch trials consecutivos
                             Al menos 1 catch trial por frecuencia testeada
                             Insertar preferentemente en niveles CERCANOS al umbral
                             (donde la tentación de adivinar es mayor)

Ventana de detección:        Misma que para tonos reales:
                             [onset_programado + 100ms, onset_programado + tono_dur + 2500ms]
                             (el "onset_programado" es cuando HABRÍA sonado el tono)

Criterio de fallo:           Si falsos positivos > 2 de 6 catch trials (>33%):
                             → Pausar test
                             → Mostrar mensaje: "Parece que estás respondiendo
                               sin escuchar el tono. Presioná solo cuando
                               estés seguro de escucharlo."
                             → Reiniciar la frecuencia actual

Criterio de invalidación:    Si falsos positivos > 50% de catch trials DESPUÉS
                             de reinstucción:
                             → Invalidar sesión de ese sujeto
                             → Registrar en JSON como "invalidated: true"
                             → Solicitar otro sujeto normoyente
```

#### 8.3.3 Implementación de Catch Trials

```
Reglas de inserción:
1. Cada frecuencia tiene un pool de presentaciones planificadas.
2. Por cada 5 presentaciones reales, insertar 1 catch trial.
3. La posición del catch trial dentro del grupo de 6 es aleatoria.
4. El catch trial tiene la misma duración temporal que un tono real
   (1000ms de "silencio" + ITI normal después).
5. El sujeto NO sabe cuáles son catch trials.
6. La UI no muestra ninguna diferencia visual durante catch trials.
```

#### 8.3.4 Registro de Catch Trials en el JSON

```json
{
  "catch_trials": {
    "total": 8,
    "false_positives": 1,
    "false_positive_rate": 0.125,
    "valid": true,
    "details": [
      {"freq_hz": 1000, "position_in_sequence": 3, "response": false},
      {"freq_hz": 1000, "position_in_sequence": 7, "response": true},
      {"freq_hz": 2000, "position_in_sequence": 4, "response": false},
      ...
    ]
  }
}
```

---

### 8.4 Pseudocódigo del Algoritmo Completo (Máquina de Estados)

#### 8.4.1 Estados del Sistema

```
┌─────────────────────────────────────────────────────────────────────┐
│                    MÁQUINA DE ESTADOS                                │
│                                                                      │
│  IDLE → SETUP → FAMILIARIZATION → TESTING → THRESHOLD_FOUND →      │
│  NEXT_FREQ → (loop) → COMPLETE → SAVE                              │
│                                                                      │
│  Estados de error: INVALID_RESPONSE → REINSTRUCT → TESTING          │
│                    MAX_LEVEL_REACHED → SKIP_FREQ → NEXT_FREQ        │
│                    SESSION_INVALID → ABORT                           │
└─────────────────────────────────────────────────────────────────────┘
```

#### 8.4.2 Pseudocódigo Principal

```pseudocode
CONSTANTES:
  FREQS_ORDER = [1000, 2000, 4000, 8000, 500, 250]  // Hz
  STEP_UP = 5        // dB (ascenso tras no-respuesta)
  STEP_DOWN = 10     // dB (descenso tras respuesta)
  TONE_DURATION = 1000  // ms
  RAMP_MS = 30       // ms (coseno elevado)
  ITI_MIN = 1000     // ms (intervalo mínimo entre tonos)
  ITI_MAX = 3000     // ms (intervalo máximo)
  RESPONSE_WINDOW_START = 100   // ms post-onset
  RESPONSE_WINDOW_END = 2500    // ms post-offset
  INITIAL_LEVEL_DBFS = -30      // dBFS (familiarización)
  MIN_LEVEL_DBFS = -80          // dBFS (piso)
  MAX_LEVEL_DBFS = -5           // dBFS (techo seguro)
  THRESHOLD_CRITERION = 2       // respuestas de 3 ascensos
  CATCH_TRIAL_RATIO = 1/6      // 1 catch cada 6 presentaciones
  MAX_FALSE_POSITIVE_RATE = 0.33
  NUM_SUBJECTS = 3

ESTADO GLOBAL:
  current_subject: int (1..3)
  current_freq_index: int (0..5)
  current_level_dBFS: float
  ascending_count: int          // ascensos al nivel actual
  response_count_at_level: int  // respuestas positivas al nivel actual
  presentations_at_level: int   // presentaciones totales al nivel actual
  phase: enum {DESCENDING, ASCENDING}
  catch_trial_counter: int
  catch_false_positives: int
  catch_total: int
  thresholds: Map<freq, float>  // resultado por frecuencia
  all_sessions: List<Map<freq, float>>  // resultados de los 3 sujetos
```

#### 8.4.3 Algoritmo Hughson-Westlake por Frecuencia

```pseudocode
FUNCIÓN testFrequency(freq_hz):
  // --- FASE 1: FAMILIARIZACIÓN ---
  level = INITIAL_LEVEL_DBFS  // -30 dBFS
  REPETIR:
    presentar_tono(freq_hz, level, TONE_DURATION)
    respuesta = esperar_respuesta(RESPONSE_WINDOW_END)
    SI respuesta == TRUE:
      SALIR de familiarización  // El sujeto escucha, podemos empezar
    SINO:
      level = level + 10  // Subir 10 dB
      SI level > MAX_LEVEL_DBFS:
        RETORNAR ERROR("Auricular inadecuado o sujeto no normoyente")

  // --- FASE 2: DESCENSO INICIAL ---
  phase = DESCENDING
  MIENTRAS level > MIN_LEVEL_DBFS:
    presentar_tono(freq_hz, level, TONE_DURATION)
    respuesta = esperar_respuesta(RESPONSE_WINDOW_END)
    SI respuesta == TRUE:
      level = level - STEP_DOWN  // Bajar 10 dB
    SINO:
      phase = ASCENDING
      SALIR del descenso  // Primera no-respuesta → empezar ascenso

  // --- FASE 3: BÚSQUEDA DE UMBRAL (Hughson-Westlake) ---
  ascending_count = 0
  response_count_at_level = 0
  presentations_at_level = 0
  catch_counter_local = 0

  MIENTRAS ascending_count < 3:  // Máximo 3 series ascendentes
    // Decidir si es catch trial
    catch_counter_local++
    SI catch_counter_local % 6 == random(1..6):
      es_catch = TRUE
    SINO:
      es_catch = FALSE

    SI es_catch:
      // CATCH TRIAL: no emitir tono, solo esperar
      esperar(TONE_DURATION + random_iti())
      respuesta = esperar_respuesta(RESPONSE_WINDOW_END)
      catch_total++
      SI respuesta == TRUE:
        catch_false_positives++
        SI catch_false_positives / catch_total > MAX_FALSE_POSITIVE_RATE:
          RETORNAR ERROR("Tasa de falsos positivos excesiva")
      CONTINUAR  // No afecta la lógica de umbral

    // PRESENTACIÓN REAL
    esperar(random_iti())  // ITI aleatorio 1000-3000 ms
    presentar_tono(freq_hz, level, TONE_DURATION)
    respuesta = esperar_respuesta(RESPONSE_WINDOW_END)

    SI phase == ASCENDING:
      SI respuesta == TRUE:
        presentations_at_level++
        response_count_at_level++
        SI response_count_at_level >= THRESHOLD_CRITERION:
          // ¡UMBRAL ENCONTRADO!
          RETORNAR level  // Este es el threshold_dBFS para esta freq
        // Descender para nueva serie
        level = level - STEP_DOWN
        phase = DESCENDING
        ascending_count++
      SINO:
        // No respuesta → subir
        level = level + STEP_UP
        response_count_at_level = 0
        presentations_at_level = 0
        SI level > MAX_LEVEL_DBFS:
          RETORNAR MAX_LEVEL_DBFS  // Techo alcanzado

    SI phase == DESCENDING:
      SI respuesta == TRUE:
        level = level - STEP_DOWN  // Seguir bajando
      SINO:
        phase = ASCENDING
        level = level + STEP_UP  // Empezar ascenso
        response_count_at_level = 0
        presentations_at_level = 0

  // Si llegamos aquí sin 2/3: usar el último nivel con respuesta
  RETORNAR level
```

#### 8.4.4 Algoritmo de Sesión Completa (3 Sujetos)

```pseudocode
FUNCIÓN calibracionBiologicaCompleta():
  all_sessions = []

  PARA subject = 1 HASTA NUM_SUBJECTS:
    // Verificar prerrequisitos
    mostrar_cuestionario_normoyente()
    SI no_pasa_cuestionario():
      RETORNAR ERROR("Sujeto no cumple criterios")

    verificar_volumen_sistema_al_maximo()
    verificar_auricular_bt_conectado()

    session_thresholds = {}
    PARA freq EN FREQS_ORDER:
      threshold = testFrequency(freq)
      session_thresholds[freq] = threshold

    // Retest de 1000 Hz (verificación de consistencia)
    retest_1k = testFrequency(1000)
    SI abs(retest_1k - session_thresholds[1000]) > 10:
      // Inconsistencia: repetir toda la sesión de este sujeto
      ADVERTIR("Diferencia >10 dB en retest 1kHz, repetir sesión")
      subject = subject - 1  // Reintentar
      CONTINUAR

    all_sessions.append(session_thresholds)
    mostrar_resumen_sesion(subject, session_thresholds)

  // --- CÁLCULO FINAL ---
  calibration_table = {}
  PARA freq EN FREQS_ORDER:
    values = [s[freq] PARA s EN all_sessions]
    mean_threshold = promedio(values)
    spread = max(values) - min(values)

    SI spread > 10:  // Tolerancia: ±10 dB entre sujetos
      ADVERTIR("Dispersión >10 dB en {freq} Hz. Considerar repetir.")

    calibration_table[freq] = {
      "threshold_dBFS": mean_threshold,
      "spread_dB": spread,
      "individual_values": values,
      "max_HL_achievable": -5 - mean_threshold  // headroom hasta -5 dBFS
    }

  guardar_calibracion(calibration_table)
  RETORNAR calibration_table
```

#### 8.4.5 Diagrama de Estados (ASCII)

```
                    ┌──────────┐
                    │   IDLE   │
                    └────┬─────┘
                         │ usuario inicia calibración
                         ▼
                    ┌──────────┐
                    │  SETUP   │ verificar BT, volumen, cuestionario
                    └────┬─────┘
                         │ todo OK
                         ▼
               ┌─────────────────┐
               │ FAMILIARIZATION │ tono a -30 dBFS, confirmar que oye
               └────────┬────────┘
                        │ responde
                        ▼
               ┌─────────────────┐
               │   DESCENDING    │ bajar 10 dB hasta no-respuesta
               └────────┬────────┘
                        │ primera no-respuesta
                        ▼
               ┌─────────────────┐         ┌──────────────┐
               │   ASCENDING     │◄────────│ CATCH_TRIAL  │
               │ subir 5 dB      │────────▶│ (sin tono)   │
               └───┬────┬────────┘         └──────────────┘
                   │    │
          responde │    │ no responde
                   ▼    ▼
        ┌──────────┐  ┌──────────────┐
        │CHECK 2/3 │  │ SUBIR 5 dB   │
        └────┬─────┘  └──────┬───────┘
             │               │
     2/3 sí  │    no 2/3     │
             ▼               ▼
    ┌────────────────┐  ┌──────────────┐
    │THRESHOLD_FOUND │  │  DESCENDING  │ (nueva serie)
    └───────┬────────┘  └──────────────┘
            │
            ▼
    ┌────────────────┐
    │   NEXT_FREQ    │ siguiente frecuencia en orden
    └───────┬────────┘
            │ todas las freqs completadas
            ▼
    ┌────────────────┐
    │   COMPLETE     │ mostrar resumen, guardar sesión
    └───────┬────────┘
            │ 3 sujetos completados
            ▼
    ┌────────────────┐
    │     SAVE       │ promediar, generar JSON, persistir
    └────────────────┘
```

---

### 8.5 Formato Exacto del JSON de Calibración

```json
{
  "schema_version": "1.0.0",
  "calibration_type": "biological",
  "created_at": "2025-01-28T14:30:00Z",
  "expires_at": "2025-04-28T14:30:00Z",

  "device": {
    "phone_model": "Samsung SM-A546E",
    "phone_os": "Android 14",
    "bluetooth_device_name": "Audífono BT v2.1",
    "bluetooth_mac": "AA:BB:CC:DD:EE:FF",
    "bluetooth_codec": "SBC",
    "system_volume_level": 15,
    "system_volume_max": 15,
    "audio_stream": "STREAM_MUSIC"
  },

  "protocol": {
    "method": "hughson_westlake_modified",
    "step_up_dB": 5,
    "step_down_dB": 10,
    "tone_duration_ms": 1000,
    "ramp_ms": 30,
    "ramp_type": "raised_cosine",
    "iti_min_ms": 1000,
    "iti_max_ms": 3000,
    "threshold_criterion": "2_of_3_ascending",
    "sample_rate": 48000,
    "bit_depth": 16,
    "channels": 1
  },

  "subjects": [
    {
      "id": 1,
      "alias": "Sujeto A",
      "age_range": "18-35",
      "self_reported_normal_hearing": true,
      "questionnaire_passed": true,
      "tested_at": "2025-01-28T14:35:00Z",
      "thresholds_dBFS": {
        "250": -62.0,
        "500": -58.0,
        "1000": -52.0,
        "2000": -50.0,
        "4000": -48.0,
        "6000": -45.0,
        "8000": -42.0
      },
      "retest_1000_dBFS": -53.0,
      "retest_difference_dB": 1.0,
      "catch_trials": {
        "total": 7,
        "false_positives": 0,
        "rate": 0.0
      },
      "valid": true
    },
    {
      "id": 2,
      "alias": "Sujeto B",
      "age_range": "18-35",
      "self_reported_normal_hearing": true,
      "questionnaire_passed": true,
      "tested_at": "2025-01-28T15:10:00Z",
      "thresholds_dBFS": {
        "250": -58.0,
        "500": -55.0,
        "1000": -50.0,
        "2000": -48.0,
        "4000": -52.0,
        "6000": -43.0,
        "8000": -40.0
      },
      "retest_1000_dBFS": -50.0,
      "retest_difference_dB": 0.0,
      "catch_trials": {
        "total": 8,
        "false_positives": 1,
        "rate": 0.125
      },
      "valid": true
    },
    {
      "id": 3,
      "alias": "Sujeto C",
      "age_range": "18-35",
      "self_reported_normal_hearing": true,
      "questionnaire_passed": true,
      "tested_at": "2025-01-28T15:45:00Z",
      "thresholds_dBFS": {
        "250": -60.0,
        "500": -56.0,
        "1000": -48.0,
        "2000": -52.0,
        "4000": -50.0,
        "6000": -44.0,
        "8000": -38.0
      },
      "retest_1000_dBFS": -49.0,
      "retest_difference_dB": 1.0,
      "catch_trials": {
        "total": 7,
        "false_positives": 0,
        "rate": 0.0
      },
      "valid": true
    }
  ],

  "calibration_result": {
    "250": {
      "mean_threshold_dBFS": -60.0,
      "std_dB": 2.0,
      "spread_dB": 4.0,
      "max_HL_achievable": 55,
      "confidence": "high"
    },
    "500": {
      "mean_threshold_dBFS": -56.3,
      "std_dB": 1.5,
      "spread_dB": 3.0,
      "max_HL_achievable": 51,
      "confidence": "high"
    },
    "1000": {
      "mean_threshold_dBFS": -50.0,
      "std_dB": 2.0,
      "spread_dB": 4.0,
      "max_HL_achievable": 45,
      "confidence": "high"
    },
    "2000": {
      "mean_threshold_dBFS": -50.0,
      "std_dB": 2.0,
      "spread_dB": 4.0,
      "max_HL_achievable": 45,
      "confidence": "high"
    },
    "4000": {
      "mean_threshold_dBFS": -50.0,
      "std_dB": 2.0,
      "spread_dB": 4.0,
      "max_HL_achievable": 45,
      "confidence": "high"
    },
    "6000": {
      "mean_threshold_dBFS": -44.0,
      "std_dB": 1.0,
      "spread_dB": 2.0,
      "max_HL_achievable": 39,
      "confidence": "high"
    },
    "8000": {
      "mean_threshold_dBFS": -40.0,
      "std_dB": 2.0,
      "spread_dB": 4.0,
      "max_HL_achievable": 35,
      "confidence": "medium"
    }
  },

  "quality_metrics": {
    "overall_spread_mean_dB": 3.6,
    "overall_spread_max_dB": 4.0,
    "total_catch_trials": 22,
    "total_false_positives": 1,
    "overall_false_positive_rate": 0.045,
    "all_retests_within_5dB": true,
    "calibration_valid": true
  },

  "usage_instructions": {
    "to_emit_X_dB_HL_at_freq_F": "amplitude_dBFS = calibration_result[F].mean_threshold_dBFS + X",
    "max_safe_level": "never exceed -1 dBFS (hard clip protection)",
    "recalibrate_if": [
      "bluetooth_device changes (different MAC)",
      "more than 90 days since calibration",
      "system volume changed from calibration level",
      "phone OS major update"
    ]
  }
}
```

---

### 8.6 Integración con el ToneEmitter Existente

#### 8.6.1 Análisis del ToneEmitter Actual

El `ToneEmitter` en `lib/calibration_spectrum/tone_emitter.dart` tiene:

**Lo que ya sirve:**
- Genera WAV PCM 16-bit mono en memoria ✓
- Envolvente coseno elevado (raised cosine) de 25 ms ✓
- Reproduce vía `just_audio` + `StreamAudioSource` ✓
- Sample rate 48000 Hz ✓
- Método `playTone(freqHz, levelDbSpl, durationMs)` ✓
- Método `stop()` ✓
- Método `dispose()` ✓

**Lo que hay que modificar/extender:**

1. **El método `_levelToAmplitude` NO sirve para calibración biológica.**

   Actualmente:
   ```dart
   double _levelToAmplitude(double dbSpl) {
     final clamped = dbSpl.clamp(20.0, 90.0);
     final dbAboveBase = clamped - 90.0;
     return math.pow(10.0, dbAboveBase / 20.0).toDouble();
   }
   ```
   Esto mapea dB SPL a amplitud con una heurística (90 dB SPL = amplitud 1.0).
   Para calibración biológica necesitamos mapear **dBFS directamente**:
   ```dart
   double _dBFSToAmplitude(double dbFS) {
     // dbFS debe estar en rango [-80, -1]
     final clamped = dbFS.clamp(-80.0, -1.0);
     return math.pow(10.0, clamped / 20.0).toDouble();
   }
   // -6 dBFS → 0.501
   // -20 dBFS → 0.1
   // -40 dBFS → 0.01
   // -60 dBFS → 0.001
   // -80 dBFS → 0.0001
   ```

2. **Necesitamos un método `playToneAtDbFS` adicional:**
   ```dart
   Future<void> playToneAtDbFS({
     required double freqHz,
     required double levelDbFS,  // ← directo en dBFS, no SPL
     required int durationMs,
   }) async {
     if (_disposed) return;
     final wav = _generateToneWav(
       freqHz: freqHz,
       durationMs: durationMs,
       sampleRate: _cfg.sampleRate,
       envelopeMs: _cfg.envelopeMs,
       amplitudeNormalized: _dBFSToAmplitude(levelDbFS),
     );
     await _player.setVolume(1.0);
     await _player.setAudioSource(_WavAudioSource(wav));
     await _player.play();
   }
   ```

3. **El `envelopeMs` actual es 25 ms.** El plan pide 30 ms.
   Diferencia despreciable (5 ms). Se puede dejar en 25 ms o parametrizar.
   Recomendación: dejarlo en 25 ms (ya cumple IEC 60645-1 que pide ≥20 ms).

#### 8.6.2 Arquitectura de Integración

```
┌─────────────────────────────────────────────────────────────────────┐
│                    CALIBRACIÓN BIOLÓGICA                              │
│                                                                      │
│  ┌──────────────────┐     ┌──────────────────┐                      │
│  │ BiologicalCalib  │────▶│   ToneEmitter    │  (existente, extendido)│
│  │   Controller     │     │  .playToneAtDbFS │                      │
│  │                  │     │  .stop()         │                      │
│  │  - state machine │     │  .dispose()      │                      │
│  │  - HW algorithm  │     └──────────────────┘                      │
│  │  - catch trials  │                                                │
│  │  - response mgmt │     ┌──────────────────┐                      │
│  │                  │────▶│ CalibrationStore │  (Hive, existente)    │
│  │                  │     │  .saveProfile()  │                      │
│  │                  │     │  .loadProfile()  │                      │
│  └────────┬─────────┘     └──────────────────┘                      │
│           │                                                          │
│           │ notifica                                                  │
│           ▼                                                          │
│  ┌──────────────────┐                                                │
│  │ BiologicalCalib  │  (UI: pantalla Flutter)                        │
│  │   Screen         │                                                │
│  │  - botón "Oigo"  │                                                │
│  │  - progreso      │                                                │
│  │  - instrucciones │                                                │
│  └──────────────────┘                                                │
└─────────────────────────────────────────────────────────────────────┘
```

#### 8.6.3 Clases Nuevas Necesarias

```dart
// 1. Controlador de la máquina de estados
class BiologicalCalibrationController extends ChangeNotifier {
  final ToneEmitter _emitter;
  final CalibrationStore _store;

  CalibrationState state = CalibrationState.idle;
  int currentSubject = 0;
  int currentFreqIndex = 0;
  double currentLevelDbFS = -30.0;
  // ... (toda la lógica del pseudocódigo 8.4)

  Future<void> startCalibration() async { ... }
  void onUserResponse() { ... }  // botón "Lo escucho"
  void onUserNoResponse() { ... }  // timeout o botón "No escucho"
  Future<void> nextPresentation() async { ... }
}

// 2. Modelo de datos de resultado
class BiologicalCalibrationResult {
  final Map<int, FrequencyCalibration> frequencies;
  final List<SubjectSession> sessions;
  final QualityMetrics quality;
  final DeviceInfo device;
  final DateTime createdAt;

  Map<String, dynamic> toJson() => { ... };
  factory BiologicalCalibrationResult.fromJson(Map<String, dynamic>) => ...;
}

// 3. Enum de estados
enum CalibrationState {
  idle,
  setup,
  familiarization,
  descending,
  ascending,
  catchTrial,
  thresholdFound,
  nextFrequency,
  sessionComplete,
  allComplete,
  error,
}
```

#### 8.6.4 Uso Posterior de la Calibración (en Audiometría)

Una vez guardada la calibración, la audiometría del paciente la usa así:

```dart
class CalibratedToneEmitter {
  final ToneEmitter _emitter;
  final BiologicalCalibrationResult _calibration;

  /// Emite un tono a X dB HL usando la calibración biológica.
  /// Retorna false si el nivel excede el máximo alcanzable.
  Future<bool> playToneAtHL({
    required double freqHz,
    required double levelHL,
    required int durationMs,
  }) async {
    final freqKey = freqHz.round();
    final cal = _calibration.frequencies[freqKey];
    if (cal == null) return false;

    // Conversión central: dB HL → dBFS
    final targetDbFS = cal.meanThresholdDbFS + levelHL;

    // Verificar que no excede el máximo seguro
    if (targetDbFS > -1.0) {
      // No se puede emitir este nivel sin distorsión
      return false;
    }

    await _emitter.playToneAtDbFS(
      freqHz: freqHz,
      levelDbFS: targetDbFS,
      durationMs: durationMs,
    );
    return true;
  }

  /// Retorna el máximo dB HL alcanzable para una frecuencia.
  double maxHLForFreq(double freqHz) {
    final cal = _calibration.frequencies[freqHz.round()];
    if (cal == null) return 0;
    return -1.0 - cal.meanThresholdDbFS;  // headroom hasta -1 dBFS
  }
}
```

---

### 8.7 Resumen de Gaps y Acciones Requeridas

| # | Gap Identificado | Severidad | Acción |
|---|-----------------|-----------|--------|
| 1 | No hay método `playToneAtDbFS` en ToneEmitter | Alta | Agregar método que acepta dBFS directo |
| 2 | No se controla volumen del sistema | Alta | Fijar a máximo + verificar antes de usar |
| 3 | No hay catch trials en el plan | Media | Implementar 1/6 ratio con criterio 33% |
| 4 | No se registra codec BT | Media | Leer codec activo (API 28+) y guardar |
| 5 | No se calcula max_HL_achievable | Media | Calcular y mostrar al usuario |
| 6 | Ventana de respuesta no considera latencia BT | Baja | Extender a offset+2500ms (ya cubre) |
| 7 | No hay corrección por mediana poblacional | Baja | Implementar como ajuste opcional |
| 8 | Retest de 1000 Hz no está en el flujo | Media | Agregar al final de cada sesión |
| 9 | No hay expiración de calibración | Baja | 90 días default, configurable |
| 10 | No se valida que el auricular BT sea el mismo | Alta | Comparar MAC address antes de usar |

---

### 8.8 Precisión Esperada y Limitaciones

#### 8.8.1 Error Esperado del Sistema

Basado en Masalski et al. (2018, PMC5784183):

```
Con calibración biológica por modelo (múltiples sujetos):
  - Diferencia media vs PTA clínica: 2.6 dB (95% CI 2.0-3.1)
  - SD de la diferencia: 8.3 dB (95% CI 7.9-8.7)
  - 89% de diferencias ≤ 10 dB
  - Test-retest SD: 4.4 dB

Con nuestra implementación (3 sujetos, calibración individual):
  - Error esperado: SD ≈ 5-8 dB vs audiometría clínica
  - Peor caso (8 kHz): hasta 7 dB de bias sistemático
  - Mejor caso (1 kHz): <1 dB de bias
  - Repetibilidad: SD ≈ 4-5 dB (test-retest)
```

#### 8.8.2 Fuentes de Error

| Fuente | Magnitud | Mitigable |
|--------|----------|-----------|
| Variabilidad inter-sujeto | ±5 dB | Parcial (más sujetos) |
| Ruido ambiental | +3 a +10 dB | Sí (ambiente silencioso) |
| Colocación del auricular | ±3 dB | Parcial (instrucciones) |
| Respuesta en frecuencia del auricular | ±5 dB | No (es lo que calibramos) |
| Latencia BT (timing) | 0 dB (no afecta nivel) | N/A |
| Volumen del sistema cambiado | 0 a -∞ dB | Sí (verificar) |
| Codec BT diferente | ±2 dB | Parcial (registrar) |
| Fatiga del sujeto | +2 a +5 dB | Parcial (descansos) |
| Falsos positivos del sujeto | -5 a -10 dB | Sí (catch trials) |

#### 8.8.3 Comparación con Tolerancia ISO 389-7

```
Tolerancia ISO 389-7 para calibración de audiometros: ±3 dB (125-5000 Hz)
Tolerancia de nuestra calibración biológica: ±5-8 dB (estimado)

¿Cumple ISO 389-7? NO estrictamente.
¿Es aceptable para screening/wellness? SÍ.
¿Es aceptable para Texas DSHS (escolar)? SÍ (ellos aceptan ±10 dB).
¿Es aceptable para FDA OTC? PROBABLEMENTE (AirPods Pro usa método similar).
```

---

### 8.9 Referencias Adicionales Consultadas para esta Revisión

13. Masalski M, et al. (2018). Hearing Tests Based on Biologically Calibrated
    Mobile Devices: Comparison With Pure-Tone Audiometry. JMIR mHealth uHealth
    6(1):e10. PMC5784183. — Validación con 70 sujetos, SD 8.3 dB, 89% ≤10 dB.

14. SoundGuys (2021). Android's Bluetooth latency needs a serious overhaul.
    — Latencia BT promedio ~40ms en phones modernos (2021+), hasta 250ms en SBC legacy.

15. PCWorld (2024). How to eliminate Bluetooth audio lag.
    — Latencia BT hasta 150ms con codecs estándar, <40ms con aptX LL.

16. CEVA (2024). Lower Power and Latency with Bluetooth LE and LE Audio.
    — LC3plus: latencia 5-15 ms, estandarizado por ETSI.

17. Texas DSHS. Audiometer Monthly Biological Calibration Check (Form M-45).
    — Procedimiento oficial: 3 normoyentes, registrar nivel HL donde responden.

18. Engdahl B, et al. (2005). Screened and unscreened hearing threshold levels
    for the adult population. Int J Audiol 44(4):213-30.
    — Medianas poblacionales de umbral por frecuencia para corrección.

---

*Sección 8 generada el 2025-01-28. Basada en revisión del plan existente,*
*código fuente del ToneEmitter, sesión previa de calibración, y búsqueda*
*complementaria en Brave Search (PMC, SoundGuys, PCWorld, CEVA, Texas DSHS).*
*Todo contenido de fuentes externas fue parafraseado para cumplimiento de licencias.*
