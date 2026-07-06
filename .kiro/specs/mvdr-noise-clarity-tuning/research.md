# Research — MVDR Noise & Clarity Tuning

Documento de investigación científica que fundamenta el `requirements.md` de este spec. Cada sección mapea a un requisito (R1–R7), resume la evidencia consultada (parafraseada, ≤30 palabras consecutivas por fuente, con cita: título, fuente/URL, año) y cierra con las decisiones técnicas tomadas (algoritmo + parámetros iniciales).

> Autor: bioingeniero (rol del proyecto). Metodología: búsqueda Brave sobre papers revisados, universidades EE.UU./China, normas ANSI/IEC/ISO y monografías clínicas. Última revisión: ver historial git.
>
> Nota de licencias: todo el contenido de fuentes externas está parafraseado. No se reproducen más de 30 palabras consecutivas de ningún material original. Contenido reformulado para cumplir restricciones de licencia.

---

## R1 — Expansión hacia abajo para eliminar hiss en silencios

### Problema medido
En pausas de voz el nivel de entrada cae a ~40 dB pero la ganancia efectiva sigue en +37 dB, amplificando el ruido propio del micrófono. La expansión está desactivada (`expansionRatio=1.0`).

### Evidencia consultada

1. **"Applying Expansion in Hearing Aid Fittings: Subjective and Objective Findings" (Article 934)** — AudiologyOnline.
   URL: https://www.audiologyonline.com/articles/applying-expansion-in-hearing-aid-934
   Hallazgos parafraseados:
   - La expansión se configuró con punto de rodilla (kneepoint) de 50 dB SPL, tiempos de ataque/liberación de 512 ms y relación de 0.5:1.
   - La activación de la expansión se restringió a los primeros canales (baja frecuencia) para reducir la amplificación de ruido de bajo nivel y baja frecuencia (ambiente + instrumento) **mientras se preservaba la audibilidad de las claves de habla de alta frecuencia**.
   - Esta restricción a canales bajos mantuvo la mejora subjetiva sin degradar el reconocimiento de habla de bajo nivel. → **respaldo directo del límite ≤1000 Hz del requisito.**

2. **"Effects of Expansion on Consonant Recognition and Consonant Audibility" (PMC2784644)** — Brennan & Souza et al.
   URL: https://pmc.ncbi.nlm.nih.gov/articles/PMC2784644/
   Hallazgos parafraseados:
   - La expansión busca reducir la ganancia para ruido de bajo nivel.
   - Con un kneepoint alto de expansión (p. ej. 50 dB SPL), la audibilidad se reduce cuando el habla llega a 50 dB SPL; el efecto es más marcado con kneepoints altos.
   - Implicación de diseño: un kneepoint demasiado alto en banda ancha "come" consonantes suaves. Por eso conviene kneepoint moderado y **restringir la expansión a baja frecuencia**, donde vive el ruido del micrófono y poca energía consonántica.

3. **"Extended high-frequency bandwidth improves reception of speech in spatially separated masking speech" (PMC4549240)**.
   URL: https://pmc.ncbi.nlm.nih.gov/articles/PMC4549240/
   Hallazgo parafraseado: la expansión de bajo nivel se usa para evitar que el ruido del micrófono sea audible, práctica común en audífonos (Dillon 2012).

4. **"Musicians and Hearing Aid Design" (PMC4040858)**.
   URL: https://pmc.ncbi.nlm.nih.gov/articles/PMC4040858/
   Hallazgo parafraseado: optimizar los umbrales de expansión de bajo nivel junto con un micrófono de menor sensibilidad en baja frecuencia reduce el ruido interno percibido.

5. **"Pediatric hearing aid fittings and DSL v5.0" (The Hearing Journal, 2007)** y **DSL v5.0 (Article 959)**.
   URLs: https://journals.lww.com/thehearingjournal/fulltext/2007/06000/Pediatric_hearing_aid_fittings_and_DSL_v5_0.11.aspx · https://www.audiologyonline.com/articles/dsl-version-v5-0-description-959
   Hallazgo parafraseado: el algoritmo DSL m[i/o] pediátrico define **cuatro etapas: (1) expansión, (2) ganancia lineal, (3) compresión, (4) limitación de salida**. La expansión es, por diseño, la primera etapa del pipeline pediátrico estándar. → valida arquitectónicamente ubicar el Expansor antes/bajo el knee del WDRC.

