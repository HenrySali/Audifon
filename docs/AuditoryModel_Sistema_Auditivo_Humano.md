# Sistema Auditivo Humano — Fundamento para el Módulo AuditoryModel

**Proyecto:** PSK Hearing Aid / Amplificador  
**Autor:** Bioingeniero (asistente IA)  
**Fecha:** 2025  
**Propósito:** Documentar el funcionamiento completo del sistema auditivo humano, desde la señal acústica hasta la percepción cortical del habla, como base teórica para implementar el módulo `AuditoryModel` en C++.

---

## 1. FÍSICA DEL SONIDO Y OÍDO EXTERNO

### 1.1 Pabellón auricular (pinna) y HRTF

**Concepto fisiológico:**  
La pinna filtra espectralmente el sonido de forma dependiente de la dirección. Las reflexiones en la hélice y la concha generan picos y muescas (notches) espectrales que el cerebro usa como clave monoaural de elevación. El conjunto de estas transformaciones se denomina Head-Related Transfer Function (HRTF).

**Parámetros numéricos:**
- Muesca espectral de pinna: varía entre 6–10 kHz según elevación
- Primer notch: ~6.5 kHz a -30°, ~8.1 kHz a 0°, ~8.8 kHz a +30° elevación
- Pinna aporta ~3 dB de ganancia alrededor de 4 kHz
- Concha aporta ~5–10 dB de ganancia en 4–5 kHz

