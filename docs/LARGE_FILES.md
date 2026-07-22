# Manejo de Archivos Binarios Grandes

## Archivos afectados

| Archivo | Tamaño | Propósito |
|---------|--------|-----------|
| `android/app/src/main/assets/dnn_denoiser/gtcrn.onnx` | 12 MB | Modelo DPDFNet4 (renombrado para compatibilidad) |
| `android/app/src/main/assets/dnn_denoiser/gtcrn_dual_mobile.pt` | 444 KB | Modelo GTCRN dual (PyTorch) |
| `android/app/src/main/assets/dnn_denoiser/gtcrn_dual_mobile.ptl` | 372 KB | Modelo GTCRN dual (PyTorch Lite) |
| `android/app/src/main/jniLibs/arm64-v8a/libonnxruntime.so` | 25 MB | ONNX Runtime (inferencia DNN) |
| `android/app/src/main/jniLibs/arm64-v8a/libsherpa-onnx-jni.so` | 4.5 MB | Sherpa ONNX JNI bridge |
| `android/app/src/main/jniLibs/arm64-v8a/liboboe.so` | 2.6 MB | Google Oboe (audio de baja latencia) |
| `android/app/src/main/jniLibs/arm64-v8a/libfbjni.so` | 176 KB | Facebook JNI utilities |

**Total: ~45 MB de binarios**

## Estrategia: Git LFS

El repositorio usa Git LFS para estos archivos. La configuración está en `.gitattributes`.

### Setup (primera vez en una máquina nueva)

```bash
# Instalar Git LFS
git lfs install

# Clonar el repo (LFS se descarga automáticamente)
git clone https://github.com/HenrySali/Audifon.git

# Si ya tenías el repo clonado sin LFS:
git lfs pull
```

### Actualizar un modelo

```bash
# Reemplazar el archivo normalmente
cp nuevo_modelo.onnx android/app/src/main/assets/dnn_denoiser/gtcrn.onnx

# Git LFS lo trackea automáticamente (por .gitattributes)
git add android/app/src/main/assets/dnn_denoiser/gtcrn.onnx
git commit -m "feat(dnn): update model to DPDFNet4 v2"
git push
```

### Actualizar una librería nativa (.so)

```bash
# Reemplazar el .so
cp libonnxruntime.so android/app/src/main/jniLibs/arm64-v8a/

# Mismo flujo
git add android/app/src/main/jniLibs/arm64-v8a/libonnxruntime.so
git commit -m "deps: update ONNX Runtime to vX.Y.Z"
git push
```

## Alternativa: GitHub Releases

Si Git LFS genera costos excesivos (>1 GB de bandwidth/mes gratis en GitHub), considerar:

1. Excluir estos archivos del repo (agregar paths al `.gitignore`)
2. Publicarlos como assets de un GitHub Release
3. Agregar un script `scripts/download_models.sh` que los descargue:

```bash
#!/bin/bash
# scripts/download_models.sh
RELEASE_TAG="v1.0-models"
BASE_URL="https://github.com/HenrySali/Audifon/releases/download/$RELEASE_TAG"

mkdir -p android/app/src/main/assets/dnn_denoiser
curl -L "$BASE_URL/gtcrn.onnx" -o android/app/src/main/assets/dnn_denoiser/gtcrn.onnx

mkdir -p android/app/src/main/jniLibs/arm64-v8a
curl -L "$BASE_URL/libonnxruntime.so" -o android/app/src/main/jniLibs/arm64-v8a/libonnxruntime.so
# ... etc
```

## Notas

- Los modelos ONNX/PT son versionados con el código — un commit específico espera un modelo específico
- Los `.so` nativos raramente cambian (solo al actualizar dependencias)
- El CI descarga estos archivos via LFS automáticamente (GitHub Actions soporta `git lfs` nativo)
