# Implementación: Smart ambiente automático mejorado (v2)

**Fecha:** 2026-06-25  
**Commit:** Smart auto v2 - usa mismo motor que diagnóstico

---

## ✅ CAMBIOS REALIZADOS

### Archivo modificado: `lib/presentation/bloc/amplification_bloc.dart`

#### 1. Imports agregados (línea ~38)
```dart
import '../../scene/scene_class.dart';
import '../../scene/scene_engine.dart';
```

#### 2. Nuevos campos (después de línea 203)
```dart
/// Motor de análisis de escenas para Smart automático mejorado.
SceneEngine? _sceneEngine;

/// Audiograma cargado para Smart automático.
Audiogram? _audiogram;

/// Última clase de escena detectada (idempotencia).
SceneClass? _lastSceneClass;
```

#### 3. `_startSmartPolling()` reescrito (línea ~4341)

**ANTES:**
- Polling cada 1 segundo
- Lee solo `environmentClass` básico (int 0-3)
- Despacha `ChangeProfile` genérico

**AHORA:**
- Polling cada 12 segundos
- Inicializa `SceneEngine` con config optimizada (session 1.5s, 8-15 muestras)
- Carga audiograma una vez al inicio
- Ejecuta análisis completo en cada tick

#### 4. `_stopSmartPolling()` actualizado (línea ~4385)

**Agregado:**
- Limpia `_sceneEngine`, `_audiogram`, `_lastSceneClass`

#### 5. Nuevo método `_onSmartPollV2()` (línea ~4413)

**Flujo completo:**
1. Valida que `_sceneEngine` exista
2. Obtiene perfil activo actual con `_getCurrentEnvironmentProfile()`
3. Ejecuta `_sceneEngine.analyze(audiogram, profile)`
4. **Idempotencia:** Solo continúa si `SceneClass` cambió
5. Aplica preset completo con `_sceneEngine.apply(result, bloc: this)`
6. Logging detallado de clase, confianza, samples
7. Actualiza `_lastEnvClass` para backward-compat con chip indicador

#### 6. Helpers agregados

**`_getCurrentEnvironmentProfile()`**
- Mapea perfil activo (string) → `EnvironmentProfile` enum
- Usado para determinar `PrescriptionMode` del bundle base

**`_sceneClassToEnvClass()`**
- Mapea `SceneClass` (enum avanzado) → `int environmentClass` (0-3)
- Backward-compat con chip indicador en `main_screen.dart`

#### 7. Método viejo marcado `@Deprecated`

`_onSmartPoll()` original se mantiene comentado como referencia histórica.

---

## 🎯 COMPORTAMIENTO NUEVO

### Antes (Smart auto viejo)
```
Cada 1s:
└─ Leer environmentClass básico (0-3) del C++
└─ Mapear a perfil (Silencioso/Conversación/Ruidoso)
└─ Despachar ChangeProfile
└─ NO usa audiograma
└─ NO aplica preset personalizado
```

### Ahora (Smart auto v2)
```
Cada 12s:
└─ SceneEngine.analyze(audiogram, profile)
   ├─ Polear 1.5s de snapshots del SceneAnalyzer C++
   ├─ SceneDecisionMaker resuelve clase dominante
   └─ Generar SmartPreset con audiograma
└─ Idempotencia: Solo aplicar si clase cambió
└─ apply() completo:
   ├─ EQ (12 bandas personalizadas)
   ├─ WDRC (knee/ratio por escena)
   ├─ NR level (0-3)
   ├─ TNR enabled (transient reducer)
   └─ Volume delta
└─ Logging detallado
└─ Persistencia en Hive
└─ Feedback tracking (SceneRecorder)
```

---

## ⚡ VENTAJAS

✅ **Consistencia:** Mismo motor que botón manual "Detectar y aplicar"  
✅ **Audiograma:** Presets personalizados con NAL-NL3  
✅ **Features avanzadas:** VAD, spectral tilt, centroid, flatness, flux  
✅ **Preset completo:** EQ + WDRC + NR + TNR (no solo perfil)  
✅ **Más estable:** Intervalo 12s + session 1.5s = menos cambios espurios  
✅ **Idempotencia:** Solo aplica si clase realmente cambió  

---

## 📊 COMPARACIÓN TÉCNICA

| Aspecto | Viejo (1 Hz) | Nuevo (12s) |
|---------|-------------|-------------|
| **Motor C++** | EnvironmentClassifier (básico) | SceneAnalyzer (avanzado) |
| **Intervalo** | 1 segundo | 12 segundos |
| **Session** | N/A (lectura instantánea) | 1.5s (8-15 muestras) |
| **Audiograma** | ❌ No usado | ✅ Personalizado |
| **Output** | 4 clases (int 0-3) | 8 clases (SceneClass enum) |
| **Features** | Nivel + SNR | VAD + spectral (6 features) |
| **Acción** | ChangeProfile (genérico) | apply() preset completo |
| **Logging** | Básico | Detallado (clase, conf, samples) |
| **Persistencia** | No | Sí (Hive + SceneRecorder) |

