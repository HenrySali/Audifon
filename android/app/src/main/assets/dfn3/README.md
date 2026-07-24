# DFN3 ONNX Models

This directory must contain the 3 DeepFilterNet3 ONNX models:
- `enc.onnx` — Encoder (ERB + spectral features → embeddings)
- `erb_dec.onnx` — ERB Decoder (embeddings → 32-band gain mask)
- `df_dec.onnx` — DF Decoder (not used in v1, optional)

## Source
Copy from: `Audifon-main (4)/Audifon-main/android/app/src/main/assets/dfn3/`

Or download from: https://github.com/Rikorose/DeepFilterNet (releases)
