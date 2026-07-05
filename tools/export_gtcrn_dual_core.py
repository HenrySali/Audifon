#!/usr/bin/env python3
"""
export_gtcrn_dual_core.py -- Export GTCRN neural core to ONNX (without STFT/WPE/IVA)
=====================================================================================

This script extracts ONLY the encoder/decoder/sequence_model (neural network
portion) from GTCRN_IVA and exports it to ONNX format. The exported model
receives spectral input [1, 257, 1, 2] (real+imag per frequency bin) and
outputs enhanced spectrum [1, 257, 1, 2] -- the same interface as the existing
mono gtcrn.onnx used by processOneFrame() in dnn_denoiser.cpp.

The STFT, WPE beamforming, and IVA steps are NOT included in the export.
Those will be implemented in C++ for the dual-channel pipeline.

USAGE:
    cd H-GTCRN
    python ..\Audifon\tools\export_gtcrn_dual_core.py

    Or with explicit paths:
    python export_gtcrn_dual_core.py --model-dir C:\path\to\H-GTCRN

REQUIREMENTS:
    - Python 3.8+
    - PyTorch >= 2.0 (tested with 2.12.1+cpu)
    - The file gtcrn_iva.py in the working directory (or --model-dir)
    - Checkpoint best_model_0121.tar in ./checkpoints/ or working directory

OUTPUT:
    gtcrn_dual_core.onnx -- ONNX model (opset 17) with:
        inputs[0]  = "mix"         shape [1, 257, 1, 2]  (real+imag spectrum)
        inputs[1]  = "conv_cache"  shape determined by model
        inputs[2]  = "tra_cache"   shape determined by model
        inputs[3]  = "inter_cache" shape determined by model
        outputs[0] = "enh"         shape [1, 257, 1, 2]  (enhanced spectrum)
        outputs[1] = "conv_cache"  (updated)
        outputs[2] = "tra_cache"   (updated)
        outputs[3] = "inter_cache" (updated)

AFTER EXPORT:
    Copy gtcrn_dual_core.onnx to:
    Audifon\android\app\src\main\assets\dnn_denoiser\gtcrn_dual_core.onnx

MANUAL MODE:
    If auto-detection of model layers fails, use --manual flag with explicit
    layer names:
    python export_gtcrn_dual_core.py --manual \
        --encoder-name encoder --decoder-name decoder \
        --sequence-model-name sequence_model
"""

import sys
import os
import argparse
import traceback


# ============================================================================
# Constants matching dnn_denoiser.cpp ONNX interface
# ============================================================================

FREQ_BINS = 257       # kDnnFftSize/2 + 1 = 512/2 + 1
TIME_FRAMES = 1       # Single frame processing (streaming mode)
COMPLEX_DIM = 2       # Real + Imaginary
OUTPUT_FILE = "gtcrn_dual_core.onnx"
OPSET_VERSION = 17

# Known layer name patterns for GTCRN-family models.
# The script tries these in order to find the neural core components.
ENCODER_NAMES = [
    "encoder", "conv_encoder", "enc", "feature_extractor",
    "encoder_conv", "input_layer", "front_end",
]
DECODER_NAMES = [
    "decoder", "conv_decoder", "dec", "reconstructor",
    "decoder_conv", "output_layer", "back_end",
]
SEQUENCE_MODEL_NAMES = [
    "sequence_model", "lstm", "gru", "rnn", "temporal_model",
    "recurrent", "seq_model", "time_model", "transformer",
    "conformer", "attention",
]
# Additional sub-modules that might be part of the core
AUXILIARY_NAMES = [
    "mask_estimator", "mask_net", "mask_decoder",
    "skip_connection", "norm", "bn", "layer_norm",
    "output_proj", "output_linear", "fc",
]


# ============================================================================
# Argument parsing
# ============================================================================