### Decisiones técnicas R1

- **Algoritmo**: expansión hacia abajo (downward expansion) por debajo del knee, aplicada por banda solo en el sub-rango ≤1000 Hz (equivalente a "restringir a canales 1–2" de Article 934).
- **Kneepoint inicial**: 45 dB SPL (rango de trabajo 40–50 dB SPL). Moderado: por debajo del habla conversacional (~55–65 dB SPL) para no atenuar voz suave, pero por encima del piso de ruido del micrófono (~40 dB). Configurable.
- **Ratio inicial**: 0.5:1 (como Article 934). Configurable en el rango 0.3–1.0 (1.0 = desactivado).
- **Ataque**: el requisito exige ≤50 ms para no "cortar" el arranque de la voz. Nota: la literatura clínica usa liberaciones más lentas (p. ej. 512 ms) para evitar bombeo; recomiendo **ataque ≤50 ms (cumple AC6)** pero **release lento configurable (~300–500 ms)** para naturalidad. Anotar en design.md que el release largo es deseable aunque el requisito solo fije el ataque.
- **Corte superior**: 1000 Hz (AC2). Configurable.
- **Default**: deshabilitado (toggle off), ratio 1.0 → passthrough (AC5, AC7).

---

## R2 — Estimador de piso de ruido y SNR realista

### Problema medido
SceneAnalyzer reporta SNR pegado en 40 dB (tope) en 100% de muestras y ruido estimado −77…−97 dB (irreal; micrófono real ~−50 dB).

### Evidencia consultada

1. **Martin, R. (2001). "Noise Power Spectral Density Estimation Based on Optimal Smoothing and Minimum Statistics."** IEEE Trans. Speech and Audio Processing, 9(5), 504–512. doi:10.1109/89.928915.
   URLs: https://ieeexplore.ieee.org/document/928915/ · PDF: https://www.csd.uoc.gr/~hy578/2005/projects/ieee_sp_tsap_2001009_05jul_0504mart.pdf
   Hallazgos parafraseados:
   - Estima el PSD de ruido no estacionario a partir de voz ruidosa **rastreando los mínimos locales** del espectro suavizado, **sin necesitar un VAD explícito**.
   - Deriva un parámetro de suavizado óptimo minimizando el error cuadrático medio en cada paso temporal y compensa el sesgo de los mínimos.
   - El estimador es **apto para implementación en tiempo real**.

2. **Gerkmann, T. & Hendriks, R. C. (2012). "Unbiased MMSE-Based Noise Power Estimation With Low Complexity and Low Tracking Delay."** IEEE Trans. Audio, Speech and Language Processing, 20(4), 1383–1393.
   URLs: https://www.uni-oldenburg.de/fileadmin/user_upload/mediphysik/ag/speech/download/paper/gerkmann_unbiasedMMSE_TASL2012.pdf · https://www.inf.uni-hamburg.de/en/inst/ab/sp/publications/taslp12noisepsd.html
   Hallazgos parafraseados:
   - El enfoque de **probabilidad de presencia de voz (SPP)** actualiza la potencia de ruido cuando se señala ausencia de voz (interpretable como estimador basado en VAD).
   - Mantiene el rastreo rápido del método MMSE con compensación de sesgo, pero **sobreestima menos** la potencia de ruido y tiene **complejidad computacional aún menor**.
   - Menor retardo de rastreo → clave para tiempo real en bloques de Oboe.

### Rangos realistas de noise floor (fundamento del AC2 −60…−40 dB)
El requisito ancla el piso de ruido estimado en −60…−40 dB (dBFS relativos). Esto es coherente con:
- Ruido propio de MEMS PDM + ganancia de captura en teléfono medio (Moto G32): un micrófono real medido en el proyecto se sitúa ~−50 dBFS.
- Los −77…−97 dB reportados son físicamente imposibles para la cadena de captura real → indican un bug de escala/normalización (probablemente el estimador arranca en un mínimo artificial y nunca sube, o compara contra un referente mal escalado que satura el SNR en el tope de 40 dB).

### Decisiones técnicas R2

