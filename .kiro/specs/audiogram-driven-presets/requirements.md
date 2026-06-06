# Requirements Document

## Spec: Presets manejados por el audiograma (audiogram-driven-presets)

> Spec ID: `audiogram-driven-presets`
> Fecha: 3 de junio de 2026.
> Owner: pendiente de asignar.
> Documento padre de investigación: [`docs/07-calibracion-audiograma/analisis-prescripcion-real-vs-simulador.md`](../../../../docs/07-calibracion-audiograma/analisis-prescripcion-real-vs-simulador.md).

## Introduction

Hoy la app Flutter del audífono ejecuta una audiometría tonal Hughson-Westlake
funcional, pero el audiograma resultante alimenta una sola cosa: las ganancias
del EQ NAL-NL2 cuando se aplica al perfil. Todo el resto de la cadena clínica
(MPO global a 110 dB SPL, WDRC con `compressionRatio` y kneepoint genéricos,
`EnvironmentProfile` con NR fijo, presets `EqPreset` con ganancias hardcodeadas,
custom presets que snapshean el `EnvironmentProfile` activo) se mantiene
desacoplado del audiograma.

Resultado: hacer la audiometría no impacta el MPO, ni el WDRC, ni los presets
manuales que el usuario puede cargar. La parte verídica de la app —los
umbrales medidos en oído del paciente— termina diluida por configuraciones
genéricas que la pisan.

Esta spec define el "puente" entre el audiograma y todas las superficies
clínicas restantes. El objetivo es que un único audiograma derive un bundle
completo de configuración (ganancias + ratios de compresión por banda + knees
+ perfil MPO + nivel de NR + tiempos WDRC), que ese bundle alimente cada preset
y cada flujo de aplicación, y que cualquier cambio del audiograma re-despache
ese bundle de forma atómica.

Esta spec se apoya en y NO duplica:

- `nal-nl3-prescriptor` — provee la prescripción base (gains + CR per-band +
  WDRC overrides + LossType). Esta spec consume su `NL3PrescriptionResult` y le
  agrega encima el perfil MPO derivado de UCL.
- `mic-calibration` — provee `splOffset` real del lado de entrada. Esta spec
  asume que `applyCalibration` ya se llamó al startup; trabaja en el dominio
  de SPL al tímpano que el módulo de calibración define.
- `core-clinico-compartido` Sprint 3 — proveerá tablas y validadores
  compartidos. Esta spec usa los prescriptores Dart actuales hasta que esa
  migración esté lista; el código nuevo se escribe de forma que el reemplazo
  por el `port-dart` sea drop-in.

## Glossary

- **Audiogram_Driven_Bundle** — estructura de datos inmutable que agrupa, para
  un audiograma dado, los 12 valores de ganancia EQ, los 12 ratios de compresión
  por banda, los 12 kneepoints WDRC por banda (o el knee broadband), los 12
  valores de MPO por banda en dB SPL, el nivel de NR sugerido y los tiempos
  WDRC (attack/release) sugeridos.
- **Bundle_Builder** — módulo Dart puro que recibe un `Audiogram` (más perfil
  del paciente, modo de prescripción y opcionales como UCL medido) y devuelve
  un `Audiogram_Driven_Bundle`.
- **UCL_Estimator** — función pura que estima `UCL[f] = 100 + 0.15 × HL[f]`
  por banda cuando el clínico no provee UCL medido.
- **MPO_Deriver** — función pura que convierte UCL a MPO con margen de
  seguridad: adulto `min(UCL[f] - 5, 132)`, pediátrico `min(UCL[f] - 10, 110)`.
- **Manual_Preset** — preset visible al usuario en la UI: incluye los 10
  `EqPreset.allPresets` (Normal, Mild High, Moderate Flat, Voice Clarity, etc.),
  los 3 `EnvironmentProfile.predefinedProfiles` (Silencioso, Conversación,
  Ruidoso), y los presets personalizados creados via `SaveCustomPreset`.
- **Smart_Scene_Generic_Preset** — preset que produce
  `SceneGenericPresetGenerator` cuando no hay audiograma cargado o el toggle
  "personalizar" está OFF.
- **Smart_Scene_Personalized_Preset** — preset que produce
  `ScenePersonalizedPresetGenerator` partiendo del audiograma + deltas por
  escena + headroom clamp.
- **Bundle_Apply_Event** — evento del `AmplificationBloc` que despacha al
  motor nativo el bundle completo en una sola transacción.
- **Headroom_Per_Band** — clamp por banda calculado como
  `mpoProfile[f] - input_level - safetyMargin`, reemplaza el clamp global a
  `110 - input - 3` que hace hoy `ScenePersonalizedPresetGenerator`.
- **Modo_Diagnostico** — modo de operación activo cuando existe un
  audiograma medido válido en el repo. El bundle se deriva 100% de la
  prescripción NAL-NL3 sobre el audiograma del paciente.
- **Modo_Amplificador** — modo de operación activo cuando NO existe un
  audiograma medido. El bundle se deriva de `Audiogram.defaultAudiogram()`
  (10 dB HL flat) escalado por un `gainScale ∈ [0.10, 1.00]`. El default
  es `0.40` (40%) por la ausencia de información del paciente; el clínico
  o el usuario avanzado puede ajustarlo dentro del rango.
- **gainScale** — factor multiplicativo `∈ [0.10, 1.00]` aplicado a
  `gainsDb` del bundle cuando el modo activo es Amplificador. No afecta
  `mpoProfileDbSpl`, `compressionRatios`, `compressionKneesDbSpl` ni
  `nrLevel`: la limitación y la compresión se derivan completos del
  audiograma default para preservar la protección del paciente.

## Requirements

### Requirement 1: Audiogram_Driven_Bundle como contrato único

**User Story:** Como desarrollador, quiero una sola estructura de datos
que capture todo lo que el pipeline DSP necesita para un audiograma, para
que cualquier preset o flujo de aplicación lea siempre la misma fuente y
no haya parámetros clínicos sueltos.

#### Acceptance Criteria

