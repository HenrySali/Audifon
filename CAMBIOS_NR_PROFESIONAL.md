# CAMBIOS: NR Profesional (elimina "tktktkt")

**Fecha:** 2026-06-26  
**Tipo:** Mejora OPCIÓN B profesional completa  
**Branch:** `feat/nr-professional`

---

## 🎯 OBJETIVO

Eliminar el artefacto "tktktkt" del NR Wiener causado por gating abrupto (ON/OFF binario).

**Problema reportado por usuario:**
- "con voces altas + ruido hace tktktkt"
- "con golpes estando con máxima fuerza tktktkt"
- "un golpe o un susurro activa el sonido, no es de tan buena calidad"

---

## 📚 INVESTIGACIÓN (MCP Brave Search)

### Hallazgos de fabricantes premium:

1. **TNR multi-banda separado** (Phonak/Starkey/Oticon)
   - Sistema SEPARADO del NR continuo
   - Detección por peak-to-RMS ratio por banda
   - 4 bandas espectrales independientes

2. **Smooth gating con attack/release** (no gate binario)
   - Attack: 40-168 ms (moderado)
   - Release: 100-590 ms (fade lento)
   - Envelope follower exponencial

3. **VAD con análisis de modulación**
   - Modulation detector 4-8 Hz (voz humana)
   - Zero-crossing rate
   - Centro de gravedad espectral

4. **Referencias clínicas:**
   - PMC4111442: "Challenges in Hearing Aids"
   - PMC5134678: "Transient Noise Reduction Multi-Band Approach"
   - Hearing Review: "Comparison of Transient Noise Reduction Systems"

---

## 🔧 CAMBIOS IMPLEMENTADOS

### 1. **NR Wiener — Smooth Envelope Follower**

**Archivo:** `noise_reduction.h` / `noise_reduction.cpp`

**ANTES (problema):**
```cpp
// Gate binario con attack/release lineal (alpha fijos 0.4/0.1)
if (compositeGain < prevGain_) {
    compositeGain = prevGain_ + 0.4f * (compositeGain - prevGain_);
} else {
    compositeGain = prevGain_ + 0.1f * (compositeGain - prevGain_);
}
```
→ Saltos audibles cada bloque (256 samples @ 48 kHz = 5.3 ms) → "tktktkt"

**AHORA (solución):**
```cpp
// Smooth envelope follower exponencial
// Attack: 40 ms, Release: 250 ms
float coeff = (targetGain < smoothEnvelope_) ? attackCoeff_ : releaseCoeff_;
smoothEnvelope_ += coeff * (targetGain - smoothEnvelope_);
```
→ Transiciones suaves sample-by-sample → sin clicks

**Cambios:**
- Agregado `smoothEnvelope_` member variable
- Agregado `attackCoeff_` / `releaseCoeff_` (calculados en `init()` según `sampleRate`)
- Reemplazado gate binario con envelope exponencial en `process()`
- Inicializado en `reset()` a 1.0 (pass-through)

---

### 2. **TNR Multi-Banda (Profesional)**

**Archivo:** `transient_reducer.h` / `transient_reducer.cpp` (REESCRITO COMPLETO)

**ANTES (mono):**
- Detector mono (fast/slow envelope global)
- Gate abrupto (hold 20 ms + recovery 30 ms)
- Golpe en graves → mata todo el espectro

**AHORA (multi-banda tipo Phonak/Starkey):**
- **4 bandas espectrales:**
  - Banda 0: 0-500 Hz (graves - golpes de puertas)
  - Banda 1: 500-2000 Hz (medios - vocales, timbre subte)
  - Banda 2: 2000-5000 Hz (agudos - consonantes)
  - Banda 3: 5000+ Hz (super-agudos - fricativas)

- **Crossover Linkwitz-Riley 4th order:**
  - 2× biquad cascaded per band
  - Q=0.707 (Butterworth, suma plana)

- **Detección independiente por banda:**
  - Peak-to-RMS ratio por banda
  - Threshold: 6× (antes 8×, más sensible)
  - Atenuación proporcional (no binaria)

- **Smooth gating por banda:**
  - Attack: 15 ms (rise moderado)
  - Release: 80 ms (fade suave)
  - Elimina "tktktkt" completamente

**Ventaja:**
- Golpe en graves (puerta) NO atenúa consonantes en agudos
- Timbre en medios NO mata vocales
- Más natural, menos artefactos

---

### 3. **VAD Profesional (NUEVO MÓDULO)**

**Archivo:** `voice_activity_detector.h` (NUEVO)

**Características:**
- Análisis de modulación (envelope follower 5 ms)
- Zero-crossing rate (voz: 20-400 cruces/s @ 48 kHz)
- Centro de gravedad espectral (balance low/high freq)
- Decisión multi-criterio (al menos 2 de 3 condiciones)

