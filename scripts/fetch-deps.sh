#!/usr/bin/env bash
#
# Fetch + build the DeepFilterNet dependency and vendor the artifacts the build needs.
# Run once after cloning, before ./build-app.sh.
#
#   - clones Rikorose/DeepFilterNet
#   - builds libDF C-API (pure-Rust tract) → engine/CDeepFilter/lib/libdf.dylib
#   - builds the deep-filter CLI (for poc/model/run_poc.sh)
#   - vendors DeepFilterNet3 models → engine/models/
#
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DFN="$ROOT/poc/model/DeepFilterNet"

command -v cargo >/dev/null || { echo "cargo (Rust) required: https://rustup.rs"; exit 1; }

if [[ ! -d "$DFN" ]]; then
    echo "==> Cloning DeepFilterNet"
    git clone --depth 1 https://github.com/Rikorose/DeepFilterNet.git "$DFN"
fi

echo "==> Building libDF C-API (this compiles tract; takes a few minutes)"
( cd "$DFN/libDF" && cargo build --release --features capi )

echo "==> Building deep-filter CLI (for the PoC)"
( cd "$DFN/libDF" && cargo build --release --bin deep-filter \
    --features "bin,tract,wav-utils,transforms,default-model" )

echo "==> Vendoring libdf.dylib (@rpath install name)"
mkdir -p "$ROOT/engine/CDeepFilter/lib"
cp "$DFN/target/release/libdf.dylib" "$ROOT/engine/CDeepFilter/lib/libdf.dylib"
install_name_tool -id "@rpath/libdf.dylib" "$ROOT/engine/CDeepFilter/lib/libdf.dylib"

echo "==> Vendoring DeepFilterNet3 models"
mkdir -p "$ROOT/engine/models"
cp "$DFN/models/DeepFilterNet3_onnx.tar.gz"    "$ROOT/engine/models/"
cp "$DFN/models/DeepFilterNet3_ll_onnx.tar.gz" "$ROOT/engine/models/"

echo "==> Done. Now: ./build.sh && ./build-app.sh"