1. THE Bundle_Builder SHALL exponer un método `buildFromAudiogram(Audiogram audiogram, {PatientProfile? profile, required PrescriptionMode mode, Map<int,double>? measuredUcl, DateTime? derivedAt})` que retorna un `Audiogram_Driven_Bundle` inmutable. Cuando `profile` se omite, el builder asume usuario adulto experimentado sin UCL medido y sin componente conductivo. Cuando `derivedAt` se omite en producción, el builder usa un reloj inyectado (no `DateTime.now()` directo).
2. THE `Audiogram_Driven_Bundle` SHALL incluir exactamente estos campos con sus rangos y unidades: `gainsDb[12]` en `[0, 50] dB`, `compressionRatios[12]` adimensional en `[1.0, 3.0]`, `compressionKneesDbSpl[12]` en `[35, 65] dB SPL`, `mpoProfileDbSpl[12]` en `[80, 132] dB SPL`, `nrLevel` entero en `[0, 3]`, `wdrcAttackMs` en `[1, 50] ms`, `wdrcReleaseMs` en `[20, 500] ms`, `expansionKneeDbSpl` en `[20, 50] dB SPL`, `lossType` (de `LossType`), `prescriptionMode` (de `PrescriptionMode`), `derivedAt` (timestamp ISO 8601 UTC con resolución ms).
3. THE `Bundle_Builder` SHALL ser una función pura: idénticos `audiogram + profile + mode + measuredUcl + derivedAt` producen idénticos `Audiogram_Driven_Bundle`. THE implementación SHALL prohibir el uso de `DateTime.now()` directo dentro del builder y de cualquier función pura aguas abajo (`UCL_Estimator`, `MPO_Deriver`, aplicación de estilos).
4. THE `Bundle_Builder` SHALL delegar el cómputo de `gainsDb` y `compressionRatios` al `GainPrescriberNL3` existente cuando `mode != mhl`, y al `MhlModule` cuando `mode == mhl`, sin reimplementar la prescripción.
5. IF el módulo delegado (`GainPrescriberNL3` o `MhlModule`) lanza una excepción durante la construcción del bundle, THEN THE `Bundle_Builder` SHALL propagar esa excepción sin envoltura adicional y SHALL NO devolver un bundle parcial.
6. IF el audiograma tiene menos de 12 frecuencias estándar o contiene umbrales fuera del rango `[-10, 120] dB HL`, THEN THE `Bundle_Builder` SHALL lanzar `ArgumentError` con mensaje que enumere las frecuencias faltantes y la lista completa requerida (250, 500, 750, 1000, 1500, 2000, 2500, 3000, 3500, 4000, 6000, 8000 Hz), sin construir el bundle.
7. THE `Audiogram_Driven_Bundle` SHALL ser serializable a JSON via `toJson()` con campo `schemaVersion = "1.0.0"`. THE round-trip via `fromJson(b.toJson())` SHALL devolver un bundle estructuralmente idéntico al original con tolerancia ≤ 0.001 para valores flotantes y igualdad exacta para enums, enteros, strings y timestamps.
8. IF un JSON entrante tiene `schemaVersion` distinto de `"1.0.0"`, THEN THE `fromJson()` SHALL lanzar `FormatException` con mensaje que incluya explícitamente la versión esperada (`"1.0.0"`) y la versión recibida.

---

### Requirement 2: Estimación de UCL y derivación de MPO por banda

**User Story:** Como audiólogo, quiero que el MPO se derive del umbral del
paciente y no esté fijo a 110 dB SPL global, para que la limitación proteja
al paciente con UCL bajo y aproveche dinámica con UCL alto.

#### Acceptance Criteria

1. IF no se provee `measuredUcl`, THEN THE `UCL_Estimator` SHALL calcular `UCL[f] = 100 + 0.15 × HL[f]` para cada una de las 12 bandas estándar, donde `HL[f]` es el umbral en dB HL del audiograma.
2. IF `measuredUcl` se provee, THEN THE `Bundle_Builder` SHALL usar `measuredUcl[f]` por banda para las frecuencias presentes en el mapa, y SHALL caer al `UCL_Estimator` solo en las frecuencias ausentes.
3. WHEN `PatientProfile.ageYears` es estrictamente menor a 18, THE `MPO_Deriver` SHALL calcular `MPO[f] = min(UCL[f] - 10, 110) dB SPL` para todas las bandas (regla pediátrica).
4. WHEN `PatientProfile.ageYears` es 18 o mayor, o el campo no está disponible y el flag pediátrico está desactivado, THE `MPO_Deriver` SHALL calcular `MPO[f] = min(UCL[f] - 5, 132) dB SPL` (regla adulto).
5. THE `MPO_Deriver` SHALL clampar cada valor del perfil MPO resultante al rango `[80, 132] dB SPL`, sustituyendo cualquier valor fuera de rango por el bound más cercano antes de devolverlo.
6. IF el audiograma contiene un umbral mayor a 120 dB HL en alguna banda, THEN THE `UCL_Estimator` SHALL clampar `HL[f]` a 120 dB HL antes de aplicar la fórmula, para evitar UCL > 118 dB SPL antes del clamp final.
7. THE `Bundle_Builder` SHALL exponer el perfil MPO derivado en el campo `mpoProfileDbSpl` del bundle, con exactamente 12 valores alineados al orden de `Audiogram.standardFrequencies`.

---

### Requirement 3: Bridge nativo para aplicar MPO en runtime

**User Story:** Como desarrollador, quiero un método para actualizar el MPO
en el motor nativo sin reiniciar el pipeline, para que un cambio de
audiograma afecte la limitación inmediatamente.

#### Acceptance Criteria

1. THE `AudioBridge` interface SHALL exponer un método `setMpoThresholdDbSpl(double thresholdDbSpl)` que acepta un valor en `[80.0, 132.0] dB SPL` (rango cerrado, inclusivo en ambos extremos) y aplica el nuevo umbral al limitador MPO broadband del pipeline DSP nativo. THE propagación al motor SHALL completarse en ≤ 50 ms p95 medido desde la invocación Dart hasta la confirmación del canal nativo.
2. WHEN `setMpoThresholdDbSpl(value)` se invoca con un `value` válido, THE `AudioBridgeImpl` SHALL despachar exactamente una invocación `MethodChannel.invokeMethod('setMpoThresholdDbSpl', {'thresholdDbSpl': value})` por llamada al canal nativo `com.psk.hearing_aid/audio`.
3. IF el valor recibido es NaN, Infinity, o está fuera del rango `[80.0, 132.0]`, THEN THE `AudioBridgeImpl` SHALL lanzar `ArgumentError` antes de invocar al canal nativo y SHALL preservar el umbral MPO previo sin modificación alguna.
4. IF la invocación al canal nativo falla por `PlatformException`, timeout o canal no disponible, THEN THE `AudioBridgeImpl` SHALL propagar la excepción al caller y SHALL preservar el umbral MPO previo sin modificación alguna.
5. WHEN el bundle define un perfil MPO de 12 valores diferentes y el limitador nativo solo soporta MPO broadband, THE `Bundle_Apply_Event` handler SHALL pasar al bridge el mínimo del perfil (`min(mpoProfileDbSpl)`) sobre los 12 valores del bundle, garantizando protección frente a la banda más sensible.
6. THE `AudioBridge` interface SHALL mantener la firma broadband `setMpoThresholdDbSpl(double)` como contrato estable de esta spec. WHEN se habilite soporte de MPO por banda en el motor nativo, cualquier extensión SHALL ser aditiva (e.g. nuevo método `setMpoProfileDbSpl(List<double>)`) sin romper la firma broadband ni requerir migración de los callers existentes.

