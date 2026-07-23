# Plan: Smart ambiente automático con lógica del diagnóstico

**Fecha:** 2026-06-25  
**Objetivo:** Que el ambiente automático use el mismo motor que "Detectar y aplicar"

---

## 🎯 PROBLEMA ACTUAL

### Smart Diagnóstico (manual) ✅
```dart
// En smart_scene_screen.dart
Future<void> _runAnalysis() async {
  final result = await _engine.analyze(audiogram: _audiogram);
  // Usa SceneAnalyzer C++ completo
  // Snapshots con VAD, spectral features, SNR real
  // SceneDecisionMaker resuelve clase dominante
  // SmartPreset con audiograma personalizado
}
```

### Smart ambiente automático (polling) ❌
```dart
// En amplification_bloc.dart línea 4400
Future<void> _onSmartPoll() async {
  final metrics = await _audioBridge.getDspStageMetrics();
  final cls = metrics['environmentClass']; // Solo 4 clases básicas
  final profile = _resolveEnvironmentProfile(cls); // Silencioso/Conversación/Ruidoso
  add(ChangeProfile(profile: profile)); // NO aplica preset personalizado
}
```

**Diferencias:**
- Manual: Usa `SceneEngine.analyze()` completo
- Auto: Lee solo `environmentClass` básico
- Manual: Aplica preset con audiograma
- Auto: Solo cambia perfil genérico

---

## 💡 SOLUCIÓN: Unificar ambos

### Nuevo polling mejorado

```dart
class AmplificationBloc {
  Timer? _smartPollTimer;
  SceneEngine? _sceneEngine;
  Audiogram? _audiogram;
  SceneClass? _lastSceneClass;
  
  // Intervalo más largo (10-15s) porque analyze() es costoso
  static const Duration _smartPollInterval = Duration(seconds: 12);
  
  void _startSmartPolling() {
    _smartPollTimer?.cancel();
    _lastSceneClass = null;
    
    // Activar clasificador C++ (sigue corriendo para UI)
    () async {
      try {
        await const MethodChannel('com.psk.hearing_aid/audio')
            .invokeMethod<void>('updateAutoClassify', {'enabled': true});
      } catch (e) {
        developer.log('updateAutoClassify failed: $e', name: 'SmartAuto');
      }
    }();
    
    // Polling con lógica completa del diagnóstico
    _smartPollTimer = Timer.periodic(_smartPollInterval, (_) => _onSmartPollV2());
  }
  
  Future<void> _onSmartPollV2() async {
    if (!_smartEnabled) return;
    if (_sceneEngine == null) {
      _sceneEngine = SceneEngine(
        // Configuración para polling automático:
        // - Session más corto (1.5s en vez de 5s)
        // - Menos muestras (8-15 en vez de 10-25)
        sessionTimeout: Duration(milliseconds: 1500),
        minSamples: 8,
        maxSamples: 15,
      );
      await _sceneEngine!.loadSettings();
    }
    
    // Cargar audiograma si no está cargado
    if (_audiogram == null) {
      try {
        _audiogram = await _audiogramRepository.getAudiogram();
      } catch (_) {
        _audiogram = null; // Fallback a default
      }
    }
    
    // Análisis completo (como el botón manual)
    SceneAnalysisResult result;
    try {
      result = await _sceneEngine!.analyze(
        audiogram: _audiogram,
        profile: _currentEnvironmentProfile(), // Perfil activo actual
      );
    } catch (e) {
      developer.log('Smart auto analyze failed: $e', name: 'SmartAuto');
      return; // Reintentar en próximo tick
    }
    
    // Idempotencia: solo aplicar si la clase cambió
    if (result.sceneClass == _lastSceneClass) {
      return; // Sin cambios
    }
    _lastSceneClass = result.sceneClass;
    
    developer.log(
      'Smart auto: clase=${result.sceneClass.name}, conf=${result.confidence}',
      name: 'SmartAuto',
      level: 300,
    );
    
    // Aplicar preset automáticamente (sin interacción del usuario)
    try {
      await _sceneEngine!.apply(result, bloc: this);
      developer.log('Smart auto: preset aplicado OK', name: 'SmartAuto');
    } catch (e) {
      developer.log('Smart auto apply failed: $e', name: 'SmartAuto', level: 800);
    }
  }
  
  EnvironmentProfile? _currentEnvironmentProfile() {
    final st = state;
    if (st is AmplificationActive) {
      // Mapear nombre de perfil → enum
      switch (st.activeProfile) {
        case 'Silencioso': return EnvironmentProfile.quiet;
        case 'Conversación': return EnvironmentProfile.speech;
        case 'Ruidoso': return EnvironmentProfile.noise;
      }
    }
    return null;
  }
}
```

---

## 📋 CAMBIOS NECESARIOS

### 1. Modificar `_startSmartPolling()` en `amplification_bloc.dart`

**Antes (línea 4341):**
```dart
void _startSmartPolling() {
  _smartPollTimer?.cancel();
  _lastEnvClass = null;
  // ...
  _smartPollTimer = Timer.periodic(
    const Duration(seconds: 1),
    (_) => _onSmartPoll(),
  );
}
```