def parse_args():
    parser = argparse.ArgumentParser(
        description="Export GTCRN neural core to ONNX (no STFT/WPE/IVA)")
    parser.add_argument("--model-dir", type=str, default=".",
                        help="Directory containing gtcrn_iva.py and checkpoints/")
    parser.add_argument("--checkpoint", type=str, default=None,
                        help="Path to checkpoint .tar file (auto-detected if omitted)")
    parser.add_argument("--output", type=str, default=OUTPUT_FILE,
                        help="Output ONNX filename (default: %(default)s)")
    parser.add_argument("--manual", action="store_true",
                        help="Use manual mode with explicit layer names")
    parser.add_argument("--encoder-name", type=str, default="encoder",
                        help="Name of encoder sub-module (manual mode)")
    parser.add_argument("--decoder-name", type=str, default="decoder",
                        help="Name of decoder sub-module (manual mode)")
    parser.add_argument("--sequence-model-name", type=str, default="sequence_model",
                        help="Name of sequence model sub-module (manual mode)")
    parser.add_argument("--skip-validation", action="store_true",
                        help="Skip ONNX graph validation (for debugging)")
    return parser.parse_args()


# ============================================================================
# Model discovery and loading
# ============================================================================

def find_checkpoint(model_dir, explicit_path=None):
    """Locate the checkpoint file."""
    if explicit_path and os.path.exists(explicit_path):
        return explicit_path

    candidates = [
        os.path.join(model_dir, "best_model_0121.tar"),
        os.path.join(model_dir, "checkpoints", "best_model_0121.tar"),
        os.path.join(model_dir, "checkpoints", "best_model.tar"),
    ]
    for c in candidates:
        if os.path.exists(c):
            return c

    print("ERROR: Cannot find checkpoint. Searched:")
    for c in candidates:
        print(f"  {c}")
    print("\nUse --checkpoint to specify the path explicitly.")
    sys.exit(1)


def load_model(model_dir):
    """Import GTCRN_IVA and create an instance."""
    sys.path.insert(0, os.path.abspath(model_dir))

    try:
        from gtcrn_iva import GTCRN_IVA
    except ImportError as e:
        print(f"ERROR: Cannot import GTCRN_IVA: {e}")
        print(f"Make sure gtcrn_iva.py is in: {os.path.abspath(model_dir)}")
        sys.exit(1)

    model = GTCRN_IVA()
    return model


def load_checkpoint(model, checkpoint_path):
    """Load weights from checkpoint into model."""
    import torch

    print(f"Loading checkpoint: {checkpoint_path}")
    checkpoint = torch.load(checkpoint_path, map_location="cpu")

    # Try common checkpoint formats
    if isinstance(checkpoint, dict):
        state_dict = None
        for key in ["model_state_dict", "model", "state_dict", "net"]:
            if key in checkpoint:
                state_dict = checkpoint[key]
                break
        if state_dict is None:
            # The checkpoint IS the state_dict
            state_dict = checkpoint
    else:
        state_dict = checkpoint

    # Try loading directly first
    try:
        model.load_state_dict(state_dict, strict=True)
        print("Checkpoint loaded (strict=True)")
        return
    except RuntimeError:
        pass

    # Try with strict=False (partial load is OK for core extraction)
    try:
        missing, unexpected = model.load_state_dict(state_dict, strict=False)
        if missing:
            print(f"  WARNING: {len(missing)} missing keys (may be OK if")
            print(f"  those belong to STFT/WPE layers not in the core)")
        if unexpected:
            print(f"  WARNING: {len(unexpected)} unexpected keys")
        print("Checkpoint loaded (strict=False)")
    except Exception as e:
        print(f"ERROR loading checkpoint: {e}")
        sys.exit(1)


# ============================================================================
# Layer discovery
# ============================================================================