---

### Requirement 4: Aplicación atómica del bundle al motor

**User Story:** Como audiólogo, quiero que aplicar el resultado de la
audiometría reconfigure ganancias, compresión, MPO y NR en un solo paso,
para que el paciente nunca quede con un estado inconsistente entre etapas
del pipeline.

#### Acceptance Criteria

1. WHEN el `AmplificationBloc` recibe un evento `ApplyAudiogramDrivenBundle(Audiogram_Driven_Bundle)`, THE bloc SHALL despachar al `AudioBridge` exactamente cuatro llamadas en una misma transacción Dart síncrona sin yields al event loop entre pasos, en este orden: (1) `setMpoThresholdDbSpl(min(bundle.mpoProfileDbSpl))`, (2) `updateWdrcParams(...)` con `compressionRatio`, `compressionKnee`, `expansionKnee`, `attackMs` y `releaseMs` derivados del bundle, (3) `updateEqGains(bundle.gainsDb)`, (4) `updateNrLevel(bundle.nrLevel)`.
2. WHEN `_onUpdateAudiogram` se invoca, THE handler SHALL construir el `Audiogram_Driven_Bundle` y SHALL despacharlo via `ApplyAudiogramDrivenBundle`, en lugar de invocar solo `updateEqGains` como hoy.
3. IF cualquiera de las cuatro llamadas del paso 1 falla (excepción del bridge, timeout, validación), THEN THE `AmplificationBloc` SHALL revertir al snapshot de parámetros DSP previo al paso 1, SHALL NO ejecutar los pasos restantes de la secuencia, y SHALL emitir un estado de error que identifique cuál de los cuatro pasos falló y la causa observable.
4. THE aplicación completa del bundle SHALL completarse en ≤ 200 ms p95 medido desde la recepción del evento hasta la emisión del nuevo estado, en hardware Snapdragon 700-series o superior con Android 10+.
5. WHEN el bundle se aplica con éxito, THE `AmplificationBloc` SHALL emitir un nuevo `AmplificationActive` que incluya `bundle.lossType`, `bundle.prescriptionMode` y un timestamp UTC en ms para que la UI pueda mostrar feedback visual con duración inclusiva entre 200 ms y 500 ms.
6. THE evento `ApplyAudiogramDrivenBundle` SHALL ser despachable desde cualquier handler del bloc (cambio de modo de prescripción, activación/desactivación de MHL, cambio de `EnvironmentProfile`, selección de estilo manual), de modo que toda mutación de parámetros clínicos pase por la misma vía atómica.
7. IF el bundle recibido tiene algún campo fuera de los rangos declarados en Requirement 1 (cualquier array con longitud ≠ 12, valor fuera de rango, enum inválido), THEN THE handler SHALL rechazar el evento sin aplicar parcialmente y SHALL emitir un estado de error con la lista de violaciones de validación.

---

### Requirement 5: Presets manuales derivados del audiograma

**User Story:** Como usuario, quiero que cuando elija un preset manual
("Mild High", "Voice Clarity", "Moderate Flat") los valores que se aplican
respeten mi audiograma y no sobreescriban con ganancias hardcodeadas.

#### Acceptance Criteria

1. THE app SHALL conservar los nombres y descripciones de los 10 `EqPreset.allPresets` actuales como "estilos" visibles al usuario, pero internamente cada estilo SHALL ser una función `applyStyle(bundle, styleName) → bundle'` pura e idempotente que ajusta ganancias, compresión y NR del bundle base sin reemplazar las ganancias por listas hardcodeadas.
2. WHEN el usuario selecciona el estilo `Normal`, THE estilo SHALL retornar un bundle estructuralmente idéntico al de entrada (excepto por `derivedAt`), preservando la prescripción del audiograma sin amplification cap adicional.
3. WHEN el usuario selecciona uno de los estilos orientados a forma de pérdida (`Mild High`, `Mild Flat`, `Moderate High`, `Moderate Flat`, `Moderate+`), THE estilo SHALL aplicar deltas relativos sobre `gainsDb` en el rango `[-3, +3] dB` por banda, SHALL clampar el resultado al rango `[0, 50] dB`, y SHALL dejar `compressionRatios` y `mpoProfileDbSpl` inalterados.
4. WHEN el usuario selecciona uno de los estilos de uso (`Voice Clarity`, `Music`, `Outdoor`, `TV/Media`), THE estilo SHALL aplicar deltas por grupo frecuencial (graves: 250–750 Hz, medios: 1000–4000 Hz, agudos: 6000–8000 Hz) sobre `gainsDb` en el rango `[-4, +4] dB` por grupo, y SHALL ajustar `nrLevel` en al menos `±1` (clampado a `[0, 3]`) según corresponda al estilo.
5. WHEN el usuario selecciona cualquier estilo, THE app SHALL despachar `ApplyAudiogramDrivenBundle` con el bundle modificado por el estilo, en lugar de despachar `UpdateEqGains` puro como hoy.
6. IF el audiograma persistido tiene menos de 12 bandas válidas o no existe en el repo, THEN THE app SHALL usar `Audiogram.defaultAudiogram()` (10 dB HL flat) para construir el bundle base, SHALL mostrar un banner persistente no-bloqueante con texto en español rioplatense indicando "Audiograma no medido — usando perfil estándar de 10 dB HL", y SHALL ocultar el banner cuando se cargue un audiograma medido.
7. IF el `styleName` recibido no corresponde a ninguno de los 10 estilos definidos, THEN THE app SHALL rechazar la selección sin modificar el bundle activo y SHALL registrar el error sin propagarlo al usuario como crash.
8. THE `EqPreset.allPresets` actual con sus arrays de ganancias hardcodeadas SHALL conservarse en código marcado `@deprecated` con comentario que indique "referencia para tests de regresión hasta migrar a `core-clinico-compartido` Sprint 3", y SHALL no ser invocado en runtime fuera de los tests.

---

### Requirement 6: EnvironmentProfile derivado del audiograma

**User Story:** Como usuario, quiero que los perfiles "Silencioso",
"Conversación" y "Ruidoso" sigan funcionando como atajos de UI pero que
respeten mi audiograma, no parámetros genéricos.

#### Acceptance Criteria