- **Algoritmo primario**: **MMSE-SPP (Gerkmann-Hendriks 2012)** como estimador de piso de ruido por bin/banda. Razón: menor complejidad, menor sobreestimación y menor retardo de rastreo que Minimum Statistics puro → mejor para el presupuesto de latencia de un bloque Oboe (AC5) y para un clasificador reactivo (R4).
- **Fallback / referencia**: **Minimum Statistics (Martin 2001)** como implementación alternativa detrás del mismo toggle si MMSE-SPP resulta inestable en las grabaciones reales. Ambos citados en el requisito, ambos real-time.
- **Escala**: trabajar en dBFS con un piso plausible acotado a [−60, −40] dBFS (AC2). Investigar y corregir la normalización que produce −77…−97 dB antes de cambiar de algoritmo (puede ser que el bug esté en la escala y no en el estimador).
- **SNR**: derivar SNR = nivel de señal (a posteriori) − piso de ruido estimado, acotado y **sin clamp fijo en 40 dB** salvo tope físico superior (AC3, AC4 → 0–40 dB con voz sobre ruido doméstico).
- **Convergencia en silencio**: durante silencio/ruido sin voz por un intervalo configurable, converger el piso hacia el nivel medido (AC6) — comportamiento natural del rastreo de mínimos / SPP con voz ausente.
- **Observabilidad**: exponer piso de ruido y SNR como valores observables (AC7) para R4 y diagnóstico.

---

## R3 — Reperfilado espectral del EQ hacia objetivo NAL-NL2/NL3

### Problema medido
EQ actual: +31 dB en 500–750 Hz y −16 dB en 8–10 kHz → sonido "boomy", pocas consonantes.

### Evidencia consultada

1. **Keidser et al. "The NAL-NL2 Prescription Procedure" (PMC4627149)**.
   URL: https://pmc.ncbi.nlm.nih.gov/articles/PMC4627149/
   Hallazgos parafraseados:
   - No se prescribe ganancia por debajo de 50 Hz ni por encima de 16 kHz; sin compresión para habla bajo 50 dB SPL.
   - Respecto a NAL-NL1, **NAL-NL2 prescribe relativamente más ganancia en bajas y altas frecuencias y menos en medias**.
   - Usa una **función de importancia** dentro del modelo de inteligibilidad para asegurar ganancia suficiente en las frecuencias más relevantes para entender el habla.
   - Implicación: el perfil "boomy" (exceso de medios-graves + agudos caídos) es **opuesto** al objetivo NAL-NL2.

2. **"Task-Dependent Effects of Signal Audibility... NAL-NL2 and DSL v5 in 9- to 17-Year-Olds" (PMC10236245)**.
   URL: https://pmc.ncbi.nlm.nih.gov/articles/PMC10236245/
   Hallazgo parafraseado: NAL-NL2 aplica ganancia frecuencia-específica con umbrales de compresión más altos para favorecer el confort de sonoridad; la ganancia se prescribe según un modelo de inteligibilidad basado en la tonalidad del idioma. → relevante para población pediátrica hispanohablante.

3. **"An Initial-Fit Comparison... NAL-NL2 and CAM2"** y comparativa NAL/DSL pediátrica (ETSU).
   URLs: https://www.researchgate.net/publication/235379300_... · https://dc.etsu.edu/context/etsu-works/article/2729/viewcontent/A_comparison_of_NAL_and_DSL_prescriptive_methods_for_paediatric_hearing_aid_fitting.pdf
   Hallazgos parafraseados:
   - En población pediátrica, NAL-NL2 fue más eficiente para el índice de inteligibilidad (SII); DSL m[i/o] fue más eficiente para la audibilidad de alta frecuencia.
   - Implicación: si el objetivo es maximizar inteligibilidad con confort, NAL-NL2 es defendible; si el objetivo pediátrico prioriza audibilidad de agudos, DSL v5 aporta más. → mantener ambos como objetivo configurable (el requisito ya cita NL2/NL3).

### Decisiones técnicas R3