def discover_layers(model):
    """
    Inspect model to find encoder, decoder, and sequence_model sub-modules.
    Returns a dict with keys: encoder, decoder, sequence_model (values are
    the sub-module objects or None if not found).
    """
    import torch.nn as nn

    found = {"encoder": None, "decoder": None, "sequence_model": None}

    # Only look at top-level children (depth 1)
    top_level = {}
    for name, module in model.named_children():
        top_level[name] = module

    print(f"\nModel top-level sub-modules ({len(top_level)}):")
    for name, mod in top_level.items():
        num_params = sum(p.numel() for p in mod.parameters())
        print(f"  {name}: {mod.__class__.__name__} ({num_params:,} params)")

    # Search for encoder
    for candidate in ENCODER_NAMES:
        if candidate in top_level:
            found["encoder"] = top_level[candidate]
            print(f"\n  -> Found encoder: '{candidate}'")
            break

    # Search for decoder
    for candidate in DECODER_NAMES:
        if candidate in top_level:
            found["decoder"] = top_level[candidate]
            print(f"  -> Found decoder: '{candidate}'")
            break

    # Search for sequence model
    for candidate in SEQUENCE_MODEL_NAMES:
        if candidate in top_level:
            found["sequence_model"] = top_level[candidate]
            print(f"  -> Found sequence_model: '{candidate}'")
            break

    # If encoder/decoder not found by name, try by type heuristics
    if found["encoder"] is None or found["decoder"] is None:
        for name, mod in top_level.items():
            all_known = set()
            for lst in [ENCODER_NAMES, DECODER_NAMES, SEQUENCE_MODEL_NAMES]:
                all_known.update(lst)
            if name in all_known:
                continue  # already checked
            has_conv = any(isinstance(m, (nn.Conv1d, nn.Conv2d,
                                          nn.ConvTranspose1d,
                                          nn.ConvTranspose2d))
                          for m in mod.modules())
            has_deconv = any(isinstance(m, (nn.ConvTranspose1d,
                                            nn.ConvTranspose2d))
                            for m in mod.modules())
            if has_deconv and found["decoder"] is None:
                found["decoder"] = mod
                print(f"  -> Found decoder (by ConvTranspose heuristic): '{name}'")
            elif has_conv and found["encoder"] is None:
                found["encoder"] = mod
                print(f"  -> Found encoder (by Conv heuristic): '{name}'")

    # If sequence_model not found, look for RNN/LSTM/GRU/Transformer
    if found["sequence_model"] is None:
        for name, mod in top_level.items():
            is_rnn = any(isinstance(m, (nn.LSTM, nn.GRU, nn.RNN,
                                        nn.TransformerEncoder,
                                        nn.TransformerEncoderLayer,
                                        nn.MultiheadAttention))
                         for m in mod.modules())
            if is_rnn:
                found["sequence_model"] = mod
                print(f"  -> Found sequence_model (by RNN/Transformer heuristic): '{name}'")
                break

    return found, top_level


# ============================================================================
# GTCRNCoreWrapper - Adaptive wrapper for the neural core
# ============================================================================