1. THE app SHALL conservar los tres `EnvironmentProfile` actuales (`quiet`, `conversation`, `noisy`) con sus nombres visibles al usuario.
2. WHEN el usuario selecciona un `EnvironmentProfile`, THE handler `_onChangeProfile` SHALL recomputar el bundle aplicando el mapping `EnvironmentProfile → PrescriptionMode` (`quiet → quiet`, `conversation → quiet`, `noisy → comfortInNoise`) y SHALL despachar el bundle resultante via `ApplyAudiogramDrivenBundle`. THE propagación SHALL completarse en ≤ 200 ms p95.
3. WHEN un `EnvironmentProfile` se aplica, THE `compressionRatio`, `compressionKnee` y `expansionKnee` enviados al motor SHALL provenir del bundle (audiograma + modo). THE handler SHALL ignorar los campos hardcodeados de `EnvironmentProfile.predefinedProfiles` para esos parámetros.
4. THE estructura `EnvironmentProfile` SHALL conservar un campo `nrDelta` entero en `[-3, +3]` con default `0` como override opcional sobre el `bundle.nrLevel` derivado.
5. WHEN un `EnvironmentProfile` define `nrDelta != 0`, THE handler SHALL aplicar `nrLevel = clamp(bundle.nrLevel + profile.nrDelta, 0, 3)` antes de despachar el bundle.
6. IF el audiograma persistido es inválido o ausente al momento de cambiar de profile, THEN THE handler SHALL caer al `Audiogram.defaultAudiogram()` y SHALL aplicar el flujo del Requirement 5.6 (banner "audiograma no medido"), sin abortar el cambio de profile.

---

### Requirement 7: Smart Scene siempre derivado del audiograma

**User Story:** Como audiólogo, quiero que el motor de escena adaptativa
siempre use el audiograma del paciente, incluso cuando el toggle
"personalizar" esté OFF, para que la app nunca cargue una curva genérica
que ignore lo medido.

#### Acceptance Criteria

1. WHEN `SceneEngine.analyze()` se invoca y existe un audiograma persistido válido, THE motor SHALL invocar el `Bundle_Builder` con ese audiograma para construir el bundle base de la escena.
2. IF no existe audiograma persistido al momento del `analyze()`, THEN THE motor SHALL usar `Audiogram.defaultAudiogram()` para construir el bundle y SHALL emitir un warning observable que la UI pueda mostrar como hint.
3. THE motor SHALL eliminar la rama `usePersonalized = _personalize && audiogram != null` actual; el bundle siempre se construye desde un audiograma (medido o default).
4. THE `SceneGenericPresetGenerator` SHALL ser refactorizado o reemplazado por una versión que opere sobre el bundle audiograma-derivado más los deltas por escena ya definidos en `ScenePersonalizedPresetGenerator`, eliminando la selección de `EqPreset.gains` hardcodeados que hace hoy.
5. WHILE el toggle `personalize_with_audiogram` está ON, THE generador SHALL aplicar tanto el bundle audiograma-derivado como los deltas por escena al EQ y a los parámetros WDRC.
6. WHILE el toggle `personalize_with_audiogram` está OFF, THE generador SHALL aplicar solo los deltas por escena sobre el bundle base, sin sumar la corrección de "ganancia individualizada" sobre el audiograma; el bundle base (gains + CR + MPO) sigue derivándose del audiograma persistido.
7. THE clamp de headroom dentro del generador personalizado SHALL usar `bundle.mpoProfileDbSpl[f]` por banda como techo, en lugar del literal `mpoThresholdDbSpl = 110.0` actual.
8. WHILE no hay audiograma medido y se está usando `defaultAudiogram()`, THE UI de Smart Scene SHALL mostrar un hint persistente en español rioplatense con texto observable "Audiograma no medido — los presets usan un perfil estándar de 10 dB HL", y SHALL ocultar el hint cuando se cargue un audiograma medido.
9. THE flag `wasPersonalizeUserSet` SHALL conservarse para que el toggle persista la última elección explícita del usuario entre sesiones de la app.

---

### Requirement 8: SaveCustomPreset captura el bundle completo

**User Story:** Como audiólogo, quiero que cuando guarde un preset
personalizado, ese preset persista todo el contexto clínico
(audiograma, ratios, MPO, NR), para que al recargarlo más tarde el
estado sea exactamente el mismo aunque haya pasado el tiempo.

#### Acceptance Criteria

1. WHEN el evento `SaveCustomPreset(name, audiogram)` se procesa, THE handler SHALL persistir un blob JSON con: `name`, `audiogram` snapshot, `Audiogram_Driven_Bundle` derivado completo (los 12 arrays + scalars + lossType + prescriptionMode), `appliedStyleName` (string vacío si no se aplicó estilo), `nrOverride` aplicado, `schemaVersion` entero, y `createdAt` ISO 8601 UTC. THE persistencia SHALL completarse en ≤ 2 s p95.
2. THE `ProfileRepository.saveCustomProfile` SHALL ser extendido para almacenar el blob completo. THE tamaño máximo del blob persistido SHALL ser ≤ 64 KB, y los campos heredados (`nrLevel`, `compressionRatio`, `expansionKnee`, `compressionKnee`) SHALL preservarse para retrocompatibilidad de lectura desde versiones anteriores.
3. IF el blob serializado supera 64 KB o la escritura a Hive falla, THEN THE handler SHALL abortar el guardado, SHALL preservar el preset existente con ese nombre (si lo hay) y SHALL emitir un estado de error sin pisar datos del usuario.
4. WHEN el usuario carga un preset personalizado guardado con `schemaVersion` menor o ausente, THE app SHALL recomputar el bundle a partir del audiograma persistido del preset, SHALL reaplicar el estilo y `nrOverride` originales, y SHALL mostrar un warning visible "preset migrado a schema actual".
5. IF el audiograma persistido del preset es inválido o ausente al momento de cargar, THEN THE app SHALL rechazar la carga del preset, SHALL preservar el bundle activo, y SHALL emitir un estado de error con identificador del preset corrupto.
6. WHEN el evento `DeleteCustomPreset(name)` se procesa, THE handler SHALL eliminar exclusivamente el preset con ese nombre del repositorio, SHALL preservar todos los demás presets personalizados, y SHALL no modificar el estado clínico activo del bloc.
7. THE listado de presets personalizados en la UI SHALL renderizar para cada preset, junto al nombre, dos chips visibles con el `lossType` y el `prescriptionMode` con los que fue creado. WHEN el preset fue migrado de un schema anterior, THE chip SHALL incluir un fallback observable "Migrado".

---

### Requirement 9: Recálculo automático cuando cambia el audiograma

**User Story:** Como audiólogo, cuando vuelvo a hacer una audiometría y
aplico el resultado al perfil, quiero que todos los presets guardados
queden marcados como obsoletos o regenerados automáticamente, no que
sigan vigentes con datos viejos.

#### Acceptance Criteria

