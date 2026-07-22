#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# Build DeepFilterNet3 Rust crate for Android (arm64-v8a).
#
# Prerequisites:
#   1. Rust toolchain: rustup target add aarch64-linux-android
#   2. cargo-ndk: cargo install cargo-ndk
#   3. Android NDK: set ANDROID_NDK_HOME env var
#   4. DeepFilterNet3 ONNX models in assets/dfn3/:
#      - enc.onnx, erb_dec.onnx, df_dec.onnx
#      Download from: https://huggingface.co/bitsydarel/deepfilternet3-onnx
#
# Usage:
#   ./build_android.sh
#
# Output:
#   ../jniLibs/arm64-v8a/libdfn3.so
# ─────────────────────────────────────────────────────────────────────────────

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

echo "═══ Building libdfn3.so for arm64-v8a ═══"

# Ensure target is installed.
rustup target add aarch64-linux-android 2>/dev/null || true

# Build with cargo-ndk. Output goes to ../jniLibs/arm64-v8a/.
cargo ndk \
    -t arm64-v8a \
    -o "$SCRIPT_DIR/../jniLibs" \
    build --release

echo ""
echo "✅ Done. Output:"
ls -lh "$SCRIPT_DIR/../jniLibs/arm64-v8a/libdfn3.so" 2>/dev/null || echo "   (check ../jniLibs/arm64-v8a/)"
echo ""
echo "Next: copy DeepFilterNet3 ONNX models to app/src/main/assets/dfn3/"
echo "  - enc.onnx"
echo "  - erb_dec.onnx"
echo "  - df_dec.onnx"
echo ""
echo "Download from: https://huggingface.co/bitsydarel/deepfilternet3-onnx"
