# DeepFilterNet3 — Rust/tract backend for Audifon

## Overview

This crate provides DeepFilterNet3 speech enhancement as a shared library
(`libdfn3.so`) for Android. It uses Sonos' `tract` runtime with pulsed-model
transformation for real-time frame-by-frame streaming inference.

## Architecture

```
Audio Engine (C++) → dfn3_api.h (C FFI) → libdfn3.so (Rust/tract)
                                              ↓
                                    enc.onnx + erb_dec.onnx + df_dec.onnx
```

## Prerequisites

1. **Rust toolchain**: `rustup target add aarch64-linux-android`
2. **cargo-ndk**: `cargo install cargo-ndk`
3. **Android NDK**: set `ANDROID_NDK_HOME` environment variable
4. **ONNX models**: download from HuggingFace

## Download Models

```bash
# From https://huggingface.co/bitsydarel/deepfilternet3-onnx
mkdir -p ../../assets/dfn3
cd ../../assets/dfn3
wget https://huggingface.co/bitsydarel/deepfilternet3-onnx/resolve/main/enc.onnx
wget https://huggingface.co/bitsydarel/deepfilternet3-onnx/resolve/main/erb_dec.onnx
wget https://huggingface.co/bitsydarel/deepfilternet3-onnx/resolve/main/df_dec.onnx
```

## Build

```bash
./build_android.sh
```

Output: `../jniLibs/arm64-v8a/libdfn3.so`

## Integration

The C++ audio engine includes `dfn3_api.h` and links against `libdfn3.so`.
The wrapper `dfn3_denoiser.h/cpp` provides the same interface as the old
GTCRN `DnnDenoiser` so the swap is minimal.

## License

Apache-2.0 (same as DeepFilterNet upstream).