1. WHEN el `_onUpdateAudiogram` del bloc detecta que el audiograma nuevo difiere del persistido en > 5 dB MAD (mean absolute difference) sobre las 12 bandas estándar, THE bloc SHALL recomputar el bundle, despachar `ApplyAudiogramDrivenBundle`, y emitir un evento `AudiogramChanged` con la lista de IDs de presets afectados. THE flujo completo (recompute + dispatch + emit) SHALL completarse en ≤ 500 ms p95.
2. WHEN se invoca `ProfileRepository.markCustomPresetsAsStale(Audiogram newAudiogram)`, THE método SHALL recorrer todos los presets personalizados, SHALL comparar el audiograma de origen de cada uno con `newAudiogram` por MAD sobre las 12 bandas, SHALL marcar `stale = true` en aquellos cuyo MAD es estrictamente mayor a 5 dB, y SHALL preservar inalterados todos los demás campos del preset.
3. IF la actualización masiva del flag stale falla parcialmente (e.g. corrupción Hive en uno de los presets), THEN THE método SHALL completar las actualizaciones exitosas, SHALL preservar inalterados los presets que fallaron, y SHALL emitir un estado de error con la lista de presets no actualizados sin abortar la operación.
4. WHILE un preset personalizado está marcado `stale = true`, THE UI SHALL renderizar un indicador visible "obsoleto" sobre la fila del preset y SHALL exponer un control accesible "regenerar con audiograma actual" en la misma fila.
5. WHEN el usuario activa "regenerar" sobre un preset stale, THE app SHALL reemplazar el bundle persistido del preset por el bundle derivado del audiograma actual aplicando el mismo `appliedStyleName` y `nrOverride` originales, SHALL limpiar el flag `stale`, y SHALL completar la operación en ≤ 1000 ms p95.
6. IF la regeneración falla (audiograma actual inválido, persistencia falla, estilo desconocido), THEN THE app SHALL revertir al estado previo del preset (incluyendo el flag stale), SHALL preservar el bundle persistido original, y SHALL mostrar feedback de error al usuario.
7. WHEN el audiograma cambia con MAD > 5 dB respecto al persistido, THE bloc SHALL invalidar la entrada `last_eq_preset` en el `settings_box` para que el próximo `apply` de Smart Scene recompute el preset desde el audiograma actual en lugar de cargar las ganancias persistidas.

---

### Requirement 10: Headroom y MPO consistentes en todas las superficies

**User Story:** Como ingeniero de QA, quiero que cualquier ruta de
aplicación de ganancias respete el mismo techo MPO derivado del
audiograma, para que ningún preset pueda saltarse el límite que protege
al paciente.

#### Acceptance Criteria

1. WHEN el handler de `Bundle_Apply_Event` despacha el bundle, THE handler SHALL aplicar `setMpoThresholdDbSpl(min(bundle.mpoProfileDbSpl))` antes de despachar `updateEqGains`, garantizando que el limitador esté actualizado antes de que la señal pase por el EQ con las nuevas ganancias.
2. IF el bundle recibido tiene `mpoProfileDbSpl` ausente, con longitud ≠ 12, o con algún valor fuera de `[80, 132] dB SPL`, THEN THE handler SHALL rechazar la aplicación, SHALL preservar el MPO y EQ actuales sin modificación, y SHALL emitir un estado de error sin pisar el techo MPO previo.
3. WHEN cualquier flujo (manual preset, environment profile, Smart Scene generic, Smart Scene personalized) computa ganancias finales, THE flujo SHALL clampar cada banda usando `gain[f] = min(target_gain[f], mpoProfileDbSpl[f] - input_db_spl[f] - 3.0)` con `safetyMargin = 3.0 dB`, donde `input_db_spl[f]` es el nivel de entrada estimado por banda. Ningún flujo SHALL usar el literal `110 - input - 3` ni un techo global alternativo.
4. THE constructor de `ScenePersonalizedPresetGenerator` SHALL recibir el `Audiogram_Driven_Bundle` (no solo el audiograma), SHALL leer `bundle.mpoProfileDbSpl` para el clamp por banda, y SHALL eliminar el parámetro `mpoThresholdDbSpl` global de su firma.
5. THE `ScenePersonalizedPresetGenerator.absoluteMaxGainDb` SHALL conservarse como tope absoluto de seguridad fijado en 50.0 dB, aplicado después del clamp por banda, y nunca SHALL exceder ese valor.
6. IF el clamp por banda obliga a reducir la ganancia debajo del target prescrito en al menos 0.1 dB, THEN THE generador SHALL incluir en la metadata del preset resultante un campo `clampedBands` con, para cada banda afectada, el `frequency`, el `gain_target` y el `gain_applied`, para que la UI pueda renderizar qué bandas están limitadas por el techo MPO del audiograma del paciente.

---

### Requirement 11: Tests de regresión y property-based

**User Story:** Como mantenedor, quiero tests automáticos que garanticen
que la introducción del bundle no degrada el comportamiento actual de
ningún preset y que cualquier cambio futuro sea visible.

#### Acceptance Criteria

1. THE test suite SHALL incluir un test de regresión que, para cada uno de los 10 `EqPreset.allPresets` originales y un audiograma plano de 30 dB HL en las 12 frecuencias estándar (250 Hz a 8000 Hz), verifique que las ganancias finales aplicadas via `ApplyAudiogramDrivenBundle` están dentro de `±3 dB` por banda respecto a las ganancias hardcodeadas anteriores.
2. THE test suite SHALL incluir un property-based test "Output invariant" con `glados` que, sobre al menos 100 audiogramas generados con 12 umbrales en `[0, 120] dB HL`, verifique que el bundle resultante tiene exactamente 12 valores en cada array de salida y cada valor está en su rango declarado en Requirement 1.
3. THE test suite SHALL incluir un property-based test "MPO bound" con `glados` que, sobre al menos 100 audiogramas generados, verifique que para todas las bandas `f` se cumple `80 ≤ mpoProfileDbSpl[f] ≤ 132`.
4. THE test suite SHALL incluir un property-based test "MPO monotonicity en HL" con `glados` que, sobre al menos 100 audiogramas generados, verifique que subir `HL[f]` de cualquier banda en 10 dB no aumenta `mpoProfileDbSpl[f]` en más de 1.5 dB (consistente con el coeficiente 0.15 de UCL).
5. THE test suite SHALL incluir un property-based test "Determinism" con `glados` que, sobre al menos 100 audiogramas generados con `derivedAt` fijo, verifique que el `Bundle_Builder` produce bundles iguales campo a campo excluyendo `derivedAt`.
6. THE test suite SHALL incluir un property-based test "JSON round-trip" con `glados` que, sobre al menos 100 bundles generados, verifique que `Bundle.fromJson(b.toJson())` es estructuralmente igual a `b` (tolerancia ≤ 0.001 para flotantes, igualdad exacta para enums/ints/strings/timestamps).
7. THE test suite SHALL incluir un test "Atomic apply" con un mock del `AudioBridge` que verifique que invocar `ApplyAudiogramDrivenBundle` con un bundle válido produce exactamente las cuatro llamadas al bridge en el orden `setMpoThresholdDbSpl → updateWdrcParams → updateEqGains → updateNrLevel`, sin llamadas adicionales.
8. THE test suite SHALL incluir un test de integración que ejecute la cadena completa: audiometría simulada con resultado conocido → `applyToProfile` → bundle construido → bridge mock recibe `setMpoThresholdDbSpl + updateWdrcParams + updateEqGains + updateNrLevel` con valores derivados del audiograma simulado, no de los presets hardcodeados.
9. IF un test de regresión detecta una desviación mayor a `5 dB` por banda respecto al baseline, THEN THE CI SHALL bloquear el merge y SHALL reportar las bandas afectadas con el delta observado.
10. IF cualquier property-based test falla durante CI, THEN THE CI SHALL bloquear el merge y SHALL reportar el contraejemplo minimizado por shrinking de `glados`.