- **Objetivo**: reperfilar las 12 bandas del EQ hacia NAL-NL2 (con NL3 como variante configurable), respetando la función de importancia: más audibilidad en 2–4 kHz, menos exceso en 500–750 Hz.
- **Balance espectral (AC2)**: ganancia relativa en 2–4 kHz > ganancia en 500–750 Hz para el mismo nivel de entrada. Reducir el pico de +31 dB en 500–750 Hz al objetivo NAL del paciente (AC3).
- **Agudos (AC4)**: reducir la atenuación de −16 dB en 8–10 kHz hacia el objetivo NAL (típicamente NAL-NL2 no atenúa esa región; DSL v5 daría aún más audibilidad de agudos). No sobre-amplificar 8–10 kHz sin datos audiométricos (riesgo de artefactos/feedback).
- **⚠️ Cambio_Prescriptivo**: este reperfilado altera la ganancia/perfil aplicado al paciente. Debe marcarse explícitamente en design.md y tasks.md (AC5) y **propagarse al clon del paciente solo tras confirmación** (AC7). Confirmar con el usuario antes de tocar C++.
- **Exposición**: perfil visible por la cadena C++ → NativeAudioBridge (Kotlin) → Dart (AC6).
- **Límite**: el perfil final NUNCA puede exceder MPO/UCL (ver R7); el reperfilado se define en ganancia relativa, la seguridad la garantiza la etapa MPO.

---

## R4 — Convergencia del clasificador de escena

### Problema medido
SceneAnalyzer da "unknown" en 100% de muestras porque sus umbrales dependen del SNR roto (R2).

### Evidencia consultada
- La dependencia es directa: el clasificador consume SNR/piso de ruido del Estimador_Ruido. Con SNR saturado en 40 dB constante, ninguna regla de umbral discrimina QUIET/SPEECH/NOISE → "unknown" por defecto.
- Base metodológica del estimador que alimenta al clasificador: Martin 2001 y Gerkmann-Hendriks 2012 (ver R2). El rastreo de mínimos / SPP produce un SNR variable con el contenido, condición necesaria para que los umbrales del clasificador operen.
- **"Challenges and Recent Developments in Hearing Aids: Part I" (PMC4111442)**.
  URL: https://pmc.ncbi.nlm.nih.gov/articles/PMC4111442/
  Hallazgo parafraseado: los sistemas de audífono usan estimaciones de nivel/SNR y modulación por frecuencia/tiempo para decidir cuándo aplicar reducción de ruido; la clasificación de entorno depende de métricas fiables de SNR.

### Decisiones técnicas R4

- **Hipótesis primaria**: el clasificador converge al arreglar R2. Primero corregir el estimador, luego re-medir.
- **Umbrales configurables (AC5)**: exponer umbral de voz (SNR) y umbral de nivel de ruido. Valores iniciales sugeridos, a calibrar con grabaciones reales:
  - QUIET: SNR bajo **y** nivel de señal bajo (< ~45 dBFS de nivel de entrada).
  - SPEECH: SNR por encima del umbral de voz (p. ej. > ~6–10 dB) con modulación de voz presente.
  - NOISE: nivel por encima del umbral de ruido con SNR bajo (sin modulación de voz).
- **Meta de calidad (AC6)**: ≤20% de muestras UNKNOWN en sesión doméstica representativa. Verificable re-procesando las grabaciones del Moto G32.
- **Exposición**: etiqueta de escena por la cadena C++ → Kotlin → Dart (AC7).
- **Nota**: no sobre-ingeniar; si tras corregir R2 el clasificador converge, solo ajustar umbrales. Un clasificador DNN queda fuera de alcance de este spec.

---

## R5 — Afinación del supresor de reverberación tardía

### Problema medido
El "eco" reportado proviene en parte de reverberación tardía y en parte del perfil "boomy" (R3). El Supresor_Reverb ya existe en `mvdr_beamformer.h`.

### Evidencia consultada

1. **Lebart, Boucher & Denbigh — dereverberación monocanal por sustracción espectral (modelo estadístico de Polack)**.
   Referencias vía: https://www.sciencedirect.com/science/article/abs/pii/S0003682X16301396 · https://www.researchgate.net/publication/240618200_Single-channel_speech_dereverberation_based_on_spectral_subtraction
   Hallazgos parafraseados:
   - Lebart estimó la potencia espectral de la reverberación tardía a partir del **modelo estadístico de Polack**, que **depende esencialmente del tiempo de reverberación (RT60)** y cambia lentamente en el tiempo.
   - La reverberación tardía se atenúa por **sustracción espectral** (misma familia que la reducción de ruido), sin resolver la respuesta impulsional completa de la sala → **baja complejidad, sin álgebra matricial pesada (no requiere LAPACK)**.