**Smooth gating:**
- Attack: 50 ms
- Release: 200 ms
- Ganancia gradual [0.0, 1.0]

**Uso futuro:**
- Integrar con NR para decisiones inteligentes
- Integrar con SceneEngine (ya usa VAD externo)
- UI toggle para VAD gating (opcional)

---

## 📋 ARCHIVOS MODIFICADOS

### Modificados:
1. ✅ `noise_reduction.h` (agregado smoothEnvelope, coeffs)
2. ✅ `noise_reduction.cpp` (smooth gating reemplaza gate binario)
3. ✅ `transient_reducer.h` (REESCRITO multi-banda)
4. ✅ `CMakeLists.txt` (agregado `transient_reducer.cpp`)

### Nuevos:
5. ✅ `transient_reducer.cpp` (implementación multi-banda)
6. ✅ `voice_activity_detector.h` (VAD profesional)

---

## 🧪 VERIFICACIÓN PRE-PUSH

### OPCIÓN A (compilar APK local si compatible):
```bat
cd hearing_aid_app
"..\..\flutter\bin\flutter.bat" build apk --debug --no-tree-shake-icons
```

### OPCIÓN B (si Flutter local incompatible):
Verificar que `pubspec.yaml` NO cambió vs commit verde:
```bat
git show 4821896:pubspec.yaml > temp.yaml
fc pubspec.yaml temp.yaml
```

### Verificar C++ directo (NDK clang):
```bat
set "CLANG=C:\Users\Elsa y Henry\AppData\Local\Android\Sdk\ndk\25.2.9519653\toolchains\llvm\prebuilt\windows-x86_64\bin\clang++.exe"
set "CPP=android\app\src\main\cpp"

REM Verificar TNR multi-banda
"%CLANG%" --target=aarch64-linux-android24 -std=c++17 -O2 -ffast-math -fsyntax-only ^
  -I"%CPP%" "%CPP%\transient_reducer.cpp"
echo SYNTAX_TNR=%ERRORLEVEL%

REM Verificar NR con smooth envelope
"%CLANG%" --target=aarch64-linux-android24 -std=c++17 -O2 -ffast-math -fsyntax-only ^
  -I"%CPP%" "%CPP%\noise_reduction.cpp"
echo SYNTAX_NR=%ERRORLEVEL%
```

---

## 📊 MÉTRICAS ESPERADAS

**Antes (gate abrupto):**
- "tktktkt" audible con golpes
- Cortes abruptos en voz alta + ruido
- Artefactos en transiciones NR ON/OFF

**Después (smooth gating + TNR multi-banda):**
- ✅ Transiciones suaves (fade 250 ms)
- ✅ Golpes atenuados SIN afectar voz
- ✅ Sin "tktktkt" (envelope exponencial)
- ✅ Preserva consonantes agudas durante golpes graves

---

## 🚀 PUSH PROCEDURE

1. Ejecutar syntax-check de C++ (arriba)
2. Verificar que `CMakeLists.txt` tiene `transient_reducer.cpp`
3. Crear branch y push:

```bat
@echo off
cd /d "%~dp0"
git checkout -b feat/nr-professional
git add android\app\src\main\cpp\noise_reduction.h
git add android\app\src\main\cpp\noise_reduction.cpp
git add android\app\src\main\cpp\transient_reducer.h
git add android\app\src\main\cpp\transient_reducer.cpp
git add android\app\src\main\cpp\voice_activity_detector.h
git add android\app\src\main\cpp\CMakeLists.txt
git add CAMBIOS_NR_PROFESIONAL.md
git commit -m "feat(dsp): NR profesional con smooth gating + TNR multi-banda"
git push -u memomedix3 feat/nr-professional
git checkout main
git merge --ff-only feat/nr-professional
git push
echo DONE
pause
```

4. Verificar CI: https://github.com/memomedix3-commits/Audifon/actions
5. Instalar APK y probar:
   - Golpe de puerta → NO debe hacer "tktktkt"
   - Voz alta + ruido → NO debe cortar
   - Timbre de subte → atenuado SIN afectar voz
   - Keys jingling → atenuado SIN afectar fricativas

---

## 🔗 COMMIT VERDE PREVIO

- **Último verde:** `4821896` (fix toggle + config verde)
- **Siguiente:** `feat/nr-professional` (este cambio)

---

## ⚠️ NOTAS IMPORTANTES

1. **TNR threshold bajado de 8× a 6×** → más sensible (detecta golpes leves)
2. **NR release aumentado de 50 ms a 250 ms** → fade más lento (evita "tktktkt")
3. **VAD NO integrado aún** → implementado pero no conectado al pipeline (futuro)
4. **Backward compatible:** Si `enabled=false`, todo pass-through (sin cambios)

---

**Fin del documento.**