---

## ⚠️ CONSIDERACIONES

### CPU / Performance

**Antes:** 1 lectura/segundo de int del C++ (despreciable)  
**Ahora:** Análisis cada 12s que tarda ~1.5-1.8s total:
- Polling snapshots: ~1.5s (bloqueante)
- Apply preset: ~100-300ms (despacha eventos al bloc)

**Impacto:** ~13% de 12s ocupado = aceptable para móvil moderno

### Estabilidad de cambios

**Hold implícito:** 12s intervalo + decisión dominante en 8-15 muestras → cambio efectivo cada 12-24s (muy estable, pediátrico-friendly)

**Histéresis C++:** EnvironmentClassifier sigue corriendo con hold de 5s → doble capa de estabilidad

### Memoria

**SceneEngine:** Lazy init en primer tick, limpia al apagar Smart  
**Audiograma:** Cargado una vez, reutilizado en todos los análisis  
**Session buffers:** 8-15 snapshots × ~200 bytes = ~3 KB pico

---

## 🧪 TESTING RECOMENDADO

### Test 1: Silencio → Habla
1. Activar Smart automático
2. Ambiente silencio (< 45 dB SPL)
3. Esperar 12s → preset SILENCE/QUIET aplicado
4. Hablar fuerte (SNR > 6 dB)
5. Esperar 12-24s → preset VOICE_ONLY/SPEECH aplicado
6. Verificar: EQ cambió, NR bajó a 1

### Test 2: Habla → Ruido
1. Hablar (SPEECH activo)
2. Música de fondo fuerte (SNR < 1.5 dB)
3. Esperar 12-24s → preset NOISE aplicado
4. Verificar: Graves bajan, agudos suben, NR sube a 3

### Test 3: Sin audiograma
1. Borrar audiograma del paciente
2. Activar Smart
3. Verificar: Usa `Audiogram.defaultAudiogram()` sin crash
4. Preset aplicado OK
5. UI muestra hint "audiograma no medido"

### Test 4: Toggle ON/OFF rápido
1. Smart ON → OFF → ON rápido
2. Verificar: No memory leak de `_sceneEngine`
3. Polling se reinicia correctamente

### Test 5: Motor apagado mid-polling
1. Smart ON, motor corriendo
2. Apagar audífono (stop audio)
3. Verificar: `analyze()` falla gracefully
4. Próximo tick reintenta sin crash

---

## 📝 PRÓXIMOS PASOS

### FASE 1: Verificación básica (hacer AHORA)
- [ ] Compilar APK (CI o local)
- [ ] Instalar en dispositivo
- [ ] Activar Smart automático
- [ ] Verificar logs con `adb logcat | findstr SmartAutoV2`
- [ ] Confirmar que presets se aplican cada 12s

### FASE 2: Ajustes finos (después de testing)
- [ ] Ajustar intervalo si 12s es muy lento/rápido (10-15s rango aceptable)
- [ ] Implementar Opción #4: Detector de incomodidad
- [ ] Implementar Opción #5: Ajustes EQ agresivos por ambiente

### FASE 3: UI opcional
- [ ] Agregar indicador en main_screen: "Smart auto: detectando..."
- [ ] Mostrar última clase aplicada + timestamp
- [ ] Botón manual "Forzar detección ahora"

---

## 🐛 DEBUG

### Si Smart auto NO cambia presets:

1. Verificar logs:
```bash
adb logcat | findstr "SmartAutoV2"
```

Buscar:
- "SceneEngine null" → init falló
- "clase sin cambios" → ambiente muy estable
- "analyze failed" → motor parado o snapshots vacíos

2. Verificar estado del motor:
```bash
adb logcat | findstr "getDspStageMetrics"
```

Si retorna null → motor no corriendo

3. Verificar toggle:
- En código: `_smartEnabled` debe ser `true`
- En UI: Toggle visible y ON

### Si cambia pero no se nota:

→ Los presets son muy similares  
→ Implementar Opción #5 (ajustes EQ agresivos)

---

**COMMIT MESSAGE:**
```
feat: Smart auto v2 - usa SceneEngine completo con audiograma

- Reemplaza polling 1Hz básico con análisis completo cada 12s
- Usa mismo motor que botón "Detectar y aplicar"
- Aplica presets personalizados con audiograma automáticamente
- Idempotencia: solo aplica si SceneClass cambió
- Logging detallado para diagnóstico
- Backward-compat con chip indicador de escena

Closes: Smart ambiente automático mejora request
```