2. **Habets — extensión y suavizado del método** (PhD Thesis; multicanal).
   Referencias vía: https://www.sciencedirect.com/science/article/abs/pii/S0003682X20306307
   Hallazgo parafraseado: Habets extendió el enfoque monocanal de Lebart y usó el modelo estadístico de RIR que depende del RT60, actualizable de forma lenta.

3. **"Single Channel Reverberation Suppression..." (Télécom Paris, HAL)**.
   URL: https://telecom-paris.hal.science/hal-02286852v1/document
   Hallazgo parafraseado: la reverberación tardía estimada se suaviza con un **filtro pasa-bajos de un polo con constante de tiempo ≈32 ms** para compensar discontinuidades del procesamiento por bloques; se usa suelo espectral (spectral floor) para limitar artefactos.

### Decisiones técnicas R5

- **Enfoque**: mantener el supresor existente basado en sustracción espectral de reverberación tardía (familia Lebart/Habets), sin introducir dependencias de álgebra lineal (sin LAPACK). Coherente con la restricción de complejidad del proyecto.
- **Parámetros configurables (AC2)**: intensidad de supresión (over-subtraction factor), suelo espectral (spectral floor, para preservar voz directa) y, si el modelo lo usa, RT60 asumido / constante de suavizado (~32 ms como punto de partida de la literatura).
- **Preservar voz directa (AC4)**: usar spectral floor conservador y over-subtraction moderado; el modelo de Polack ataca la cola tardía, no las reflexiones tempranas ni el directo.
- **Toggle (AC3)**: deshabilitado → comportamiento actual intacto.
- **Alcance**: mejora menor / afinación de parámetros, no reescritura del algoritmo.

---

## R6 — Compatibilidad con modos existentes y cadena nativa

### Fundamento
No es un requisito de algoritmo sino de arquitectura/regresión. Base del proyecto (steering `pre-push-verification.md`):
- Toda mejora debe ser toggleable e independiente; con todos los toggles off, salida equivalente a la previa (AC3).
- Cada parámetro nuevo debe propagarse por la cadena C++ → NativeAudioBridge (Kotlin) → Dart (AC4) con default seguro si Dart no envía valor (AC5).
- Debe compilar y correr en Moto G32 vía Oboe FullDuplexStream (AC6).

### Decisiones técnicas R6
- Cada mejora (Expansor R1, estimador R2, perfil EQ R3, umbrales R4, supresor R5) detrás de su propio toggle con default = comportamiento previo.
- Verificar `CMakeLists.txt` ante cualquier `.cpp`/`.h` nuevo o modificado.
- Trazar los 3 eslabones (C++ → Kotlin → Dart) por cada parámetro antes de dar por cerrada una tarea.
- Recordar: el paciente **clona** el C++ del técnico; no tiene C++ propio. Todo parámetro nuevo llega al paciente al clonar.

---

## R7 — Seguridad clínica (MPO/UCL)

### Evidencia consultada

1. **ANSI/ASA S3.22-2014 (R2020) — Specification of Hearing Aid Characteristics**.
   URL: https://webstore.ansi.org/preview-pages/ASA/preview_ANSI+ASA+S3.22-2014+(R2020).pdf · resumen de tests: https://docs.audioscan.com/library/misc/ANSI-S3_22-Tests-Summary.pdf
   Hallazgos parafraseados:
   - OSPL90 (nivel de salida con entrada de 90 dB SPL) es el parámetro normativo de salida máxima.
   - Para pruebas normativas se pone la ganancia en full-on, el control de salida al máximo y se **deshabilitan las funciones adaptativas** (reducción de ruido, supresión de feedback). → nuestras mejoras (adaptativas) no deben alterar el techo MPO.

