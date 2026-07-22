# ✅ AUDITORÍA SMART SCENE COMPLETADA

**Fecha:** 2026-06-25

---

## 📊 HALLAZGOS

### ✅ Sistema Smart Scene EXISTE y está COMPLETO

1. **EnvironmentClassifier C++**
   - ✅ Compilado en CMakeLists.txt
   - ✅ Integrado al DSP pipeline (`dsp_pipeline.cpp` línea 254)
   - ✅ Actualiza cada bloque de audio (~250 veces/segundo)
   - ✅ Clasifica en 4 ambientes: QUIET (0), SPEECH (1), SPEECH_IN_NOISE (2), NOISE (3)
   - ✅ Hold de 5 segundos para estabilidad
   - ✅ Histéresis para evitar oscilación

2. **Polling automático Dart**
   - ✅ Implementado en `AmplificationBloc._startSmartPolling()` línea 4341
   - ✅ Lee `environmentClass` cada 1 segundo
   - ✅ Mapea 4 clases C++ → 3 perfiles (Silencioso/Conversación/Ruidoso)
   - ✅ Despacha `ChangeProfile` automáticamente
   - ✅ Modula intensidad DNN por escena

3. **Control de activación**
   - ✅ Flag `autoClassifyEnabled_` en C++ (atómico, thread-safe)
   - ✅ Handler Kotlin `updateAutoClassify` existe
   - ✅ Activación desde `_startSmartPolling()` funcional

---

## ❓ HIPÓTESIS DE FALLO

### HIPÓTESIS #1: Toggle Smart apagado (MÁS PROBABLE)

**Evidencia:**
- El polling solo arranca si `_smartEnabled = true`
- Si el usuario nunca activó el toggle → clasificador C++ dormido

**Verificación necesaria:**
- ¿Hay un toggle "Smart Scene" visible en la UI del técnico?
- ¿Cuál es su estado actual (ON/OFF)?

### HIPÓTESIS #2: Motor de audio no corriendo

**Evidencia:**
- `_startSmartPolling()` requiere motor activo
- Si el usuario no tiene el audífono encendido → no hay polling

**Verificación necesaria:**
- ¿El usuario tiene el motor de audio activo cuando reporta que "no funciona"?

### HIPÓTESIS #3: Ambiente muy estable

**Evidencia:**
- Hold de 5 segundos (pediátrico)
- Si el ambiente es realmente estable (ej: siempre SPEECH) → no hay cambios visibles

**Verificación necesaria:**
- ¿El usuario probó ambientes claramente diferentes (silencio absoluto vs hablar fuerte vs ruido)?

---

## 🎯 ACCIONES INMEDIATAS

### PARA EL USUARIO:

**Por favor ejecutar esto y reportar qué ves:**

1. **Abrir la app del técnico**
2. **Ir a "Smart Scene · diagnóstico"** (en el menú principal)
3. **Captura de pantalla de:**
   - Sección "Ambiente automático (técnico)" (si existe)
   - Estado del toggle Smart Scene
   - Valor de "Clase detectada (C++)"
   
4. **Probar cambios de ambiente:**
   - Silencio absoluto (sin hablar, ambiente tranquilo)
   - Hablar fuerte cerca del micrófono
   - Poner música o ruido de fondo

5. **Reportar:**
   - ¿La "Clase detectada" cambia entre 0, 1, 2, 3?
   - ¿El perfil activo (Silencioso/Conversación/Ruidoso) cambia automáticamente?
   - ¿Cuánto tiempo tarda en cambiar después de cambiar el ambiente?

---

## 🚀 PLAN DE ACCIÓN SEGÚN RESULTADO

### Si "Toggle Smart no existe o está escondido"
→ **Agregar toggle visible en main_screen.dart**

### Si "Toggle existe pero está OFF"
→ **Activar y probar de nuevo**

### Si "Toggle ON pero clase siempre es 0 (QUIET)"
→ **Bug en el clasificador C++ o SNR estimation**
→ **Agregar logging verboso al update()**

### Si "Clase cambia pero perfil NO cambia"
→ **Bug en el mapping Dart (línea 4456 de amplification_bloc.dart)**

### Si "Clase y perfil cambian pero no se nota diferencia"
→ **Los presets Silencioso/Conversación/Ruidoso son demasiado similares**
→ **Implementar Opción #5: Ajustes EQ agresivos por ambiente**

---

## 💡 MEJORAS PROPUESTAS (DESPUÉS DE DIAGNOSTICAR)

### Opción #4: Detector de incomodidad
- Monitorear historial de volumen + picos de entrada
- Si paciente baja volumen después de pico > 75 dB → reducir MPO automáticamente

### Opción #5: Optimización por ambiente (ajustes EQ agresivos)
**NOISE:**
- -6 dB graves (250-500 Hz) — reducir enmascaramiento
- +3 dB agudos (4-8 kHz) — realzar consonantes
- NR = 3 (máximo)

**SPEECH:**
- +3 dB medios (2-4 kHz) — realzar formantes
- +2 dB banda de voz
- NR = 1 (bajo)

**SPEECH_IN_NOISE:**
- +4 dB agudos (3-6 kHz) — inteligibilidad máxima
- +2 dB medios
- NR = 2 (medio)

**QUIET:**
- Perfil balanceado (base audiograma)
- NR = 0 (off)

---

## ✅ SIGUIENTE PASO

**USUARIO:** Por favor ejecuta las pruebas de arriba y reporta los resultados.

**DESARROLLADOR:** Una vez tengamos los resultados, implementaremos la solución adecuada según el diagnóstico.

---

**Documentación completa:** `docs/investigacion/AUDITORIA_SMART_SCENE.md`
