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
