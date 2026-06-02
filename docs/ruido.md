# Diccionario del Sistema de Limpieza de Ruido (DNN GTCRN)

> Diccionario exhaustivo de TODO lo que participa, influye o interviene en el pipeline
> de denoising por red neuronal del audífono PSK Hearing Aid (Android · Oboe · ONNX).
> Cada viñeta = un único término técnico con su valor numérico cuando aplica.

---

## 1. Modelo de IA / Red Neuronal

- **GTCRN** — Grouped Temporal Convolutional Recurrent Network (modelo elegido).
- **GTCRN simple** — variante "simple" exportada a ONNX (~523 KB).
- **Paper origen** — ICASSP 2024, IEEE 10448310, Xiaobin-Rong/gtcrn.
- **Backbone** — DPCRN simplificado con estrategias agrupadas.
- **ERB filter bank** — banco perceptual que reduce redundancia del input.
- **Grouped convolution** — conv 2D con grupos para reducir cómputo.
- **Grouped RNN** — GRU agrupada para bajar complejidad.
- **SFE (Subband Feature Extraction)** — módulo de features por subbanda.
- **TRA (Temporal Recurrent Attention)** — atención temporal recurrente.
- **Causal** — frame-online, sin lookahead (apto tiempo real).
- **Speech enhancement** — denoising supervisado de voz.
- **Modelo agnóstico al perfil** — no depende de NAL-NL2/DSL v5.
- **Dataset entrenamiento típico** — VoiceBank+DEMAND.
- **Métrica académica** — WB-PESQ, STOI, SI-SDR.
- **Ultralightweight** — diseñado para "ultralow computational resources".
- **Asset path** — `assets/dnn_denoiser/gtcrn.onnx`.
- **SHA256 modelo** — `E77603AC0C23DAC3227DD2D7135B3A585CBEE2679048AECFA886657D3AE1B534`.
- **Tamaño binario** — 535 638 bytes (≈ 523 KB).
- **Formato** — ONNX (Open Neural Network Exchange).
- **Runtime** — Microsoft ONNX Runtime (full build, no mobile).
- **libonnxruntime.so** — 24.6 MB, arm64-v8a.
- **libsherpa-onnx-jni.so** — 4.4 MB (incluido pero no usado).
- **Origen binarios** — sherpa-onnx v1.13.2 release tarball.
- **Ort::Env** — env global con `ORT_LOGGING_LEVEL_WARNING`.
- **Ort::SessionOptions** — opciones de sesión.
- **IntraOpNumThreads** — 1 (single-thread).
- **InterOpNumThreads** — 1 (single-thread).
- **GraphOptimizationLevel** — `ORT_ENABLE_ALL`.
- **Ort::Session** — sesión de inferencia (única).
- **Ort::MemoryInfo** — `OrtArenaAllocator`, `OrtMemTypeDefault`, CPU.
- **Provider** — CPUExecutionProvider (default).
- **NNAPI provider** — disponible pero no habilitado.
- **Inputs del modelo (4 tensores)** — `mix`, `conv_cache`, `tra_cache`, `inter_cache`.
- **Outputs del modelo (4 tensores)** — `enh`, `conv_cache`, `tra_cache`, `inter_cache`.
- **Mapeo posicional** — `inputs[0]=mix`, `inputs[1..3]=caches`.
- **Mapeo por nombre** — eliminado (causaba "metálico" silencioso).
- **mix shape** — `[1, 257, 1, 2]` (B, F, T, complejo).
- **enh shape** — idéntica a mix.
- **257 bins** — `FFT/2 + 1` (espectro hasta Nyquist).
- **Cache recurrente** — estado persistente entre frames.
- **conv_cache** — buffers de convs causales.
- **tra_cache** — estado de la atención temporal recurrente.
- **inter_cache** — estado inter-frame.
- **Caches inicializadas** — vector de ceros al startup y al `reset()`.
- **shapeNumel()** — producto de dims para preallocar caches.
- **Frame del modelo** — 256 samples = 16 ms @ 16 kHz.
- **VAD** — el modelo no expone probabilidad explícita en GTCRN simple.
- **SNR improvement objetivo** — 8–12 dB.
- **Speech distortion target** — < 5%.
- **lazy initialization** — modelo se carga al primer `initialize()`.
- **modelReady (bool)** — flag interno post-introspección.