2. **"Regulatory Recommendations for OTC Hearing Aids" (AAA/ADA consensus)**.
   URL: https://www.audiology.org/wp-content/uploads/2021/06/ConsensusPaper_OTC_HA.pdf
   Hallazgo parafraseado: se recomienda que el OSPL90, según ANSI S3.22-2014, no supere 110 dB SPL. (Referencia OTC adulto; en pediatría el límite se individualiza por UCL/RECD — más conservador.)

3. **DSL v5.0 pediátrico (Article 959; The Hearing Journal 2007; PMC4111494)**.
   URLs: https://www.audiologyonline.com/articles/dsl-version-v5-0-description-959 · https://journals.lww.com/thehearingjournal/fulltext/2007/06000/Pediatric_hearing_aid_fittings_and_DSL_v5_0.11.aspx
   Hallazgos parafraseados:
   - El algoritmo DSL m[i/o] incluye **limitación de salida como etapa final** (etapa 4), tras expansión, ganancia lineal y compresión.
   - DSL v5 pediátrico reduce la ganancia respecto al adulto (p. ej. ~7 dB menos para 50 dB HL a 60 dB SPL de entrada) y usa objetivos individualizados → los límites de salida pediátricos deben ser conservadores y personalizados por el técnico.

### Decisiones técnicas R7
- **MPO como última etapa** de ganancia antes de la salida (AC1) — coherente con DSL m[i/o] etapa 4. Ninguna mejora de este spec se coloca después del limitador.
- **No exceder UCL/MPO configurado** (AC2, AC3): el limitador recorta cualquier ganancia que supere el MPO, independientemente de expansión/NR/reverb.
- **Invariante**: el comportamiento del limitador MPO es independiente del estado de los toggles de mejora (AC4). Verificar con test de regresión.
- **Propagación al paciente**: los valores MPO/UCL del técnico se propagan idénticos al clon del paciente (AC5).
- **Regla del proyecto**: OSPL90 pediátrico individualizado por UCL/RECD (no un tope genérico de 110 dB SPL adulto). La validación clínica final exige revisión humana experta y verificación en oído real (REM); ningún cambio de software sustituye eso.

---

## Resumen de decisiones (tabla)

| Req | Algoritmo elegido | Parámetros iniciales | Default |
|-----|-------------------|----------------------|---------|
| R1  | Downward expansion en baja frecuencia | knee 45 dB SPL, ratio 0.5:1, ataque ≤50 ms, release ~300–500 ms, corte 1000 Hz | OFF (ratio 1.0) |
| R2  | MMSE-SPP (Gerkmann-Hendriks 2012); fallback Minimum Statistics (Martin 2001) | piso acotado [−60,−40] dBFS, SNR 0–40 dB sin clamp fijo | corregir escala primero |
| R3  | Reperfilado EQ 12 bandas → NAL-NL2 (NL3 variante) | 2–4 kHz > 500–750 Hz; recortar pico +31 dB; subir 8–10 kHz | ⚠️ Cambio_Prescriptivo, requiere confirmación |
| R4  | Umbrales sobre SNR/nivel corregidos | umbral voz ~6–10 dB SNR; UNKNOWN ≤20% | converge al arreglar R2 |
| R5  | Sustracción espectral de reverb tardía (Lebart/Habets, sin LAPACK) | over-subtraction moderado, spectral floor, suavizado ~32 ms | OFF |
| R6  | Toggles independientes + cadena C++→Kotlin→Dart | defaults = comportamiento previo | todos OFF |
| R7  | Limitador MPO última etapa (DSL m[i/o] etapa 4) | UCL/OSPL90 individualizado pediátrico | invariante |

## Riesgos y notas abiertas
- **R2**: antes de cambiar de algoritmo, confirmar si los −77…−97 dB son bug de normalización/escala. Puede que el estimador actual sea razonable y el bug esté en la conversión a dBFS o en el clamp de SNR a 40 dB.
- **R3**: es el único **Cambio_Prescriptivo**. No tocar C++ sin confirmación explícita del usuario; impacta directamente al paciente que clona.
- **Validación clínica**: los valores prescriptivos y de MPO/UCL requieren verificación en oído real (REM) y revisión audiológica humana. Este documento fundamenta el diseño, no reemplaza el ajuste clínico.
- **Cumplimiento de licencias**: todas las fuentes están parafraseadas (≤30 palabras consecutivas). Contenido reformulado para cumplir restricciones de licencia.
