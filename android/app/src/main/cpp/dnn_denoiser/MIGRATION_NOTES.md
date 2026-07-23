# Migration: PyTorch Lite -> PyTorch Full JIT Runtime

## Fecha: 2024

## Problema

El modelo GTCRN dual-channel fue trazado con:
```python
torch.jit.trace(model, torch.randn(1, 2, 48000))
```

El **lite interpreter** (`pytorch_android_lite:2.1.0`) crasheaba con **SIGSEGV**
al ejecutar el forward porque las shapes estaticas quedan baked en el trace
(T=48000 fijo). Cualquier intento de pasar un tensor con T != 48000 al lite
interpreter causaba acceso a memoria invalido.

## Solucion aplicada

Migracion de `pytorch_android_lite:2.1.0` a `pytorch_android:2.1.0` (full runtime):

1. **build.gradle**: dependencia cambiada a `org.pytorch:pytorch_android:2.1.0`
2. **CMakeLists.txt**: .so cambiada de `libpytorch_jni_lite.so` a `libpytorch_jni.so`,
   define cambiado de `HAVE_PYTORCH_LITE` a `HAVE_PYTORCH`
3. **dnn_denoiser.cpp**: API cambiada de `torch::jit::_load_for_mobile()` /
   `torch::jit::mobile::Module` a `torch::jit::load()` / `torch::jit::Module`
4. **dnn_denoiser.h**: `kDnnDualBlock` cambiado de 128 a 48000 para coincidir
   con el T del trace original

## Requisito T=48000 y latencia de 3 segundos

Como el modelo fue trazado con T=48000:
- El dummy forward de validacion usa `[1, 2, 48000]`
- El worker thread acumula 48000 samples por canal (3 segundos a 16 kHz)
  antes de ejecutar cada forward
- **Latencia algoritmica**: 48000 / 16000 = **3 segundos**

Esta latencia es alta para una aplicacion de audifonos en tiempo real, pero es
la unica forma de usar el modelo actual sin crashes.

## Buffer sizing

- `kDnnRingCapacity` aumentado de 1024 a 65536 (potencia de 2 >= 48000 + margen)
- Los ring buffers SPSC ahora pueden contener un bloque completo de 48000 samples
  mas espacio extra para el handoff asincrono audio-thread/worker-thread

## Ruta futura: re-export con torch.jit.script

Para eliminar la latencia de 3 segundos, el modelo debe re-exportarse usando
`torch.jit.script` en vez de `torch.jit.trace`:

```python
# Opcion A: scripted model (shapes dinamicas)
scripted_model = torch.jit.script(model)
scripted_model.save("gtcrn_dual_scripted.pt")

# Opcion B: trace con input_signature que marca T como dinamico
# (requiere torch >= 2.0 con dynamic_axes)
```

Con un modelo scripted:
- T puede ser cualquier valor (128, 256, 480, etc.)
- `kDnnDualBlock` puede volver a `kDnnHopSize` (128) = 8 ms de latencia
- `kDnnRingCapacity` puede volver a 1024
- La latencia total volveria a ~14-18 ms (misma que la ruta mono ONNX)

## Extraccion de libpytorch_jni.so del AAR

```bash
# Descargar el AAR desde Maven Central
curl -L -o pytorch_android-2.1.0.aar \
  "https://repo1.maven.org/maven2/org/pytorch/pytorch_android/2.1.0/pytorch_android-2.1.0.aar"

# Extraer las .so para arm64-v8a a jniLibs/
unzip -j pytorch_android-2.1.0.aar "jni/arm64-v8a/libpytorch_jni.so" \
  -d android/app/src/main/jniLibs/arm64-v8a/

unzip -j pytorch_android-2.1.0.aar "jni/arm64-v8a/libfbjni.so" \
  -d android/app/src/main/jniLibs/arm64-v8a/

# Verificar (~60 MB para libpytorch_jni.so)
ls -la android/app/src/main/jniLibs/arm64-v8a/libpytorch_jni.so
```

> **NOTA:** Gradle tambien incluye las .so desde el AAR automaticamente al
> hacer `assembleDebug`/`assembleRelease`. Las copias en jniLibs/ son
> necesarias para que CMake pueda linkear contra ellas durante la compilacion
> nativa. El `packagingOptions.pickFirsts` en build.gradle resuelve el
> conflicto de duplicados al empaquetar el APK.

## Archivos modificados

- `android/app/build.gradle`
- `android/app/src/main/cpp/CMakeLists.txt`
- `android/app/src/main/cpp/dnn_denoiser/dnn_denoiser.h`
- `android/app/src/main/cpp/dnn_denoiser/dnn_denoiser.cpp`
- `android/app/src/main/cpp/dnn_denoiser/pytorch_lite/README.md`
