# PyTorch Full JIT Runtime Headers -- GTCRN Dual-Channel

## Proposito

Este directorio contiene los headers del **PyTorch Full JIT Runtime**
necesarios para compilar el `DnnDenoiser` con soporte dual-channel (LibTorch).

> **NOTA:** El nombre del directorio sigue siendo `pytorch_lite/` por razones
> historicas de compatibilidad con la estructura del proyecto. Los headers
> dentro soportan tanto la API mobile como la API full JIT (`torch::jit::load`,
> `torch::jit::Module`). No es necesario renombrarlo.

## Migracion de Lite a Full Runtime

Se migro de `pytorch_android_lite:2.1.0` a `pytorch_android:2.1.0` (full runtime)
porque el modelo fue trazado con `torch.jit.trace(model, torch.randn(1, 2, 48000))`
y el lite interpreter crasheaba con SIGSEGV al ejecutar el forward con shapes
que no coincidian exactamente con las del trace. El full JIT interpreter maneja
correctamente los shapes del modelo trazado.

## Como obtener los headers

Los headers se extraen del AAR oficial `org.pytorch:pytorch_android:2.1.0`:

```bash
# 1. Descargar el AAR desde Maven Central
curl -L -o pytorch_android-2.1.0.aar \
  "https://repo1.maven.org/maven2/org/pytorch/pytorch_android/2.1.0/pytorch_android-2.1.0.aar"

# 2. Extraer (es un ZIP)
unzip pytorch_android-2.1.0.aar -d pytorch_aar_extracted/

# 3. Los headers estan en:
#    pytorch_aar_extracted/headers/
#    Copiar todo el contenido a este directorio.
```

Alternativamente, desde el source de PyTorch v2.1.0:
- `torch/csrc/jit/serialization/import.h` -- `torch::jit::load()`
- `torch/csrc/jit/api/module.h` -- `torch::jit::Module`
- `torch/script.h` -- API de alto nivel (TorchScript, incluye todo lo anterior)
- `c10/` -- Core tensor types
- `ATen/` -- Tensor operations

## Headers minimos requeridos

Para el uso en `DnnDenoiser` (solo `torch::jit::load()` + `Module::forward()`):

```
pytorch_lite/
|-- torch/
|   |-- script.h
|   +-- csrc/
|       +-- jit/
|           |-- serialization/
|           |   +-- import.h      (torch::jit::load)
|           +-- api/
|               +-- module.h      (torch::jit::Module)
|-- c10/
|   |-- core/
|   |   |-- Scalar.h
|   |   |-- TensorImpl.h
|   |   +-- ...
|   +-- util/
|       +-- ...
+-- ATen/
    |-- Tensor.h
    +-- ...
```

## Nota sobre las .so en jniLibs/

Las siguientes `.so` deben estar en `jniLibs/arm64-v8a/`:

| Archivo                | Origen                      | Tamano aprox. |
|------------------------|-----------------------------|---------------|
| `libpytorch_jni.so`   | AAR pytorch_android:2.1.0   | ~60 MB        |
| `libfbjni.so`         | AAR fbjni (transitiva)      | ~0.1 MB       |

> **NOTA:** En `pytorch_android:2.1.0` (full runtime), `libc10.so` viene
> fusionada dentro de `libpytorch_jni.so`. No se necesita un archivo separado.

### Extraccion desde el AAR

```bash
# Descargar el AAR
curl -L -o pytorch_android-2.1.0.aar \
  "https://repo1.maven.org/maven2/org/pytorch/pytorch_android/2.1.0/pytorch_android-2.1.0.aar"

# Extraer las .so para arm64-v8a
unzip -j pytorch_android-2.1.0.aar "jni/arm64-v8a/*" -d jniLibs/arm64-v8a/

# Verificar
ls -la jniLibs/arm64-v8a/libpytorch_jni.so
```

## Conflictos potenciales con OnnxRuntime

Ambas librerias (ORT y LibTorch) usan internamente XNNPACK para kernels
cuantizados. No deberia haber conflicto de simbolos porque:
- ORT compila XNNPACK como estatico con `-fvisibility=hidden`
- LibTorch hace lo mismo con su copia interna

Si surgiera un conflicto de simbolos duplicados en link-time, la solucion es
recompilar una de las dos con `EXCLUDE_OPERATOR_PATTERN` (LibTorch) o
usar ORT sin XNNPACK EP (que no usamos actualmente).

## Version

- PyTorch: 2.1.0 (full JIT runtime, compatible con TorchScript trace exportado por torch 2.x)
- Modelo: `gtcrn_dual_mobile.ptl` (traced con torch 2.1+, T=48000)
- API: `torch::jit::load()` + `torch::jit::Module::forward()`
