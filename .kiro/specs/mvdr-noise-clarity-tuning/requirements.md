# Requirements Document

## Introduction

Este spec define las mejoras de calidad de audio necesarias para llevar el modo MVDR (beamforming de 2 micrófonos) de un audífono digital pediátrico a un nivel apto para producción. El modo MVDR ya funciona a nivel de captación direccional, pero mediciones reales sobre grabaciones del dispositivo Moto G32 (ambiente doméstico con voces) revelaron cuatro defectos confirmados que degradan la calidad percibida: (1) hiss/ruido residual amplificado en silencios, (2) un estimador de ruido/SNR roto que satura y produce valores irreales, (3) un perfil espectral "boomy" con exceso de graves-medios y agudos caídos que reduce la nitidez de consonantes, y (4) un clasificador de escena que nunca converge y reporta "unknown" en el 100% de las muestras.

El sistema de procesamiento (Sistema_DSP) reside en la cadena nativa C++ ubicada en `Repo Oir Pro2\Audifon\android\app\src\main\cpp\` y se propaga al paciente cuando este clona el código del técnico. La cadena de procesamiento es: micrófono → MVDR/DNN → EQ (12 bandas) → WDRC → Volumen → MPO → salida. Las mejoras deben ser configurables/toggleables, no romper los modos existentes (Bypass, DNN dual, MVDR), preservar la seguridad clínica (MPO/limitador, no exceder UCL) y marcar explícitamente cualquier cambio que afecte la prescripción del paciente.

Las soluciones propuestas cuentan con respaldo científico citado en cada requisito.

## Glossary

- **Sistema_DSP**: Motor de procesamiento de señal digital implementado en C++ (`dsp_pipeline.h`/`.cpp`, `mvdr_beamformer.h`, `environment_classifier.h`/`.cpp`, `audio_engine.cpp`) que procesa el audio en tiempo real mediante Oboe FullDuplexStream.
- **Expansor**: Componente del Sistema_DSP que aplica expansión hacia abajo (downward expansion) por debajo del punto de rodilla (knee) del WDRC para atenuar la ganancia en niveles de entrada bajos.
- **WDRC**: Wide Dynamic Range Compression; compresor multibanda que aplica la ganancia prescriptiva del audífono.
- **Estimador_Ruido**: Componente del Sistema_DSP que estima el piso de ruido y la relación señal-ruido (SNR) del audio de entrada.
- **SNR**: Relación señal-ruido estimada, expresada en decibelios (dB).
- **SceneAnalyzer**: Módulo del `environment_classifier` que estima SNR, ruido y VAD (detección de actividad de voz).
- **Environment_Classifier**: Clasificador de entorno acústico que asigna una etiqueta de escena (QUIET, SPEECH, NOISE, UNKNOWN) a partir de las métricas del SceneAnalyzer.
- **EQ**: Ecualizador de 12 bandas que aplica el perfil espectral prescriptivo.
- **NAL-NL2/NL3**: Objetivos de prescripción de ganancia (National Acoustic Laboratories) que favorecen la audibilidad de agudos (2-4 kHz) para inteligibilidad sin sobre-amplificar graves.
- **MPO**: Maximum Power Output; nivel máximo de salida del audífono.
- **UCL**: Uncomfortable Loudness Level; nivel de sonoridad incómoda del paciente que la salida no debe exceder.
- **VAD**: Voice Activity Detection; detección de presencia de voz.
- **Modo_Bypass**: Modo de operación que pasa el audio sin procesamiento de mejora.
- **Modo_DNN_Dual**: Modo de operación basado en redes neuronales duales.
- **Modo_MVDR**: Modo de operación basado en beamforming MVDR de 2 micrófonos.
- **NativeAudioBridge**: Puente Kotlin (`NativeAudioBridge.kt`) que expone la cadena nativa C++ a la capa Dart de Flutter.
- **Cambio_Prescriptivo**: Cambio en el Sistema_DSP que altera la ganancia o el perfil espectral aplicado al paciente y, por tanto, afecta su prescripción clínica.
- **Supresor_Reverb**: Supresor de reverberación tardía ya implementado en `mvdr_beamformer.h`.

## Requirements

### Requirement 1: Expansión hacia abajo para eliminar hiss en silencios

**User Story:** Como paciente pediátrico usuario del audífono, quiero que el ruido propio del micrófono no se amplifique durante los silencios, para no escuchar hiss molesto cuando nadie habla.

**Contexto/Respaldo científico:** En las pausas de voz medidas, el nivel de entrada cae a ~40 dB pero la ganancia efectiva se mantiene en +37 dB, amplificando el ruido propio del micrófono. La expansión está actualmente desactivada (`expansionRatio=1.0`). La expansión hacia abajo por debajo del knee del WDRC es el mecanismo estándar de audífonos contra el hiss generado por el WDRC en niveles bajos. Hallazgo clave: limitar la expansión a frecuencias ≤1000 Hz preserva la audibilidad de consonantes. Fuentes: AudiologyOnline art. 934 "Applying Expansion in Hearing Aid Fittings"; Hearing Review "Noise Management in Modern Hearing Aid Fittings"; PMC2784644 "Effects of Expansion on Consonant Recognition".

#### Acceptance Criteria

1. WHERE la expansión hacia abajo está habilitada, THE Sistema_DSP SHALL aplicar una reducción de ganancia a la señal cuyo nivel de entrada esté por debajo del umbral de rodilla configurado del Expansor.
2. WHERE la expansión hacia abajo está habilitada, THE Sistema_DSP SHALL limitar la acción del Expansor a las componentes de frecuencia iguales o inferiores a 1000 Hz.
3. WHERE la expansión hacia abajo está habilitada, WHILE el nivel de entrada supera el umbral de rodilla configurado del Expansor, THE Sistema_DSP SHALL aplicar una relación de expansión de 1.0 (sin reducción de ganancia).
4. THE Expansor SHALL exponer los parámetros umbral de rodilla (dB), relación de expansión, frecuencia de corte superior (Hz), tiempo de ataque (ms) y tiempo de liberación (ms) como parámetros configurables.
4a. THE Expansor SHALL soportar un tiempo de liberación (release) configurable e independiente del tiempo de ataque, de forma que pueda ajustarse un release lento que evite el bombeo audible al recuperar la ganancia tras un evento de voz (respaldo: Article 934 AudiologyOnline usa release de 512 ms).
5. THE Expansor SHALL estar deshabilitado por defecto mediante un conmutador de activación (toggle).
6. WHEN la señal de entrada transita de un nivel bajo (por debajo del umbral) a un nivel de voz (por encima del umbral), THE Sistema_DSP SHALL completar la transición de ganancia del Expansor dentro de un tiempo de ataque configurable menor o igual a 50 ms.
7. WHILE la relación de expansión configurada es 1.0, THE Expansor SHALL dejar la señal sin modificación de ganancia.

### Requirement 2: Estimador de piso de ruido y SNR realista

**User Story:** Como técnico audiólogo, quiero que el estimador de ruido y SNR reporte valores realistas, para que el reductor de ruido y el clasificador de escena tomen decisiones correctas.

**Contexto/Respaldo científico:** El SceneAnalyzer reporta SNR pegado en 40 dB (tope) en el 100% de las muestras y ruido estimado entre −77 y −97 dB, valores irreales dado que un micrófono real se sitúa en ~−50 dB. Solución: estimador de piso de ruido tipo Minimum Statistics (Martin 2001, IEEE Trans. Speech Audio Proc.) o MMSE con Speech Presence Probability (Gerkmann & Hendriks 2012); ambos de baja complejidad y aptos para tiempo real.

#### Acceptance Criteria

1. THE Estimador_Ruido SHALL estimar el piso de ruido de la señal de entrada mediante un algoritmo de Minimum Statistics o MMSE con probabilidad de presencia de voz.
2. WHEN la señal de entrada proviene de un micrófono activo del dispositivo, THE Estimador_Ruido SHALL producir un piso de ruido estimado dentro del rango de −60 dB a −40 dB.
3. THE Estimador_Ruido SHALL producir valores de SNR estimado que varíen en función del contenido de la señal de entrada, sin saturarse en un único valor constante.
4. WHILE la entrada contiene voz sobre ruido de fondo doméstico, THE Estimador_Ruido SHALL producir un SNR estimado dentro del rango de 0 dB a 40 dB.
5. THE Estimador_Ruido SHALL actualizar la estimación del piso de ruido en tiempo real dentro del presupuesto de latencia de un bloque de audio del Oboe FullDuplexStream.
6. IF la señal de entrada es silencio o ruido sin voz durante un intervalo configurable, THEN THE Estimador_Ruido SHALL converger el piso de ruido estimado hacia el nivel de ruido medido de esa señal.
7. THE Estimador_Ruido SHALL exponer el piso de ruido estimado y el SNR estimado como valores observables para el Environment_Classifier y para diagnóstico.
8. THE Estimador_Ruido SHALL calcular el piso de ruido y el SNR sobre una escala de nivel consistente (dBFS) verificada contra el nivel real de captura del micrófono, de modo que el piso estimado no produzca valores físicamente imposibles (p. ej. −77 a −97 dB para un micrófono real de ~−50 dBFS) ni un SNR fijado en el tope del rango.

### Requirement 3: Reperfilado espectral del EQ hacia objetivo prescriptivo NAL

**User Story:** Como paciente pediátrico usuario del audífono, quiero un balance espectral que favorezca la nitidez de las consonantes en lugar de un sonido cargado en graves, para entender mejor el habla.

**Contexto/Respaldo científico:** El EQ actual aplica +31 dB en 500-750 Hz (graves/medios) y −16 dB en 8-10 kHz (agudos), produciendo un sonido "boomy" con poca nitidez de consonantes. Solución: reperfilar el EQ hacia el objetivo prescriptivo NAL-NL2/NL3, que favorece agudos 2-4 kHz para inteligibilidad sin sobre-amplificar graves. ADVERTENCIA: este cambio afecta la prescripción clínica del paciente (Cambio_Prescriptivo) y debe marcarse y confirmarse por su impacto.

#### Acceptance Criteria

1. THE EQ SHALL aplicar un perfil espectral de 12 bandas alineado con el objetivo prescriptivo NAL-NL2/NL3 configurado para el paciente.
2. THE EQ SHALL aplicar una ganancia relativa mayor en la región de 2000 Hz a 4000 Hz que la aplicada en la región de 500 Hz a 750 Hz para un mismo nivel de entrada.
3. THE EQ SHALL limitar la ganancia aplicada en la banda de 500 Hz a 750 Hz a un valor que no exceda el objetivo prescriptivo NAL configurado.
4. THE EQ SHALL reducir la atenuación aplicada en la región de 8000 Hz a 10000 Hz respecto al valor actual de −16 dB, según el objetivo prescriptivo NAL configurado.
5. THE Sistema_DSP SHALL identificar la modificación del perfil del EQ como un Cambio_Prescriptivo en la documentación de diseño y de tareas.
6. THE Sistema_DSP SHALL exponer el perfil del EQ a través de la cadena C++ → NativeAudioBridge (Kotlin) → Dart de forma que la capa de aplicación pueda mostrar el perfil aplicado.
7. WHERE el paciente clona el código C++ del técnico, THE Sistema_DSP SHALL propagar el nuevo perfil del EQ únicamente cuando el Cambio_Prescriptivo haya sido confirmado.

### Requirement 4: Convergencia del clasificador de escena

**User Story:** Como técnico audiólogo, quiero que el clasificador de entorno converja a escenas concretas, para que las adaptaciones automáticas del audífono se activen según el ambiente real.

**Contexto/Respaldo científico:** El SceneAnalyzer reporta "unknown" en el 100% de las muestras y nunca clasifica QUIET/SPEECH/NOISE porque sus umbrales dependen del SNR roto del Requisito 2. Solución: revisar los umbrales del Environment_Classifier una vez corregido el estimador; probablemente el clasificador converge al arreglar el estimador.

#### Acceptance Criteria

1. WHEN el Estimador_Ruido provee un SNR y un piso de ruido realistas, THE Environment_Classifier SHALL asignar una etiqueta de escena entre QUIET, SPEECH o NOISE.
2. WHILE la entrada es silencio con SNR por debajo del umbral de voz configurado, THE Environment_Classifier SHALL clasificar la escena como QUIET.
3. WHILE la entrada contiene voz con SNR por encima del umbral de voz configurado, THE Environment_Classifier SHALL clasificar la escena como SPEECH.
4. WHILE la entrada contiene ruido sin voz por encima del umbral de ruido configurado, THE Environment_Classifier SHALL clasificar la escena como NOISE.
5. THE Environment_Classifier SHALL exponer los umbrales de clasificación de SNR y de nivel como parámetros configurables.
6. WHEN se procesa una sesión de audio doméstico con voces representativa, THE Environment_Classifier SHALL clasificar como UNKNOWN no más del 20% de las muestras.
7. THE Environment_Classifier SHALL exponer la etiqueta de escena vigente a través de la cadena C++ → NativeAudioBridge (Kotlin) → Dart.

### Requirement 5: Afinación del supresor de reverberación tardía

**User Story:** Como paciente pediátrico usuario del audífono, quiero que la reverberación tardía se atenúe sin degradar la voz directa, para reducir la sensación de eco en ambientes reflectantes.

**Contexto/Respaldo científico:** El eco reportado por el usuario proviene en parte de reverberación y en parte del perfil espectral (Requisito 3). El Supresor_Reverb de reverberación tardía ya está implementado en `mvdr_beamformer.h`; este requisito cubre su afinación como mejora menor.

#### Acceptance Criteria

1. WHERE el Supresor_Reverb está habilitado, THE Sistema_DSP SHALL atenuar las componentes de reverberación tardía de la señal según sus parámetros configurados.
2. THE Supresor_Reverb SHALL exponer sus parámetros de intensidad de supresión como parámetros configurables.
3. THE Supresor_Reverb SHALL estar controlado por un conmutador de activación (toggle) que preserve el comportamiento actual cuando esté deshabilitado.
4. WHILE el Supresor_Reverb está habilitado, THE Sistema_DSP SHALL preservar el componente de voz directa de la señal.

### Requirement 6: Compatibilidad con modos existentes y cadena nativa

**User Story:** Como técnico audiólogo, quiero que las nuevas mejoras sean configurables y no rompan los modos existentes, para poder activarlas de forma controlada sin afectar el funcionamiento actual.

#### Acceptance Criteria

1. THE Sistema_DSP SHALL preservar el funcionamiento del Modo_Bypass, el Modo_DNN_Dual y el Modo_MVDR tras la incorporación de las mejoras de este spec.
2. THE Sistema_DSP SHALL exponer cada mejora de reducción de ruido y de expansión mediante un conmutador de activación (toggle) independiente.
3. WHERE todas las mejoras de este spec están deshabilitadas, THE Sistema_DSP SHALL producir una salida equivalente al comportamiento previo a este spec.
4. THE Sistema_DSP SHALL propagar cada nuevo parámetro configurable a través de la cadena C++ → NativeAudioBridge (Kotlin) → Dart.
5. IF un nuevo parámetro configurable no recibe valor desde la capa de aplicación, THEN THE Sistema_DSP SHALL aplicar un valor por defecto que preserve el comportamiento previo a este spec.
6. THE Sistema_DSP SHALL compilar y ejecutar en el dispositivo objetivo (Moto G32) mediante Oboe FullDuplexStream tras la incorporación de las mejoras.

### Requirement 7: Seguridad clínica (MPO/UCL)

**User Story:** Como técnico audiólogo responsable de un paciente pediátrico, quiero que ninguna mejora exceda los límites de salida clínicos, para proteger la audición del paciente.

#### Acceptance Criteria

1. THE Sistema_DSP SHALL aplicar el limitador MPO como última etapa de ganancia antes de la salida.
2. THE Sistema_DSP SHALL limitar el nivel de salida para que no exceda el UCL configurado del paciente.
3. IF cualquier mejora de este spec produce una ganancia que llevaría la salida por encima del MPO configurado, THEN THE Sistema_DSP SHALL limitar la salida al MPO configurado.
4. THE Sistema_DSP SHALL preservar el comportamiento del limitador MPO independientemente del estado de activación de las mejoras de expansión, reducción de ruido y supresión de reverberación.
5. WHERE el paciente clona el código C++ del técnico, THE Sistema_DSP SHALL propagar los límites MPO/UCL con los mismos valores configurados por el técnico.
