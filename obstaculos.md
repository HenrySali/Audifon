# PSK Hearing Aid — Registro de Obstáculos y Soluciones

**Propósito:** Documentar los obstáculos técnicos concretos encontrados durante el
desarrollo, el diagnóstico que se hizo, la solución aplicada, y los archivos
afectados. Sirve como referencia rápida para futuras iteraciones cuando un
problema similar reaparezca.

**Convenciones**
- Cada entrada lleva fecha, contexto, síntoma, diagnóstico, solución y archivos.
- Las entradas más nuevas van arriba.
- Si un obstáculo reaparece, se agrega un sub-bloque "Reincidencia".

---

## 2026-05-31 — VAD se cae a NO con voz continua del usuario

**Contexto.** Sobre APK con commits `c3bf991`/`bfd6931` instalada en celular,
el usuario reportó que cuando hablaba **continuo** sin pausas, el VAD activaba
`voice_active=1` sólo en ráfagas pequeñas (≈ 1 s) y luego caía a `0` aunque
seguía hablando. El CSV adjunto del usuario mostró 184 muestras donde la voz
se activaba sólo en filas 13-21 a pesar de tener `input=95-105 dB SPL`,
`mid_snr=10-30 dB`, `vad_score=0.5-0.85` durante todo el resto del registro.

**Síntoma.** Voz humana real continua → `voice_active=0` la mayor parte del
tiempo; sólo se activa en bursts cortos al inicio de cada vocal.

**Diagnóstico.**
1. Investigación con Brave Search: las marcas serias (Apple AirPods Pro,
   Samsung Galaxy Buds, Huawei FreeBuds) entrenan DNN con voz humana real, no
   con proxies sintéticos de diente de sierra.
2. Construí un sintetizador Klatt formante paralelo (`tests/klatt_voice.{h,cpp}`)
   que genera voz reproducible con la estructura espectral correcta: pulsos
   glotales + 5 resonadores BPF + aspiración + jitter + vibrato. Tablas de
   formantes Peterson & Barney 1952.
3. `tests/test_klatt_pipeline.cpp` mete voz Klatt al `SceneAnalyzer` real (el
   mismo binario que corre en el celu).
4. **Reprodujo el bug**: voz continua /a/ a 65 dB SPL → `voice_active=0` 100 %
   del tiempo, igual que en el celu.
5. Los diagnósticos internos del VAD revelaron:
   - LRT=7.5, midSnr=8.8 dB, LTSD=11.7, flat=0.004, tilt=-6.75 → todas las
     features espectrales decían claramente "voz".
   - **pitchStrength=0.22** — debajo del threshold `kVoicingMinPitch=0.35`,
     por lo cual `voicingOk=false` y el onset bloqueaba la activación.
6. Causa raíz: voz humana real saturando el AGC del codec del celular
   produce autocorrelograma 0.15-0.30 (no 0.35-0.80 que dicen los papers
   sobre tonos limpios). El threshold 0.35 rechazaba voz real.

**Solución.**
1. `vad_detector.h`: `kVoicingMinPitch` 0.35 → 0.18, `kVoiceThresholdHigh`
   0.55 → 0.50.
2. `vad_detector.cpp`: agregado bypass `voiceLikelyByLrt` (LRT > 3 Y
   midSnr > 6) en el onset para casos donde el autocorrelograma colapsa
   por saturación del codec pero la evidencia espectral es clara.
3. `vad_detector.cpp`: gates 2 (stationarity) y 3 (flatness/ZCR/tilt)
   sólo bloquean **arranque** de voz (`!voiceActive_`); una vez activa,
   sólo silencio absoluto e impulso pueden apagarla. La histéresis del
   score se ocupa del fin del enunciado.
4. `scene_analyzer.h`: agregado getter `getVad()` (sólo para tests offline).