## 2. Sample Rates y Conversiones

- **kDnnSampleRate** — 16 000 Hz (rate nativa GTCRN).
- **Native Oboe sample rate** — 48 000 Hz (típico).
- **Ratio 3:1** — 48 kHz ↔ 16 kHz (`M = L = 3`).
- **inputSr (variable)** — rate observado por el wrapper.
- **effectiveSampleRate** — el que negocia Oboe (16 000 o 48 000).
- **Caso 16 kHz** — bypass del resampler (identidad).
- **Caso 48 kHz** — polyphase 3:1.
- **Caso otros (22050, 44100)** — interpolación lineal genérica.
- **downsample** — input nativo → 16 kHz (antes del worker).
- **upsample** — 16 kHz enhanced → rate nativa (después del worker).
- **Round-trip** — down + up = ~2 ms a 48 kHz.
- **Identity mode** — `memcpy` puro, sin estado.
- **Bit-exact bypass** — cuando enabled=false y crossfadeGain=0.

## 3. Resampler (filtro de re-muestreo)

- **Polyphase FIR** — banco de subfiltros por fase.
- **Prototipo LPF** — filtro pasabajos compartido down/up.
- **96 taps** — longitud del prototipo.
- **32 taps por fase** — `protoN / L = 96/3 = 32`.
- **fc** — 7 500 Hz (cutoff midpoint banda transición).
- **fc normalizado** — 0.15625 (`7500/48000`).
- **Banda de transición** — 7–8 kHz (~1 kHz de ancho).
- **Ventana Kaiser** — β = 8 (≈80 dB stopband).
- **Bessel I0** — `besselI0Approx` (Abramowitz & Stegun 9.8.1/9.8.2).
- **Sinc ideal** — `2·fc·sinc(2·fc·(n-center))`.
- **Center** — `(N-1)/2` = 47.5.
- **Normalización DC** — suma de coeficientes = 1.0.
- **Down compensation** — proto con DC=1 para downsample.
- **Up compensation** — multiplicar polyphase por L (=3) por inserción de ceros.
- **Group delay (samples)** — `(N-1)/2 = 47.5`.
- **Group delay down** — ≈ 0.99 ms a 48 kHz.
- **Group delay up** — ≈ 0.99 ms a 48 kHz.
- **Lineal genérico** — interpolación entre `last` y `next` con frac.
- **linearRatio** — `inputRate / outputRate` (down) o inverso (up).
- **linearAccum** — fracción acumulada.
- **linearLast** — último sample consumido.
- **Resampler::Mode** — enum `kIdentity | kPolyDown48to16 | kPolyUp16to48 | kLinearGeneric`.
- **delay line** — buffer circular (96 floats poly / 1 float lineal).
- **writeIdx** — índice circular del delay.
- **phase counter** — fase actual del polyphase.
- **stateful** — preserva estado entre llamadas.
- **Idempotente** — `configure()` no resetea si la rate no cambió.
- **Realloc fuera del hot path** — staging crece con `.assign()` raro.
- **Calidad** — alta (Kaiser β=8) en 48↔16; suficiente lineal en otros.
- **Fase lineal** — sí en polyphase (filtro simétrico).

## 4. Análisis y Síntesis Espectral (STFT/iSTFT)