---

### Requirement 12: Documentación y disclaimer

**User Story:** Como audiólogo o auditor, quiero entender exactamente
qué fórmula deriva cada parámetro del bundle, para que la trazabilidad
clínica sea verificable.

#### Acceptance Criteria

1. THE módulo `Bundle_Builder` SHALL incluir Dartdoc completo en cada función pública con cuatro secciones obligatorias: (a) parámetros con rango y unidad, (b) retorno con rango y unidad, (c) referencia bibliográfica con sección o número de línea de `docs/07-calibracion-audiograma/analisis-prescripcion-real-vs-simulador.md`, (d) ejemplo de uso ejecutable.
2. IF cualquier función pública del módulo `Bundle_Builder`, `UCL_Estimator` o `MPO_Deriver` carece de alguna de las cuatro secciones del criterio 1, THEN THE pipeline de validación documental del CI SHALL fallar el build identificando la función incompleta.
3. WHILE un preset está activo en la pantalla principal, THE UI SHALL renderizar adyacente al nombre del preset un texto persistente en español rioplatense con el `LossType` detectado y el `prescriptionMode` activo.
4. IF no hay preset activo o el `LossType` es indeterminado, THEN THE UI SHALL renderizar un texto de fallback observable ("Sin perfil activo" o equivalente) en lugar de ocultar el indicador.
5. THE README de la spec y el Dartdoc de la función `MPO_Deriver` SHALL incluir explícitamente la nota: "El MPO derivado de UCL estimado (UCL ≈ 100 + 0.15 × HL) es una aproximación clínica. Para fitting clínico certificado, medir UCL con escala Cox Contour y reemplazar `measuredUcl` por los valores reales."
6. THE README de la spec SHALL contener una sección titulada "Dependencias" que liste exactamente las tres specs vinculadas (`nal-nl3-prescriptor`, `mic-calibration`, `core-clinico-compartido`), cada una con una descripción de máximo dos oraciones explicando qué provee la spec dependiente y qué responsabilidad queda en `audiogram-driven-presets`.

---

### Requirement 13: Modos de operación (Diagnóstico vs Amplificador)

**User Story:** Como usuario, quiero que la app distinga claramente cuándo
está operando con mi audiometría medida y cuándo no, y que en el modo "sin
audiometría" pueda regular cuánta amplificación recibo, para no estar
limitado a una curva fija ni a la prescripción completa cuando no fui
diagnosticado.

#### Acceptance Criteria

1. THE app SHALL exponer dos modos mutuamente excluyentes de operación: **Modo Diagnóstico** y **Modo Amplificador**. THE modo activo SHALL ser determinado automáticamente por la presencia o ausencia de un audiograma medido válido en `AudiogramRepository`, sin requerir acción manual del usuario.
2. WHEN existe un audiograma medido válido (12 frecuencias estándar dentro del rango `[-10, 120] dB HL`), THE app SHALL operar en **Modo Diagnóstico**: el `Bundle_Builder` deriva el bundle 100% del audiograma del paciente y el `gainScale` queda fijo en `1.00` sin opción de modificarlo.
3. WHEN no existe audiograma medido o el persistido es inválido, THE app SHALL operar en **Modo Amplificador**: el `Bundle_Builder` deriva el bundle del `Audiogram.defaultAudiogram()` (10 dB HL flat) y aplica `gainScale` configurable en `[0.10, 1.00]` con default `0.40`.
4. THE `gainScale` SHALL afectar exclusivamente al campo `gainsDb` del bundle mediante la operación `gainsDb[f] = clamp(prescribedGains[f] × gainScale, 0, 50)`. THE `gainScale` SHALL NOT modificar `mpoProfileDbSpl`, `compressionRatios`, `compressionKneesDbSpl` ni `nrLevel`, para preservar la protección del paciente y la lógica de compresión.
5. THE app SHALL exponer en la UI de Modo Amplificador un control deslizante con paso `0.05` y rango `[0.10, 1.00]` etiquetado como "Intensidad de amplificación" en español rioplatense, mostrando el valor actual como porcentaje (e.g. "40%"). THE control SHALL estar oculto o deshabilitado mientras el modo activo sea Diagnóstico.
6. WHEN el usuario modifica el `gainScale` en Modo Amplificador, THE bloc SHALL reconstruir el bundle aplicando el nuevo factor y SHALL despachar `ApplyAudiogramDrivenBundle` en ≤ 200 ms p95 desde la recepción del cambio.
7. THE app SHALL persistir el `gainScale` por dispositivo en Hive bajo la clave `amplifier_gain_scale` en `settings_box`, SHALL restaurarlo al iniciar la app, y SHALL aplicarlo al primer bundle del Modo Amplificador después del boot. WHEN no hay valor persistido, THE valor inicial SHALL ser `0.40`.
8. WHEN la app transita de Modo Amplificador a Modo Diagnóstico (al aplicarse una audiometría nueva via `applyToProfile`), THE app SHALL ignorar el `gainScale` previamente persistido para la prescripción activa, recomputar el bundle desde el audiograma medido con `gainScale = 1.00`, y despachar `ApplyAudiogramDrivenBundle` con el bundle nuevo.
9. WHEN la app transita de Modo Diagnóstico a Modo Amplificador (al borrar manualmente el audiograma medido o detectarse corrupción), THE app SHALL recomputar el bundle desde `defaultAudiogram()` con el `gainScale` persistido (o `0.40` si no hay), y SHALL emitir un evento observable que la UI pueda usar para mostrar el cambio de modo.
10. WHILE el modo activo sea Amplificador, THE UI SHALL renderizar un disclaimer persistente en español rioplatense con texto observable "Modo amplificador — sin audiometría medida. Para una prescripción personalizada, hacé la audiometría desde Servicio Técnico." THE disclaimer SHALL ocultarse cuando se transite a Modo Diagnóstico.
11. WHILE el modo activo sea Diagnóstico, THE UI SHALL renderizar junto al preset activo dos chips visibles con `LossType` y `prescriptionMode` (heredado del Requirement 12.3) e SHALL ocultar el control "Intensidad de amplificación".
12. THE bundle resultante en Modo Amplificador SHALL incluir un campo `mode = OperatingMode.amplifier` y `gainScale` con el valor aplicado, para que serialización JSON, presets personalizados y tests puedan distinguir bundles de uno y otro modo. THE bundle resultante en Modo Diagnóstico SHALL incluir `mode = OperatingMode.diagnostic` y `gainScale = 1.00`.
13. IF el `gainScale` recibido al construir el bundle está fuera del rango `[0.10, 1.00]` o es NaN/Infinity, THEN THE `Bundle_Builder` SHALL clampar al bound más cercano y SHALL emitir un warning observable. THE bundle SHALL construirse igualmente con el valor clampado, sin abortar la operación.
14. THE Modo Amplificador SHALL respetar todos los demás Requirements de la spec: la aplicación atómica del bundle (Req 4), el clamp por banda usando `mpoProfileDbSpl` (Req 10), el funcionamiento de Smart Scene (Req 7), los presets manuales (Req 5) y los `EnvironmentProfile` (Req 6) operan de la misma forma; lo único que cambia es el origen del audiograma base y el factor `gainScale` aplicado a las ganancias finales.

