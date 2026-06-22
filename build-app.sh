#!/usr/bin/env bash
#
# Build the Crisp menu-bar app into build/Crisp.app (release), bundling the
# deep-filter model binary for offline file processing.
#
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
APP="$ROOT/build/Crisp.app"
DYLIB="$ROOT/engine/CDeepFilter/lib/libdf.dylib"
MODEL="$ROOT/engine/models/DeepFilterNet3_onnx.tar.gz"

echo "==> swift build (release)"
swift build -c release --package-path "$ROOT/app"
BIN_DIR="$(swift build -c release --package-path "$ROOT/app" --show-bin-path)"

echo "==> Assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources/lib" "$APP/Contents/Resources/models"
cp "$BIN_DIR/CrispApp" "$APP/Contents/MacOS/CrispApp"
cp "$ROOT/app/Info.plist" "$APP/Contents/Info.plist"

# Real-time model (libDF dylib, loaded via @rpath = Resources/lib) + model weights.
cp "$DYLIB" "$APP/Contents/Resources/lib/libdf.dylib"
cp "$MODEL" "$APP/Contents/Resources/models/DeepFilterNet3_onnx.tar.gz"
[[ -f "$ROOT/engine/models/DeepFilterNet3_ll_onnx.tar.gz" ]] && \
    cp "$ROOT/engine/models/DeepFilterNet3_ll_onnx.tar.gz" "$APP/Contents/Resources/models/"
echo "    bundled libdf.dylib + DeepFilterNet3 models (full + low-latency)"
# File processing uses libdf directly (AVFoundation decode/encode) — no ffmpeg, no CLI.

echo "==> Ad-hoc signing (inside-out; no hardened runtime for local dev)"
# Sign nested code first, then the bundle. Hardened runtime + ad-hoc would enforce
# library validation and reject the cargo-built libdf.dylib (different Team ID);
# Phase 5 (scripts/package.sh) re-signs everything with a Developer ID + hardened runtime.
codesign --force --sign - "$APP/Contents/Resources/lib/libdf.dylib"
codesign --force --sign - "$APP/Contents/MacOS/CrispApp"
codesign --force --sign - "$APP"

echo "==> Built: $APP"
codesign -dv "$APP" 2>&1 | sed 's/^/    /' || true