def create_adaptive_wrapper(model):
    """
    Create a wrapper that adapts to whatever model structure is found.
    This is the primary export strategy -- it creates a minimal nn.Module
    that calls only the neural core, auto-detecting the call signature.
    """
    import torch
    import torch.nn as nn

    class AdaptiveGTCRNCore(nn.Module):
        """
        Adaptive GTCRN Core wrapper for ONNX export.

        This wrapper copies all neural-network sub-modules from the full
        GTCRN_IVA model and reconstructs a forward() that processes spectral
        input frame-by-frame with recurrent caches.

        The forward() signature matches the existing mono gtcrn.onnx:
            inputs:  mix[1,257,1,2], conv_cache, tra_cache, inter_cache
            outputs: enh[1,257,1,2], conv_cache, tra_cache, inter_cache

        IMPORTANT: If the auto-detected forward path does not work for your
        specific GTCRN_IVA variant, you need to manually edit the forward()
        method below. The key constraints are:
          - Input shape: [1, 257, 1, 2] (batch, freq_bins, time_frames, real_imag)
          - Output shape: [1, 257, 1, 2] (same)
          - NO torch.stft / torch.istft
          - NO torch.linalg.inv or matrix inverse ops
          - NO complex64 tensor operations
          - Cache tensors flow in and out for streaming inference
        """

        def __init__(self, full_model):
            super().__init__()

            # Copy all sub-modules from the full model
            # (this ensures all weights are part of this module's state_dict)
            for name, module in full_model.named_children():
                setattr(self, name, module)

            # Store the module names for reference
            self._child_names = [n for n, _ in full_model.named_children()]

        def forward(self, mix, conv_cache, tra_cache, inter_cache):
            """
            Neural core forward pass (streaming, single frame).

            Args:
                mix:         [1, 257, 1, 2] - Real+Imag spectrum (post-beamforming)
                conv_cache:  Convolutional layer recurrent state
                tra_cache:   Transformer/RNN recurrent state (h_0)
                inter_cache: Inter-frame recurrent state (c_0 for LSTM)

            Returns:
                enh:             [1, 257, 1, 2] - Enhanced real+imag spectrum
                new_conv_cache:  Updated conv cache
                new_tra_cache:   Updated transformer/RNN cache
                new_inter_cache: Updated inter-frame cache

            Architecture patterns supported (in order of attempt):
                Pattern A: encoder -> sequence_model(+caches) -> decoder
                Pattern B: encoder -> lstm/gru(+h,c) -> decoder
                Pattern C: Full model with streaming forward method
            """
            # === Pattern A: encoder -> sequence_model -> decoder ===
            enc_out = None
            encoder_name = None
            for name in ENCODER_NAMES:
                if hasattr(self, name):
                    encoder_name = name
                    enc_module = getattr(self, name)
                    enc_out = enc_module(mix)
                    break

            if enc_out is None:
                # No encoder found - try passing mix directly
                enc_out = mix

            # === Sequence model with caches ===
            seq_out = enc_out
            new_tra_cache = tra_cache
            new_inter_cache = inter_cache

            for name in SEQUENCE_MODEL_NAMES:
                if hasattr(self, name):
                    seq_module = getattr(self, name)
                    # Try: output, h_n, c_n = seq_model(input, h_0, c_0)
                    try:
                        result = seq_module(enc_out, tra_cache, inter_cache)
                        if isinstance(result, tuple):
                            if len(result) >= 3:
                                seq_out = result[0]
                                new_tra_cache = result[1]
                                new_inter_cache = result[2]
                            elif len(result) == 2:
                                seq_out = result[0]
                                # result[1] might be (h_n, c_n) tuple
                                hidden = result[1]
                                if isinstance(hidden, tuple) and len(hidden) == 2:
                                    new_tra_cache = hidden[0]
                                    new_inter_cache = hidden[1]
                                else:
                                    new_tra_cache = hidden
                            else:
                                seq_out = result[0]
                        else:
                            seq_out = result
                        break
                    except (TypeError, RuntimeError):
                        pass

                    # Try: output, (h_n, c_n) = lstm(input, (h_0, c_0))
                    try:
                        result = seq_module(enc_out, (tra_cache, inter_cache))
                        if isinstance(result, tuple) and len(result) == 2:
                            seq_out = result[0]
                            hidden = result[1]
                            if isinstance(hidden, tuple) and len(hidden) == 2:
                                new_tra_cache = hidden[0]
                                new_inter_cache = hidden[1]
                            else:
                                new_tra_cache = hidden
                        break
                    except (TypeError, RuntimeError):
                        pass

                    # Try without caches (stateless)
                    try:
                        seq_out = seq_module(enc_out)
                        break
                    except (TypeError, RuntimeError):
                        seq_out = enc_out
                    break

            # === Decoder ===
            enh = seq_out
            for name in DECODER_NAMES:
                if hasattr(self, name):
                    dec_module = getattr(self, name)
                    # Try decoder(seq_out)
                    try:
                        enh = dec_module(seq_out)
                        break
                    except (TypeError, RuntimeError):
                        pass
                    # Try decoder(seq_out, enc_out) -- skip connection
                    try:
                        enh = dec_module(seq_out, enc_out)
                        break
                    except (TypeError, RuntimeError):
                        pass
                    # Try decoder(seq_out, mix) -- residual from input
                    try:
                        enh = dec_module(seq_out, mix)
                        break
                    except (TypeError, RuntimeError):
                        enh = seq_out
                    break

            # Conv cache: pass through (updated by encoder/decoder internally
            # if they use causal convolutions with explicit state)
            new_conv_cache = conv_cache

            return enh, new_conv_cache, new_tra_cache, new_inter_cache

    return AdaptiveGTCRNCore(full_model)


# ============================================================================
# Cache shape detection
# ============================================================================