---

### Requirement 14: Ajustes manuales como delta sobre el bundle

**User Story:** Como audiólogo, cuando estoy en Modo Diagnóstico y el
usuario o yo movemos sliders, abrimos el EQ manual o cambiamos el volumen,
quiero que esos ajustes sumen sobre la prescripción de la audiometría
sin reemplazarla, para que el audiograma siempre sea la base y los
cambios manuales sean correcciones finas auditables.

#### Acceptance Criteria

1. WHILE el modo activo es Diagnóstico o Amplificador, THE app SHALL representar todo ajuste manual del EQ, volumen master, NR override, y parámetros WDRC editables como un `ManualAdjustmentDelta` aditivo sobre el bundle base, en lugar de un set absoluto que reemplaza al bundle.
2. THE `ManualAdjustmentDelta` SHALL incluir exactamente estos campos con sus rangos: `eqDeltaDb[12]` en `[-10, +10] dB` por banda, `volumeDeltaDb` en `[-10, +10] dB`, `nrLevelDelta` entero en `[-3, +3]`, `compressionRatioDelta` en `[-1.0, +1.0]`, `compressionKneeDeltaDbSpl` en `[-10, +10] dB SPL`, y `editedAt` (timestamp ISO 8601 UTC).
3. WHEN el usuario aplica un ajuste manual, THE bloc SHALL computar las ganancias finales como `finalGains[f] = clamp(bundle.gainsDb[f] + delta.eqDeltaDb[f], 0, 50)` y SHALL clamparlas además al headroom por banda definido en Req 10.3 (`finalGains[f] ≤ mpoProfileDbSpl[f] - input_db_spl[f] - 3.0`).
4. WHEN el usuario aplica un ajuste manual al volumen, NR, ratio o knee, THE bloc SHALL aplicar el delta sobre el campo correspondiente del bundle clampando al rango declarado en Req 1.2, sin permitir que el ajuste manual baje el MPO ni desactive la limitación.
5. THE selección de un ajuste manual SHALL despachar `ApplyAudiogramDrivenBundle` con el bundle base + delta aplicado, no `UpdateEqGains` puro.
6. WHILE el modo activo es Diagnóstico, THE app SHALL persistir el `ManualAdjustmentDelta` por dispositivo en Hive bajo la clave `manual_delta_diagnostic` en `settings_box` y SHALL restaurarlo al boot. WHILE el modo activo es Amplificador, THE app SHALL persistir el delta bajo `manual_delta_amplifier`.
7. WHEN el `_onUpdateAudiogram` detecta que el audiograma cambió con MAD > 5 dB respecto al persistido (Req 9.1), THE bloc SHALL marcar el `manual_delta_diagnostic` actual como `stale = true` y SHALL ofrecer al usuario tres opciones observables: "reaplicar delta", "descartar delta" o "regenerar delta proporcionalmente". WHILE el delta esté stale, la UI SHALL mostrar un indicador visible.
8. THE `SaveCustomPreset` SHALL persistir el `ManualAdjustmentDelta` activo junto al bundle (Req 8.1), de modo que al recargar el preset se restauren tanto el bundle como el delta como entidades separadas.
9. WHEN el usuario elige "Resetear ajustes manuales" en la UI, THE bloc SHALL limpiar el `ManualAdjustmentDelta` activo (todos los campos a cero), SHALL despachar `ApplyAudiogramDrivenBundle` con el bundle base puro, y SHALL persistir el reset.
10. IF un `ManualAdjustmentDelta` cargado de Hive contiene valores fuera de los rangos declarados en el criterio 2, THEN THE app SHALL clampar al bound más cercano y SHALL emitir un warning observable, sin abortar la carga.
11. WHILE el modo activo es Diagnóstico y el usuario abre la pantalla de "EQ manual", THE UI SHALL mostrar simultáneamente el bundle base derivado del audiograma (línea de referencia visible) y la curva con delta aplicado, en español rioplatense, para que el ajuste manual sea siempre auditable contra la prescripción del audiograma.

---

### Requirement 15: Veracidad clínica end-to-end de audiograma a salida

**User Story:** Como auditor regulatorio o como audiólogo, quiero
garantizar que lo que el usuario carga en la audiometría es lo que
queda persistido en la API, lo que se prescribe es la prescripción
clínica publicada, y lo que sale del audífono es coherente con esa
prescripción dentro de tolerancia clínica, para que el sistema sea
defendible como dispositivo médico.

#### Acceptance Criteria

**Tramo 1 — Audiograma → API (sin distorsión de datos)**

1. WHEN el usuario completa la audiometría con un umbral conocido por banda, THE persistencia (`AudiogramRepository.saveAudiogram` + `AudiometryStore.saveLast`) SHALL conservar cada umbral con error absoluto ≤ 0.001 dB HL respecto al valor capturado por el `AudiometryEngine`.
2. WHEN el repositorio devuelve el audiograma persistido (`getAudiogram()`), THE valor retornado SHALL coincidir bit a bit con lo persistido para campos enteros y string, y dentro de ≤ 0.001 dB HL para los umbrales en double.
3. THE round-trip de `AudiometryResult.toJson()` + `AudiometryResult.fromJson()` SHALL preservar todos los campos (incluyendo `outOfRange`, `normalLimit`, `retest1000Diff`) sin pérdida de información.
4. THE test suite SHALL incluir un test que ejecute la cadena completa `AudiometryEngine.recordResponse → AudiometryStore.saveLast → AudiometryStore.loadLast → AudiometryResult.toAudiogram → AudiogramRepository.saveAudiogram → AudiogramRepository.getAudiogram` con audiogramas Bisgaard N1–N7 y verifique conservación bit a bit.

