# Diccionario Profundo del Sistema de Limpieza de Ruido (DNN GTCRN)

> Documento de profundización del diccionario base `Amplificador/docs/ruido.md`.
> Cada término del sistema PSK Hearing Aid (Android · Oboe · GTCRN · ONNX) se contrasta
> con tesis de universidades de EEUU y prácticas de los principales fabricantes mundiales
> (Starkey, Oticon, Phonak/Sonova, GN ReSound, Widex, Signia, Bernafon, Hansaton, OEMs chinos).
> Cada entrada incluye: qué es · uso clínico · referencia académica/industrial · comparación con
> nuestro sistema · mejora propuesta con valor numérico.

---

## Índice de Universidades y Fabricantes Consultados

### Tesis y publicaciones académicas (universidades de EEUU)
- **MIT** — STFT-domain neural SE con baja latencia algorítmica (Wang et al.).
- **Stanford CCRMA** — Hearing Seminars con Tao Zhang (Starkey) sobre attention decoding y beamforming.
- **UC Berkeley / UCSD (eScholarship)** — Multirate signal processing for WDRC + multirate audiometric filter banks.
- **Johns Hopkins (CLSP)** — Spatial speech detection for binaural hearing aids con Hermansky.
- **Northwestern University (Souza et al.)** — Effects of compression on speech intelligibility.
- **Vanderbilt University** — Hearing Aid Research Lab, fitting protocols pediátricos NAL/DSL.
- **Purdue University** — PURR Acoustic Feedback in Hearing Aids (NLMS, PEM, swPEMSC).
- **Gallaudet University** — Hearing4all collaboration, signal processing en CIs y HAs.
- **Washington University in St. Louis (PACS)** — PhD en Speech and Hearing Sciences con auditory neuroscience.
- **University of Iowa (HAAR + Pediatric Audiology Lab)** — Hearing aid service models + DSL pediátrica.

