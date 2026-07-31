# DPDFNet-2 48 kHz ONNX Model

This directory must contain the DPDFNet-2 48 kHz high-resolution denoiser model:

- `dpdfnet2_48khz_hr.onnx` — DPDFNet-2 48 kHz native denoiser (10.3 MB, 2.58M params)

## Model Specifications

| Field         | Value                          |
|---------------|--------------------------------|
| Input shape   | `[1, 1, 481, 2]` (batch, channel, freq_bins, real_imag) |
| Output shape  | `[1, 1, 481, 2]` (complex mask) |
| Sample rate   | 48000 Hz (native, no resampling) |
| Hop size      | 480 samples (10 ms)            |
| FFT size      | 960 (481 complex bins)         |
| Model size    | 10.3 MB                        |
| Parameters    | 2.58M                          |
| MACs per hop  | 2.42G                          |
| Architecture  | Deep Filtering (complex mask on magnitude + phase) |

## Source

Download from sherpa-onnx releases:
https://github.com/k2-fsa/sherpa-onnx/releases

Look for the model file named `dpdfnet2_48khz_hr.onnx` in the speech denoiser models section.

## Usage

The `Dpdfnet2_48khzDenoiser` class loads this model at runtime via:
```cpp
initialize(assetManager, "dpdfnet2/dpdfnet2_48khz_hr.onnx");
```

## Notes

- This directory is independent of other denoiser engines (dfn3/, dnn_denoiser/)
- The model operates at 48 kHz natively — no resampling required
- If this model is missing, DPDFNet2_Engine will fail to initialize and the
  DenoiserSelector will fallback to RNNoise automatically
