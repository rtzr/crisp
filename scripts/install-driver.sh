#!/usr/bin/env bash
#
# Install the Crisp HAL plug-in and restart coreaudiod. Requires sudo.
#
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC="$ROOT/build/CrispAudio.driver"
DEST_DIR="/Library/Audio/Plug-Ins/HAL"

if [[ $EUID -ne 0 ]]; then
    echo "Must run with sudo:  sudo $0" >&2
    exit 1
fi
if [[ ! -d "$SRC" ]]; then
    echo "Driver not built. Run ./build.sh first." >&2
    exit 1
fi

echo "==> Installing CrispAudio.driver -> $DEST_DIR"
rm -rf "$DEST_DIR/CrispAudio.driver"
mkdir -p "$DEST_DIR"
cp -R "$SRC" "$DEST_DIR/"

echo "==> Restarting coreaudiod (system audio will blip briefly)"
killall coreaudiod 2>/dev/null || true

echo "==> Done. Verify with: ./scripts/verify-driver.sh"