- **STFT** — Short-Time Fourier Transform.
- **iSTFT** — Inverse STFT (por overlap-add).
- **kDnnFftSize** — 512.
- **kDnnHopSize** — 256 (50% overlap).
- **Hop ratio** — `hop = N/2`.
- **fftRadix2** — Cooley-Tukey radix-2 in-place.
- **Bit-reversal permutation** — pre-fase del FFT.
- **Cooley-Tukey butterflies** — núcleo del FFT.
- **fftRe / fftIm** — workspace `[512]` cada uno.
- **Ventana Hann periódica** — `0.5·(1-cos(2πi/N))`.
- **Hann simétrica (descartada)** — denominador `(N-1)` introducía sesgo ~0.4%.
- **sqrt-Hann** — aplicada en análisis y síntesis.
- **COLA** — Constant Overlap-Add con hop=N/2.
- **Unity-gain OLA** — suma de window² = 1 al solapar.
- **stftInBuf** — buffer deslizante `[512]`.
- **olaBuf** — acumulador overlap-add `[512]`.
- **outputFrame** — 256 samples extraídos del olaBuf.
- **Bins espectrales** — 257 (`FFT/2 + 1`).
- **Simetría hermítica** — reconstrucción real conjugando bins espejo.
- **Packing complex** — pares `[Re, Im]` por bin.
- **Freq dim detection** — busca dim con tamaño 257 en mix shape.
- **Shape esperada** — `[1, 257, 1, 2]`.
- **Frame rate del modelo** — 1 frame cada 256 samples = 62.5 fps.
- **Latencia STFT algorítmica** — 1 hop = 256 samples = 16 ms @ 16 kHz.

## 5. Buffering y Concurrencia

- **SpscRing** — single-producer single-consumer ring buffer.
- **Lock-free** — operaciones no bloqueantes en ambas direcciones.
- **Capacidad** — `kDnnRingCapacity = 4096` (potencia de 2).
- **Mask** — `capacity - 1` para wrap-around.
- **head_ / tail_** — atomics int.
- **memory_order_acquire** — al leer del lado opuesto.
- **memory_order_release** — al publicar avance.
- **memory_order_relaxed** — al leer el propio índice.
- **inputRing** — audio thread → worker (samples 16 kHz).
- **outputRing** — worker → audio thread (samples 16 kHz).
- **dryDelayRing** — audio thread → audio thread (rate nativa).
- **freeSpace()** — espacio libre productor.
- **available()** — datos disponibles consumidor.
- **push() / pop()** — devuelven cantidad real procesada.
- **clear()** — vacía desde el consumidor (sólo si productor inactivo).
- **Audio thread (callback Oboe)** — single-producer.
- **Worker thread** — `std::thread` en GTCRN.
- **workerRun (atomic bool)** — flag de vida del worker.
- **resetRequested (atomic bool)** — flag de reset deferido.
- **workerMtx** — mutex para condition variable.
- **workerCv** — `std::condition_variable` con `wait_for(50 ms)`.
- **notify_one** — al subir umbral de hop disponible.
- **Drop policy** — descarta frame entero si no hay espacio TOTAL.
- **Underrun policy** — sale dry inalterado si worker no alcanza tasa.
- **Capacidad temporal** — 4096 samples ≈ 256 ms de buffer.

## 6. Latencia

- **Latencia algorítmica STFT** — hop = 256 samples = 16 ms.
- **Latencia GTCRN frame** — 16 ms a 16 kHz.
- **Group delay resampler down** — ~0.99 ms.
- **Group delay resampler up** — ~0.99 ms.
- **Round-trip resampler** — ~2 ms.
- **Buffering del worker** — variable, hasta 256 ms en peor caso.
- **Latencia total esperada** — 22–27 ms.
- **inferenceTimeMs target** — < 16 ms (para no perder tiempo real).
- **lastInferenceUs** — métrica observable en µs.
- **CPU load target** — < 5% en arm64-v8a moderno.
- **Block time Oboe** — ~4 ms (192 frames @ 48 kHz).
- **Latency monitor** — graceful degradation si excede budget.

## 7. Pipeline DSP (Orden de Etapas)