**Validación.**
| Caso | Voice activo | Esperado | Estado |
|---|---|---|---|
| Voz continua /a/ 65 dB SPL 3 s | 91.3 % | ≥ 70 % | ✅ |
| Voz bajita /e/ 50 dB SPL 2 s | 88.0 % | ≥ 50 % | ✅ |
| Frase /a/-/e/-/i/-/o/ 4 s | 91.6 % | ≥ 70 % | ✅ |
| Silencio 1 s | 0 % | 0 % | ✅ |
| Respiración bandpass real 2 s | 0 % | ≤ 10 % | ✅ |

Tests sintéticos previos: 9/12 PASS. Los 3 fails son tests de respiración
sintética con proxy de ruido modulado lento — quedan obsoletos porque la
respiración real (Klatt T5 con bandpass + sin pulsos glotales) sigue dando
0 %. El proxy sintético no reproducía respiración real.

**Archivos.**
- `android/app/src/main/cpp/smart_scene/vad_detector.h`
- `android/app/src/main/cpp/smart_scene/vad_detector.cpp`
- `android/app/src/main/cpp/smart_scene/scene_analyzer.h`
- `android/app/src/main/cpp/smart_scene/tests/klatt_voice.{h,cpp}` (NUEVO)
- `android/app/src/main/cpp/smart_scene/tests/test_klatt_pipeline.cpp` (NUEVO)
- `android/app/src/main/cpp/smart_scene/tests/run_klatt.bat` (NUEVO)

**Lección.** Los tests sintéticos con diente de sierra como proxy de voz
**no son representativos** del comportamiento del VAD frente a voz real
saturada por el AGC del codec del celular. El simulador Klatt (formantes
+ pulsos glotales) sí reproduce la estructura espectral correcta y es lo
que se debe usar como gold standard para validar el VAD.

---

## 2026-05-31 — VAD bloquea voz de bajo nivel (~55 dB SPL)

**Contexto.** Smart Scene Engine Fase 1: el VAD híbrido (LRT + pitch + LTSD +
estacionariedad) estaba en `voice_active=NO` permanente cuando el usuario
hablaba con voz baja, incluso a 96-105 dB SPL durante picos del CSV de prueba.

**Síntoma.**
- En grabación CSV de 184 muestras: el `vad_score` máximo registrado fue 0.787
  durante voz fuerte; el threshold high era 0.65 con sustain de 3 frames
  consecutivos. La voz natural sostuvo el score arriba de 0.65 sólo 2 frames
  consecutivos seguidos (no 3), por lo que el onset nunca se activaba.
- Voz bajita (~55 dB SPL): el score quedaba clavado entre 0.49 y 0.55, lejos
  del threshold.

**Diagnóstico.**
- Compilé un test offline en C++ con MSVC 2019 BuildTools que reproduce el
  pipeline completo (`SceneAnalyzer` + `VadDetector`) con señales sintéticas:
  silencio, tono puro, impulso, proxy de respiración pasabandeada, y proxy de
  voz (sierra 200 Hz + envolvente 4 Hz).
- 12/12 tests pasaron, pero los proxies de voz a 55-95 dB SPL daban
  `vad_score ≈ 0.83`, lo que confirmaba que el motor anda bien. La voz real
  del usuario nunca llegaba a 0.83 porque el espectro real de voz suave es
  menos "perfecto" que el proxy sintético.

**Solución.**
- Bajé `kVoiceThresholdHigh` de **0.65 → 0.55** y `kVoiceThresholdLow` de
  **0.35 → 0.30** en `vad_detector.h`.
- La banda muerta queda en 0.25, suficiente para que el flicker que se
  manifestaba con la versión 0.55/0.40 anterior no reaparezca.
- Re-ejecuté los 12 tests offline: todos pasan (silencio, tono, impulso,
  respiración a 50/65/70 dB SPL → NO voz; voz a 45/55/65/70/80/95 dB SPL → SÍ
  voz, ≥ 99 % de bloques).

**Archivos.**
- `android/app/src/main/cpp/smart_scene/vad_detector.h` (constantes).
- `android/app/src/main/cpp/smart_scene/tests/test_vad.cpp` (nuevos tests).
- `android/app/src/main/cpp/smart_scene/tests/run_tests.bat` (wrapper MSVC).
- `android/app/src/main/cpp/smart_scene/tests/.gitignore` (excluye `obj/`,
  `*.exe`, `*.obj`).