**Después:**
```dart
void _startSmartPolling() {
  _smartPollTimer?.cancel();
  _lastSceneClass = null;
  _sceneEngine = SceneEngine(
    sessionTimeout: Duration(milliseconds: 1500),
    minSamples: 8,
    maxSamples: 15,
  );
  
  // Activar clasificador C++ para UI
  () async {
    await const MethodChannel('com.psk.hearing_aid/audio')
        .invokeMethod<void>('updateAutoClassify', {'enabled': true});
  }();
  
  _smartPollTimer = Timer.periodic(
    const Duration(seconds: 12), // Cada 12s
    (_) => _onSmartPollV2(),
  );
}
```

### 2. Agregar nuevo handler `_onSmartPollV2()`

Reemplazar `_onSmartPoll()` actual con la lógica de arriba.

### 3. Agregar campos al bloc

```dart
class AmplificationBloc {
  // Existentes
  Timer? _smartPollTimer;
  bool _smartEnabled = false;
  
  // NUEVOS para Smart v2
  SceneEngine? _sceneEngine;
  Audiogram? _audiogram;
  SceneClass? _lastSceneClass;
  
  // Repositorio ya existe
  final AudiogramRepository _audiogramRepository;
}
```

---

## ⚡ VENTAJAS

✅ **Mismo motor** que el botón manual (consistencia)  
✅ **Audiograma personalizado** en automático  
✅ **Presets completos** (EQ + WDRC + NR + TNR)  
✅ **Features espectrales avanzadas** (VAD, tilt, centroid, flux)  
✅ **Menos cambios espurios** (session más largo = más estable)  

---

## ⚠️ CONSIDERACIONES

### Intervalo de polling

**Antes:** 1 segundo (muy frecuente, usa solo int de C++)  
**Ahora:** 12 segundos (razonable para análisis completo)

**Razón:** `analyze()` tarda ~1.5s + aplicar preset ~100ms = 1.6s total  
Si polleamos cada 1s → bloquearíamos el bloc  
Cada 12s → 13% de CPU, aceptable

### Hold implícito

El `SceneDecisionMaker` interno ya tiene lógica de hold (requiere clase dominante en 8-15 muestras).  
Combinado con polling cada 12s → cambio efectivo cada ~12-24s (estable).

### Memoria de audiograma

Se carga UNA VEZ al inicio del polling. Si el usuario cambia audiograma mid-session, se actualiza en próximo restart del motor.

---

## 🚀 IMPLEMENTACIÓN

### Archivos a modificar:

1. **`lib/presentation/bloc/amplification_bloc.dart`**
   - Línea 4341: `_startSmartPolling()`
   - Línea 4400: reemplazar `_onSmartPoll()` con `_onSmartPollV2()`
   - Agregar campos: `_sceneEngine`, `_audiogram`, `_lastSceneClass`

2. **`lib/scene/scene_engine.dart`**
   - Agregar constructor opcional con `sessionTimeout`, `minSamples`, `maxSamples` personalizables
   - Ya existe, solo verificar que acepte params

3. **Sin cambios en C++** (ya funciona)

---

## ✅ TESTING

### Escenario 1: Silencio → Habla
1. Usuario en ambiente silencio (< 45 dB SPL)
2. Después de 12s: preset "SmartScene · QUIET" aplicado
3. Usuario comienza a hablar (SNR > 6 dB)
4. Después de 12-24s: preset "SmartScene · SPEECH" aplicado
5. Verificar: EQ cambia, NR baja a 1

### Escenario 2: Habla → Ruido
1. Usuario hablando (SPEECH)
2. Pone música de fondo fuerte (SNR < 1.5 dB)
3. Después de 12-24s: preset "SmartScene · NOISE" aplicado
4. Verificar: EQ graves bajan, agudos suben, NR sube a 3

### Escenario 3: Sin audiograma medido
1. Usuario sin audiograma cargado
2. Smart auto usa `Audiogram.defaultAudiogram()`
3. Preset aplicado OK
4. UI muestra hint "audiograma no medido" (ya existe)

---

## 📊 COMPARACIÓN

| Feature | Smart manual | Smart auto viejo | Smart auto NUEVO |
|---------|-------------|------------------|------------------|
| Motor C++ | SceneAnalyzer | EnvironmentClassifier | SceneAnalyzer |
| Audiograma | ✅ Personalizado | ❌ N/A | ✅ Personalizado |
| Preset completo | ✅ EQ+WDRC+NR+TNR | ❌ Solo perfil | ✅ EQ+WDRC+NR+TNR |
| Intervalo | Manual | 1s | 12s |
| Features | VAD+spectral | Solo SNR+nivel | VAD+spectral |
| Aplicación | Botón | ChangeProfile | apply() completo |

---

**PRÓXIMO PASO:** ¿Implemento el nuevo `_onSmartPollV2()` en `amplification_bloc.dart`?