**Tramo 2 — API → Prescripción (fidelidad a la fórmula publicada)**

5. THE test suite SHALL incluir fixtures de referencia con los 10 audiogramas Bisgaard (N1–N7 + S1–S3) y la prescripción NAL-NL2 esperada por banda según la tabla publicada en Keidser et al. 2011 (Audiology Research 1(1):e24).
6. WHEN el `Bundle_Builder` se ejecuta sobre un audiograma Bisgaard con `mode = quiet` y perfil de adulto experimentado, THE bundle resultante SHALL coincidir con la prescripción de referencia dentro de ±0.5 dB por banda en `gainsDb` para input 65 dB SPL, y dentro de ±0.05 en `compressionRatios`.
7. WHEN el `Bundle_Builder` se ejecuta con un perfil pediátrico (`ageYears < 18`), THE `mpoProfileDbSpl` resultante SHALL respetar la regla `MPO[f] ≤ 110 dB SPL` para todas las bandas, y SHALL coincidir con la fórmula `min(UCL[f] - 10, 110)` dentro de ±0.1 dB SPL.
8. THE `UCL_Estimator` SHALL ser validado contra la fórmula publicada `UCL = 100 + 0.15 × HL` con error absoluto ≤ 0.01 dB SPL en al menos 100 audiogramas generados.
9. THE conversión HL → SPL en oído real (cuando `mic-calibration` provea `splOffset` y RECD predicho por edad esté disponible) SHALL coincidir con la fórmula `SPL_realear[f] = HL[f] + RETSPL[f, transducer] + RECD[f, age]` dentro de ±0.1 dB SPL contra fixtures derivados de ANSI S3.6-2018 y Bagatto 2005.
10. IF cualquier fixture del Tramo 2 desvía más de la tolerancia declarada, THEN THE CI SHALL bloquear el merge y SHALL reportar la banda, el valor esperado, el observado y el delta.

**Tramo 3 — Prescripción → Audífono (loopback físico real)**

11. THE proyecto SHALL incluir un protocolo de QC manual `docs/qc/loopback-validation.md` que describa el setup mínimo (smartphone Android target + audífono PSK conectado por BLE/cable + micrófono de medición tipo IEC 61672 Clase 2 + acoplador 2cc IEC 60318-5 + sonómetro o app de medición calibrada) y los pasos para medir el SPL real entregado por el audífono cuando se aplica un audiograma de referencia.
12. THE protocolo de loopback SHALL definir al menos cinco audiogramas de prueba (Bisgaard N2 leve, N4 moderada-severa, S2 ski-slope moderada, plano 30 dB HL, y plano 60 dB HL) y para cada uno un set de inputs de referencia (50, 65, 80 dB SPL warble tone en 250, 1000, 4000 Hz).
13. THE protocolo SHALL especificar que para cada combinación audiograma × frecuencia × input, el SPL medido en el acoplador (más RECD del adulto si corresponde) SHALL estar dentro de ±5 dB del SPL prescrito por el `Bundle_Builder` (alineado con la tolerancia clínica BAA REMS 2018 y AudiologyOnline 28708).
14. THE protocolo SHALL ser ejecutado y firmado antes de cada release etiquetado como "production" en el `audit_trail_box`, con el resultado del QC adjunto en formato PDF (operador, fecha, equipo de medición, audiogramas probados, tabla de mediciones, pass/fail final).
15. IF el QC manual reporta una desviación mayor a ±5 dB en alguna combinación, THEN THE release SHALL ser bloqueado y se SHALL abrir un ticket de auditoría que identifique audiograma, frecuencia, input, SPL esperado, SPL medido y delta.
16. THE app SHALL incluir un modo "Loopback test" en la pantalla de Servicio Técnico (oculto detrás de un PIN o flag de operador) que reproduzca los warble tones del protocolo y muestre las mediciones esperadas en la UI, para facilitar la ejecución del QC sin requerir scripts externos.

**Cobertura de los dos modos**

17. THE Tramo 2 (validación numérica) SHALL ejecutarse igual en Modo Diagnóstico (audiograma medido) y en Modo Amplificador (`defaultAudiogram()` + `gainScale`); en Modo Amplificador la prescripción de referencia es la fórmula NAL-NL2 sobre `defaultAudiogram` multiplicada por `gainScale` con tolerancia ±0.5 dB.
18. THE Tramo 3 (loopback físico) SHALL incluir una corrida del Modo Amplificador con `gainScale ∈ {0.10, 0.40, 1.00}` para verificar que el escalado de ganancias también es médicamente coherente y respeta el MPO en todos los casos.

## Non-functional Requirements

- **Determinismo:** el `Bundle_Builder` y todas las funciones derivadas (UCL, MPO, estilos) son puras. Ninguna usa `DateTime.now()` salvo el campo `derivedAt`, que es inyectable.
- **Performance:** la construcción del bundle más la aplicación atómica al motor completan en menos de 200 ms p95 en hardware Snapdragon 700-series o superior con Android 10+.
- **Compatibilidad:** el código existente de `GainPrescriber`, `GainPrescriberNL3`, `MhlModule`, `CinModule` y `EqPreset` se conserva; los cambios son aditivos. La firma de `AudioBridge` solo gana un método nuevo (`setMpoThresholdDbSpl`).
- **Idioma:** comentarios y mensajes de error en español rioplatense; identificadores en inglés.
- **Documentación inline:** Dartdoc completo en todo el módulo nuevo con referencias bibliográficas.
- **Testing coverage:** target 95% de líneas en el módulo `audiogram_driven_presets/`. Tests property-based ejecutándose en CI.

## Out of Scope

- Implementación de MPO por banda en el motor C++ nativo (la spec define la interfaz `setMpoProfileDbSpl` como reservada para futuro, pero el handler aplica solo broadband con `min(mpoProfile)`). Se cubrirá en una spec posterior.
- Migración del módulo a `core-clinico-compartido` (Sprint 3 de esa spec).
- Audiograma bilateral OD/OI en la app nativa (decisión documentada: queda fuera del alcance comercial actual).
- DSL v5 pediátrica completa.
- Calibración de mic in-app (cubierta por `mic-calibration`).
- Ajuste fino subjetivo por loudness scaling (ACALOS).
- Cambios en el simulador web (cubiertos por `audiogram-window-overhaul`).
- Frequency lowering / NLFC.