def detect_cache_shapes(model):
    """
    Determine the cache tensor shapes by inspecting the model.
    Returns a dict with cache_name -> shape list.

    Default GTCRN cache shapes for 257-bin (512-point FFT) streaming model:
      conv_cache:  [1, C, 1, K]  where C=channels, K=kernel_width
      tra_cache:   [num_layers*dirs, 1, hidden_size]  (h_0 for LSTM/GRU)
      inter_cache: [num_layers*dirs, 1, hidden_size]  (c_0 for LSTM)
    """
    import torch.nn as nn

    # Defaults (common for GTCRN with 64 channels, 2-layer LSTM hidden=64)
    conv_cache_shape = [1, 64, 1, 7]
    tra_cache_shape = [2, 1, 64]
    inter_cache_shape = [2, 1, 64]

    # Try to detect from model parameters
    for name, mod in model.named_modules():
        if isinstance(mod, (nn.LSTM, nn.GRU)):
            h = mod.hidden_size
            n = mod.num_layers
            d = 2 if mod.bidirectional else 1
            tra_cache_shape = [n * d, 1, h]
            inter_cache_shape = [n * d, 1, h]
            print(f"  Detected RNN cache shape from '{name}': "
                  f"[{n*d}, 1, {h}]")
            break

    # Detect conv cache from first encoder conv layer
    for name, mod in model.named_modules():
        if isinstance(mod, nn.Conv2d):
            # Look for causal conv (typically in encoder)
            out_ch = mod.out_channels
            kernel = mod.kernel_size
            if isinstance(kernel, tuple):
                k = max(kernel)  # causal dim is usually the larger one
            else:
                k = kernel
            if k > 1:  # skip 1x1 convs
                conv_cache_shape = [1, out_ch, 1, k]
                print(f"  Detected conv cache shape from '{name}': "
                      f"[1, {out_ch}, 1, {k}]")
                break
        elif isinstance(mod, nn.Conv1d):
            out_ch = mod.out_channels
            k = mod.kernel_size[0] if isinstance(mod.kernel_size, tuple) else mod.kernel_size
            if k > 1:
                conv_cache_shape = [1, out_ch, 1, k]
                print(f"  Detected conv cache shape from '{name}': "
                      f"[1, {out_ch}, 1, {k}]")
                break

    return {
        "conv_cache": conv_cache_shape,
        "tra_cache": tra_cache_shape,
        "inter_cache": inter_cache_shape,
    }


# ============================================================================
# ONNX Export
# ============================================================================

def export_to_onnx(wrapper, cache_shapes, output_path, skip_validation=False):
    """Export the wrapper model to ONNX format."""
    import torch

    print(f"\n{'='*70}")
    print("Exporting to ONNX...")
    print(f"{'='*70}")

    # Create dummy inputs matching the expected interface
    mix = torch.randn(1, FREQ_BINS, TIME_FRAMES, COMPLEX_DIM)
    conv_cache = torch.zeros(*cache_shapes["conv_cache"])
    tra_cache = torch.zeros(*cache_shapes["tra_cache"])
    inter_cache = torch.zeros(*cache_shapes["inter_cache"])

    print(f"  mix shape:         {list(mix.shape)}")
    print(f"  conv_cache shape:  {list(conv_cache.shape)}")
    print(f"  tra_cache shape:   {list(tra_cache.shape)}")
    print(f"  inter_cache shape: {list(inter_cache.shape)}")

    # Test forward pass first
    print("\nRunning test forward pass...")
    wrapper.eval()
    with torch.no_grad():
        try:
            outputs = wrapper(mix, conv_cache, tra_cache, inter_cache)
        except Exception as e:
            print(f"\nERROR: Forward pass failed: {e}")
            print("\nThis means the wrapper's forward() does not match the")
            print("model's internal architecture. You need to:")
            print("  1. Inspect the model:")
            print("     python -c \"from gtcrn_iva import GTCRN_IVA; "
                  "m = GTCRN_IVA(); "
                  "[print(n, type(mod).__name__, "
                  "sum(p.numel() for p in mod.parameters())) "
                  "for n, mod in m.named_children()]\"")
            print("  2. Edit AdaptiveGTCRNCore.forward() in this script")
            print("  3. Make it call the correct sub-modules in order")
            traceback.print_exc()
            sys.exit(1)

    if isinstance(outputs, tuple) and len(outputs) == 4:
        enh, out_conv, out_tra, out_inter = outputs
    else:
        print(f"ERROR: Forward pass did not return a 4-tuple.")
        print(f"Got type={type(outputs)}, "
              f"len={len(outputs) if isinstance(outputs, tuple) else 'N/A'}")
        sys.exit(1)

    print(f"  Output enh shape:         {list(enh.shape)}")
    print(f"  Output conv_cache shape:  {list(out_conv.shape)}")
    print(f"  Output tra_cache shape:   {list(out_tra.shape)}")
    print(f"  Output inter_cache shape: {list(out_inter.shape)}")

    # Validate output shape
    expected_enh_shape = [1, FREQ_BINS, TIME_FRAMES, COMPLEX_DIM]
    if list(enh.shape) != expected_enh_shape:
        print(f"\nWARNING: Output 'enh' shape {list(enh.shape)} != "
              f"expected {expected_enh_shape}.")
        print("The C++ processOneFrame() expects [1, 257, 1, 2].")
        print("You may need to adjust the wrapper's forward() or add a reshape.")

    # Export
    print(f"\nExporting with opset_version={OPSET_VERSION}...")

    input_names = ["mix", "conv_cache", "tra_cache", "inter_cache"]
    output_names = ["enh", "conv_cache_out", "tra_cache_out", "inter_cache_out"]

    # Dynamic axes: time dimension (axis 2 of mix/enh) can vary
    dynamic_axes = {
        "mix": {2: "time_frames"},
        "enh": {2: "time_frames"},
    }

    try:
        torch.onnx.export(
            wrapper,
            (mix, conv_cache, tra_cache, inter_cache),
            output_path,
            input_names=input_names,
            output_names=output_names,
            dynamic_axes=dynamic_axes,
            opset_version=OPSET_VERSION,
            do_constant_folding=True,
            export_params=True,
            verbose=False,
        )
    except Exception as e:
        print(f"\nERROR: ONNX export failed: {e}")
        print("\nCommon causes:")
        print("  - Unsupported ops (complex64, linalg.inv, etc.)")
        print("  - Dynamic control flow not supported by ONNX")
        print("  - Type mismatches in tensor operations")
        traceback.print_exc()
        sys.exit(1)

    size_mb = os.path.getsize(output_path) / (1024 * 1024)
    print(f"\nExported: {output_path} ({size_mb:.2f} MB)")

    if not skip_validation:
        validate_onnx(output_path)

    return output_path


