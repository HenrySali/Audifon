# Manejo de Archivos Binarios Grandes

## Estrategia: GitHub Releases + script de descarga

Los binarios grandes (~45 MB) **no están en el repo**. Se descargan desde GitHub Releases.

## Setup (primera vez después de clonar)

```bash
git clone https://github.com/HenrySali/Audifon.git
cd Audifon
chmod +x scripts/setup.sh
./scripts/setup.sh
```

El script descarga automáticamente todos los binarios necesarios.

## Archivos descargados

| Archivo | Tamaño | Propósito |
|---------|--------|-----------|
| `dnn_denoiser/gtcrn.onnx` | 12 MB | Modelo DPDFNet4 |
| `dnn_denoiser/gtcrn_dual_mobile.pt` | 444 KB | GTCRN dual (PyTorch) |
| `dnn_denoiser/gtcrn_dual_mobile.ptl` | 372 KB | GTCRN dual (PyTorch Lite) |
| `jniLibs/libonnxruntime.so` | 25 MB | ONNX Runtime |
| `jniLibs/libsherpa-onnx-jni.so` | 4.5 MB | Sherpa ONNX JNI |
| `jniLibs/liboboe.so` | 2.6 MB | Google Oboe |
| `jniLibs/libfbjni.so` | 176 KB | Facebook JNI |

## Actualizar un binario

1. Compilar/obtener el nuevo binario
2. Subir como asset al release `v1.0-binaries` en GitHub
3. Otros devs ejecutan `./scripts/setup.sh` (detecta y re-descarga)

## CI

El workflow `ci-core.yml` usa `./scripts/setup.sh` para obtener los binarios antes de compilar.

## Crear el release (una sola vez)

```bash
# Desde la raíz del proyecto con los binarios presentes localmente
gh release create v1.0-binaries \
  android/app/src/main/assets/dnn_denoiser/gtcrn.onnx \
  android/app/src/main/assets/dnn_denoiser/gtcrn_dual_mobile.pt \
  android/app/src/main/assets/dnn_denoiser/gtcrn_dual_mobile.ptl \
  android/app/src/main/jniLibs/arm64-v8a/libonnxruntime.so \
  android/app/src/main/jniLibs/arm64-v8a/libsherpa-onnx-jni.so \
  android/app/src/main/jniLibs/arm64-v8a/liboboe.so \
  android/app/src/main/jniLibs/arm64-v8a/libfbjni.so \
  --title "Binary dependencies" \
  --notes "DNN models + native libraries for Audifon build"
```
