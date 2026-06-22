#!/usr/bin/env bash
#
# Build the Crisp HAL Audio Server Plug-in into build/CrispAudio.driver
#
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
SRC="$ROOT/driver/CrispAudioDriver"
OUT="$ROOT/build/CrispAudio.driver"
BIN_DIR="$OUT/Contents/MacOS"
BIN="$BIN_DIR/CrispAudio"

echo "==> Cleaning $OUT"
rm -rf "$OUT"
mkdir -p "$BIN_DIR"

# Prefer a universal binary (Apple Silicon + Intel); fall back to arm64 only.
ARCH_FLAGS="-arch arm64 -arch x86_64"
echo "==> Compiling (universal: arm64 + x86_64)"
if ! clang -bundle $ARCH_FLAGS \
        -fvisibility=hidden \
        -framework CoreFoundation -framework CoreAudio \
        -o "$BIN" \
        "$SRC/CrispAudioDriver.c" 2>/dev/null; then
    echo "    universal build failed; falling back to arm64-only"
    clang -bundle -arch arm64 \
        -fvisibility=hidden \
        -framework CoreFoundation -framework CoreAudio \
        -o "$BIN" \
        "$SRC/CrispAudioDriver.c"
fi

echo "==> Installing Info.plist"
cp "$SRC/Info.plist" "$OUT/Contents/Info.plist"

echo "==> Ad-hoc code signing (required for coreaudiod to load on Apple Silicon)"
codesign --force --sign - "$OUT"

echo "==> Built:"
echo "    $OUT"
file "$BIN" | sed 's/^/    /'
codesign -dv "$OUT" 2>&1 | sed 's/^/    /' || true