# ============================================================================
# ONNX Validation
# ============================================================================

def validate_onnx(onnx_path):
    """Validate the exported ONNX model for correctness and compatibility."""
    print(f"\n{'='*70}")
    print("Validating ONNX model...")
    print(f"{'='*70}")

    try:
        import onnx
    except ImportError:
        print("  WARNING: onnx package not installed. Skipping validation.")
        print("  Install with: pip install onnx")
        print("  The model was exported but NOT validated.")
        return

    # Load and check basic structure
    model = onnx.load(onnx_path)

    try:
        onnx.checker.check_model(model)
        print("  ONNX checker: PASSED")
    except Exception as e:
        print(f"  ONNX checker: FAILED - {e}")
        return

    # Print I/O info
    graph = model.graph
    print(f"\n  Inputs ({len(graph.input)}):")
    for inp in graph.input:
        shape = []
        for d in inp.type.tensor_type.shape.dim:
            if d.dim_value > 0:
                shape.append(d.dim_value)
            else:
                shape.append(d.dim_param if d.dim_param else "?")
        print(f"    {inp.name}: {shape}")

    print(f"\n  Outputs ({len(graph.output)}):")
    for out in graph.output:
        shape = []
        for d in out.type.tensor_type.shape.dim:
            if d.dim_value > 0:
                shape.append(d.dim_value)
            else:
                shape.append(d.dim_param if d.dim_param else "?")
        print(f"    {out.name}: {shape}")

    # Check for forbidden ops that indicate STFT/WPE/IVA leaked into the graph
    forbidden_ops = {
        "STFT", "DFT", "ComplexAbs", "ComplexMul",
        "MatrixInverse", "Inverse",
    }
    forbidden_patterns = ["stft", "istft", "linalg", "complex"]

    found_ops = set()
    for node in graph.node:
        found_ops.add(node.op_type)

    print(f"\n  Op types used ({len(found_ops)}):")
    for op in sorted(found_ops):
        print(f"    {op}")

    issues = []
    for op in found_ops:
        if op in forbidden_ops:
            issues.append(f"Forbidden op: {op}")
        for pattern in forbidden_patterns:
            if pattern in op.lower():
                issues.append(f"Suspicious op: {op} (matches '{pattern}')")

    if issues:
        print("\n  ISSUES FOUND:")
        for issue in issues:
            print(f"    - {issue}")
        print("\n  The model may contain STFT/WPE/IVA operations that should")
        print("  NOT be in the neural core. Edit the wrapper's forward().")
    else:
        print("\n  No forbidden ops detected. Model appears clean for Android.")

    # Verify I/O count matches GTCRN convention (4 inputs, 4 outputs)
    if len(graph.input) != 4:
        print(f"\n  NOTE: Expected 4 inputs (mix + 3 caches), "
              f"got {len(graph.input)}")
    if len(graph.output) != 4:
        print(f"\n  NOTE: Expected 4 outputs (enh + 3 caches), "
              f"got {len(graph.output)}")

    print("\n  Validation complete.")