**Fuentes:**
- [PMC4432547 - Real ear unaided gain](https://pmc.ncbi.nlm.nih.gov/articles/PMC4432547/) — resonancia promedio 2700 Hz, 16.8 dB
- [HRTF - Wikipedia](https://en.wikipedia.org/wiki/Head-related_transfer_function)
- [Chapter 6 HRTF](https://www.lesonbinaural.fr/EDIT/DOCS/45612.PDF) — frecuencias de notch por elevación
- [Ento Key - Anatomy and Physiology of Hearing](https://entokey.com/anatomy-and-physiology-of-hearing/) — concha ~5 kHz
- [Shaw 1974, The External Ear - Springer](https://link.springer.com/chapter/10.1007/978-3-642-65829-7_14)

**Implicación para AuditoryModel:**  
El modelo debe incluir un filtro HRTF simplificado (o al menos la ganancia del oído externo ~15–20 dB en 2–4 kHz) para calibrar correctamente la presión sonora que llega al tímpano desde el micrófono del audífono, que NO está en la posición natural del canal.

### 1.2 Resonancia del canal auditivo externo (EAC)

**Concepto fisiológico:**  
El canal auditivo funciona como un tubo resonante cuarto-de-onda, cerrado en el tímpano y abierto en la entrada. Su primer modo de resonancia genera la Real-Ear Unaided Response (REUR).

**Parámetros numéricos:**
- Frecuencia de resonancia fundamental: **~2700 Hz** (adultos)
- Ganancia pico: **15–20 dB** (compilación de estudios: media 16.8 dB)
- Longitud efectiva del canal: ~25–30 mm
- En infantes: resonancia **~8 kHz** (canal más corto), desciende a valores adultos a los ~2.5 años
- Q del resonador: moderado (amortiguado por paredes blandas)

**Fuentes:**
- [PMC4432547](https://pmc.ncbi.nlm.nih.gov/articles/PMC4432547/) — "average resonance frequency of 2700 Hz with amplitude of 16.8 dB"
- [Hearing Review - Standing Waves](https://hearingreview.com/hearing-products/hearing-aids/the-acoustics-of-hearing-aids-standing-waves-damping-and-flared-tubes-2) — primer modo a 2700 Hz
- [Ento Key](https://entokey.com/anatomy-and-physiology-of-hearing/) — infantes 8 kHz, adultos 2.5 años
- [Chasin - Etiology of REUR](https://marshallchasinassociates.ca/pdf/acoustics/The%20etiology%20of%20the%20REUR._.%20maybe.pdf)

**Implicación para AuditoryModel:**  
Crítico para la corrección RECD (Real-Ear-to-Coupler Difference) en fitting pediátrico DSL v5. El audífono bloquea parcialmente esta resonancia natural; el fitting debe compensar la pérdida de ganancia natural con inserción gain adicional en la zona 2–4 kHz.

### 1.3 Difracción de la cabeza

**Concepto fisiológico:**  
La cabeza actúa como obstáculo acústico. Para frecuencias con longitud de onda menor que el diámetro de la cabeza (~2 kHz en adelante), se produce shadow effect en el oído contralateral y bright spot en el ipsilateral. Esto genera la ILD (Interaural Level Difference) usada para localización.

**Parámetros numéricos:**
- Diámetro efectivo de cabeza humana: ~17–18 cm
- ILD máxima: **~20 dB** a frecuencias >3 kHz
- ILD despreciable por debajo de ~500 Hz
- La difracción agrega ~6 dB de ganancia ipsilateral alrededor de 2–4 kHz

**Fuentes:**
- [Superior olivary complex - Wikipedia](https://en.wikipedia.org/wiki/Superior_olivary_complex)
- [NCBI Bookshelf - The External Ear](https://www.ncbi.nlm.nih.gov/books/NBK10908/) — "boosts sound pressure 30-100 fold for frequencies around 3 kHz"

**Implicación para AuditoryModel:**  
Para fitting binaural, la ILD es fundamental. El audífono BTE no preserva la shadow acústica natural; en el modelo se debe considerar que la señal captada por el mic no tiene las claves de difracción naturales.

---

## 2. OÍDO MEDIO (Mecánica de transmisión)

### 2.1 Membrana timpánica (tímpano)

**Concepto fisiológico:**  
Membrana cónica delgada (~0.1 mm) que convierte variaciones de presión acústica en vibración mecánica. Su área vibrante efectiva es menor que su área total.

**Parámetros numéricos:**
- Área total: ~85 mm²
- Área vibrante efectiva: ~55 mm² (≈2/3 del total)
- Frecuencia natural: ~800–1600 Hz (fuertemente amortiguada)
- Impedancia acústica: dominada por rigidez a baja frecuencia, por masa a alta frecuencia
- Linealidad: se mantiene lineal hasta ~124 dB SPL

**Fuentes:**
- [Nature - Scientific Reports - Middle ear transfer functions](https://www.nature.com/articles/s41598-022-21245-w) — linealidad hasta 124 dB SPL
- [NCBI Bookshelf - The Middle Ear](https://www.ncbi.nlm.nih.gov/books/NBK11076/)
- [Frontiers - Mammalian middle ear mechanics](https://www.frontiersin.org/journals/bioengineering-and-biotechnology/articles/10.3389/fbioe.2022.983510/full)

### 2.2 Cadena osicular: martillo, yunque, estribo

**Concepto fisiológico:**  
Los tres huesecillos transmiten vibración del tímpano a la ventana oval. Funcionan como transformador de impedancia mediante dos mecanismos: relación de áreas (hidráulica) y palanca osicular.

**Parámetros numéricos:**
- Ratio de áreas (TM efectiva / platina del estribo): **~17:1 a 20:1**
- Platina del estribo (oval window): ~3.2 mm²
- Ratio de palanca (brazo largo / brazo corto): **~1.3:1**
- Producto total (transformer ratio): **17 × 1.3 ≈ 22:1**
- Ganancia en presión: **~25–27 dB** (teórica ideal)
- Ganancia real medida: **~20–30 dB** (variable con frecuencia)
- Máxima eficiencia del oído medio: **1–2 kHz**
- Sin oído medio funcional (rotura osicular): pérdida conductiva de **50–60 dB**

**Fuentes:**
- [NCBI/StatPearls - Ossiculoplasty](https://www.ncbi.nlm.nih.gov/books/NBK563162/) — "area 17-20 times greater"
- [Frontiers - Mammalian middle ear mechanics](https://www.frontiersin.org/journals/bioengineering-and-biotechnology/articles/10.3389/fbioe.2022.983510/full)
- [PMC3805178 - Middle-ear velocity transfer function](https://pmc.ncbi.nlm.nih.gov/articles/PMC3805178/)
- [PMC4718164 - Structure and function of mammalian middle ear](https://pmc.ncbi.nlm.nih.gov/articles/PMC4718164/)

**Implicación para AuditoryModel:**  
La función de transferencia del oído medio es un filtro pasa-banda con pico en 1–2 kHz. Se debe modelar como un filtro de segundo o tercer orden para simular correctamente la presión coclear a partir de la presión en el tímpano.

### 2.3 Reflejo estapedial (acoustic reflex)

**Concepto fisiológico:**  
Contracción involuntaria del músculo estapedio ante sonidos fuertes. Aumenta la rigidez de la cadena osicular, atenuando principalmente frecuencias bajas.

**Parámetros numéricos:**
- Umbral de activación: **70–90 dB SL** (sobre umbral auditivo)
- Latencia: **~25–150 ms** (demasiado lento para transientes impulsivos)
- Atenuación máxima: **~10–15 dB** (principalmente <1–2 kHz)
- Algunos estudios reportan hasta 20–30 dB de atenuación a baja frecuencia
- Fatiga: el reflejo decae con exposición sostenida (adaptación)
- Vía neural: ipsi y contralateral (CN → SOC → nervio facial → estapedio)

**Fuentes:**
- [Acoustic reflex - Wikipedia](https://en.wikipedia.org/wiki/Acoustic_reflex)
- [ScienceDirect - Acoustic Reflex overview](https://www.sciencedirect.com/topics/neuroscience/acoustic-reflex) — "70 to 90 dB above threshold"
- [Grokipedia - Acoustic reflex](https://grokipedia.com/page/Acoustic_reflex) — "attenuating low-frequency sounds by up to 20–30 dB"
- [ProSoundWeb](https://www.prosoundweb.com/keeping-it-real-ii-in-ear-monitoring-and-the-acoustic-reflex-threshold/) — latencia 150 ms

**Implicación para AuditoryModel:**  
El MPO limiter del audífono cumple una función análoga al reflejo estapedial (protección ante sonidos fuertes) pero con latencia mucho menor (~1 ms). El modelo puede incluir un bloque de "protección" con constante de tiempo lenta que simule la adaptación del reflejo.

### 2.4 Función de transferencia global del oído medio

**Curva frecuencial:**
- <200 Hz: atenuación por rigidez (pendiente +6 dB/oct)
- 200–2000 Hz: banda pasante (máxima transmisión ~1 kHz)
- >2000 Hz: atenuación por masa (pendiente -6 a -12 dB/oct)
- Pico de transferencia: ~0.7–2 kHz según especie y metodología
- Impedancia mismatch sin oído medio: >50 dB a 100 Hz (Killion & Dallos, 1979)

**Fuentes:**
- [PMC4491943 - Mass and Stiffness Impact](https://www.ncbi.nlm.nih.gov/pmc/articles/PMC4491943/) — "maximum transfer function in 1-2 kHz"
- [Frontiers - Mammalian middle ear mechanics](https://www.frontiersin.org/journals/bioengineering-and-biotechnology/articles/10.3389/fbioe.2022.983510/full) — "impedance mismatch larger than 50 dB at 100 Hz"

---

## 3. OÍDO INTERNO — CÓCLEA

### 3.1 Membrana basilar y onda viajera (von Békésy)

**Concepto fisiológico:**  
El sonido genera una onda de presión diferencial que viaja desde la base (ventana oval) hacia el ápex de la cóclea. La membrana basilar (BM) tiene un gradiente de rigidez: rígida y estrecha en la base, flexible y ancha en el ápex. Esto crea un mapa tonotópico donde cada frecuencia tiene un lugar de máxima vibración.

**Parámetros numéricos:**
- Longitud coclear humana: ~35 mm (desenrollada)
- Mapa tonotópico: base ~20 kHz, ápex ~20 Hz
- Ancho BM en base: ~0.1 mm; en ápex: ~0.5 mm
- Rigidez: decrece ~100× de base a ápex
- Onda viajera se propaga base→ápex; velocidad decrece hasta detenerse en la zona de resonancia
- Resolución frecuencial pasiva (sin OHC): ancha, Q~2-4

**Fuentes:**
- [J Int Adv Otol 2017](https://www.advancedotology.org/index.php/pub/article/download/924/922) — amplificación y agudización coclear
- [Von Békésy and cochlear mechanics - PMC](https://pmc.ncbi.nlm.nih.gov/articles/PMC3572775/) — "cochlear amplification works by changing resistance, not stiffness"
- [Springer - Travelling waves and tonotopicity](https://link.springer.com/article/10.1007/s00359-018-1279-8) — Békésy descubrió ondas base-a-ápex en cadáveres
- [ScienceDirect - Basilar Membrane overview](https://www.sciencedirect.com/topics/immunology-and-microbiology/basilar-membrane)

**Implicación para AuditoryModel:**  
El filterbank del DSP (ya sea gammatone, QMF o cascade) simula la descomposición frecuencial de la BM. La resolución del filterbank debe ser ~1/3 oct o ERB-spacing para aproximar la selectividad coclear normal.

### 3.2 Células ciliadas externas (OHC) — Amplificador coclear

**Concepto fisiológico:**  
Las OHC son motores electromecánicos activos. La proteína **prestin** (SLC26A5) en su membrana lateral genera electromotilidad: la célula se contrae y expande en fase con el estímulo, inyectando energía mecánica a la BM. Esto amplifica las señales débiles de forma selectiva en frecuencia y las comprime de forma no-lineal.

**Parámetros numéricos:**
- Ganancia activa del amplificador coclear: **40–60 dB** (a nivel umbral)
- Sin OHC funcionales → pérdida auditiva de 40–60 dB (demostrado con knockout de prestin)
- Selectividad frecuencial activa: Q~10-20 (vs Q~2-4 pasiva)
- Operación ciclo-a-ciclo hasta altas frecuencias (debatido >10 kHz)
- Las OHC son ~12,000 en total (3 filas)
- Electromotilidad mediada por cambios conformacionales de prestin

**Fuentes:**
- [Nature - Prestin is required for electromotility](https://www.nature.com/articles/nature01059) — "40–60 dB loss of cochlear sensitivity in vivo"
- [J Neurosci - Frequency response of OHC motility](https://www.jneurosci.org/content/38/24/5495) — "provides 40–60 dB gain"
- [PMC2630119 - Cochlear amplification, OHC and prestin](https://pmc.ncbi.nlm.nih.gov/articles/PMC2630119/)
- [PNAS - OHC electromotility enhances organ of Corti](https://www.pnas.org/doi/10.1073/pnas.2025206118)

### 3.3 Compresión coclear no-lineal

**Concepto fisiológico:**  
La curva input/output de la BM es altamente compresiva en la zona activa. A bajos niveles la respuesta es lineal (ganancia ~1 dB/dB), luego se comprime fuertemente, y vuelve a ser lineal a niveles muy altos.

**Parámetros numéricos:**
- Pendiente compresiva (compression ratio) normal: **0.2–0.3 dB/dB** (equivale a ratio 3:1 – 5:1)
- Valores extremos medidos: hasta **0.1 dB/dB** (10:1) por encima de CF
- Knee point (inicio compresión): ~20–30 dB SPL
- Rango compresivo: ~30–90 dB SPL
- Por debajo del knee: lineal (~1 dB/dB)
- Por encima de ~90 dB: vuelve a linealidad (OHC saturada)
- Con daño OHC: la curva se lineariza → pérdida de sensibilidad + reclutamiento

**Fuentes:**
- [ScienceDirect - Cochlear compression in SNHL](https://www.sciencedirect.com/science/article/abs/pii/S0378595505001024) — "slopes of 0.2–0.3 dB/dB"
- [PMC3248057 - Behavioral estimates of BM compression](https://pmc.ncbi.nlm.nih.gov/articles/PMC3248057/) — "compression ratios as high as 5:1"
- [Frontiers - Spatial buildup of nonlinear compression](https://www.frontiersin.org/journals/cellular-neuroscience/articles/10.3389/fncel.2024.1450115/full) — "as low as 0.1 dB/dB above best frequency"
- [PMC3697738 - Low-frequency hearing](https://pmc.ncbi.nlm.nih.gov/articles/PMC3697738/) — "slope of 0.2 dB/dB"
- [Hearing Review - Concave curvilinear WDRC](https://hearingreview.com/inside-hearing/research/concave-curvilinear-wdrc-optimizing-the-shape-of-compression) — ratio 4:1 en niveles medios

**Implicación para AuditoryModel:**  
La WDRC (Wide Dynamic Range Compression) del audífono replica la función compresiva perdida de las OHC. Los ratios de compresión del audífono (típicamente 1.5:1 a 3:1 según prescripción) intentan restaurar parcialmente la compresión coclear normal de 0.2–0.3 dB/dB. El modelo debe incluir una I/O function no-lineal por banda que simule la BM sana y la dañada.

### 3.4 Células ciliadas internas (IHC) — Transducción mecánico-eléctrica

**Concepto fisiológico:**  
Las IHC (~3,500 en total, 1 fila) son los verdaderos receptores sensoriales. La deflexión de sus estereocilios abre canales MET (mechanoelectrical transduction) permeables a K⁺ y Ca²⁺, generando un potencial de receptor que despolariza la célula. La despolarización abre canales de Ca²⁺ voltage-dependientes en la base, causando liberación de glutamato en sinapsis ribbon hacia las fibras del nervio auditivo.

**Parámetros numéricos:**
- Canales MET: conductancia ~100 pS por canal
- Potencial de receptor: bipolar (despolarización con deflexión hacia estereocilia más alta, hiperpolarización en sentido contrario)
- ~10–30 sinapsis ribbon por IHC
- Neurotransmisor: glutamato
- Receptores postsinápticos: AMPA
- Cada fibra del nervio auditivo contacta UNA sola IHC
- La IHC no tiene electromotilidad (no es motor activo)

**Fuentes:**
- [PMC6886459 - Hair Cell Afferent Synapses](https://pmc.ncbi.nlm.nih.gov/articles/PMC6886459/)
- [ScienceDirect - Cochlear hair cells: sound-sensing machines](https://www.sciencedirect.com/science/article/pii/S0014579315007309)
- [Nature Communications - IHC stereocilia embedded in tectorial membrane](https://www.nature.com/articles/s41467-021-22870-1)
- [NCBI Bookshelf - Hair Cells and Mechanoelectrical Transduction](https://www.ncbi.nlm.nih.gov/books/NBK10867/)
- [J Neurosci - Mechanoelectric Transduction of Adult IHC](https://www.jneurosci.org/content/27/5/1006)

**Implicación para AuditoryModel:**  
La transducción IHC introduce una rectificación de media onda (responde más a una dirección) y un filtrado pasa-bajo (~3–4 kHz) que limita el phase-locking temporal. El modelo debe incluir una etapa de half-wave rectification + lowpass filter después del filterbank.

### 3.5 Daño OHC → Pérdida neurosensorial y reclutamiento

**Concepto fisiológico:**  
Cuando las OHC se dañan (ruido, ototóxicos, edad), se pierde: (1) amplificación activa → umbral sube 40–60 dB; (2) compresión no-lineal → la BM responde linealmente; (3) selectividad frecuencial → filtros más anchos. El resultado perceptual es loudness recruitment: sensación normal de volumen a altos niveles pero sordera a bajos niveles, con rango dinámico comprimido.

**Parámetros numéricos:**
- Pérdida OHC pura: hasta 50–60 dB de pérdida conductiva coclear
- Rango dinámico residual: puede reducirse de ~120 dB a ~40–60 dB
- UCL (Uncomfortable Loudness Level): permanece similar (~100 dB SPL)
- Selectividad frecuencial reducida: filtros auditivos 2–4× más anchos
- Resolución temporal reducida en tareas supraumbrales
- Pérdida IHC adicional: peor discriminación del habla, "dead regions"

**Fuentes:**
- [ScienceDirect - Inner Ear Hearing Loss](https://www.sciencedirect.com/topics/pharmacology-toxicology-and-pharmaceutical-science/inner-ear-hearing-loss) — "loudness recruitment arises from OHC damage"
- [PMC9006468 - Recruitment vs Hyperacusis](https://pmc.ncbi.nlm.nih.gov/articles/PMC9006468/)
- [ASHA Leader - Beyond Audibility](https://leader.pubs.asha.org/doi/10.1044/leader.FTR5.14142009.14) — "reduced sensitivity, loss of nonlinear gain, impaired frequency selectivity, temporal processing deficits"
- [Frontiers - OHC and AN function in speech](https://www.frontiersin.org/journals/neuroscience/articles/10.3389/fnins.2017.00157/full) — low-SR fibers damaged

**Implicación para AuditoryModel:**  
El modelo debe poder configurarse con "grado de daño OHC" por banda para simular audiogramas reales. Parametrizar: (1) pérdida de ganancia, (2) linearización de compresión, (3) ensanchamiento de filtros. Esto permite predecir qué procesamiento necesita cada paciente.

---

## 4. NERVIO AUDITIVO (Codificación neural)

### 4.1 Phase-locking (codificación temporal)

**Concepto fisiológico:**  
Las fibras del nervio auditivo disparan preferentemente durante la fase positiva de la onda acústica (despolarizante). Este "enganche de fase" (phase-locking) codifica la frecuencia del estímulo en el patrón temporal de spikes, con precisión de microsegundos.

**Parámetros numéricos:**
- Phase-locking significativo: hasta **~4–5 kHz** (en mamíferos)
- Degrada progresivamente arriba de ~1 kHz
- Fibras de alta SR: detectan phase-locking ~30 dB debajo del umbral de tasa
- El filtro pasa-bajo de la IHC (τ ≈ 0.5–1 ms) limita el phase-locking
- La frecuencia de corte del lowpass varía con SR (contribución sináptica)

**Fuentes:**
- [NCBI Bookshelf - Tuning and Timing in Auditory Nerve](https://www.ncbi.nlm.nih.gov/books/NBK11105/) — "fire only during positive phases of low-frequency sounds"
- [PMC7294794 - Phase Locking: Role of Lowpass Filtering](https://pmc.ncbi.nlm.nih.gov/articles/PMC7294794/) — cutoff varía con SR
- [PMC6529866 - Phase Locking reveals stereotyped distortions](https://pmc.ncbi.nlm.nih.gov/articles/PMC6529866/)
- [J Neurosci - Spike time and spike rate](https://www.jneurosci.org/content/38/25/5727) — "ANF firing is phase locked to sinusoidal waveform"

**Implicación para AuditoryModel:**  
El temporal fine structure (TFS) es crucial para percepción de pitch y localización binaural. El procesamiento del audífono NO debe destruir la estructura temporal fina de la señal por debajo de 4 kHz. El modelo temporal incluye: envelope + fine structure.

### 4.2 Rate coding (codificación por tasa de disparo)

**Concepto fisiológico:**  
A frecuencias más altas donde el phase-locking es débil, la intensidad se codifica por la tasa media de disparos. A mayor nivel sonoro, mayor tasa de disparo, hasta saturación.

**Parámetros numéricos:**
- Tasa espontánea: 0–180 spikes/s (distribución sesgada a tasas bajas)
- Tasa máxima saturada: ~200–300 spikes/s
- Rango dinámico por fibra individual: **~20–40 dB**
- Rango dinámico poblacional: **~120 dB** (gracias a fibras con distintos umbrales)

**Fuentes:**
- [Springer - Basic response properties of AN fibers](https://link.springer.com/article/10.1007/s00441-015-2177-9) — review completo
- [J Neurosci - Peristimulus Time Responses](https://www.jneurosci.org/content/42/11/2253) — "population achieves intensity coding over large dynamic range"
- [PMC2774902 - Dynamic Range Adaptation in AN](https://pmc.ncbi.nlm.nih.gov/articles/PMC2774902/)

### 4.3 Categorías de fibras por tasa espontánea (SR)

**Concepto fisiológico:**  
Las fibras del nervio auditivo se clasifican en tres grupos según su actividad espontánea, que correlaciona inversamente con su umbral de activación:

| Categoría | SR (spikes/s) | Umbral | Rango dinámico | Función principal |
|-----------|--------------|--------|----------------|-------------------|
| Alta SR | >18 | Bajo (mejor) | Estrecho (~20 dB) | Detección en silencio |
| Media SR | 0.5–18 | Medio | Intermedio | Transición |
| Baja SR | <0.5 | Alto (peor) | Amplio (~40 dB) | Codificación en ruido |

**Parámetros numéricos:**
- ~60% de fibras son alta-SR
- ~25% son media-SR
- ~15% son baja-SR
- Las fibras de baja SR son más vulnerables al daño por ruido (synaptopathy / hidden hearing loss)
- La pérdida selectiva de fibras baja-SR explica dificultad en ruido con audiograma normal

**Fuentes:**
- [ScienceDirect - Sound Coding in AN](https://www.sciencedirect.com/science/article/abs/pii/S0306452218306730) — "high-SR fibers driven by low-freq tones can phase lock ~30 dB below rate threshold"
- [Frontiers - OHC and AN Function](https://www.frontiersin.org/journals/neuroscience/articles/10.3389/fnins.2017.00157/full) — "low spontaneous rate fibers selectively damaged"
- [J Neurosci - Maturation of SR](https://www.jneurosci.org/content/36/41/10584) — "SRs inversely correlated with threshold"

**Implicación para AuditoryModel:**  
La pérdida de fibras baja-SR (hidden hearing loss / synaptopathy) NO aparece en el audiograma pero sí en la queja "escucho pero no entiendo en ruido". El modelo debe poder simular poblaciones con SR diversa y modelar el efecto de su pérdida selectiva en el SII en ruido.

### 4.4 Adaptación temporal

**Concepto fisiológico:**  
La respuesta del nervio auditivo muestra una tasa elevada al onset del estímulo (onset response) que decae rápidamente a una tasa sostenida (adapted rate). Hay componentes de adaptación rápida (~1–10 ms), corta (~10–100 ms) y larga (segundos).

**Parámetros numéricos:**
- Onset peak: 3–5× la tasa sostenida
- Constante de adaptación rápida: ~1–5 ms
- Constante de adaptación corta: ~30–60 ms
- Adaptación larga: ~10 s (power-law dynamics)

**Fuentes:**
- [J Neurosci - Onset Coding degraded without synaptic ribbons](https://www.jneurosci.org/content/30/22/7587)
- [Springer - Basic response properties](https://link.springer.com/article/10.1007/s00441-015-2177-9)

**Implicación para AuditoryModel:**  
La adaptación es clave para la detección de onset de consonantes y transiciones formánticas. El attack/release del WDRC debe respetar estas constantes de tiempo neuronales (~5 ms attack, ~50 ms release mínimo) para no destruir la codificación de onset.

---

## 5. VÍA AUDITIVA CENTRAL

### 5.1 Núcleo coclear (CN)

**Concepto fisiológico:**  
Primera estación sináptica central. TODAS las fibras del nervio auditivo hacen sinapsis aquí. Se divide en ventral (VCN) y dorsal (DCN) con tipos celulares especializados:

- **Bushy cells** (VCN anterior): preservan timing preciso, respuesta "primary-like". Alimentan procesamiento binaural en SOC.
- **Stellate cells** (VCN): codifican espectro, filtros con inhibición lateral. Respuesta "chopper" regular.
- **Octopus cells** (VCN posterior): detectan coincidencia temporal, onset broadband.
- **DCN (fusiform cells)**: integración espectral compleja, supresión de ecos/reflexiones.

**Fuentes:**
- [Wikipedia - Cochlear nucleus](https://en.wikipedia.org/wiki/Cochlear_nucleus) — tipos celulares
- [ScienceDirect - Cochlear Nucleus overview](https://www.sciencedirect.com/topics/medicine-and-dentistry/cochlear-nucleus)
- [ScienceDirect - Ventral Cochlear Nucleus](https://www.sciencedirect.com/topics/immunology-and-microbiology/ventral-cochlear-nucleus) — "transforming temporal and spectral information"

**Implicación para AuditoryModel:**  
El procesamiento paralelo del CN (timing en bushy, espectro en stellate, onset en octopus) sugiere que el audífono debe preservar TANTO la estructura temporal fina (TFS) como la envolvente espectral y los transientes de onset.

### 5.2 Complejo olivar superior (SOC) — Localización binaural

**Concepto fisiológico:**  
Primera estación con convergencia binaural. Computa:
- **MSO (Medial Superior Olive):** detecta ITD (Interaural Time Difference) — localización en azimut para frecuencias bajas (<1.5 kHz)
- **LSO (Lateral Superior Olive):** detecta ILD (Interaural Level Difference) — localización para frecuencias altas (>1.5 kHz)

**Parámetros numéricos:**
- Resolución ITD humana: ~10–20 μs
- ITD máxima (cabeza humana): ~700 μs
- ILD máxima: ~20 dB (frecuencias >3 kHz)
- Crossover ITD↔ILD: ~1500 Hz

**Fuentes:**
- [Wikipedia - Superior olivary complex](https://en.wikipedia.org/wiki/Superior_olivary_complex)
- [J Neurosci - ITD processing in mammalian MSO](https://www.jneurosci.org/content/28/27/6914) — "microsecond differences in time-of-arrival"
- [Frontiers - Extraction of ITD using spiking MSO model](https://www.frontiersin.org/journals/neuroscience/articles/10.3389/fnins.2018.00140/full) — "MSO extracts fine structure ITDs, LSO extracts ILDs"

**Implicación para AuditoryModel:**  
En fitting binaural, el audífono debe preservar ITD e ILD naturales. El procesamiento bilateral sincronizado (wireless binaural link) es esencial. Latencia asimétrica entre oídos destruye la percepción ITD. El modelo binaural requiere sincronización <50 μs.

### 5.3 Colículo inferior (IC)

**Concepto fisiológico:**  
Centro obligatorio de convergencia: TODAS las vías auditivas ascendentes hacen sinapsis aquí. Integra información espectral, temporal y espacial. Genera mapas de espacio auditivo. Participa en orientación y reflejos.

**Fuentes:**
- [ScienceDirect - Inferior Colliculus](https://www.sciencedirect.com/topics/neuroscience/inferior-colliculus) — "receives virtually all ascending auditory information"
- [NCBI Bookshelf - Neuroanatomy, Auditory Pathway](https://www.ncbi.nlm.nih.gov/books/NBK532311/)

### 5.4 Cuerpo geniculado medial (MGB) — Tálamo auditivo

**Concepto fisiológico:**  
Relay talámico hacia corteza. Filtrado atencional (gating). División en ventral (tonotópica), dorsal (multisensorial) y medial (emocional/arousal).

**Fuentes:**
- [StatPearls - Neuroanatomy Auditory Pathway](https://www.ncbi.nlm.nih.gov/books/NBK532311/) — "auditory cortex from telencephalon, MGB from diencephalon"
- [LibreTexts - Auditory System Central Processing](https://med.libretexts.org/Sandboxes/admin/Introduction_to_Neuroscience_(Hedges)/05:_Sensory_Systems/5.05:_Auditory_System-_Central_Processing)

### 5.5 Corteza auditiva primaria (A1)

**Concepto fisiológico:**  
Ubicada en el giro de Heschl (lóbulo temporal superior). Organización tonotópica en espejo: frecuencias bajas lateralmente, altas medialmente. Columnas iso-frecuencia. Mapas de modulación, onset, duración. Plasticidad dependiente de experiencia.

**Parámetros numéricos:**
- Localización: giro temporal transverso (Heschl's gyrus)
- Mapa tonotópico: 200 Hz – 6400 Hz mapeados
- Organización en espejo (campos A1 y R con gradientes opuestos)
- Latencia cortical: ~20–50 ms post-estímulo

**Fuentes:**
- [PMC3412441 - Mapping Tonotopic Organization](https://pmc.ncbi.nlm.nih.gov/articles/PMC3412441/) — "two mirror-symmetric tonotopic maps"
- [PMC2830355 - Tonotopic organization of human auditory cortex](https://pmc.ncbi.nlm.nih.gov/articles/PMC2830355/) — "200, 400, 800, 1600, 3200, 6400 Hz"
- [Wikipedia - Tonotopy](https://en.wikipedia.org/wiki/Tonotopy) — "low frequencies laterally, high medially around Heschl's gyrus"

**Implicación para AuditoryModel:**  
La corteza espera recibir representaciones tonotópicas ordenadas. Distorsiones severas en la coclea/nervio (dead regions, phase-locking degradado) no pueden ser "reparadas" centralmente. El audífono debe entregar señal con estructura espectro-temporal correcta, que la corteza pueda interpretar.

---

## 6. PERCEPCIÓN DEL HABLA

### 6.1 Extracción de formantes y modulaciones temporales

**Concepto fisiológico:**  
El habla se caracteriza por modulaciones lentas de amplitud (4–16 Hz, correspondientes a la tasa silábica) superpuestas a una estructura fina rápida (pitch, formantes). El cerebro opera en dos escalas temporales paralelas:
- **Envelope (4–16 Hz):** clave para segmentación silábica e inteligibilidad
- **Temporal fine structure (30–500 Hz):** clave para pitch, voicing, formant transitions

**Parámetros numéricos:**
- Modulaciones temporales <25 Hz: contienen ~90% de la potencia del espectro de modulación del habla
- Modulaciones <16 Hz: suficientes para inteligibilidad razonable (Drullman et al.)
- Tasa silábica del habla: ~4–5 Hz
- Modulaciones 30–50 Hz: información fonémica (transiciones formánticas, VOT)
- Corteza auditiva: oscilaciones theta (~4–8 Hz) y gamma (~30–50 Hz) en sincronía con el habla

**Fuentes:**
- [PLoS Comput Biol - Modulation Transfer Function for Speech](https://journals.plos.org/ploscompbiol/article?id=10.1371/journal.pcbi.1000302) — "90% of power below 25 Hz temporal modulations"
- [PMC2639724 - MTF for Speech Intelligibility](https://www.ncbi.nlm.nih.gov/pmc/articles/PMC2639724/)
- [Frontiers - Cortical Oscillations in Auditory Perception](https://www.frontiersin.org/journals/psychology/articles/10.3389/fpsyg.2012.00170/full) — "modulation frequencies below approximately 16 Hz suffice for intelligible speech"
- [PMC4461038 - Cortical oscillations and speech](https://pmc.ncbi.nlm.nih.gov/articles/PMC4461038/) — "30–50 Hz range associated with phonemic scale"
- [Nature - Importance of TFS for time-compressed speech](https://www.nature.com/articles/s41598-023-29755-x)

**Implicación para AuditoryModel:**  
El DSP del audífono debe preservar:
1. Modulaciones de envelope 4–16 Hz (NO las debe suavizar con release times excesivos)
2. Temporal fine structure por debajo de 4 kHz (phase-locking information)
3. Las constantes de tiempo WDRC (attack/release) deben permitir seguir modulaciones de ~16 Hz → release ≤ 60 ms para no aplanar.

### 6.2 Speech Intelligibility Index (SII)

**Concepto fisiológico:**  
Medida estandarizada (ANSI S3.5-1997) que predice la proporción de habla que es audible dada la configuración de audiograma, ruido de fondo y señal de habla. Valores de 0 (nada audible) a 1 (todo audible).

**Parámetros numéricos:**
- 21 bandas críticas (método 1) o bandas de 1/3 de octava
- Cada banda tiene un peso de importancia (importance function)
- Bandas más importantes para inteligibilidad: **1–4 kHz**
- SII > 0.7: inteligibilidad excelente en silencio
- SII 0.4–0.7: inteligibilidad moderada
- SII < 0.3: inteligibilidad pobre
- Meta de fitting DSL/NAL: maximizar SII aided

**Fuentes:**
- [ANSI Blog - Speech Intelligibility Index](https://blog.ansi.org/ansi/speech-intelligibility-index/)
- [Audiology Online - 20Q: Using Aided SII](https://www.audiologyonline.com/articles/20q-aided-speech-intelligibility-index-23707)
- [ASA S3-79 Working Group SII](https://sii.to/index.html) — implementación Python disponible

**Implicación para AuditoryModel:**  
El SII es la métrica clave para evaluar la prescripción NAL/DSL. El módulo AuditoryModel debe poder calcular SII predicho a partir del audiograma y la ganancia prescrita, tanto unaided como aided, para validar el fitting.

### 6.3 Por qué un audífono NO es un oído sano

**Concepto fisiológico:**  
La amplificación restaura audibilidad pero NO restaura:
1. **Selectividad frecuencial** — filtros auditivos ensanchados no se corrigen con amplificación
2. **Compresión coclear** — WDRC la aproxima pero no reproduce exactamente la I/O biológica
3. **Resolución temporal** — fibras dañadas/ausentes pierden phase-locking y onset coding
4. **Dead regions** — amplificar dentro de una zona muerta empeora (off-frequency listening, distorsión)
5. **Estructura temporal fina** — la compresión y el procesamiento digital introducen distorsión y latencia
6. **Synaptopathy** — pérdida de fibras baja-SR invisible en audiograma pero devastadora en ruido

**Fuentes:**
- [Trends in Neurosciences - Why Do Hearing Aids Fail](https://pubmed.ncbi.nlm.nih.gov/29449017/) — "effects of hearing loss on neural activity cannot be corrected by amplification alone"
- [PMC7612903 - Compression algorithms impair selectivity](https://pmc.ncbi.nlm.nih.gov/articles/PMC7612903/) — "hearing aid compression distorts spectral and temporal features"
- [PMC4168936 - Dead Regions: diagnosis and implications](https://pmc.ncbi.nlm.nih.gov/articles/PMC4168936/) — "no benefit from amplification inside dead region"
- [Frontiers - Why Hearing Aids Fail and How to Solve This](https://www.frontiersin.org/journals/network-physiology/articles/10.3389/fnetp.2022.868470/full)
- [PMC9449765 - Long-term effects of HA use](https://pmc.ncbi.nlm.nih.gov/articles/PMC9449765/) — "unable to correct hearing loss due to suprathreshold distortion"

**Implicación para AuditoryModel:**  
El modelo debe representar explícitamente qué se puede y qué NO se puede compensar con procesamiento. Esto guía decisiones de diseño:
- Si hay dead region → no amplificar esa banda, usar frequency compression/lowering
- Si hay selectividad reducida → no usar bandas muy estrechas (smearing)
- Si hay pérdida de TFS → priorizar envelope clarity (denoising agresivo)

---

## 7. IMPLICACIONES PARA EL DISEÑO DEL AUDÍFONO

### 7.1 Qué debe compensar un audífono según tipo de pérdida

| Tipo de pérdida | Mecanismo dañado | Compensación del audífono |
|----------------|------------------|---------------------------|
| Conductiva | Oído medio | Amplificación lineal proporcional |
| Sensorial (OHC) | Amplificador coclear | WDRC multibanda + ganancia por banda |
| Neural (IHC/AN) | Transducción/sinapsis | Poco compensable, preservar TFS, denoise |
| Mixta | Combinación | WDRC + amplificación + preservación temporal |
| Hidden (synaptopathy) | Fibras baja-SR | Mejorar SNR (beamforming, denoise) |

### 7.2 Por qué la amplificación simple NO basta

La razón fundamental: **el oído no es un micrófono + amplificador, es un analizador no-lineal activo**. El audífono debe:

1. **Restaurar audibilidad** (ganancia frequency-specific) ✓ factible
2. **Restaurar compresión** (WDRC con ratios y knees correctos) ✓ parcialmente factible
3. **Preservar estructura temporal** (latencia mínima, no destruir onset) ⚠️ difícil
4. **Mejorar SNR** (beamforming, denoise) ✓ factible con tradeoffs
5. **Restaurar selectividad frecuencial** ✗ NO factible con señal procesamiento
6. **Restaurar phase-locking degradado** ✗ NO factible
7. **Compensar dead regions** → frequency lowering (parcial)

### 7.3 Modelos auditivos computacionales para diseño de audífonos

#### CARFAC (Lyon, 2017)
- **Arquitectura:** Cascade of Asymmetric Resonators with Fast-Acting Compression
- **Principio:** Filtros en cascada (no paralelos) que simulan la propagación base→ápex
- **Ventajas:** Captura coupling entre canales, eficiente computacionalmente, open-source (Google)
- **Aplicación:** Evaluar cómo suena la señal procesada "a través de una cóclea"
- **Repositorio:** https://github.com/google/carfac
- **Referencia:** Lyon R.F. (2017) "Human and Machine Hearing", Cambridge University Press

**Fuentes:**
- [PMC5902704 - FPGA Implementation of CAR-FAC](https://pmc.ncbi.nlm.nih.gov/articles/PMC5902704/)
- [Cambridge University Press - The CARFAC Digital Cochlear Model](https://www.cambridge.org/core/books/abs/human-and-machine-hearing/carfac-digital-cochlear-model/C8341FBDA54160D3E9B8694A856DD3FF)
- [arXiv - CARFAC V2 in MATLAB, NumPy, JAX](https://arxiv.org/pdf/2404.17490)

#### Zilany et al. (2014) — Auditory Nerve Model
- **Arquitectura:** Modelo fenomenológico completo: oído medio → cóclea no-lineal → IHC → sinapsis → AN
- **Principio:** Simula fibras individuales del nervio auditivo con parámetros de SR, CF, daño OHC/IHC
- **Ventajas:** Validado extensamente contra datos fisiológicos de gato; parámetros para pérdida auditiva (cohc, cihc)
- **Aplicación:** Predecir neurogramas con y sin pérdida, evaluar procesamiento del audífono
- **Código:** MATLAB/C disponible en McMaster University

**Fuentes:**
- [Zilany et al. 2014 - Updated parameters](https://pubmed.ncbi.nlm.nih.gov/24437768/)
- [Carney Lab - Auditory Models Publications](https://www.urmc.rochester.edu/labs/carney/publications-code/auditory-models)
- [Computational Audiology - Tuning CARFAC v3 with SR classes](https://computationalaudiology.com/tuning-a-version-of-carfac-cochlear-model-that-includes-different-spontaneous-rate-classes-of-auditory-nerve-fibers/)

#### openMHA (Open Master Hearing Aid)
- **Arquitectura:** Framework de plugins de procesamiento en tiempo real
- **Principio:** Plataforma modular para investigación de algoritmos de audífonos
- **Ventajas:** Open-source, validada en investigación, multi-plataforma, bajo latencia
- **Aplicación:** Referencia para implementar y evaluar algoritmos WDRC, beamforming, noise reduction
- **Repositorio:** https://github.com/HoerTech-gGmbH/openMHA

**Fuentes:**
- [PMC9022875 - openMHA platform](https://pmc.ncbi.nlm.nih.gov/articles/PMC9022875/)
- [openmha.org](https://www.openmha.org/)

---

## 8. RESUMEN DE PARÁMETROS CLAVE PARA EL MÓDULO AuditoryModel

| Etapa | Parámetro | Valor típico | Relevancia DSP |
|-------|-----------|-------------|----------------|
| Canal auditivo | Resonancia | 2700 Hz, +17 dB | RECD, ganancia de inserción |
| Concha | Resonancia | 4500–5000 Hz, +8 dB | Compensación BTE |
| Oído medio | Ganancia pico | 25–27 dB @ 1 kHz | Calibración input |
| Oído medio | Banda pasante | 0.5–4 kHz | Filtro pre-coclear |
| Reflejo estapedial | Umbral | 80 dB SL | MPO limiter análogo |
| OHC | Ganancia activa | 40–60 dB | Pérdida = ganancia necesaria |
| BM | Compression slope | 0.2–0.3 dB/dB | WDRC target ratio |
| BM | Knee point | 20–30 dB SPL | WDRC threshold |
| IHC | Lowpass cutoff | ~3–4 kHz | Límite phase-locking |
| AN | Phase-lock limit | ~4–5 kHz | TFS preservation band |
| AN | Rango dinámico (fibra) | 20–40 dB | Input headroom por banda |
| AN | Onset adaptation | τ = 1–5 ms | Attack time mínimo |
| AN | Short adaptation | τ = 30–60 ms | Release time mínimo |
| SOC | ITD resolución | 10–20 μs | Sincronización binaural |
| Speech | Modulaciones clave | 4–16 Hz | Release WDRC ≤ 60 ms |
| Speech | Bandas importantes | 1–4 kHz | Prioridad de ganancia |
| SII | Meta aided | >0.65 | Objetivo de fitting |

---

## 9. ARQUITECTURA PROPUESTA PARA AuditoryModel (C++)

Basado en la fisiología documentada, el módulo debería tener estos bloques:

```
Input (dB SPL calibrado)
    │
    ├─ [1] Filtro oído externo (RECD/REUR correction)
    │
    ├─ [2] Filtro oído medio (pasa-banda 0.5–4 kHz, 2nd order)
    │
    ├─ [3] Filterbank coclear (gammatone/ERB-spaced, 16–32 bandas)
    │       │
    │       ├─ [4] Compresión no-lineal por banda (I/O function)
    │       │       - Normal: slope 0.2–0.3 dB/dB, knee 25 dB
    │       │       - Dañado: slope → 1.0, threshold elevado
    │       │
    │       ├─ [5] Half-wave rectification (IHC transduction)
    │       │
    │       └─ [6] Lowpass filter (~4 kHz, IHC membrane)
    │
    ├─ [7] Adaptación temporal (onset emphasis, τ_rapid=3ms, τ_short=50ms)
    │
    ├─ [8] Excitation pattern (summing across bands)
    │
    └─ [9] SII calculator (audibility per band × importance weight)
```

**Parámetros configurables por paciente:**
- `ohc_damage[band]`: 0.0 (sano) – 1.0 (destruido) → controla ganancia y compresión
- `ihc_damage[band]`: 0.0 – 1.0 → controla resolución temporal
- `audiogram_hl[freq]`: pérdida en dB HL por frecuencia
- `dead_region[band]`: booleano → inhabilita amplificación en esa banda

---

## 10. REFERENCIAS BIBLIOGRÁFICAS PRINCIPALES

1. Moore, B.C.J. (2012). *An Introduction to the Psychology of Hearing*, 6th ed. Brill.
2. Dillon, H. (2012). *Hearing Aids*, 2nd ed. Boomerang Press.
3. Lyon, R.F. (2017). *Human and Machine Hearing*. Cambridge University Press.
4. Zilany, M.S.A., Bruce, I.C., & Carney, L.H. (2014). Updated parameters for auditory periphery model. *JASA* 135(1), 283–286.
5. Dallos, P. et al. (2008). Prestin-based outer hair cell motility is necessary for mammalian cochlear amplification. *Neuron* 58(3), 333–339.
6. Oxenham, A.J. & Bacon, S.P. (2003). Cochlear compression: perceptual measures and implications. *JASA* 114(3), 1403-1410.
7. ANSI S3.5-1997 (R2020). Methods for Calculation of the Speech Intelligibility Index.
8. Herzke, T. et al. (2022). Open Master Hearing Aid (openMHA). *SoftwareX* 17, 100953.

---

*Documento generado por Bioingeniero IA. Contenido parafraseado de fuentes académicas (≤30 palabras consecutivas por fuente). URLs proporcionadas para verificación.*
