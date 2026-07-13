#!/usr/bin/env bash
# =============================================================================
# Audifon — Download large binary dependencies
#
# Usage:
#   ./scripts/setup.sh
#
# Downloads DNN models and native libraries from GitHub Releases.
# Run this after cloning the repo for the first time.
# =============================================================================

set -euo pipefail

REPO="HenrySali/Audifon"
RELEASE_TAG="v1.0-binaries"
BASE_URL="https://github.com/$REPO/releases/download/$RELEASE_TAG"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

info()  { echo -e "${GREEN}[+]${NC} $1"; }
warn()  { echo -e "${YELLOW}[!]${NC} $1"; }
error() { echo -e "${RED}[x]${NC} $1"; exit 1; }

# Detect project root (script is in scripts/)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
cd "$PROJECT_ROOT"

info "Audifon binary setup — downloading from GitHub Releases ($RELEASE_TAG)"
echo ""

# --- DNN Models ---
MODEL_DIR="android/app/src/main/assets/dnn_denoiser"
mkdir -p "$MODEL_DIR"

declare -A MODELS=(
  ["gtcrn.onnx"]="12M"
  ["gtcrn_dual_mobile.pt"]="444K"
  ["gtcrn_dual_mobile.ptl"]="372K"
)

for file in "${!MODELS[@]}"; do
  target="$MODEL_DIR/$file"
  if [ -f "$target" ]; then
    warn "Already exists: $target (${MODELS[$file]}) — skipping"
  else
    info "Downloading $file (${MODELS[$file]})..."
    curl -fSL --progress-bar "$BASE_URL/$file" -o "$target" || \
      error "Failed to download $file. Ensure release '$RELEASE_TAG' exists with this asset."
  fi
done

echo ""

# --- Native Libraries (arm64-v8a) ---
LIB_DIR="android/app/src/main/jniLibs/arm64-v8a"
mkdir -p "$LIB_DIR"

declare -A LIBS=(
  ["libonnxruntime.so"]="25M"
  ["libsherpa-onnx-jni.so"]="4.5M"
  ["liboboe.so"]="2.6M"
  ["libfbjni.so"]="176K"
)

for file in "${!LIBS[@]}"; do
  target="$LIB_DIR/$file"
  if [ -f "$target" ]; then
    warn "Already exists: $target (${LIBS[$file]}) — skipping"
  else
    info "Downloading $file (${LIBS[$file]})..."
    curl -fSL --progress-bar "$BASE_URL/$file" -o "$target" || \
      error "Failed to download $file. Ensure release '$RELEASE_TAG' exists with this asset."
  fi
done

echo ""
info "Done! All binaries downloaded (~45 MB total)."
info "You can now build the APK: flutter build apk --debug"
echo ""
echo "To update binaries: upload new files to GitHub Release '$RELEASE_TAG'"
echo "and re-run this script."