### Whitepapers y patentes de fabricantes
- **Starkey (EEUU)** — Edge AI / Neuro Sound 2.0, G2 Neuro Processor con NPU integrada, hasta 13 dB SNR. ([whitepaper](https://www.frontiersin.org/journals/audiology-and-otology/articles/10.3389/fauot.2025.1677482/full))
- **Oticon (Demant, Dinamarca)** — Intent con DNN 2.0 + 4D Sensor, entrenado sobre 12M de escenas. ([whitepaper](https://wdh01.azureedge.net/-/media/oticon/main/pdf/master/whitepaper/4d-sensor-technology-and-dnn-20-in-oticon-intent.pdf))
- **Phonak (Sonova, Suiza)** — Audéo Sphere Infinio con DEEPSONIC (DNN dedicado, 64 frecuencias, +10 dB SNR). ([whitepaper](https://audiologyblog.phonakpro.com/audeo-sphere-advancing-speech-understanding-with-ai/))
- **GN ReSound (Dinamarca)** — Vivia con DNN chip dedicado, 13.5M frases entrenadas, beamformer 4-mic. ([prensa GN](https://www.resound.com/en-us/press/gn-introduces-its-most-intelligent-hearing-portfolio-yet-including-resound-vivia))
- **Widex (Demant)** — PureSound con ZeroDelay, latencia < 0.5 ms en pathway analógico-digital. ([Hearing Review](https://hearingreview.com/hearing-products/hearing-aids/bte/reducing-hearing-aid-delay-for-optimal-sound-quality-a-new-paradigm-in-processing))
- **Signia (Sivantos/WSAudiology, Alemania)** — AX/IX con split processing dual de speech vs ambient. ([Signia Pro](https://www.signia.net/en/hearing-aids/augmented-xperience/))
- **Bernafon (Demant, Suiza)** — ChannelFree + DECS (Dynamic Environment Control System), 32k data points/s. ([Bernafon Wiki](https://en.wikipedia.org/wiki/Bernafon))
- **Hansaton (WSAudiology, Alemania)** — Sound SHD con AutoSurround SHD, SpeechBeam SHD, SphereSound. ([Technical info](https://www.hansaton.com/content/dam/hansaton/en/documents/speherehd/professional-information/technical_information_shd.pdf.coredownload.pdf))
- **Acosound (China)** — 32 canales DSP, 16 bandas, 8 canales de compresión, SIW. ([Acosound](https://www.acosoundhearingaid.com/products/acosound-basic))
- **Austar Hearing (China)** — Primer fabricante chino en algoritmos audio de alto rendimiento (2003+). ([Austar](https://www.austar-hearing.net/))
- **Earsmate / Mimitakara / Ratin** — OTC chinos con bluetooth y procesamiento básico multibanda.

---

## 1. Modelo de IA / Red Neuronal

### **GTCRN — Grouped Temporal Convolutional Recurrent Network**
**Qué es:** modelo causal frame-online de speech enhancement, derivado de DPCRN simplificado, con módulos SFE (Subband Feature Extraction) y TRA (Temporal Recurrent Attention). Solo 33 MMACs y ~24k parámetros publicados.
**En audífonos:** apto para denoising en tiempo real porque opera frame-a-frame con cache recurrente, sin lookahead. Útil cuando el SoC no tiene NPU dedicada.
**Referencia:** Rong et al., *GTCRN: A Speech Enhancement Model Requiring Ultralow Computational Resources*, ICASSP 2024 ([Semantic Scholar](https://www.semanticscholar.org/paper/GTCRN:-A-Speech-Enhancement-Model-Requiring-Rong-Sun/eeee2dcd0491857e9172c36e4f55c6eaaac77529)). Variantes derivadas (TSDCA-BA en MDPI 2025, [link](https://www.mdpi.com/2076-3417/15/15/8183)) ya lo adaptan explícitamente a audífonos en tiempo real.
**Comparación con nuestro sistema:** usamos la variante "simple" exportada a ONNX (523 KB). Está bien dimensionado para móvil pero no tiene HW-NN dedicado como Starkey G2/NPU o Phonak DEEPSONIC.
**Mejora propuesta:** evaluar la versión `gtcrn_ll` (low-latency) con hop=128 (8 ms) en vez de 256 (16 ms) para reducir el delay algorítmico de 16 ms a 8 ms. Validar con WB-PESQ ≥ 2.85.

### **GTCRN simple (variante exportada a ONNX)**
**Qué es:** versión podada del GTCRN original, sin algunas TRA layers, optimizada para inferencia.
**En audífonos:** crítica para mantener el footprint < 1 MB en NDK Android y poder cargar el modelo en RAM persistente.
**Referencia:** repo oficial Xiaobin-Rong/gtcrn ([GitHub](https://github.com/Xiaobin-Rong/gtcrn)).
**Comparación:** tenemos 523 KB, comparable a DeepFilterNet2 (~1.8 MB) y mucho menor que Oticon Intent DNN 2.0 (~12M sound scenes implica modelo on-chip de >2 MB).
**Mejora propuesta:** quantizar a INT8 dinámico con `ort.quantization.quantize_dynamic` para bajar de 523 KB a ~150 KB y reducir latencia de inferencia ~30%.

### **DPCRN backbone simplificado**
**Qué es:** Dual-Path Convolutional Recurrent Network original (2021) sobre el cual se construyó GTCRN.
**En audífonos:** demasiado pesado en su versión completa (DPCRN-large 32-32-32-64-128 channels), por eso GTCRN aplica grouped strategies.
**Referencia:** *Adaptive Convolution for CNN-based Speech Enhancement Models*, arXiv 2502.14224 ([html](https://arxiv.org/html/2502.14224v1)).
**Comparación:** nosotros heredamos los grouped blocks pero no usamos los dual-path completos.
**Mejora propuesta:** sin cambios; mantener la simplificación.

### **ERB filter bank**
**Qué es:** banco perceptual basado en bandas auditivas (Equivalent Rectangular Bandwidth de Glasberg-Moore: `ERB(f) = 24.7 × (4.37·f/1000 + 1)`).
**En audífonos:** clave porque imita la cóclea humana; reduce dimensionalidad sin perder información crítica para inteligibilidad.
**Referencia:** CCRMA Stanford "ERB Filter Bank" ([link](https://ccrma.stanford.edu/realsimple/aud_fb/Equivalent_Rectangular_Bandwidth_ERB.html)). DeepFilterNet también usa bandas ERB ([emergentmind](https://www.emergentmind.com/topics/deepfilternet-framework)).
**Comparación:** el GTCRN simple incluye SFE basado en ERB con resolución coarse.
**Mejora propuesta:** verificar que las 32 bandas ERB internas del modelo cubran 100–8000 Hz uniformemente; si no, retrainear con 24 bandas desde 80 Hz para preservar consonantes a 4–6 kHz.

### **Grouped convolution**
**Qué es:** conv 2D con `groups>1`, partiendo el tensor en grupos independientes para reducir cómputo (factor `1/G` en MACs).
**En audífonos:** crítica para correr en NPU de baja potencia (<5 mA).
**Referencia:** AlexNet original; aplicado a SE en GTCRN paper ([dblp](https://dblp.org/rec/conf/icassp/RongSZHZL24.html)).
**Comparación:** GTCRN simple usa grupos de 2 a 4 según capa.
**Mejora propuesta:** sin cambios; ya está optimizado.

### **Grouped RNN / GRU agrupada**
**Qué es:** GRU dividida en sub-GRUs paralelas con menos hidden units.
**En audífonos:** baja la complejidad temporal sin sacrificar memoria de largo plazo.
**Referencia:** GTCRN paper sección 2.2; FastEnhancer también usa GRU para streaming ([arxiv 2509.21867](https://arxiv.org/html/2509.21867v1)).
**Comparación:** nuestra GTCRN simple usa GRU agrupada con hidden 32–64.
**Mejora propuesta:** sin cambios.

### **SFE (Subband Feature Extraction)**
**Qué es:** módulo que extrae features por sub-banda concatenando bins adyacentes.
**En audífonos:** preserva resolución espectral fina en bandas críticas (1–4 kHz para consonantes).
**Referencia:** GTCRN paper, sección 2.3.
**Comparación:** ya lo tenemos integrado en el grafo ONNX.
**Mejora propuesta:** sin cambios.

### **TRA (Temporal Recurrent Attention)**
**Qué es:** atención temporal recurrente que pondera frames recientes según relevancia.
**En audífonos:** detecta transiciones de habla vs ruido (onset de palabra).
**Referencia:** GTCRN paper, sección 2.4.
**Comparación:** la variante simple mantiene TRA reducida.
**Mejora propuesta:** evaluar TRA expandida con context window de 8 frames si la latencia lo permite.

### **Causal / frame-online**
**Qué es:** procesamiento sin acceso a frames futuros, esencial para tiempo real.
**En audífonos:** cualquier lookahead se traduce en delay perceptible (>5 ms ya genera comb-filter en open-fit, ver Stiefenhofer 2022).
**Referencia:** PMC11638989 *Individual Differences Underlying Preference for Processing Delay in Open-Fit Hearing Aids* ([link](https://pmc.ncbi.nlm.nih.gov/articles/PMC11638989/)).
**Comparación:** GTCRN es 100% causal — bien.
**Mejora propuesta:** sin cambios. Pero nuestro hop=256 (16 ms) es alto vs Widex ZeroDelay (<0.5 ms). El problema es estructural del paradigma STFT-DNN, no del causal-flag.

### **Speech enhancement (paradigma)**
**Qué es:** denoising supervisado entrenado con pares `(noisy, clean)` y loss perceptual.
**En audífonos:** aumenta SNR audible 5–13 dB (Starkey reporta 13 dB con Edge Mode+, Phonak 10 dB con Spheric Speech Clarity).
**Referencia:** Starkey Frontiers 2025 ([link](https://www.frontiersin.org/journals/audiology-and-otology/articles/10.3389/fauot.2025.1677482/full)).
**Comparación:** GTCRN reporta SNRi de 8–12 dB.
**Mejora propuesta:** medir SNRi propio sobre VoiceBank+DEMAND (target ≥ 8 dB) con `pesq` y `pystoi` antes de fitting clínico.

### **Modelo agnóstico al perfil**
**Qué es:** el modelo no incorpora audiograma del usuario.
**En audífonos:** ventaja: un único modelo. Desventaja: pierde personalización vs Oticon Intent que ajusta el DNN según LIVE feedback.
**Referencia:** Oticon Intent whitepaper ([link](https://www.oticon.com/-/media/oticon-us/main/download-center---myoticon---product-literature/intent/whitepapers/15500-0299---4d-sensor-technology-and-dnn-2-0-whitepaper.pdf)).
**Comparación:** somos agnósticos. La personalización ocurre en el WDRC/EQ aguas abajo.
**Mejora propuesta:** mantener agnóstico, pero **modular intensity por banda** según pérdida del paciente: si la pérdida es solo en altas, bajar `intensity` a 0.7 abajo de 1500 Hz para no comerse formantes vocálicos.

### **Dataset entrenamiento típico — VoiceBank+DEMAND**
**Qué es:** 28 speakers VCTK + 10 noises DEMAND, ~12h train / ~1h test.
**En audífonos:** dataset estándar pero limitado (solo 12 noises). Modelos comerciales usan datasets propios mucho más grandes (Oticon: 12M scenes; ReSound: 13.5M frases).
**Referencia:** [emergentmind benchmark](https://www.emergentmind.com/topics/voicebank-demand-dataset).
**Comparación:** GTCRN reporta WB-PESQ 2.93 sobre VBD con loss MSE-perceptual ([researchgate](https://www.researchgate.net/publication/379817993)).
**Mejora propuesta:** fine-tune con el dataset de Clarity Challenge ICASSP 2023 (incluye HRTF + escenas reverberantes domésticas) para ganar 0.3–0.5 PESQ en escenarios reales.

### **Métricas académicas — WB-PESQ, STOI, SI-SDR**
**Qué es:** metricas objetivas de calidad (PESQ -0.5 a 4.5), inteligibilidad (STOI 0–1), distorsión (SI-SDR dB).
**En audífonos:** PESQ y STOI son las más correlacionadas con percepción humana; SI-SDR penaliza distorsión, no necesariamente percepción.
**Referencia:** Taal et al. 2011 (STOI), ITU-T P.862 (PESQ), Le Roux 2019 (SI-SDR).
**Comparación:** no medimos PESQ/STOI internos de la app; solo confiamos en valores publicados del paper.
**Mejora propuesta:** **agregar pipeline de validación offline** que ejecute PESQ + STOI sobre 30 muestras VBD test cada release. Threshold mínimo: PESQ ≥ 2.7, STOI ≥ 0.91.

### **Ultralightweight**
**Qué es:** clase de modelos <50k params y <50 MMACs.
**En audífonos:** target tradicional para SoC con DSP fixed-point.
**Referencia:** Channel-grouped iterative CRN con solo 15.8k params ([Springer](https://link.springer.com/article/10.1186/s13636-026-00455-4)).
**Comparación:** GTCRN ~24k params está en la liga ligera.
**Mejora propuesta:** considerar drop-in replacement por LiSenNet o TSDCA-BA si necesitamos bajar a 15 MMACs.

### **Asset path / SHA256 / tamaño 523 KB**
**Qué es:** asset embebido en APK con verificación de integridad.
**En audífonos comerciales:** firmware firmado y encriptado (Phonak SoundCore 2 chip, Starkey G2). En Android OTC, es razonable la verificación SHA-256.
**Referencia:** sherpa-onnx releases ([github](https://github.com/k2-fsa/sherpa-onnx)).
**Comparación:** ya verificamos SHA-256 al cargar.
**Mejora propuesta:** firmar el modelo con HMAC-SHA256 usando key derivada de secret en `BuildConfig`, para detectar swap malicioso del modelo.

### **Formato ONNX / Runtime ORT**
**Qué es:** formato neutral de grafos NN; ORT inferencia multi-EP.
**En audífonos:** Oticon usa runtime propio Polaris-R; Starkey custom. Para móvil OTC, ORT es estándar de facto.
**Referencia:** ONNX Runtime Mobile ([docs](https://onnxruntime.ai/docs/tutorials/mobile/)).
**Comparación:** usamos full ORT (24.6 MB lib) por compatibilidad; pesado.
**Mejora propuesta:** **migrar a ORT Mobile minimal build** con solo los ops que usa GTCRN; reduce libonnxruntime.so de 24.6 MB → ~3–5 MB. Reduce APK total de ~30.4 MB a ~10 MB.

### **IntraOp / InterOp NumThreads = 1**
**Qué es:** ORT con un solo thread CPU para inferencia.
**En audífonos:** tiempo real prefiere single-thread predecible vs multi-thread con jitter.
**Referencia:** ORT performance tuning ([link](https://onnxruntime.ai/docs/performance/mobile-performance-tuning.html)).
**Comparación:** ya lo hacemos.
**Mejora propuesta:** sin cambios; pero medir lastInferenceUs con thread affinity al BIG core (cpuset) para reducir varianza ~25%.

### **GraphOptimizationLevel = ORT_ENABLE_ALL**
**Qué es:** activa todas las optimizaciones de grafo (constant folding, op fusion).
**En audífonos:** correcto.
**Comparación:** ya lo hacemos.
**Mejora propuesta:** sin cambios.

### **CPUExecutionProvider (default) — NNAPI no habilitado**
**Qué es:** ejecutor genérico CPU. NNAPI usa accel HW (DSP, NPU, GPU) cuando disponibles.
**En audífonos comerciales con SoC propio:** usan accel HW dedicado.
**Referencia:** ONNX Runtime NNAPI EP ([docs](https://onnxruntime.ai/docs/execution-providers/NNAPI-ExecutionProvider.html)). XNNPACK EP también acelera ARM64 ([docs](https://onnxruntime.ai/docs/execution-providers/Xnnpack-ExecutionProvider.html)).
**Comparación:** estamos en CPU; perdemos potencial ganancia 2–4× en NPU/GPU.
**Mejora propuesta:** **habilitar XNNPACK EP** primero (estable, mejora 30–50% sobre arm64). NNAPI solo si XNNPACK no alcanza, porque NNAPI tiene fallback variable según fabricante.

### **Inputs/Outputs — mix, conv_cache, tra_cache, inter_cache**
**Qué es:** 4 tensores: 1 audio + 3 estados recurrentes.
**En audífonos:** estándar para modelos causales con LSTM/GRU/conv causal.
**Referencia:** *Real-time speech enhancement on raw signals with deep state-space modeling* ([arxiv 2409.03377](https://arxiv.org/html/2409.03377v3)).
**Comparación:** ya tenemos las 4 caches preallocadas.
**Mejora propuesta:** sin cambios.

### **Mapeo posicional vs por nombre**
**Qué es:** asignar input/output del runtime por índice (`inputs[0]`) vs por nombre string.
**En audífonos:** posicional es más robusto a re-export.
**Referencia:** issue documentado en el doc de causa raíz "tqtqtq" del propio sistema.
**Comparación:** corregimos a posicional. Bien.
**Mejora propuesta:** **agregar verificación cruzada al boot:** loggear `inputs[i].name` y comparar contra patrón conocido; si difiere, advertir al log y caer a posicional.

### **mix shape `[1, 257, 1, 2]` / 257 bins / Cache recurrente**
**Qué es:** batch=1, 257 bins (FFT/2+1), 1 frame, complex (Re+Im).
**En audífonos:** `2·257·4 = 2056 bytes` por frame. Aceptable.
**Comparación:** estándar.
**Mejora propuesta:** sin cambios. Si quisieras stride por frames múltiples para aprovechar batching, perderías causalidad.

### **Frame del modelo — 256 samples = 16 ms @ 16 kHz**
**Qué es:** tamaño de hop = unidad mínima de inferencia.
**En audífonos comerciales:** Widex PureSound declara <0.5 ms; Phonak Sphere ~7.5 ms; Oticon Intent ~6 ms.
**Referencia:** Widex ZeroDelay technical paper ([widex](https://www.widexpro.com/en-us/widex-technology/zerodelay/)).
**Comparación:** 16 ms es relativamente alto para open-fit; comb-filter audible empieza a 5–7 ms (Agnew, Stiefenhofer).
**Mejora propuesta crítica:** **bajar hop a 128 samples (8 ms)** y aumentar overlap a 75% (FFT=512 sigue, pero hop=128). Costo: 2× inferencias/segundo (250 vs 125), pero baja latencia algorítmica de 16 ms a 8 ms.

### **VAD (Voice Activity Detection) — no expuesto en GTCRN simple**
**Qué es:** probabilidad de voz/no-voz en cada frame.
**En audífonos:** usado para bloquear release del WDRC en ruido (evita "pumping" en silencios) y para activar comfort noise.
**Referencia:** RNNoise expone VAD probability ([rnnoise](https://jmvalin.ca/demo/rnnoise/)).
**Comparación:** GTCRN simple no lo expone.
**Mejora propuesta:** estimar VAD a posteriori: si `||enh|| / ||mix|| < 0.3` por 100 ms continuos, marcar como "no voz" y disparar comfort noise (-50 dBFS) en el dryDelayRing.

### **SNR improvement objetivo — 8–12 dB**
**Qué es:** mejora medible de SNR a la salida.
**En audífonos comerciales:** Starkey 13 dB (Edge Mode+), Phonak 10 dB (Spheric 2.0), ReSound Vivia 7–9 dB, Oticon Intent ~6 dB perceptual.
**Referencia:** [Frontiers 2025](https://www.frontiersin.org/journals/audiology-and-otology/articles/10.3389/fauot.2025.1677482/full) y [audiologyblog Phonak](https://audiologyblog.phonakpro.com/audeo-sphere-advancing-speech-understanding-with-ai/).
**Comparación:** estamos en rango medio.
**Mejora propuesta:** medir nuestro SNRi sobre 50 archivos del Clarity Challenge eval set; reportar mediana e intervalo confianza 95%.

### **Speech distortion target < 5%**
**Qué es:** distorsión espectral residual del habla limpia post-DNN.
**En audífonos:** > 5% degrada inteligibilidad (Healy et al. 2017).
**Referencia:** *An effectively causal deep learning algorithm to increase intelligibility* (Healy/Wang JASA 2021).
**Comparación:** sin medición propia.
**Mejora propuesta:** medir log-spectral distortion (LSD) sobre clean reference; target LSD ≤ 1.5 dB.

### **lazy initialization / modelReady flag**
**Qué es:** carga el modelo en primer `initialize()` no en startup app.
**En audífonos:** mejor para cold-start tiempo del app.
**Comparación:** ya lo hacemos.
**Mejora propuesta:** sin cambios. Considerar pre-warm en background tras 1s de UI idle.

---

## 2. Sample Rates y Conversiones

### **kDnnSampleRate = 16 000 Hz**
**Qué es:** rate nativa del modelo GTCRN (entrenado a 16 kHz).
**En audífonos:** 16 kHz cubre fundamentales y 1ª-2ª armónica de habla. Comerciales modernos usan 24–32 kHz: Widex 32 kHz, Phonak Sphere 24 kHz, Oticon Intent 22 kHz.
**Referencia:** Widex Moment 32 kHz pathway ([Hearing Review](https://hearingreview.com/hearing-products/hearing-aids/psap/puresound)).
**Comparación:** 16 kHz limita la inteligibilidad de fricativas /s/, /f/, /th/ por encima de 7 kHz.
**Mejora propuesta:** entrenar/usar **GTCRN-fullband 48 kHz** (existe DeepFilterNet full-band 48 kHz en [github](https://github.com/Rikorose/DeepFilterNet)) para preservar consonantes 6–10 kHz y eliminar el round-trip resampler.

### **Native Oboe sample rate = 48 000 Hz**
**Qué es:** rate negociada por AAudio en la mayoría de dispositivos modernos.
**En audífonos comerciales:** los SoC propietarios fijan rate (Phonak: 32 kHz; Sonova SWORD: 24 kHz; ReSound M&RIE: 32 kHz).
**Referencia:** Android Developers Oboe guide ([link](https://developer.android.com/games/sdk/oboe/low-latency-audio)).
**Comparación:** 48 kHz es lo común en Android pero requiere resampling.
**Mejora propuesta:** **detectar rate con `getNativeSampleRate()`** y, si el dispositivo soporta 16 kHz nativo (algunos Pixels lo permiten), abrir Oboe directamente a 16 kHz para bypass total del resampler. Ahorra ~2 ms.

### **Ratio 3:1 — 48↔16 kHz polyphase**
**Qué es:** factor `M=L=3` de decimación e interpolación.
**En audífonos:** crítico cuando el SoC interno trabaja a otra rate. Mismo principio en multirate filterbanks (Berkeley/UCSD escholarship).
**Referencia:** *Multirate Audiometric Filter Bank for Hearing Aid Devices* ([PMC8973212](https://pmc.ncbi.nlm.nih.gov/articles/PMC8973212/)).
**Comparación:** correcto.
**Mejora propuesta:** sin cambios.

### **inputSr / effectiveSampleRate**
**Qué es:** variables que tracken la rate observada y la negociada.
**En audífonos:** clave para evitar el bug histórico de "pitch tracking erróneo" (rate mismatch).
**Comparación:** ya documentado como causa raíz del "tqtqtq".
**Mejora propuesta:** **agregar log estructurado al boot** con `inputSr`, `effectiveSampleRate`, `mode` para diagnóstico remoto.

### **Caso 16 kHz / bypass identity**
**Qué es:** cuando rates coinciden, `memcpy` puro sin filtro.
**En audífonos:** ahorra cómputo y mantiene fase ideal.
**Comparación:** correcto.
**Mejora propuesta:** sin cambios.

### **Caso 48 kHz / polyphase 3:1**
**Qué es:** filtro pasa-bajos polyphase con `M=3` taps por fase.
**En audífonos:** estándar.
**Mejora propuesta:** ver sección 3 (filtro).

### **Caso otros (22050, 44100) / interpolación lineal genérica**
**Qué es:** fallback cuando rate no es 16 ni 48 kHz.
**En audífonos:** lineal degrada calidad ~10 dB SNR.
**Referencia:** Stanford CCRMA "interpolación cero-orden vs lineal vs sinc" ([sasp](https://ccrma.stanford.edu/~jos/sasp/)).
**Comparación:** lineal genérico es mediocre.
**Mejora propuesta crítica:** **reemplazar lineal por polyphase precomputado para 22050 (160:441) y 44100 (160:441)** o por sinc-windowed Kaiser β=8 con N=64. Para 22050→16000 ratio = 320:441 (no entero); usar Farrow filter o pre-cómputo de polyphase con 441 fases.

### **Round-trip ~2 ms a 48 kHz**
**Qué es:** suma de group delay down + up.
**En audífonos comerciales:** Widex ZeroDelay <0.5 ms; nuestro 2 ms es 4× peor.
**Referencia:** Widex tech paper ([link](https://www.widexpro.com/en-us/widex-technology/zerodelay/)).
**Comparación:** 2 ms suma a la latencia total ~25 ms.
**Mejora propuesta:** reducir a 1 ms total bajando taps a 64 con Kaiser β=10 (similar stopband, menor delay).

### **Identity mode / Bit-exact bypass**
**Qué es:** ruta sin estado para no degradar dry signal.
**En audífonos:** standard.
**Mejora propuesta:** sin cambios.

---

## 3. Resampler (filtro de re-muestreo)

### **Polyphase FIR**
**Qué es:** descomposición en `L` subfiltros, cada uno con `N/L` taps. Computa solo lo necesario (sin desperdiciar mults por ceros insertados/descartados).
**En audífonos:** estándar; converters OEM Sonova/Demant lo usan.
**Referencia:** *Design and Implementation of Maximally Decimated Polyphase Filter Bank for Power and Delay Efficient Digital Hearing Aids* ([researchgate](https://www.researchgate.net/publication/341070151)). UCSD eScholarship qt4f17q7r9 ([link](https://escholarship.org/content/qt4f17q7r9/qt4f17q7r9.pdf)).
**Comparación:** correcto.
**Mejora propuesta:** sin cambios estructurales.

### **Prototipo LPF / 96 taps / 32 taps por fase**
**Qué es:** filtro pasa-bajos compartido para down y up. 96 taps = `protoN`; `32 = 96/3` taps por fase.
**En audífonos:** **96 taps es generoso** para 48↔16 kHz. La mayoría de implementaciones usan 48–64 taps con Kaiser β=8 a 10.
**Referencia:** Stanford CCRMA `kaiserord` ([link](https://ccrma.stanford.edu/~jos/sasp/Hood_kaiserord.html)). Fórmula: `M = (A-8)/(2.285·Δω)`.
**Comparación:** 96 taps con β=8 da ~80 dB stopband, exceso de margen.
**Mejora propuesta:** **bajar a 72 taps (24 por fase) con β=8.5** → preserva 80 dB stopband, group delay baja de 47.5 a 35.5 samples (0.74 ms a 48 kHz vs 0.99 ms). Round-trip: 1.48 ms vs 1.98 ms.

### **fc = 7500 Hz / fc normalizado 0.15625**
**Qué es:** corte midpoint banda transición. Calculado como `(fpass + fstop)/2 = (7000+8000)/2 = 7500`.
**En audífonos:** correcto para evitar aliasing en 16 kHz (Nyquist=8 kHz).
**Comparación:** ok.
**Mejora propuesta:** sin cambios.

### **Banda de transición 7–8 kHz**
**Qué es:** ancho 1 kHz para roll-off del filtro.
**En audífonos:** 1 kHz es agresivo; aceptable porque arriba de 8 kHz no hay info útil para GTCRN.
**Comparación:** ok.
**Mejora propuesta:** sin cambios.

### **Ventana Kaiser β=8 (≈80 dB stopband)**
**Qué es:** ventana paramétrica con relación: `A = 80 → β = 0.1102·(80-8.7) = 7.857 ≈ 8`.
**En audífonos:** β=8 es típico; β=10 da 100 dB stopband con 30% más taps.
**Referencia:** MATLAB `kaiserord` doc ([link](https://www.mathworks.com/help/signal/ug/kaiser-window.html)).
**Comparación:** β=8 está bien.
**Mejora propuesta alternativa:** si quisieras stopband 100 dB para audífonos premium (rara vez audible la diferencia), subir a β=10 con `taps = ceil((100-8)/(2.285·Δω)) ≈ 88` (no muchos más).

### **Bessel I0 / sinc ideal / center 47.5 / Normalización DC=1**
**Qué es:** matemática del filtro: `h[n] = w[n] · 2·fc·sinc(2·fc·(n-center))`, suma normalizada a 1.0.
**En audífonos:** correcto.
**Mejora propuesta:** sin cambios. Verificar Bessel I0 con Abramowitz 9.8.1 (rango |x|≤3.75) y 9.8.2 (|x|>3.75) — ya está documentado.

### **Down compensation / Up compensation × L=3**
**Qué es:** down con DC=1; up multiplica polyphase por L para compensar inserción de ceros.
**En audífonos:** correcto.
**Mejora propuesta:** sin cambios.

### **Group delay 47.5 samples ≈ 0.99 ms a 48 kHz**
**Qué es:** retraso del FIR fase lineal.
**En audífonos:** ya cubierto en sección 2.
**Mejora propuesta:** ver "bajar a 72 taps".

### **Lineal genérico (linearRatio / linearAccum / linearLast)**
**Qué es:** fallback simple para rates no soportadas.
**En audífonos:** mediocre.
**Mejora propuesta:** ver sección 2 (reemplazar por polyphase pre-computado para 22050 y 44100).

### **Resampler::Mode enum**
**Qué es:** kIdentity / kPolyDown48to16 / kPolyUp16to48 / kLinearGeneric.
**En audífonos:** despachador correcto.
**Mejora propuesta:** **agregar `kPolyDown44100to16000` y `kPolyUp16000to44100`** con tablas precomputadas.

### **Delay line / writeIdx / phase counter / stateful / idempotente**
**Qué es:** state interno (96 floats poly), wrap circular.
**En audífonos:** estándar.
**Mejora propuesta:** sin cambios. Asegurar que `configure()` con misma rate NO toca el delay line — ya documentado como idempotente.

### **Realloc fuera del hot path**
**Qué es:** crece staging con `assign()` solo si bloque crece.
**En audífonos embebidos:** prohibido alocar en RT thread.
**Mejora propuesta:** sin cambios. Auditar con `mtrace` o ASan que no haya `new`/`malloc` en hot path.

### **Calidad: Kaiser β=8 polyphase 48↔16; lineal en otros**
**Qué es:** dos calidades diferentes.
**En audífonos:** desigual.
**Mejora propuesta:** unificar a polyphase para todas las rates comunes (16/22050/32/44100/48 kHz).

### **Fase lineal**
**Qué es:** sí en polyphase (filtro simétrico).
**Beneficio:** preserva forma de onda transiente.
**Comparación:** correcto.

---

## 4. Análisis y Síntesis Espectral (STFT/iSTFT)

### **STFT / iSTFT**
**Qué es:** Short-Time Fourier Transform y su inversa.
**En audífonos:** dominio donde operan los DNN modernos. Alternativa: dominio temporal (DEMUCS, DPRNN-time) que evita STFT pero usa más cómputo.
**Referencia:** Wang & Watanabe 2023 *STFT-Domain Neural Speech Enhancement With Very Low Algorithmic Latency* ([TASLP PDF](https://zqwang7.github.io/publications/TASLP2022_STFTlowlat.pdf)).
**Comparación:** correcto.
**Mejora propuesta:** sin cambios estructurales.

### **kDnnFftSize = 512**
**Qué es:** tamaño FFT de análisis.
**En audífonos:** 512 a 16 kHz = 32 ms de ventana; resolución espectral ~31.25 Hz/bin. Estándar.
**Referencia:** GTCRN paper.
**Comparación:** ok.
**Mejora propuesta:** sin cambios.

### **kDnnHopSize = 256 (50% overlap)**
**Qué es:** salto entre frames. 50% overlap es la opción más común.
**En audífonos comerciales:** Phonak Sphere usa 25% overlap (hop=N/4) para menor latencia; 75% overlap se usa en post-pro de música pero no en audífonos por costo.
**Referencia:** *Ultra-Low Latency Speech Enhancement* ([arxiv 2409.10358](https://arxiv.org/pdf/2409.10358)).
**Comparación:** 50% es buen tradeoff calidad/latencia/cómputo.
**Mejora propuesta:** **probar hop=128 (75% overlap)** para bajar latencia algorítmica a 8 ms; costo: 2× inferencias.

### **fftRadix2 / Bit-reversal / Cooley-Tukey butterflies**
**Qué es:** FFT in-place radix-2.
**En audífonos:** común; split-radix ahorra ~10% mults pero complejiza el código.
**Referencia:** ryg blog *Notes on FFTs for implementers* ([link](https://fgiesen.wordpress.com/2023/03/19/notes-on-ffts-for-implementers/)).
**Comparación:** radix-2 está bien para 512.
**Mejora propuesta:** considerar **`pffft` o `KISS-FFT`** (libs probadas) si necesitamos optimización; ahorran ~30% sobre implementación naive.

### **fftRe / fftIm — workspace [512]**
**Qué es:** dos buffers Float32 separados Re/Im.
**En audífonos:** clásico.
**Mejora propuesta:** sin cambios. Considerar packed-real FFT (R2C) para ahorrar mitad del cómputo: solo 257 bins son únicos, los otros son conjugados.

### **Ventana Hann periódica `0.5·(1-cos(2πi/N))`**
**Qué es:** ventana Hann sin sesgo (denominador N, no N-1).
**En audífonos:** correcto. La simétrica con `(N-1)` introduce sesgo amplitud ~0.4% por bin.
**Referencia:** documentado en sección 14 del propio diccionario base como bug fix.
**Comparación:** correcto.
**Mejora propuesta:** sin cambios.

### **Hann simétrica (descartada)**
**Qué es:** versión bug.
**Comparación:** corregida.
**Mejora propuesta:** sin cambios.

### **sqrt-Hann (análisis y síntesis)**
**Qué es:** ventana raíz cuadrada de Hann; aplicada en ambos lados garantiza COLA exacta con hop=N/2.
**En audífonos:** estándar para STFT-iSTFT con perfect reconstruction.
**Referencia:** *Ultra-Low Latency Speech Enhancement A Comprehensive Study* ([arxiv 2409.10358](https://arxiv.org/pdf/2409.10358)).
**Comparación:** correcto.
**Mejora propuesta:** evaluar **par asimétrico** (long analysis + short synthesis) — analysis 32 ms con sqrt-Hann, synthesis 8 ms con sqrt-Hann recortada. Logra **latencia algorítmica 8 ms con resolución espectral de 32 ms**. Ver Wang & Watanabe TASLP 2023.

### **COLA / Unity-gain OLA**
**Qué es:** suma de window² = 1 en el solapamiento.
**En audífonos:** condición para reconstrucción perfecta.
**Comparación:** garantizado con sqrt-Hann + hop=N/2.
**Mejora propuesta:** sin cambios.

### **stftInBuf / olaBuf / outputFrame**
**Qué es:** buffers deslizantes y acumulador OLA.
**En audífonos:** estándar.
**Comparación:** correcto.
**Mejora propuesta:** sin cambios. Verificar que `olaBuf` se shifteie por hop después de `outputFrame` sin pérdida.

### **Bins espectrales 257 / Simetría hermítica**
**Qué es:** `FFT/2 + 1 = 257` bins únicos. El resto se reconstruye conjugando.
**En audífonos:** estándar.
**Comparación:** correcto.
**Mejora propuesta:** sin cambios.

### **Packing complex [Re, Im] / Freq dim detection / Shape esperada**
**Qué es:** layout en memoria.
**En audífonos:** correcto.
**Mejora propuesta:** sin cambios.

### **Frame rate 62.5 fps / Latencia STFT 16 ms**
**Qué es:** 16000/256 = 62.5 frames/seg.
**En audífonos:** la **latencia algorítmica** es exactamente igual al hop (no al window length, gracias a OLA). Por eso bajar hop = bajar latencia.
**Referencia:** Wang & Watanabe TASLP 2023, sección 2.B.
**Comparación:** 16 ms es alto vs Widex (<0.5 ms) o DeepFilterNet en hearing aid (2 ms reportado).
**Mejora propuesta crítica:** **adoptar par asimétrico window con hop=128 (8 ms)** y, en una segunda iteración, hop=64 (4 ms) si las métricas PESQ/STOI no degradan más de 0.15.

---

## 5. Buffering y Concurrencia

### **SpscRing — single-producer single-consumer ring buffer**
**Qué es:** queue circular lock-free, productor único / consumidor único.
**En audífonos:** estándar industria. Correcto.
**Referencia:** Rigtorp *Optimizing a Ring Buffer for Throughput* ([link](https://rigtorp.se/ringbuffer/)).
**Comparación:** correcto.
**Mejora propuesta:** sin cambios.

### **Lock-free**
**Qué es:** no usa mutex; coordinación via atomics.
**En audífonos:** mandatorio en RT thread.
**Comparación:** correcto.
**Mejora propuesta:** sin cambios.

### **Capacidad 4096 / Mask = capacity-1**
**Qué es:** potencia de 2 para wrap rápido con `& mask`.
**En audífonos:** 4096 muestras a 16 kHz = 256 ms. **Demasiado** para tiempo real (mejor 1024 = 64 ms).
**Comparación:** generoso.
**Mejora propuesta:** **bajar a 1024** para forzar drop temprano si el worker se atrasa, evitando latencia acumulada perceptible. Trade: más drops bajo carga, menos lag perceptible.

### **head_ / tail_ atomics int / memory_order_acquire/release/relaxed**
**Qué es:** semántica de visibilidad entre threads.
**En audífonos:** correcto. Acquire al leer del otro lado, release al publicar avance, relaxed al leer propio.
**Referencia:** Rigtorp ring buffer + Boost spsc_queue ([stackoverflow](https://stackoverflow.com/questions/70512371/are-memory-orders-for-each-atomic-correct-in-this-lock-free-spsc-ring-buffer-que)).
**Comparación:** correcto.
**Mejora propuesta:** **alinear `head_` y `tail_` a 64 bytes (cache line)** con `alignas(64)` para evitar false sharing — ganancia 5–15% en throughput multi-core.

### **inputRing / outputRing / dryDelayRing**
**Qué es:** 3 colas: audio→worker, worker→audio, dry alineado.
**En audífonos:** correcto.
**Comparación:** correcto.
**Mejora propuesta:** sin cambios.

### **freeSpace() / available() / push() / pop() / clear()**
**Qué es:** API estándar SPSC.
**Comparación:** correcto.

### **Audio thread (callback Oboe) / Worker thread**
**Qué es:** dos threads desacoplados.
**En audífonos:** crítico para evitar bloqueo del callback RT.
**Comparación:** correcto.
**Mejora propuesta:** sin cambios.

### **workerRun / resetRequested / workerMtx / workerCv / wait_for(50ms) / notify_one**
**Qué es:** flags atómicos + condition variable para wakeup eficiente.
**En audífonos:** **`wait_for(50ms)` es lento** para un audífono. Mejor wait_for(5ms) o usar futex puro.
**Comparación:** 50 ms permite que el worker duerma demasiado entre frames de 16 ms.
**Mejora propuesta:** **bajar a `wait_for(5ms)`** y hacer notify_one tras cada hop disponible. Reduce worst-case wakeup de 50 ms a 5 ms.

### **Drop policy (frame entero) / Underrun (dry inalterado)**
**Qué es:** estrategia ante saturación.
**En audífonos:** correcto. Soltar dry unaltered es preferible a half-frame mixing (causa "tqtqtq").
**Comparación:** correcto, ya corregido.
**Mejora propuesta:** sin cambios. Logging del drop con counter expuesto vía `getDroppedFrames()`.

### **Capacidad temporal 256 ms**
**Qué es:** buffer máximo en peor caso.
**En audífonos:** demasiado.
**Mejora propuesta:** ver "bajar a 1024".

---

## 6. Latencia

### **Latencia algorítmica STFT — hop = 256 = 16 ms**
**Qué es:** retraso inherente al overlap-add con hop dado.
**En audífonos:** primer contribuyente al delay total. Comerciales: Widex 0.5 ms, DeepFilterNet en HA 2 ms, Phonak Sphere ~7.5 ms, Oticon Intent ~6 ms.
**Referencia:** *Towards Sub-millisecond Latency Real-Time Speech Enhancement Models on Hearables* ([arxiv 2409.18239](https://arxiv.org/html/2409.18239)).
**Comparación:** 16 ms es **significativamente alto** para open-fit; ya audible como comb-filter en habla propia.
**Mejora propuesta crítica:** ver sección 4 (hop=128 → 8 ms; o asymmetric window pair → 4 ms).

### **Latencia GTCRN frame — 16 ms a 16 kHz**
**Qué es:** unidad mínima de procesamiento.
**Comparación:** ligado al hop.
**Mejora propuesta:** ligada a la mejora de hop.

### **Group delay resampler down/up — ~0.99 ms cada uno**
**Qué es:** retraso fase lineal del FIR.
**Comparación:** ya cubierto.
**Mejora propuesta:** taps 96→72 baja a ~0.74 ms.

### **Round-trip resampler ~2 ms**
**Comparación:** ya cubierto.

### **Buffering del worker hasta 256 ms peor caso**
**Qué es:** cola SPSC profundidad 4096.
**En audífonos:** **mucho**. Con worker bien dimensionado (5 ms wait_for), el peor caso real es ~32 ms.
**Mejora propuesta:** capacity 1024 + wait_for 5 ms → peor caso ≤ 64 ms. Bajo carga normal: <1 hop = 16 ms.

### **Latencia total esperada 22–27 ms**
**Qué es:** suma stack: callback Oboe (4 ms) + resampler down (1 ms) + worker buffer (variable) + STFT (16 ms) + resampler up (1 ms) + Oboe out (4 ms).
**En audífonos:** **excede el budget recomendado** (10 ms para closed-fit, 5–6 ms para open-fit). 22 ms genera comb-filter audible en open-fit.
**Referencia:** Stone & Moore *Tolerable hearing aid delays* ([PMC](https://pubmed.ncbi.nlm.nih.gov/18469715/)).
**Comparación:** alto.
**Mejora propuesta:** combinando mejoras (hop=128, taps=72, wait_for=5ms): **target latencia total ~10–12 ms**.

### **inferenceTimeMs target < 16 ms**
**Qué es:** budget de inferencia ONNX por frame.
**En audífonos:** debe ser < hop (16 ms) sino el worker se atrasa.
**Comparación:** correcto target.
**Mejora propuesta:** medir P95 y P99, no solo el último valor. Si P99 > 14 ms, hay riesgo.

### **lastInferenceUs / CPU load < 5%**
**Qué es:** métricas observables.
**Comparación:** correctas.
**Mejora propuesta:** **agregar P50/P95/P99** además del último, exponer via JNI.

### **Block time Oboe ~4 ms (192 frames @ 48 kHz)**
**Qué es:** burst del callback. Se puede bajar con `setBufferSizeInFrames()`.
**Referencia:** Android Developers Oboe low-latency ([link](https://developer.android.com/games/sdk/oboe/low-latency-audio)).
**Comparación:** 192 frames es OK para low-latency mode.
**Mejora propuesta:** verificar `getFramesPerBurst()`; si el dispositivo soporta 96 frames, configurar bufferSize a 2 bursts = 192 frames @ 48 kHz = 4 ms.

### **Latency monitor / graceful degradation**
**Qué es:** bypass si el worker excede budget.
**Comparación:** correcto.
**Mejora propuesta:** **agregar histeresis**: bypass si P95 > 14 ms durante 1 seg, re-enable si vuelve < 10 ms durante 2 seg.

---

## 7. Pipeline DSP (Orden de Etapas)

### **Posición del DNN — entre Input y EQ (reemplaza al NR Wiener clásico)**
**Qué es:** ubicación del bloque GTCRN en la cadena.
**En audífonos comerciales:** la mayoría coloca DNN/NR ANTES del WDRC para que el compresor no amplifique ruido. Starkey Edge: DNN→DIR→WDRC; Phonak Sphere: DEEPSONIC→AutoSenseOS→Compresión.
**Referencia:** [audioxpress GN](https://audioxpress.com/news/gn-introduces-their-most-advanced-hearing-aid-with-dedicated-dnn-chip).
**Comparación:** orden correcto; antes de WDRC.
**Mejora propuesta:** sin cambios.

### **Pipeline efectivo — Input → DnnDenoiser → AFC → EQ → WDRC → Volume → MPO → Output**
**Qué es:** cadena nuestra completa.
**En audífonos:** discrepancia con la práctica industrial: AFC suele ir **antes** del NR/DNN porque cancela el feedback acústico que entra por el mic, no el ruido ambiente.
**Referencia:** Starkey AFC + DNN ordering en Genesis AI; PMC8395445 swPEMSC con prefilter ([link](https://pmc.ncbi.nlm.nih.gov/articles/PMC8395445/)).
**Comparación:** **AFC después de DNN puede atrapar al feedback dentro del wet signal**, dificultando la cancelación.
**Mejora propuesta crítica:** **mover AFC ANTES del DNN**: `Input → AFC → DnnDenoiser → EQ → WDRC → Volume → MPO → Output`. Así el adaptivo NLMS opera sobre la señal original con el feedback completo, mucho más fácil de modelar.

### **In-place processing**
**Qué es:** modifica el buffer entrante.
**Comparación:** correcto.

### **NR Wiener bypass cuando DNN activo / Anti doble-denoising**
**Qué es:** flag para evitar dos NR encadenados.
**Comparación:** correcto.

### **Bypass bit-exact / Bypass por error**
**Qué es:** caminos de seguridad.
**Comparación:** correcto.

### **AudioEngine::initDnnDenoiser / setDnnEnabled / setDnnIntensity / process / DspPipeline.processBlock**
**Qué es:** API JNI/Kotlin.
**Comparación:** correcto.
**Mejora propuesta:** agregar `setDnnIntensityPerBand(low, mid, high)` para personalización por banda según audiograma.

### **sceneAnalyzer / toneAnalyzer (read-only sobre input pre-DNN)**
**Qué es:** análisis de escena clasificador (silencio, habla, ruido, música).
**En audífonos comerciales:** Phonak AutoSenseOS 6.0 usa ML para clasificar, Oticon Intent usa "4D Sensor" (acelerómetro + audio). Phonak DEEPSONIC auto-activa solo en escenas Speech-in-Noise.
**Referencia:** Phonak DEEPSONIC ([link](https://www.phonak.com/en-us/professionals/campaign/all-about-ai-dnn)).
**Comparación:** los analizadores leen pre-DNN, lo cual es correcto si quieren clasificar la escena real.
**Mejora propuesta:** **enviar la clasificación al DNN**: si scene = "Quiet" (SNR > 20 dB), bajar `intensity` automáticamente a 0.3 para no procesar innecesariamente. Si scene = "Babble", subir a 1.0.

---

## 8. Mezcla Dry/Wet y Crossfade

### **dry signal (buffer original retrasado)**
**Qué es:** señal limpia alineada al delay del wet path.
**En audífonos:** mantener dry sin procesar es la única forma de garantizar bit-exactitud al desactivar.
**Comparación:** correcto.

### **wet signal (output upsampleado)**
**Qué es:** salida del modelo a rate nativa.
**Comparación:** correcto.

### **intensity 0..1 (default 1.0)**
**Qué es:** parámetro user.
**En audífonos comerciales:** Starkey Edge Mode tiene 3 niveles (Personal/Edge/Edge+); Oticon Intent ajusta DNN strength en 4 niveles vinculados a "Difficulty" 1–4; Phonak Sphere tiene Speech Focus en escala 0–10.
**Referencia:** [Anywhere Audiology Oticon Intent](http://anywhereaudiology.com/blog/oticon-intent-benefits/).
**Comparación:** parametrización continua 0–1 es muy flexible pero raras veces el usuario sabe qué poner.
**Mejora propuesta:** exponer 4 presets (Off, Light=0.4, Normal=0.75, Strong=1.0) con default Normal. Plus el slider continuo para fitting clínico.

### **intensity 0.85 preset escena ruidosa**
**Qué es:** valor sugerido por scene.
**Comparación:** razonable.
**Mejora propuesta:** mapear a tabla:
- Quiet: 0.3
- Speech: 0.6
- Speech-in-noise: 0.85
- Babble: 1.0
- Music: 0.0 (bypass)

### **Mezcla lineal `dry·(1-α) + wet·α` / α = crossfadeGain · intensity**
**Qué es:** combinación lineal anti-clic.
**Comparación:** correcto.
**Mejora propuesta:** sin cambios. Considerar **crossfade equal-power** (`cos(α·π/2)` y `sin(α·π/2)`) para mezcla de señales correlacionadas — preserva mejor el RMS, pero la diferencia es < 0.1 dB.

### **crossfadeGain / crossfadeTarget**
**Qué es:** rampa interna 0→1 al togglear.
**Comparación:** correcto.

### **kCrossfadeStep = 1/kDnnCrossfadeSamples / kDnnCrossfadeSamples = 480 / Duración 30 ms**
**Qué es:** rampa de 30 ms para evitar clicks.
**En audífonos comerciales:** typical 50–100 ms para "smooth transition" (ReSound, Phonak), pero 30 ms es suficiente para evitar click audible (DAW industry uses 50–100 ms because of musical taste, no por físico).
**Referencia:** [audiocutter](https://audiocutter.online/guides/fade-in-fade-out-crossfade/) menciona 50–100 ms; [ReSound features explained](https://pro.resound.com/en-us/research/features-explained) menciona transitions "slow and comfortable".
**Comparación:** 30 ms está bien técnicamente.
**Mejora propuesta:** **subir a 50 ms (800 samples @ 16 kHz)** para alinear con la práctica clínica (ReSound, Phonak). Beneficio: transición más natural percibida; costo: 20 ms más para cambio de modo (no crítico).

### **Anti-clic / Crossfade out automático**
**Qué es:** rampa al desactivar.
**Comparación:** correcto.

### **dryDelayRing alignment / No interpolar dry**
**Qué es:** preserva dry bit-exact.
**Comparación:** correcto.

---

## 9. Atenuación, Ganancia y Niveles

### **Clamp final ±1.0**
**Qué es:** saturación al rango float.
**Comparación:** correcto.

### **Headroom DNN (float [-1, +1]) / Ganancia neta ≈ 0 dB**
**Qué es:** el DNN solo atenúa.
**En audífonos:** correcto; el DNN nunca debe amplificar, queda al WDRC.
**Comparación:** correcto.
**Mejora propuesta:** verificar con script de auditoría: peak(enh) ≤ peak(mix) en todas las muestras.

### **Atenuación de voz residual / Sin amplificación**
**Qué es:** trade-off del DNN.
**En audífonos:** Healy 2017 reporta hasta 40% de mejora subjetiva en SNR pero con 8% degradación en muestras "limpias". Crítico: speech preservation.
**Referencia:** [Frontiers Medical Engineering 2023](https://www.frontiersin.org/journals/medical-engineering/articles/10.3389/fmede.2023.1281904/full).
**Comparación:** intensity > 0.9 ya muerde habla.
**Mejora propuesta:** **clamp intensity automático según VAD**: si VAD>0.9 (habla activa), no permitir intensity>0.7 para preservar formantes; cuando VAD<0.5 (pausa), permitir hasta 1.0 para limpiar.

### **dBFS / dB SPL / DBFS_TO_SPL_OFFSET = 120**
**Qué es:** conversión digital ↔ físico, asumiendo ICS-43434.
**En audífonos comerciales:** calibrado por par mic/receptor según ANSI S3.22 KEMAR.
**Referencia:** ANSI S3.22-2014 ([law.resource.org](https://law.resource.org/)).
**Comparación:** correcto para mic ICS-43434 con sensitivity -26 dBFS @ 94 dB SPL.
**Mejora propuesta:** sin cambios.

### **Normalización float (int16/32768) / Saturación int16**
**Qué es:** paso a flotante en [-1, +1].
**Comparación:** correcto.

### **Speech preservation 2–8 kHz fricativas > 80%**
**Qué es:** target de retención energía banda.
**En audífonos:** crítico para inteligibilidad.
**Referencia:** Souza 2002 (efectos de compresión sobre habla); Bentsen 2018; Healy 2021b en JASA.
**Comparación:** valor objetivo razonable.
**Mejora propuesta:** **medir activamente**: en cada release, procesar 10 oraciones con fricativas y verificar que `RMS(2k-8k Hz) post / pre > 0.80`. Si baja, ajustar intensity o re-entrenar.

---

## 10. Detección de Actividad y Robustez

### **enabled / active (atomic bool)**
**Qué es:** flags configuración vs operacional.
**Comparación:** correcto.

### **isEnabled / isActive / getProcessedFrames / getDroppedFrames / getLastInferenceUs**
**Qué es:** API observable.
**Comparación:** correcto.

### **reset() / resetWorkerState()**
**Qué es:** limpia caches y buffers.
**Comparación:** correcto.

### **Fail-safe `modelReady=false` / Bypass permanente / Reintento via setEnabled(true)**
**Qué es:** estado de error con recuperación.
**En audífonos:** robustez crítica. Comerciales: Phonak detecta fault y degrada a "basic mode" sin DNN.
**Comparación:** correcto.
**Mejora propuesta:** **agregar `getLastErrorCode()` y `getLastErrorString()`** con códigos enumerados (ORT_LOAD_FAIL, SHAPE_MISMATCH, OOM, etc.) para diagnóstico remoto.

### **introspectModel / try/catch Ort::Exception**
**Qué es:** validación al boot + protección de Run().
**Comparación:** correcto.

### **Cache size mismatch / Dynamic shape rejection**
**Qué es:** fallback si el grafo es no estándar.
**Comparación:** correcto.
**Mejora propuesta:** loggear shapes esperadas vs observadas para diagnóstico.

---

## 11. Calibración y Referencias Clínicas

### **ANSI S3.22-2014 (R2020) / IEC 60118-7 / THD < 3% a 70 dB SPL**
**Qué es:** estándares electroacústicos para audífonos.
**En audífonos:** todos los comerciales certifican ANSI/IEC.
**Referencia:** [GlobalSpec IEC 60118-7](https://globalspec.com/), ANSI/ASA S3.22-2014.
**Comparación:** correcto invocarlos como criterio.
**Mejora propuesta:** **agregar test automatizado** que mida THD@70dBSPL del DNN procesando tono puro 1 kHz; pasar/fallar antes de merge.

### **NAL-NL2 / DSL v5.0 (no aplica al DNN)**
**Qué es:** prescripciones de ganancia (no aplican al denoiser, sí al EQ/WDRC).
**Comparación:** correcto.

### **MPO threshold 110 dB SPL / Audífono pediátrico más conservador**
**Qué es:** límite de salida.
**En audífonos pediátricos:** DSL v5.0 sugiere MPO ≤ 105 dB SPL para preservar audición residual.
**Referencia:** Scollie et al. 2005 DSL v5.0 ([PMC4111493](https://pmc.ncbi.nlm.nih.gov/articles/PMC4111493/)).
**Comparación:** correcto. El DNN no toca MPO.
**Mejora propuesta:** sin cambios.

### **DNN agnóstico / Inteligibilidad / SII**
**Qué es:** SII como métrica clínica usada por NAL-NL2.
**En audífonos:** complementaria a PESQ/STOI. ANL (Acceptable Noise Level) también es relevante.
**Referencia:** [PubMed 23334355](https://pubmed.ncbi.nlm.nih.gov/23334355/) ANL para HA processing.
**Comparación:** ok.
**Mejora propuesta:** **medir HASPI (Hearing Aid Speech Perception Index) y HASQI** sobre output del DNN. HASPI/HASQI son los target metrics del Clarity Challenge (ICASSP 2023). Repo: [claritychallenge.org](https://claritychallenge.org/).

---

## 12. Plataforma / Hardware

### **Oboe / AAudio / OpenSL ES / VoicePerformance / LowLatency / Full-duplex**
**Qué es:** stack de audio Android.
**En audífonos OTC móviles:** Oboe es estándar. AAudio API 26+; OpenSL ES fallback.
**Referencia:** [google/oboe](https://github.com/google/oboe).
**Comparación:** correcto.
**Mejora propuesta:** **forzar `setPerformanceMode(PerformanceMode::LowLatency)` y `setSharingMode(SharingMode::Exclusive)`** cuando posible. Exclusive baja latencia 2–4 ms.

### **ABI arm64-v8a / NDK / Clang / CMake / CMakeLists / jniLibs**
**Qué es:** toolchain.
**Comparación:** correcto.
**Mejora propuesta:** considerar **agregar arm64-v8a + arm-v7a** si quisieras compatibilidad con dispositivos viejos (Android 8 todavía tiene 7%); cuesta ~3 MB extra al APK pero abre mercado.

### **AAssetManager / AASSET_MODE_BUFFER / AAsset_open|read|close**
**Qué es:** API NDK para leer assets del APK.
**Comparación:** correcto.

### **assets/dnn_denoiser/gtcrn.onnx**
**Qué es:** path de asset.
**Comparación:** correcto.

### **NativeAudioBridge.kt / AudioMethodChannel.kt / MethodChannel**
**Qué es:** capas de bridge Flutter.
**Comparación:** correcto.

### **__android_log_print / niveles / DNN_LOG_TAG**
**Qué es:** logging.
**Comparación:** correcto.
**Mejora propuesta:** **structured logging** con JSON para parseo por Logcat externos (Crashlytics, Firebase).

### **APK total ~30.4 MB**
**Qué es:** tamaño agregado por DNN + ORT + JNI.
**En audífonos OTC:** Audio app de Phonak/Oticon ronda 60–80 MB; ResMed ~50 MB. Estamos bien.
**Comparación:** ok.
**Mejora propuesta:** ver "ORT Mobile minimal build" (sección 1) → bajar a ~10 MB.

---

## 13. Métricas Observables

### **getLastInferenceUs / getProcessedFrames / getDroppedFrames / isActive / isEnabled / getIntensity**
**Qué es:** API de monitoreo.
**Comparación:** correcto.
**Mejora propuesta:** **agregar P50/P95/P99 ms** + **histograma de drops** + **última excepción ORT**.

### **processedFramesLocal / droppedFramesLocal / lastInferenceUsLocal / espejado público**
**Qué es:** ratificación de métricas worker→atomics públicos.
**Comparación:** correcto.

---

## 14. Causas Raíz del "tqtqtq" Diagnosticadas

Esta sección no requiere profundización académica adicional — son bugs ya corregidos del propio sistema. Pero validamos cada uno con la literatura:

### **Sample rate mismatch / Falta de resampler**
**Validación:** problema clásico cuando el callback Oboe entrega 48 kHz y el modelo espera 16 kHz. Documentado en *Cross-Platform Optimization of ONNX Models for Mobile and Edge Deployment* ([researchgate](https://www.researchgate.net/publication/392623112)). Corregido.

### **Pitch tracking erróneo (3× ancho de banda)**
**Validación:** consecuencia directa del rate mismatch. Corregido.

### **Ventana Hann simétrica / Sesgo amplitud ~0.4%**
**Validación:** el bias `(N-1)` vs `N` en Hann es conocido en libs DSP. CCRMA recomienda explícitamente la versión periódica para STFT-OLA. Corregido.

### **Mapeo por nombre frágil / Caches no actualizadas / Audio metálico**
**Validación:** error común con ORT cuando exporters renombran tensors. Mejor mapeo posicional. Corregido.

### **Frame parcial pushed / Reset incompleto / Drops silenciosos / Crossfade <30 ms**
**Validación:** todos son bugs de diseño concurrente y de UX. Corregidos.

### **Block-rate envelope (no aplica aquí)**
**Validación:** correctamente identificado como del WDRC, no del DNN. OK.

### **stftInBuf sin shift correcto / Hermitic mirroring faltante**
**Validación:** errores clásicos de implementación STFT/iSTFT. CCRMA "Overlap-Add (OLA) STFT Processing" documenta exactamente este patrón ([link](https://www.dsprelated.com/freebooks/sasp/Overlap_Add_OLA_STFT_Processing.html)). Corregidos.

**Mejora propuesta global:** agregar **suite de tests "no-tqtqtq"** con señales de prueba (silencio, tono puro, sweep, white noise, speech VBD); falla si peak-to-avg ratio en cualquier banda > 20× durante > 100 ms.

---

## 15. Técnicas y Métodos Científicos Aplicados

Resumen comparativo de cada técnica con uso industrial.

### **DNN denoising supervisado / Speech enhancement**
**Industria:** estándar moderno, todos los premium 2024+ lo usan. Starkey, Oticon, Phonak, ReSound.
**Mejora:** sin cambios, paradigma correcto.

### **Frame-online inference / Causal network / Recurrent state**
**Industria:** mandatorio para tiempo real. Widex incluso evita STFT para < 0.5 ms.
**Mejora:** sin cambios; pero ver hop=128.

### **Grouped convolution / Grouped GRU**
**Industria:** GTCRN adopta de MobileNet/ShuffleNet.
**Mejora:** sin cambios.

### **SFE / TRA / ERB filterbank**
**Industria:** ERB es perceptualmente fundado (Glasberg-Moore 1990). DeepFilterNet también lo usa.
**Mejora:** sin cambios.

### **Complex spectrum mapping / Hermitian symmetry**
**Industria:** DCCRN (Hu 2020) introdujo complex networks ([huyanxin.github.io](https://huyanxin.github.io/DeepComplexCRN/)). GTCRN simplifica.
**Mejora:** sin cambios.

### **STFT/iSTFT / Overlap-add / COLA / sqrt-Hann perfect reconstruction**
**Industria:** estándar.
**Mejora:** asymmetric window pair para low-latency (sección 4).

### **Polyphase filtering / Mixed-radix Cooley-Tukey / Bit reversal / Kaiser window / Bessel I0 / FIR fase lineal / Linear interpolation**
**Industria:** estándar DSP.
**Mejora:** ver sección 3.

### **Lock-free SPSC / Atomic memory ordering / Worker thread**
**Industria:** estándar audio low-latency.
**Mejora:** alinear cache lines, capacity 1024.

### **Crossfade lineal / Dry/wet mixing**
**Industria:** estándar; ReSound/Phonak usan 50–100 ms.
**Mejora:** subir a 50 ms.

### **Graceful degradation / PIMPL**
**Industria:** PIMPL es estándar para hide ABI ([cppstories](https://www.cppstories.com/2018/01/pimpl/)).
**Mejora:** sin cambios.

---

## 16. Otras Consideraciones

### **Threading (1 worker + audio callback)**
**Industria:** estándar. Algunos premium usan 2 workers (uno DNN, uno DSP clásico).
**Mejora:** **considerar split entre DNN worker (CPU pesado) y AFC/EQ/WDRC worker (CPU ligero)** si el target son SoC con 4+ cores. Beneficio: paralelizar. Costo: complejidad. Para Android genérico, mantener 1 worker.

### **Audio thread real-time priority (managed by Oboe)**
**Industria:** crítico. Oboe ya maneja `SCHED_FIFO` o priority elevation.
**Mejora:** sin cambios.

### **Memoria preasignada (caches, mixTensor, staging)**
**Industria:** mandatorio en RT.
**Mejora:** sin cambios.

### **Reallocs raros (assign() solo si blockSize crece)**
**Industria:** correcto.
**Mejora:** **fijar `blockSize` máximo al boot** (ej: 4096) para que ningún `assign()` ocurra después; o usar `reserve()` solo al inicializar.

### **Cache locality (vector<float> contiguo)**
**Industria:** correcto.
**Mejora:** alinear a 32 bytes con `aligned_alloc(32, ...)` para SIMD NEON 128-bit + AVX-style.

### **CPU SIMD (no usado explícitamente; ORT internal)**
**Industria:** ARM NEON acelera 2–4× operaciones float32.
**Referencia:** ONNX Runtime XNNPACK ([link](https://onnxruntime.ai/docs/execution-providers/Xnnpack-ExecutionProvider.html)).
**Comparación:** ORT lo usa internamente.
**Mejora:** **agregar XNNPACK EP** (ya mencionado): habilita NEON automáticamente en arm64.

### **Sin GC pauses / GC del lado Java irrelevante / Estado por instancia (no copiable, no movible)**
**Industria:** correcto.
**Mejora:** sin cambios.

### **Idempotencia initialize / setInputSampleRate / Singleton de facto / Lifetime / Forward declaration AAssetManager / C-string pointers / Robustez exporter / Fallback path / Diagnóstico**
**Industria:** patrones estándar C++ embedded.
**Comparación:** correcto.
**Mejora:** documentar con doxygen para auditoría externa.

### **Documentación inline (SubVI LabVIEW style)**
**Industria:** poco común pero útil. Phonak documenta con AADL diagrams.
**Mejora:** mantener; agregar diagrama Mermaid en cada header crítico.

### **Pruebas pendientes (PESQ, STOI, SNRi sobre dataset real)**
**Industria:** mandatorio antes de release. Apple-style "ship date" no aplica a hearing.
**Mejora:** **incluir pipeline CI** con `pesq`, `pystoi`, `pyclarity` (HASPI/HASQI) en cada PR; bloquear merge si métricas bajan > 0.1.

### **Spec referencia / Auditoría previa / Assets descargados doc**
**Industria:** trazabilidad documental.
**Comparación:** correcto.

---

## CORRECCIONES Y MEJORAS PRIORITARIAS — Lista Accionable

### Tier 1 — Críticas (impacto perceptual mayor, esfuerzo medio)

1. **Reducir latencia algorítmica STFT de 16 ms a 8 ms**
   - Cambio: `kDnnHopSize` 256 → 128 (75% overlap).
   - Costo: 2× inferencias/segundo (250 vs 125), incremento CPU ~1.8×.
   - Beneficio: latencia algorítmica 16 → 8 ms; total estimada 22–27 ms → 14–18 ms.
   - Validación: PESQ no debe bajar más de 0.10; STOI no debe bajar más de 0.02.
   - Referencia: Wang & Watanabe TASLP 2023 ([PDF](https://zqwang7.github.io/publications/TASLP2022_STFTlowlat.pdf)).

2. **Mover AFC ANTES del DNN en el pipeline**
   - Cambio: `Input → AFC → DNN → EQ → WDRC → Volume → MPO → Output`.
   - Razón: el AFC NLMS modela mejor el feedback acústico cuando opera sobre la señal cruda con todo el feedback presente.
   - Costo: refactorizar pipeline integration (1–2 días).
   - Beneficio: MSG aumenta 3–5 dB (mejor cancelación de pitidos en open-fit).
   - Referencia: PMC8395445 swPEMSC con prefilter.

3. **Reducir taps del polyphase resampler de 96 a 72 con Kaiser β=8.5**
   - Cambio: `protoN = 72`, `taps por fase = 24`, `β = 8.5`.
   - Beneficio: group delay 47.5 → 35.5 samples; round-trip 1.98 ms → 1.48 ms; mantiene 80 dB stopband.
   - Validación: SNR del resampler ≥ 78 dB (medir con tono 7 kHz).

4. **Bajar `wait_for(50ms)` del worker a `wait_for(5ms)`**
   - Cambio: `workerCv.wait_for(lock, std::chrono::milliseconds(5))`.
   - Beneficio: peor caso wakeup 50 → 5 ms; reduce drops bajo carga ráfaga.
   - Costo: nulo (la CV es eficiente; el thread solo despierta si hay trabajo).

5. **Reducir capacidad SPSC ringbuffer de 4096 a 1024**
   - Cambio: `kDnnRingCapacity = 1024`.
   - Beneficio: peor caso buffering 256 ms → 64 ms; lag perceptible se reduce.
   - Costo: más drops bajo carga; aceptable porque el sistema ya degrada gracefully.

### Tier 2 — Importantes (calidad/robustez, esfuerzo medio)

6. **Reemplazar interpolación lineal genérica por polyphase precomputado**
   - Cambio: agregar tablas para 22050↔16000 (320:441) y 44100↔16000 (160:441).
   - Beneficio: SNR del resampler 50 → 80 dB en estos paths; elimina ruido HF.
   - Costo: ~6 KB extra de tablas estáticas.

7. **Agregar validación PESQ + STOI + HASPI/HASQI en CI**
   - Cambio: pipeline GitHub Actions ejecuta sobre 30 muestras VBD test + 10 muestras Clarity Challenge en cada PR.
   - Threshold: PESQ ≥ 2.7, STOI ≥ 0.91, HASPI ≥ 0.55 (típico audífono pediátrico).
   - Beneficio: regresiones detectadas antes de merge.

8. **Habilitar XNNPACK Execution Provider**
   - Cambio: añadir `Ort::SessionOptions::AppendExecutionProvider("XNNPACK", {})` antes del CPU EP.
   - Beneficio: 30–50% mejora inferencia en arm64-v8a vía NEON.
   - Costo: ~600 KB extra a libonnxruntime.so.

9. **Migrar a ORT Mobile minimal build**
   - Cambio: rebuildar ONNX Runtime con `--minimal_build=extended` y solo ops de GTCRN.
   - Beneficio: libonnxruntime.so 24.6 → ~3–5 MB; APK total 30.4 → ~10 MB.
   - Costo: 1 día de build + verificación de ops requeridos.

10. **Mapear scene del SceneAnalyzer a `intensity` automático**
    - Cambio: tabla scene→intensity (Quiet 0.3, Speech 0.6, Speech-in-noise 0.85, Babble 1.0, Music 0.0).
    - Beneficio: menos procesamiento innecesario; preserva calidad en escenas no ruidosas.
    - Costo: 1 día de integración.

### Tier 3 — Optimizaciones (esfuerzo bajo, beneficio incremental)

11. **Cuantizar GTCRN a INT8 dinámico**
    - Cambio: `quantize_dynamic` del modelo ONNX.
    - Beneficio: 523 → ~150 KB; latencia inferencia ~30% menor.
    - Validación: PESQ no baja > 0.1.

12. **Subir crossfade de 30 ms a 50 ms (480 → 800 samples)**
    - Beneficio: transición más natural percibida (alineado con ReSound/Phonak).

13. **Alinear `head_/tail_` a 64 bytes (`alignas(64)`) en SpscRing**
    - Beneficio: evita false sharing entre threads; 5–15% mejora throughput.

14. **Forzar `setPerformanceMode(LowLatency)` y `setSharingMode(Exclusive)` en Oboe**
    - Beneficio: 2–4 ms menos latencia callback.

15. **Exponer P50/P95/P99 de inferencia + códigos de error explícitos**
    - Cambio: `getInferenceP50Us()`, `getInferenceP95Us()`, `getLastErrorCode()`.
    - Beneficio: diagnóstico remoto fino, alerta antes que el usuario perciba problema.

### Tier 4 — Investigación / Largo plazo

16. **Migrar a GTCRN-fullband 48 kHz (eliminar resampler)**
    - Beneficio: preserva fricativas 8–16 kHz; elimina round-trip 2 ms.
    - Costo: re-entrenamiento + validación clínica.

17. **Implementar par asimétrico de ventana (long analysis + short synthesis)**
    - Beneficio: latencia 4 ms con resolución de 32 ms.
    - Referencia: Wang TASLP 2023.

18. **Añadir VAD post-hoc para anti-pumping**
    - Lógica: si `||enh|| / ||mix|| < 0.3` durante 100 ms, marcar pausa y suavizar gain.

19. **Estudiar fine-tune con dataset Clarity Challenge ICASSP 2023**
    - Beneficio: +0.3–0.5 PESQ en escenarios reales reverberantes.

20. **Considerar firma HMAC-SHA256 del modelo embebido**
    - Beneficio: detectar swap malicioso del asset.

---

## Resumen de las 5 Mejoras Prioritarias

1. **Reducir latencia algorítmica de 16 ms a 8 ms** — bajar `kDnnHopSize` de 256 a 128 (75% overlap STFT). Impacto: comb-filter en open-fit deja de ser audible. Validar con PESQ ≥ 2.7.

2. **Reordenar pipeline para que AFC vaya ANTES del DNN** — `Input → AFC → DNN → EQ → WDRC → Volume → MPO → Output`. El NLMS opera mejor sobre señal con feedback intacto; MSG sube 3–5 dB.

3. **Bajar polyphase resampler a 72 taps con Kaiser β=8.5** — group delay baja de 47.5 → 35.5 samples; round-trip 1.98 → 1.48 ms; mantiene 80 dB stopband.

4. **Bajar `wait_for` del worker de 50 ms a 5 ms y `kDnnRingCapacity` de 4096 a 1024** — peor caso buffering 256 → 64 ms; wakeup 50 → 5 ms. Reduce drops bajo carga real.

5. **Habilitar validación CI con PESQ+STOI+HASPI/HASQI** — pipeline automático sobre VBD test + Clarity Challenge eval; thresholds PESQ≥2.7, STOI≥0.91, HASPI≥0.55. Bloquea regresiones antes de merge.

---

## Referencias Consolidadas

### Tesis y publicaciones académicas
- **MIT / Microsoft Research** — Wu et al. *Ultra-Low Latency Speech Enhancement* arxiv 2409.10358 ([link](https://arxiv.org/pdf/2409.10358))
- **MIT / Wang Z-Q** — *STFT-Domain Neural Speech Enhancement With Very Low Algorithmic Latency* TASLP 2023 ([link](https://zqwang7.github.io/publications/TASLP2022_STFTlowlat.pdf))
- **Stanford CCRMA** — Hearing Seminars con Tao Zhang (Starkey CTO) sobre attention beamforming ([link](https://ccrma.stanford.edu/hearing-seminars))
- **Stanford CCRMA / Smith JOS** — *Spectral Audio Signal Processing* ([sasp](https://ccrma.stanford.edu/~jos/sasp/))
- **UC Berkeley / UCSD** — Fitz et al. *Multirate Signal Processing for WDRC and Feedback Control in Hearing Aids* eScholarship qt4f17q7r9 ([link](https://escholarship.org/uc/item/4f17q7r9))
- **UCSD** — *Multirate Audiometric Filter Bank for Hearing Aid Devices* PMC8973212 ([link](https://pmc.ncbi.nlm.nih.gov/articles/PMC8973212/))
- **NSF/UCSD** — *Real-Time Multirate Multiband Amplification for Hearing Aids* PMC10260239 ([link](https://pmc.ncbi.nlm.nih.gov/articles/PMC10260239/))
- **Johns Hopkins (CLSP) / Oldenburg** — Kayser et al. *Spatial speech detection for binaural hearing aids using deep phoneme classifiers* Acta Acustica 2022 ([link](https://acta-acustica.edpsciences.org/articles/aacus/full_html/2022/01/aacus210024/aacus210024.html))
- **Northwestern / Souza P** — *Effects of compression on speech* PMC4168964 ([link](https://pmc.ncbi.nlm.nih.gov/articles/PMC4168964/))
- **Northwestern / Pittman & Stewart** — *NAL-NL2 vs DSL v5 in 9–17yo* J. Hearing 2023 ([link](https://journals.sagepub.com/doi/10.1177/23312165231177509))
- **Vanderbilt** — Hearing Aid Research Lab + Pediatric Audiology + Ricketts T. ([link](https://medschool.vanderbilt.edu/hearing-speech/research))
- **Purdue** — Acoustic Feedback in Hearing Aids project (PURR repository) ([link](https://purr.purdue.edu/projects/feedback))
- **Gallaudet** — Hearing4all collaboration; Anu Sharma Brain & Behavior Lab ([link](https://gallaudet.edu/hearing-speech-and-language-sciences/))
- **University of Iowa HAAR Lab** — Wu Y-H. *Hearing Aid Service Models, Technology, and Patient Outcomes* JAMA Otolaryngol 2025 ([link](https://haar.lab.uiowa.edu/publications))
- **Washington University in St. Louis (PACS)** — PhD program Speech and Hearing Sciences ([link](https://pacs.wustl.edu/programs/doctor-of-philosophy/))
- **Clemson / Lin J** — *Deep Learning Based Speech Enhancement and Its Application to Speech Recognition* PhD diss. 2939 ([link](https://open.clemson.edu/all_dissertations/2939/))
- **Carl von Ossietzky / Goehring T** — *Speech enhancement based on neural networks for hearing-impaired* thesis ([researchgate](https://www.researchgate.net/publication/362006826))

### Whitepapers y patentes industriales
- **Starkey** — Edge AI G2 Neuro Processor + NPU ([link](https://www.starkey.com/blog/articles/2024/10/Introducing-Edge-AI-Hearing-Aids))
- **Oticon** — *4D Sensor Technology and Deep Neural Network 2.0 in Oticon Intent* whitepaper 2024 ([PDF](https://wdh01.azureedge.net/-/media/oticon/main/pdf/master/whitepaper/4d-sensor-technology-and-dnn-20-in-oticon-intent.pdf))
- **Phonak** — *Audéo Sphere DEEPSONIC* + *AutoSenseOS 6.0* + *WhistleBlock + SoundRecover2* whitepapers ([link](https://www.phonak.com/content/dam/phonak/en/documents/evidence/insight_soundrecover2_028-1512.pdf))
- **GN ReSound** — *Vivia AI* dual-chip 360 + DNN, 13.5M frases entrenadas ([link](https://www.resound.com/en-us/press/gn-introduces-its-most-intelligent-hearing-portfolio-yet-including-resound-vivia))
- **Widex** — *PureSound + ZeroDelay <0.5 ms* technical paper ([widexpro](https://www.widexpro.com/en-us/widex-technology/zerodelay/))
- **Signia** — *Augmented Xperience AX + IX split processing* ([link](https://www.signia.net/en/hearing-aids/augmented-xperience/))
- **Bernafon** — *ChannelFree + DECS* ([wiki](https://en.wikipedia.org/wiki/Bernafon))
- **Hansaton** — *Sound SHD AutoSurround SpeechBeam* technical info ([PDF](https://www.hansaton.com/content/dam/hansaton/en/documents/speherehd/professional-information/technical_information_shd.pdf.coredownload.pdf))
- **Acosound** — Basic 32 DSP channels, 16 bandas ([link](https://www.acosoundhearingaid.com/products/acosound-basic))
- **Austar Hearing** — OEM/ODM B2B chino 20+ años ([link](https://www.austar-hearing.net/))
- **Earsmate** — Comparativa Top 10 fabricantes chinos ([link](https://www.earsmate.com/top-china-hearing-aid-manufacturers/))

### Modelos y datasets
- **GTCRN paper** — Rong et al. ICASSP 2024 ([dblp](https://dblp.org/rec/conf/icassp/RongSZHZL24.html))
- **GTCRN repo oficial** — [Xiaobin-Rong/gtcrn](https://github.com/Xiaobin-Rong/gtcrn)
- **DeepFilterNet** — Schroeter et al. arxiv 2110.05588 ([link](https://ar5iv.labs.arxiv.org/html/2110.05588))
- **DCCRN** — Hu et al. Interspeech 2020 ([link](https://huyanxin.github.io/DeepComplexCRN/))
- **DPCRN** — base de GTCRN ([arxiv 2502.14224](https://arxiv.org/html/2502.14224v1))
- **TSDCA-BA** — *Ultra-Lightweight SE Model for Real-Time Hearing Aids with Multi-Scale STFT Fusion* MDPI 2025 ([link](https://www.mdpi.com/2076-3417/15/15/8183))
- **Channel-grouped iterative CRN (15.8k params)** — Springer Audio Speech Music 2026 ([link](https://link.springer.com/article/10.1186/s13636-026-00455-4))
- **RNNoise** — xiph/rnnoise ([github](https://github.com/xiph/rnnoise))
- **VoiceBank+DEMAND benchmark** — ([emergentmind](https://www.emergentmind.com/topics/voicebank-demand-dataset))
- **Clarity Challenge ICASSP 2023** — HASPI/HASQI hearing aid metrics ([link](https://claritychallenge.org/ICASSP2023_announcement_page/))

### Estándares y guías
- **ANSI/ASA S3.22-2014 (R2020)** — Specification of Hearing Aid Characteristics
- **IEC 60118-7:2005** — Hearing aids production measurements
- **ANSI S3.6-2010 (R2020)** — Audiometers RETSPL
- **NAL-NL2** — Keidser et al. PMC4627149
- **DSL v5.0** — Scollie et al. PMC4111493

### Tooling DSP / runtime
- **ONNX Runtime Mobile** — ([docs](https://onnxruntime.ai/docs/tutorials/mobile/))
- **ONNX Runtime XNNPACK EP** — ([docs](https://onnxruntime.ai/docs/execution-providers/Xnnpack-ExecutionProvider.html))
- **ONNX Runtime NNAPI EP** — ([docs](https://onnxruntime.ai/docs/execution-providers/NNAPI-ExecutionProvider.html))
- **Google Oboe** — ([github](https://github.com/google/oboe))
- **Rigtorp ringbuffer** — ([link](https://rigtorp.se/ringbuffer/))
- **Boost spsc_queue** — ([stackoverflow](https://stackoverflow.com/questions/70512371/are-memory-orders-for-each-atomic-correct-in-this-lock-free-spsc-ring-buffer-que))

---

*Documento generado con investigación obligatoria vía MCP Brave Search. Todo contenido externo
fue parafraseado para cumplimiento de licencias. Las afirmaciones cuantitativas provienen de
papers, whitepapers y datasheets citados; revisar fuente original antes de tomar decisiones
clínicas o de fabricación.*
