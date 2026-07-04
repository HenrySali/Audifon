# PyTorch Lite Headers — GTCRN Dual-Channel

## Propósito

Este directorio contiene los headers mínimos del **PyTorch Lite Interpreter**
necesarios para compilar el `DnnDenoiser` con soporte dual-channel (LibTorch).

## Cómo obtener los headers

Los headers se extraen del AAR oficial `org.pytorch:pytorch_android_lite:2.1.0`:

```bash
# 1. Descargar el AAR desde Maven Central
curl -L -o pytorch_android_lite-2.1.0.aar \
  "https://repo1.maven.org/maven2/org/pytorch/pytorch_android_lite/2.1.0/pytorch_android_lite-2.1.0.aar"

# 2. Extraer (es un ZIP)
unzip pytorch_android_lite-2.1.0.aar -d pytorch_aar_extracted/

# 3. Los headers están en:
#    pytorch_aar_extracted/headers/
#    Copiar todo el contenido a este directorio.
```

Alternativamente, desde el source de PyTorch v2.1.0:
- `torch/csrc/jit/mobile/` → Lite Interpreter API
- `torch/script.h` → API de alto nivel (TorchScript)
- `c10/` → Core tensor types
- `ATen/` → Tensor operations

## Headers mínimos requeridos

Para el uso en `DnnDenoiser` (solo `torch::jit::mobile::Module::load()` + `forward()`):

```
pytorch_lite/
├── torch/
│   ├── script.h
│   └── csrc/
│       └── jit/
│           └── mobile/
│               ├── module.h
│               └── import.h
├── c10/
│   ├── core/
│   │   ├── Scalar.h
│   │   ├── TensorImpl.h
│   │   └── ...
│   └── util/
│       └── ...
└── ATen/
    ├── Tensor.h
    └── ...
```

## Nota sobre las .so en jniLibs/

Las siguientes `.so` deben estar en `jniLibs/arm64-v8a/`:

| Archivo                    | Origen                          | Tamaño aprox. |
|----------------------------|---------------------------------|---------------|
| `libpytorch_jni_lite.so`   | AAR pytorch_android_lite:2.1.0  | ~15 MB        |
| `libc10.so`                | AAR pytorch_android_lite:2.1.0  | ~1.5 MB       |
| `libfbjni.so`              | AAR fbjni (transitiva)          | ~0.1 MB       |

Extraer de: `pytorch_aar_extracted/jni/arm64-v8a/`

## Conflictos potenciales con OnnxRuntime

Ambas librerías (ORT y LibTorch) usan internamente XNNPACK para kernels
cuantizados. No debería haber conflicto de símbolos porque:
- ORT compila XNNPACK como estático con `-fvisibility=hidden`
- LibTorch hace lo mismo con su copia interna

Si surgiera un conflicto de símbolos duplicados en link-time, la solución es
recompilar una de las dos con `EXCLUDE_OPERATOR_PATTERN` (LibTorch) o
usar ORT sin XNNPACK EP (que no usamos actualmente).

## Versión

- PyTorch: 2.1.0 (compatible con TorchScript trace exportado por torch 2.x)
- Modelo: `gtcrn_dual_mobile.pt` (traced con torch 2.1+, Lite Interpreter format)
