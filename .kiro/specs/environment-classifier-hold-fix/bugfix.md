# Bugfix — `kEnvHoldBlocks` declarado pero nunca usado

## Introduction

El header `environment_classifier.h` declara la constante `kEnvHoldBlocks = 125`
(documentada como "500 ms / 4 ms = 125 bloques" para la ventana de hold tras
una transición). La implementación en `environment_classifier.cpp` ignora esa
constante y hardcodea `750` (3 segundos) en la asignación de `holdCounter_`.

No es un fallo de funcionamiento: el clasificador opera con 3 s de hold y se
comporta de forma estable. El problema es de **integridad del código**:
constante zombie en el header + valor mágico en el cpp. Cualquiera que cambie
`kEnvHoldBlocks` esperando alterar el comportamiento no consigue ningún efecto.

La doc `Amplificador/docs/06-ruido-y-nitidez/ruido.md` (sección 17.11) ya
reportó el drift como hallazgo de auditoría.

## Bug Analysis

### Current Behavior (Defect)

- `environment_classifier.h:31` declara `static constexpr int kEnvHoldBlocks = 125;`
  con comentario que afirma "500 ms / 4 ms = 125 bloques".
- `environment_classifier.cpp:~129` asigna `holdCounter_ = 750;` con un
  literal numérico, ignorando la constante.
- `environment_classifier.cpp:~7` (cabecera) afirma "Aplicar hold timer
  (125 bloques = 500 ms) para estabilidad", contradiciendo el comportamiento
  real (750 bloques / 3 s).
- `kEnvHoldBlocks` no aparece referenciado en ningún `.cpp` del proyecto.

Síntomas para mantenimiento:

- Cambiar el valor del header **no cambia nada** en runtime.
- Lectura cruzada del header sugiere un hold de 500 ms, mientras que el
  comportamiento real es 3 s. Documentación interna mentirosa.
- Riesgo de regresión silenciosa si alguien "limpia" la constante o el
  literal sin entender el desfase.

### Expected Behavior (Correct)

- El header declara la constante con el valor que realmente está en uso (`750`).
- El comentario del header refleja el valor real ("750 bloques × 4 ms = 3 s").
- El cpp usa la constante en lugar del literal numérico.
- El comentario de cabecera del cpp reporta el valor real (3 s).
- `grep kEnvHoldBlocks` arroja al menos 2 hits: la declaración y al menos un uso.

### Unchanged Behavior (Regression Prevention)

- El valor numérico efectivo del hold **no debe cambiar**: sigue siendo 750
  bloques / 3 s. El refactor es de presentación, no de comportamiento.
- La lógica de transición (`if (newClass != current)`) y el decremento
  (`holdCounter_--`) permanecen idénticos.
- Las clases de entorno (`QUIET`, `SPEECH`, `SPEECH_IN_NOISE`, `NOISE`),
  los thresholds (`kEnvLevelQuietThreshold`, `kEnvSnrSpeechThreshold`, etc.)
  y las tablas (`kEnvNrLevelTable`, `kEnvWdrcKneeTable`, `kEnvWdrcRatioTable`)
  no se tocan.
- El tipo de la constante (`static constexpr int`) no cambia.
- La copia espejo en `Amplificador2/` sólo se modifica si sigue activa;
  si es legado archivado, no requiere cambios.

## Decisión del owner

Antes de implementar, hay que confirmar cuál es el valor correcto:

1. **Opción A — Mantener 3 s:** Renombrar la constante a `kEnvHoldBlocks = 750`
   y actualizar comentarios. Es el comportamiento real probado.
2. **Opción B — Volver a 500 ms:** Usar la constante tal cual está (125) y
   borrar el literal `750` del cpp. Riesgo: oscilación percibida en
   transiciones rápidas SPEECH ↔ NOISE. Requiere validación auditiva.
3. **Opción C — Hacerlo configurable:** Convertirlo en parámetro atómico
   ajustable desde Dart. Overkill para una constante de UX interna.

**Recomendación:** Opción A. El valor de 3 s ya está en producción y tiene
motivación documentada (estabilidad en escenas reales).

## Plan de implementación (Opción A)

### Paso 1 — Actualizar el header

`environment_classifier.h`:

```cpp
/// Bloques de hold tras una transición de clase de entorno.
/// 750 bloques × 4 ms/bloque = 3 segundos de hold.
///
/// Histórico: el valor original (500 ms = 125 bloques) producía oscilación
/// audible en transiciones SPEECH ↔ SPEECH_IN_NOISE. Subido a 3 s tras
/// pruebas en escenas reales para mayor estabilidad subjetiva.
static constexpr int kEnvHoldBlocks = 750;
```

### Paso 2 — Usar la constante en el cpp

`environment_classifier.cpp`:

```cpp
if (newClass != current) {
    prevClass_ = current;
    currentClass_.store(static_cast<int>(newClass), std::memory_order_relaxed);
    holdCounter_ = kEnvHoldBlocks;  // Usar la constante del header
}
```

Y actualizar el comentario adyacente para que coincida con el valor.

### Paso 3 — Actualizar el docstring del archivo

`environment_classifier.cpp` (cabecera del archivo):

```cpp
/// 3. Aplicar hold timer (750 bloques = 3 s) para estabilidad
```

### Paso 4 — Mirror en `Amplificador2/`

El árbol `Amplificador2/hearing_aid_app/android/app/src/main/cpp/environment_classifier.{h,cpp}`
tiene los mismos archivos con el mismo drift. Si esa copia sigue activa,
aplicar el mismo cambio. Si es legado, marcar como archivado en una nota.

### Paso 5 — Actualizar `ruido.md`

En `Amplificador/docs/06-ruido-y-nitidez/ruido.md`, sección 17.11, eliminar
la nota del drift y dejar solo:

```md
- **kEnvHoldBlocks** — `750` (3 s a 4 ms/bloque). Hold timer tras transición
  de clase para estabilidad. Antes era 125 (500 ms); subido a 750 tras
  pruebas auditivas en escenas reales.
```

## Verificación

1. Compilar el módulo nativo de Android. El cambio es trivial (mismo valor
   numérico, solo lo lleva al header).
2. `grep kEnvHoldBlocks` debe encontrar declaración + al menos un uso.
3. `grep "holdCounter_ = 750"` no debe encontrar nada en
   `environment_classifier.cpp`.
4. Smoke test manual: arrancar la app, alternar entre habla y silencio,
   confirmar que el cambio de clase reportado por `getCurrentClass()`
   ocurre con el delay esperado (~3 s).

## Riesgos y rollback

Riesgo bajo. El cambio es refactor, no altera comportamiento numérico.
Rollback: revertir el commit; el sistema vuelve al estado actual (que ya
funciona).

## Estado

- **Detectado:** Junio 2026, durante validación cruzada de `ruido.md`
  (sección 17.11) contra el código real de `environment_classifier.{h,cpp}`.
- **Resuelto:** Junio 2026 — aplicada Opción A (Renombrar a 750 + usar la
  constante en el cpp). Cambios:
  - `environment_classifier.h:36`: `kEnvHoldBlocks = 750` con docstring que
    explica el histórico (500 ms → 3 s).
  - `environment_classifier.cpp:129`: `holdCounter_ = kEnvHoldBlocks;`
    (eliminado el literal `750`).
  - Docstrings de cabecera de ambos archivos actualizados al valor real.
  - Mirror en `Amplificador2/` queda como TODO (es legado, no se modifica
    salvo que se confirme que sigue activo).
- **Owner:** Resuelto sin asignación formal — refactor trivial.
- **Prioridad:** Baja (no afecta operación, solo integridad del código).
