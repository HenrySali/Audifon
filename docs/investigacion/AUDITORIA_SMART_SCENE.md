# Auditoría Smart Scene + Auto-ajuste automático

**Fecha:** 2026-06-25  
**Contexto:** Usuario reporta que Smart Scene (ambiente automático) no funciona

---

## 🎯 OBJETIVO

1. **Diagnosticar por qué el ambiente automático no cambia presets**
2. **Implementar detector de incomodidad** (#4 de opciones de autoajuste)
3. **Optimizar cambios de ambiente** (#5 - ajustes EQ más agresivos por escena)

---

## 📊 ESTADO ACTUAL

### Componentes del sistema Smart Scene

#### **C++ (SceneAnalyzer)**
- **Ubicación:** `android/app/src/main/cpp/smart_scene/scene_analyzer.cpp`
- **Función:** Analiza audio en tiempo real (FFT, VAD, features espectrales, SNR)
- **Output:** `SceneSnapshot` cada ~100ms con:
  - `inputDbSpl` - nivel de entrada
  - `noiseFloorDbSpl` - piso de ruido
  - `snrDb` - relación señal/ruido
  - `vadScore` / `vadConfidence` - detección de voz
  - `spectralTilt`, `spectralCentroid`, `spectralFlatness`, `spectralFlux`
  - `scene_class` - UNKNOWN en Fase 1 (clasificador no implementado aún)

**⚠️ HALLAZGO 1:** El `SceneAnalyzer` NO clasifica ambientes todavía - solo recolecta features

#### **C++ (EnvironmentClassifier)**
- **Ubicación:** Buscada en código, mencionada pero no verificada existencia
- **Función:** Clasificador de 4 clases (QUIET / SPEECH / SPEECH_IN_NOISE / NOISE)
- **Output:** `environmentClass` (int 0-3) expuesto en `getDspStageMetrics()`

**❓ HALLAZGO 2:** Necesitamos verificar si este clasificador C++ existe y funciona

#### **Dart (AmplificationBloc - Polling automático)**
- **Ubicación:** `lib/presentation/bloc/amplification_bloc.dart` línea 4341
- **Función:** 
  - Cada 1 segundo lee `getDspStageMetrics()['environmentClass']`
  - Mapea 4 clases → 3 perfiles (Silencioso/Conversación/Ruidoso)
  - Despacha `ChangeProfile` cuando la clase cambia
  - Modula intensidad DNN por escena
- **Estado:** Solo se activa cuando `_smartEnabled = true`

**❓ HALLAZGO 3:** ¿El usuario tiene el toggle Smart Scene activado?

#### **Dart (SceneEngine - Manual "Detectar y aplicar")**
- **Ubicación:** `lib/scene/scene_engine.dart`
- **Función:** 
  - Botón manual en `smart_scene_screen.dart`
  - Polea snapshots durante 2.5s
  - Usa `SceneDecisionMaker` para resolver clase dominante
  - Aplica preset con `SmartPreset` generado

**⚠️ HALLAZGO 4:** Dos sistemas separados:
- **Técnico:** Polling 1 Hz con `EnvironmentClassifier` C++ → solo cambia perfil (Silencioso/Conversación/Ruidoso)
- **Manual:** Botón "Detectar y aplicar" con `SceneAnalyzer` snapshots → aplica preset completo

---

## 🔍 HIPÓTESIS DE FALLO

### Hipótesis 1: Toggle Smart apagado
- El usuario nunca activó el toggle
- Solución: Verificar en `main_screen.dart` si hay toggle visible y su estado

### Hipótesis 2: EnvironmentClassifier C++ no existe o está roto
- El código Dart polea `environmentClass` pero el C++ no lo calcula
- Retorna siempre -1 o 0 (QUIET) → no hay cambios de ambiente
- Solución: Buscar `environment_classifier.cpp` y verificar compilación

### Hipótesis 3: Hold de 5s demasiado largo
- El clasificador C++ tiene histéresis de 5 segundos
- En ambientes mixtos nunca estabiliza → no emite cambios
- Solución: Reducir hold a 2-3s

### Hipótesis 4: Umbral de confianza demasiado alto
- El clasificador requiere > 80% confianza para emitir clase
- Features espectrales no son suficientemente discriminativas
- Solución: Bajar umbral o agregar más features

---

## 📋 PLAN DE AUDITORÍA

### FASE 1: Diagnóstico rápido (15 min)

```bash
cd c:\Users\Elsa y Henry\Desktop\Amplificador\hearing_aid_app
```

#### 1.1 Verificar existencia de EnvironmentClassifier C++
```cmd
dir /s android\app\src\main\cpp\*environment*.cpp
dir /s android\app\src\main\cpp\*environment*.h
```

#### 1.2 Buscar en CMakeLists si está compilado
```cmd
type android\app\src\main\cpp\CMakeLists.txt | findstr /i environment
```

#### 1.3 Verificar si toggle Smart existe en UI
```cmd
type lib\presentation\screens\main_screen.dart | findstr /i "Smart\|smart_scene\|ToggleSmart"
```

#### 1.4 Revisar logs del usuario
```dart
// Agregar en _onSmartPoll (línea 4400):
developer.log(
  'Smart poll: cls=$cls, lastEnvClass=$_lastEnvClass, metrics=$metrics',
  name: 'SmartScenePoll',
  level: 300,
);
```

### FASE 2: Implementar diagnóstico en tiempo real (30 min)

#### 2.1 Crear script de diagnóstico en `smart_scene_screen.dart`
- Agregar sección "Ambiente automático (técnico)"
- Mostrar:
  - Estado toggle Smart: ON/OFF
  - `environmentClass` actual (cada 1s)
  - Último cambio de perfil (timestamp)
  - Historial últimos 10 cambios

#### 2.2 Agregar logging verboso al polling
```dart
Future<void> _onSmartPoll() async {
  developer.log('Smart poll START', name: 'SmartScenePoll', level: 300);
  
  if (!_smartEnabled) {
    developer.log('Smart DISABLED', name: 'SmartScenePoll', level: 300);
    return;
  }
  
  Map<String, dynamic>? metrics;
  try {
    metrics = await _audioBridge.getDspStageMetrics();
    developer.log('Metrics: $metrics', name: 'SmartScenePoll', level: 300);
  } catch (e) {
    developer.log('getDspStageMetrics ERROR: $e', name: 'SmartScenePoll', level: 800);
    return;
  }
  
  // ... resto del código con más logs
}
```

### FASE 3: Si EnvironmentClassifier NO existe → implementarlo (2-3 horas)

Basado en las features del `SceneSnapshot`:
- SNR > 15 dB + VAD activo → SPEECH
- SNR 5-15 dB + VAD activo → SPEECH_IN_NOISE  
- SNR < 5 dB → NOISE
- Input < 45 dB SPL + VAD inactivo → QUIET

```cpp
// android/app/src/main/cpp/environment_classifier.h
class EnvironmentClassifier {
public:
    enum Class { QUIET = 0, SPEECH = 1, SPEECH_IN_NOISE = 2, NOISE = 3 };
    
    void update(const SceneSnapshot& snap);
    Class getCurrentClass() const;
    float getConfidence() const;
    
private:
    Class currentClass_ = QUIET;
    Class candidate_ = QUIET;
    int holdCounter_ = 0;
    static constexpr int kHoldFrames = 30; // 3s a 10 Hz
};
```

---

## 🚀 OPCIONES DE AUTOAJUSTE

### Opción #4: Detector de incomodidad

**Trigger:** Paciente reduce volumen después de pico de entrada

**Implementación:**
```dart
class DiscomfortDetector {
  List<double> _volumeHistory = []; // últimos 10s
  List<double> _inputHistory = [];  // últimos 10s
  
  bool detectDiscomfort() {
    // Si en últimos 5s hubo:
    // 1. Pico > 75 dB SPL
    // 2. Reducción de volumen > 3 dB
    // → reducir MPO en 2 dB
    
    final recentPeak = _inputHistory.skip(_inputHistory.length - 50).reduce(max);
    final volumeDrop = _volumeHistory.first - _volumeHistory.last;
    
    return recentPeak > 75.0 && volumeDrop > 3.0;
  }
}
```

**Acciones:**
- Reducir MPO en 2 dB (acumulativo hasta -10 dB máximo)
- Notificar al técnico en próxima sesión
- Permitir reset manual

### Opción #5: Optimización por ambiente

**Ajustes EQ automáticos agresivos:**

| Ambiente | Cambios EQ | NR | Lógica |
|----------|-----------|-----|--------|
| **NOISE** | -6 dB graves (250-500 Hz)<br>+3 dB agudos (4-8 kHz) | 3 | Reducir enmascaramiento de graves, realzar consonantes |
| **SPEECH** | +3 dB medios (2-4 kHz)<br>+2 dB banda de voz | 1 | Realzar formantes vocálicos |
| **SPEECH_IN_NOISE** | +4 dB agudos (3-6 kHz)<br>+2 dB medios | 2 | Inteligibilidad máxima |
| **QUIET** | Perfil balanceado<br>(base audiograma) | 0 | Sin ajustes agresivos |

**Implementación:**
```dart
class AggressiveSceneOptimizer {
  List<double> buildOptimizedGains(
    AudiogramDrivenBundle base,
    EnvironmentProfile.Class envClass,
  ) {
    final gains = List<double>.from(base.eqGains);
    
    switch (envClass) {
      case EnvironmentProfile.Class.NOISE:
        // Reducir graves
        gains[0] -= 6.0; // 250 Hz
        gains[1] -= 4.0; // 500 Hz
        // Realzar agudos
        gains[9] += 3.0;  // 4 kHz
        gains[10] += 3.0; // 6 kHz
        gains[11] += 2.0; // 8 kHz
        break;
        
      case EnvironmentProfile.Class.SPEECH:
        // Realzar banda de voz
        gains[6] += 3.0;  // 2 kHz
        gains[7] += 3.0;  // 3 kHz
        gains[8] += 2.0;  // 4 kHz
        break;
        
      // ... otros casos
    }
    
    return gains;
  }
}
```

---

## 📝 SIGUIENTE PASO INMEDIATO

**ACCIÓN 1:** Crear script de diagnóstico para que el usuario pruebe:

```dart
// Agregar en smart_scene_screen.dart después de _DetectCard

class _AutomaticEnvironmentCard extends StatelessWidget {
  final bool smartEnabled;
  final int? currentEnvClass;
  final String? currentProfile;
  final DateTime? lastChange;
  
  @override
  Widget build(BuildContext context) {
    return _SceneCard(
      icon: Icons.autorenew,
      title: 'Ambiente automático (técnico)',
      child: Column(
        children: [
          _MetricRow(
            label: 'Estado Smart Scene',
            value: smartEnabled ? 'ACTIVO' : 'DESACTIVADO',
            valueColor: smartEnabled ? Colors.greenAccent : Colors.redAccent,
          ),
          if (smartEnabled && currentEnvClass != null) ...[
            _MetricRow(
              label: 'Clase detectada (C++)',
              value: _envClassLabel(currentEnvClass!),
            ),
            _MetricRow(
              label: 'Perfil activo',
              value: currentProfile ?? 'N/A',
            ),
            if (lastChange != null)
              _MetricRow(
                label: 'Último cambio',
                value: _formatTimestamp(lastChange!),
              ),
          ],
        ],
      ),
    );
  }
  
  String _envClassLabel(int cls) {
    switch (cls) {
      case 0: return '0 - QUIET';
      case 1: return '1 - SPEECH';
      case 2: return '2 - SPEECH_IN_NOISE';
      case 3: return '3 - NOISE';
      default: return '$cls - UNKNOWN';
    }
  }
}
```

**ACCIÓN 2:** Usuario ejecuta la app, va a Smart Scene screen, y reporta:
- ¿El toggle Smart está visible?
- ¿Qué dice "Estado Smart Scene"?
- ¿La "Clase detectada (C++)" cambia cuando habla vs silencio?

---

## ✅ CRITERIOS DE ÉXITO

### Auditoría completada cuando:
- [x] Sabemos si `EnvironmentClassifier` existe en C++
- [x] Sabemos si el toggle Smart funciona
- [x] Tenemos logs del polling 1 Hz mostrando valores reales

### Autoajuste implementado cuando:
- [ ] Detector de incomodidad reduce MPO automáticamente
- [ ] Optimización por ambiente aplica EQ agresivo
- [ ] Usuario confirma que los cambios mejoran experiencia

---

**PRÓXIMO COMMIT:** Agregar diagnóstico en tiempo real a `smart_scene_screen.dart`