- **Posición del DNN** — entre Input y EQ (reemplaza al NR Wiener clásico).
- **Pipeline efectivo** — Input → DnnDenoiser → AFC → EQ → WDRC → Volume → MPO → Output.
- **In-place processing** — modifica el buffer de entrada (sin copia extra).
- **NR Wiener bypass** — `pipeline_.setNrBypassed(true)` cuando DNN activo.
- **Anti doble-denoising** — sólo uno de los dos NR está activo.
- **Bypass bit-exact** — return inmediato si `!enabled && crossfade==0`.
- **Bypass por error** — si `isActive=false` el wrapper hace passthrough.
- **AudioEngine::initDnnDenoiser()** — entry-point de carga.
- **AudioEngine::setDnnEnabled()** — toggle wrapper + setNrBypassed.
- **AudioEngine::setDnnIntensity()** — ajusta dry/wet 0..1.
- **dnnDenoiser_.process(outPtr, numFrames)** — invocación por callback.
- **DspPipeline.processBlock()** — invocado DESPUÉS del DNN.
- **sceneAnalyzer_.process()** — read-only sobre input pre-DNN.
- **toneAnalyzer_.process()** — read-only sobre input pre-DNN.

## 8. Mezcla Dry/Wet y Crossfade

- **dry signal** — buffer original retrasado (alineado 1:1).
- **wet signal** — output del modelo upsampleado a rate nativa.
- **intensity** — float `[0, 1]`, default 1.0 (100% wet).
- **intensity 0.85** — preset por escena ruidosa.
- **Mezcla lineal** — `out = dry·(1-α) + wet·α`.
- **α efectivo** — `crossfadeGain · intensity`.
- **crossfadeGain** — float `[0, 1]` (0=dry, 1=wet).
- **crossfadeTarget** — 1.0 si enabled, 0.0 si bypass.
- **kCrossfadeStep** — `1 / kDnnCrossfadeSamples` por sample.
- **kDnnCrossfadeSamples** — 480 samples.
- **Duración crossfade** — 30 ms (480/16000).
- **Anti-clic** — rampa lineal evita transiente al togglear.
- **Crossfade out automático** — al perder `isActive`.
- **dryDelayRing alignment** — preserva dry bit-exact a la rate nativa.
- **No interpolar dry** — evita degradar señal limpia.

## 9. Atenuación, Ganancia y Niveles

- **Clamp final** — `±1.0` por seguridad (anti-overflow).
- **Headroom DNN** — el modelo opera en float `[-1, +1]`.
- **Ganancia neta** — ≈ 0 dB (sólo atenúa ruido).
- **Atenuación de voz residual** — riesgo si intensity > 0.9.
- **Sin amplificación** — el DNN nunca añade ganancia.
- **dBFS** — escala digital usada en niveles.
- **dB SPL** — escala física (offset depende del transductor).
- **DBFS_TO_SPL_OFFSET** — 120 dB (modo realtime, ICS-43434).
- **Normalización float** — int16/32768 → float `[-1, +1]`.
- **Saturación int16** — al final del pipeline post-MPO.
- **Speech preservation 2–8 kHz** — fricativas conservadas > 80%.

## 10. Detección de Actividad y Robustez

- **enabled (atomic bool)** — flag de configuración usuario.
- **active (atomic bool)** — flag operacional (modelo OK + worker vivo).
- **isEnabled()** — retorna `enabled_`.
- **isActive()** — retorna `active_`.
- **getProcessedFrames()** — uint64_t, monotónico.
- **getDroppedFrames()** — uint64_t, drops por congestión.
- **getLastInferenceUs()** — uint32_t, última latencia inferencia.
- **reset()** — flag deferido para worker + clear de rings.
- **resetWorkerState()** — limpia caches, stftInBuf, olaBuf, fftRe/Im.
- **Fail-safe** — `modelReady=false` ante excepción ONNX.
- **Bypass permanente** — tras fallo hasta nuevo `initialize()`.
- **Reintento** — `setEnabled(true)` puede pedir reactivación.
- **introspectModel** — valida shapes y nombres antes de correr.
- **try/catch Ort::Exception** — protege `Run()`.
- **Cache size mismatch detection** — falla si #inputs ≠ #outputs caches.
- **Dynamic shape rejection** — falla si dim ≤ 0 (no preallocable).

## 11. Calibración y Referencias Clínicas