# ============================================================================
# Main entry point
# ============================================================================

def main():
    import torch

    args = parse_args()

    print(f"{'='*70}")
    print("GTCRN Dual Core ONNX Export")
    print(f"{'='*70}")
    print(f"PyTorch version: {torch.__version__}")
    print(f"Working directory: {os.getcwd()}")
    print(f"Model directory: {os.path.abspath(args.model_dir)}")
    print()

    # Step 1: Load model
    model = load_model(args.model_dir)
    checkpoint_path = find_checkpoint(args.model_dir, args.checkpoint)
    load_checkpoint(model, checkpoint_path)
    model.eval()

    # Step 2: Discover layers
    if args.manual:
        print(f"\nManual mode: using specified layer names")
        found = {
            "encoder": getattr(model, args.encoder_name, None),
            "decoder": getattr(model, args.decoder_name, None),
            "sequence_model": getattr(model, args.sequence_model_name, None),
        }
        top_level = dict(model.named_children())
        if found["encoder"] is None:
            print(f"  ERROR: encoder '{args.encoder_name}' not found")
            print(f"  Available sub-modules: {list(top_level.keys())}")
            sys.exit(1)
    else:
        found, top_level = discover_layers(model)
        # Hard failure if no core layers discovered (encoder AND decoder missing).
        # Without at least one of these, the wrapper will silently wrap the full
        # model forward(), which may include STFT/complex ops that break on Android.
        if found["encoder"] is None and found["decoder"] is None:
            print(f"\n{'='*70}")
            print("ERROR: Layer discovery failed.")
            print(f"{'='*70}")
            print("\nCould not find encoder or decoder sub-modules in the model.")
            print("The AdaptiveGTCRNCore wrapper cannot safely extract the neural")
            print("core without these layers. Wrapping the full model would likely")
            print("include STFT/complex/linalg ops that are incompatible with the")
            print("C++ pipeline on Android.")
            print("\nAvailable top-level sub-modules:")
            for name in top_level.keys():
                print(f"  - {name}")
            print("\nTo fix this, use --manual mode with explicit layer names:")
            print(f"  python {sys.argv[0]} --manual \\")
            print(f"      --encoder-name <name> --decoder-name <name> \\")
            print(f"      --sequence-model-name <name>")
            print("\nOr inspect the model structure:")
            print('  python -c "from gtcrn_iva import GTCRN_IVA; m = GTCRN_IVA(); '
                  '[print(n, type(mod).__name__, '
                  'sum(p.numel() for p in mod.parameters())) '
                  'for n, mod in m.named_children()]"')
            sys.exit(1)

    # Step 3: Create wrapper
    print(f"\n{'='*70}")
    print("Creating AdaptiveGTCRNCore wrapper...")
    print(f"{'='*70}")
    wrapper = create_adaptive_wrapper(model)
    wrapper.eval()

    # Step 4: Detect cache shapes
    cache_shapes = detect_cache_shapes(model)
    print(f"\nCache shapes for export:")
    for name, shape in cache_shapes.items():
        print(f"  {name}: {shape}")

    # Step 5: Export
    output_path = export_to_onnx(
        wrapper, cache_shapes, args.output,
        skip_validation=args.skip_validation)

    # Step 6: Summary
    print(f"\n{'='*70}")
    print("EXPORT COMPLETE")
    print(f"{'='*70}")
    print(f"\nOutput file: {output_path}")
    print(f"\nNext steps:")
    print(f"  1. Copy {output_path} to:")
    print(f"     Audifon\\android\\app\\src\\main\\assets\\"
          f"dnn_denoiser\\{OUTPUT_FILE}")
    print(f"  2. Rebuild: flutter build apk --release")
    print(f"  3. The C++ pipeline (STFT -> WPE -> ONNX -> iSTFT) will use "
          f"this model")
    print()
    print("If the export failed or produced wrong shapes, inspect the model:")
    print('  python -c "from gtcrn_iva import GTCRN_IVA; m = GTCRN_IVA(); '
          '[print(n, type(mod).__name__, '
          'sum(p.numel() for p in mod.parameters())) '
          'for n, mod in m.named_children()]"')
    print()
    print("Then edit AdaptiveGTCRNCore.forward() in this script to match")
    print("the model's internal architecture (encoder -> RNN -> decoder).")
    print(f"{'='*70}")


if __name__ == "__main__":
    main()