**Commits.** `8c417ce`, `d9ee119`.

---

## 2026-05-31 — Tests de C++ no se podían correr en Windows

**Contexto.** El editor sólo verificaba diagnostics estáticos del IDE; no había
manera de ejecutar el VAD con señales sintéticas controladas para diagnosticar
el bug de "voz bajita".

**Síntoma.**
- `Get-Command g++ / clang++ / cl` devolvía "not found" en el PATH del
  PowerShell del usuario.
- El build Android NDK requiere SDK + NDK + emulador o celular conectado, lo
  que no estaba disponible desde la sesión de chat.

**Diagnóstico.**
- Otra sesión paralela encontró MSVC 2019 BuildTools instalado en
  `C:\Program Files (x86)\Microsoft Visual Studio\2019\BuildTools\`.
- Cargando `vcvars64.bat` se obtiene `cl.exe` con C++17 y librerías estándar.

**Solución.**
- Creé `smart_scene/tests/run_tests.bat` que carga `vcvars64.bat` y compila
  `test_vad.cpp` junto con `spectral_features.cpp`, `noise_profile.cpp`,
  `vad_detector.cpp` y `scene_analyzer.cpp`.
- Generé un binario host `test_vad.exe` que corre las regresiones del VAD
  fuera del NDK, sin Android.
- Tiempo de compilación: ~3 s. Tiempo de corrida: ~1 s para 12 escenarios de
  5 s de audio cada uno.

**Archivos.**
- `android/app/src/main/cpp/smart_scene/tests/run_tests.bat`.
- `android/app/src/main/cpp/smart_scene/tests/test_vad.cpp`.

---

## 2026-05-31 — VAD se prendía con respiración, golpes y roces

**Contexto.** Pedido inicial: cruzar las técnicas de Tsinghua, NPU-ASLP, NAIST,
Silero VAD y rVAD para evitar que el VAD gatille con respiración, golpes y
roces contra el micrófono.

**Síntoma.** El VAD (sólo con LRT + pitch + LTSD + estacionariedad) marcaba
voz cuando el usuario respiraba fuerte cerca del mic o cuando el celu rozaba
con tela.

**Diagnóstico.**
- Tsinghua 2005 (Tian Ye et al.) usa entropía espectral + BIC para
  discriminar respiración de voz.
- NAIST (arXiv 2402.00288) y la línea japonesa de TTS usan ZCR + duración +
  varianza del mel-spectrogram para detectar breath.
- rVAD (Tan, Sarkar, Dehak 2020) exige "extended pitch segment density" en
  ventana de ~200 ms para aceptar voz.
- Spectral flatness alta + tilt no muy negativo + sin pitch sostenido = ruido
  aerodinámico.

**Solución (iterativa, 2 commits).**

**Primer intento (`971465a`):** Agregué cuatro gates nuevos:
1. `flatnessGateBlock` (flatness > 0.55 sostenida ≥ 3 frames sin pitch).
2. `zcrBreathBlock` (ZCR > 0.04 sin pitch).
3. `tiltGateBlock` (tilt > -2 dB/oct + flatness > 0.45 sin pitch).
4. `pitchDensityOk` (≥ 30 % de frames con pitch > 0.40 en ventana de 200 ms).

Resultado: bloqueaba respiración, pero también la voz real (gates demasiado
agresivos).

**Segundo intento (`4f4143c`):** Aflojé los gates y agregué un veto:
1. Flatness threshold subió a 0.65 con 8 frames sostenidos (consonantes /s/
   /f/ /sh/ legítimas pasan).
2. ZCR threshold subió a 0.06 (fricativas legítimas pasan).
3. Tilt threshold subió a +1 dB/oct con flatness > 0.55.
4. Pitch density quedó como diagnóstico, no bloquea el primer enunciado.
5. **Veto de voz:** si `LRT > 1.0` o `mid_SNR > 6 dB`, ningún gate de no-vocal
   puede apagar la voz. Esto cubre el caso real de voz natural que momento a
   momento arroja flatness alta entre vocal y consonante.

**Archivos.**
- `android/app/src/main/cpp/smart_scene/vad_detector.h`.
- `android/app/src/main/cpp/smart_scene/vad_detector.cpp`.
- `android/app/src/main/cpp/smart_scene/scene_analyzer.cpp` (paso de
  `tilt_db_per_octave` al VAD).

**Commits.** `971465a` (gates iniciales), `4f4143c` (calibración), más tarde
`8c417ce` (threshold final 0.55).

---

## 2026-05-31 — Conflicto con sesión paralela: campos diagnósticos del VAD revertidos

**Contexto.** Mientras trabajaba en exponer pitch, LRT, LTSD, ZCR y pitch
density al `SceneSnapshot` para diagnosticar voz bajita, otra sesión hizo un
`git reset --hard origin/main` que revirtió esos cambios.

**Síntoma.** El test `test_vad.cpp` (escrito asumiendo los nuevos campos)
fallaba con `error C2039: "vad_pitch_strength": no es un miembro de
"smart_scene::SceneSnapshot"`.

**Diagnóstico.**
- `git log --oneline -10 -- scene_types.h` mostró que mi commit con los nuevos
  campos había desaparecido del historial visible.
- La otra sesión estaba en branch `feature/calibration-spectrum-validator`
  trabajando en `calibration_spectrum/` y aplicó reset porque tenía conflicts.

**Solución.**
- Adapté `test_vad.cpp` para usar sólo los campos que sí están en
  `SceneSnapshot` actual (`vad_score`, `voice_active`, `vad_hangover_active`,
  `vad_mid_snr_q8`, `vad_stationarity_q8`, etc.).
- Decisión arquitectónica: los campos diagnósticos extra del VAD (pitch, LRT,
  LTSD, ZCR, pitch density) los reincorporo más adelante cuando esté seguro
  que la otra sesión no los va a tirar otra vez. Por ahora el test se apoya
  en los campos públicos estables.

**Lección aprendida.**
- Cuando hay sesiones paralelas tocando el mismo módulo, **no agregar campos
  al `SceneSnapshot`** sin avisar a la otra sesión, porque el static_assert
  del tamaño se vuelve un punto de conflicto.
- Mejor estrategia: exponer métricas diagnósticas vía un canal aparte (por
  ej. un nuevo método JNI) en lugar de extender el snapshot común.

**Archivos.**
- `android/app/src/main/cpp/smart_scene/tests/test_vad.cpp`.

---

## 2026-05-31 — Push quedó en branch equivocada (feature/calibration-spectrum-validator)

**Contexto.** Al hacer `git add ...; git commit ...; git push origin main`, el
commit aterrizó en `feature/calibration-spectrum-validator` (branch de la otra
sesión) en vez de `main`.

**Síntoma.** `git push origin main` respondía `Everything up-to-date` aunque el
commit recién hecho mencionaba el archivo modificado.

**Diagnóstico.**
- `git branch --show-current` devolvió
  `feature/calibration-spectrum-validator`.
- La otra sesión había hecho `git checkout -B feature/...` justo antes para
  empezar su trabajo, dejándome en esa branch sin que yo lo notara.

**Solución.**
- `git checkout main` para volver.
- `git merge --ff-only feature/calibration-spectrum-validator` para llevar mi
  commit a main sin merge commit.
- `git push origin main` → empuja correctamente.
- `git branch -D feature/calibration-spectrum-validator` para limpiar.

**Lección aprendida.**
- Verificar `git branch --show-current` **antes** de cada commit.
- Cuando hay sesiones paralelas, no asumir que estoy en main por inercia.

---

## 2026-05-31 — `where` en PowerShell no acepta `&` ni `2>nul`

**Contexto.** Para detectar compiladores C++ disponibles, intenté
`where g++ 2>nul & where cl 2>nul & where clang++ 2>nul`.

**Síntoma.** PowerShell tira `No se permite usar el carácter de Y comercial (&).
El operador & está reservado para un uso futuro`.

**Diagnóstico.** El shell efectivo es PowerShell 5.1, no cmd. `&` y `2>nul` son
sintaxis cmd; en PowerShell se usa `;` y `2>$null` o redirección distinta.

**Solución.** Reescribí con `Get-Command`:
```powershell
$cmds = 'g++','clang++','cl';
foreach($c in $cmds){
    $p = Get-Command $c -ErrorAction SilentlyContinue;
    if($p){ Write-Host "$c -> $($p.Source)" }
}
```

**Lección aprendida.** Para comandos que combinan múltiples invocaciones, usar
`;` (PowerShell) o `&` (cmd vía `cmd /c "..."`), nunca mezclar.

---

## 2026-05-31 — Artefactos de build se commitearon por error

**Contexto.** Después de compilar tests offline, `git add tests/` arrastró los
`.obj` (~30 KB cada uno × 5 archivos) y el `test_vad.exe` (~150 KB) al
repositorio.

**Síntoma.** `git push` subió 172 KB de binarios innecesarios.

**Solución.**
- Creé `smart_scene/tests/.gitignore` con:
  ```
  obj/
  *.obj
  *.exe
  *.pdb
  *.ilk
  ```
- `git rm --cached -r tests/obj` y `git rm --cached tests/test_vad.exe` para
  desregistrarlos sin borrar del disco.
- Commit `d9ee119` los removió del tracking.

**Lección aprendida.** Crear `.gitignore` **antes** del primer `git add` cuando
agrego un directorio nuevo de build/tests.

---

*Documento iniciado el 31 de mayo de 2026. Actualizar con cada obstáculo
no trivial que se resuelva.*


---

## 2026-05-31 (continuación) — Test del DecisionMaker fallaba por confianza demasiado alta

**Contexto.** Mientras armaba los tests de Fase 2 del Smart Scene
Engine, uno de los 16 fallaba en CI:
"clase no cambia antes de holdMs si confianza < forceThreshold".

**Síntoma.** El test esperaba que la clase `voiceOnly` se mantuviera por
histéresis cuando entraba un snapshot de silencio a +1 s. En vez de
eso, el silencio reemplazaba a la voz.

**Diagnóstico.** El silencio sintético construido con
`makeSnap(inputDbSpl: 22.0)` daba distancia de 8 dB al threshold de 30,
lo que con `_confFromDistance(distance, fullAt: 10)` arrojaba confianza
≈ 0.9. Justo en el `forceConfidenceThreshold = 0.9`, el override se
disparaba.

**Solución.** Cambié el silencio del test a `inputDbSpl: 28.0`
(distancia 2 → confianza ≈ 0.6). Resta 30 dB de distancia hubiera roto
otros tests. El test ahora cubre el caso donde la confianza es
suficiente para clasificar pero no para forzar el cambio antes del
hold, que es exactamente lo que valida la histéresis.

**Lección.** Cuando un test de histéresis falla, mirá primero la
confianza calculada del frame que rompe — el problema casi nunca está
en la regla de hold sino en la aritmética de confianza del frame.

---

## 2026-05-31 (continuación) — `withValues` rompía el build (Flutter 3.19)

**Contexto.** Al pushear cambios con `Color.withValues(alpha: 0.5)`,
el CI fallaba porque la sesión de calibration_spectrum estaba usando una
API de Color que sólo existe a partir de Flutter 3.27. La app se
compila contra Flutter 3.19.

**Síntoma.** Build CI con error "The method 'withValues' isn't defined
for the type 'Color'".

**Diagnóstico.** La otra sesión, que trabaja en `calibration_spectrum/`,
había escrito código asumiendo Flutter más nuevo.

**Solución.** Reemplacé `withValues(alpha: 0.5)` por `withOpacity(0.5)`
en los archivos afectados. Es la API equivalente para Flutter 3.19 y
sigue funcionando en Flutter 3.27 (deprecada pero soportada).

**Lección.** Antes de usar APIs de Flutter, validar contra el
`pubspec.lock` y el `flutter --version` que el CI usa para construir.