- **ANSI S3.22-2014 (R2020)** — características electroacústicas audífonos.
- **IEC 60118-7** — mediciones de control de calidad audífonos.
- **THD < 3% a 70 dB SPL** — criterio IEC 60118-7.
- **NAL-NL2** — prescripción adultos (no aplica al DNN).
- **DSL v5.0** — prescripción pediátrica (no aplica al DNN).
- **MPO threshold** — 110 dB SPL típico.
- **Audífono pediátrico** — más conservador en MPO.
- **DNN agnóstico** — mismo modelo para adultos y niños.
- **Inteligibilidad** — métrica clínica primaria.
- **Speech Intelligibility Index (SII)** — usado en NAL-NL2.

## 12. Plataforma / Hardware

- **Oboe** — librería de audio low-latency Android.
- **AAudio** — backend preferido (API 26+).
- **OpenSL ES** — fallback legacy.
- **VoicePerformance / LowLatency** — perfomance modes.
- **Full-duplex stream** — input + output sincronizados.
- **ABI** — `arm64-v8a` (AArch64).
- **Android NDK** — toolchain de build.
- **Clang** — compilador.
- **CMake** — build system.
- **CMakeLists.txt** — define `dnn_denoiser` como target.
- **jniLibs/arm64-v8a/** — `.so` empaquetados al APK.
- **AAssetManager** — handle nativo a `assets/`.
- **AASSET_MODE_BUFFER** — modo de apertura para lectura completa.
- **AAsset_open / AAsset_read / AAsset_close** — API NDK assets.
- **assets/dnn_denoiser/gtcrn.onnx** — ruta dentro del APK.
- **NativeAudioBridge.kt** — capa Kotlin de JNI.
- **AudioMethodChannel.kt** — canal Flutter ↔ Kotlin.
- **MethodChannel** — bridge Dart ↔ plataforma.
- **__android_log_print** — logging nativo.
- **ANDROID_LOG_INFO/WARN/ERROR** — niveles de log.
- **DNN_LOG_TAG** — `"DnnDenoiser"`.
- **APK total agregado** — ~30.4 MB (modelo + ORT + JNI).

## 13. Métricas Observables

- **getLastInferenceUs()** — microsegundos última `Run()`.
- **getProcessedFrames()** — frames de 256 procesados.
- **getDroppedFrames()** — frames descartados (worker o ring lleno).
- **isActive()** — bool operacional.
- **isEnabled()** — bool configuración.
- **getIntensity()** — float actual.
- **processedFramesLocal** — contador interno worker.
- **droppedFramesLocal** — drops internos worker.
- **lastInferenceUsLocal** — espejo en Impl.
- **Espejado público** — sincroniza atomics expuestos cada bloque.

## 14. Causas Raíz del "tqtqtq" Diagnosticadas

- **Sample rate mismatch** — Oboe daba 48 kHz, modelo esperaba 16 kHz, sin resampler.
- **Falta de resampler** — pipeline original nunca convertía 48↔16.
- **Pitch tracking erróneo** — al asumir 48 kHz, ERB y bandas operaban sobre 3× ancho de banda.
- **Ventana Hann simétrica** — denominador `(N-1)` rompía COLA exacta.
- **Sesgo de amplitud Hann** — ~0.4% por bin no esperado por el modelo.
- **Mapeo por nombre frágil** — substring `"mix"`/`"enh"` fallaba con exporters renombrados.
- **Caches no actualizadas** — al fallar el match por nombre quedaban en cero.
- **Audio "metálico" tras segundos** — síntoma del cache estático.
- **Frame parcial pushed** — desalineaba dryDelayRing → clicks periódicos.
- **Reset incompleto** — al cambiar SR no se limpiaba dryDelayRing y resamplers.
- **Drops silenciosos** — si outputRing estaba lleno se mezclaba half-frame (causaba "tqtqtq").
- **Crossfade demasiado corto** — clicks audibles si era < 30 ms.
- **Block-rate envelope** — no aplicable aquí (es DNN, no WDRC).
- **stftInBuf sin shift correcto** — desfase de hop generaba ruido modulado.
- **Hermitic mirroring faltante** — bins negativos sin conjugar daban distorsión.

## 15. Técnicas y Métodos Científicos Aplicados

- **DNN denoising supervisado** — pares `(noisy, clean)`.
- **Speech enhancement** — paradigma del modelo.
- **Frame-online inference** — frame a frame, sin batch.
- **Causal network** — sin acceso al futuro.
- **Recurrent state** — caches que reemplazan al lookahead.
- **Grouped convolution** — reduce parámetros y FLOPs.
- **Grouped GRU** — RNN agrupada.
- **Subband Feature Extraction (SFE)** — features por sub-banda.
- **Temporal Recurrent Attention (TRA)** — atención temporal.
- **ERB filterbank** — bandas perceptuales.
- **Complex spectrum mapping** — `mix → enh` en dominio complejo.
- **Hermitian symmetry** — para reconstrucción real desde 257 bins.
- **STFT/iSTFT** — análisis-síntesis espectral.
- **Overlap-add (OLA)** — recombinación temporal.
- **COLA constraint** — Constant Overlap-Add.
- **sqrt-Hann perfect reconstruction** — análisis·síntesis = ventana² unity sum.
- **Polyphase filtering** — descomposición eficiente del FIR.
- **Mixed-radix Cooley-Tukey** — base del FFT (radix-2 aquí).
- **Bit reversal** — permutación inicial del FFT.
- **Kaiser window** — ventana paramétrica para LPF.
- **Bessel I0** — base de Kaiser.
- **FIR fase lineal** — group delay constante.
- **Linear interpolation** — fallback genérico de re-muestreo.
- **Lock-free SPSC** — concurrencia sin mutex.
- **Atomic memory ordering** — acquire/release/relaxed.
- **Worker thread** — desacopla DSP pesado del callback realtime.
- **Crossfade lineal** — anti-clic en transiciones.
- **Dry/wet mixing** — control fino de agresividad.
- **Graceful degradation** — bypass ante drop o latencia excesiva.
- **PIMPL** — oculta dependencias ONNX al header consumidor.

## 16. Otras Consideraciones

- **Threading** — 1 worker dedicado + audio callback Oboe.
- **Audio thread real-time priority** — managed por Oboe.
- **Memoria preasignada** — caches, mixTensor y staging fuera del hot path.
- **Reallocs raros** — `assign()` sólo si blockSize crece.
- **Cache locality** — buffers contiguos (`std::vector<float>`).
- **CPU SIMD** — no usado explícitamente (ORT puede usar internamente).
- **Sin GC pauses** — C++ puro, no JVM.
- **GC del lado Java** — irrelevante (no hay JNI en hot path).
- **Estado por instancia** — clase no copiable ni movible.
- **DnnDenoiser(const&) = delete** — no copy.
- **operator=(const&) = delete** — no assign.
- **Idempotencia** — `initialize()` y `setInputSampleRate()` son seguros de llamar de nuevo.
- **Singleton de facto** — `dnnDenoiser_` miembro único de `AudioEngine`.
- **Lifetime** — destructor detiene worker y libera sesión.
- **Forward declaration de AAssetManager** — evita arrastrar `<android/asset_manager.h>`.
- **C-string pointers** — `inputNameCStr`/`outputNameCStr` apuntan a `std::string` propios.
- **Robustez exporter** — soporta nombres genéricos `input_0`, `output_0`.
- **Fallback path** — log warning si #inputs ≠ 4 o #outputs ≠ 4.
- **Diagnóstico** — logs `Input[i]` y `Output[i]` con shape al boot.
- **Documentación inline** — bloques estilo SubVI LabVIEW en headers.
- **Pruebas pendientes** — PESQ, STOI y SNRi sobre dataset real.
- **Spec referencia** — `.kiro/specs/rnnoise-dnn-denoiser/design.md`.
- **Auditoría previa** — `Amplificador/docs/auditoria-rnnoise-existente.md`.
- **Assets descargados doc** — `Amplificador/docs/dnn-assets-downloaded.md`.

---

*Última actualización: tras el ajuste que eliminó el artefacto "tqtqtq".
Cubre todos los parámetros y técnicas que afectan el comportamiento del DNN denoiser
(GTCRN) en la app PSK Hearing Aid sobre Android + Oboe + ONNX Runtime.*
