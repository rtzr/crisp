#!/usr/bin/env bash
#
# Remove the Crisp HAL plug-in and restart coreaudiod. Requires sudo.
#
set -euo pipefail

DEST="/Library/Audio/Plug-Ins/HAL/CrispAudio.driver"

if [[ $EUID -ne 0 ]]; then
    echo "Must run with sudo:  sudo $0" >&2
    exit 1
fi

if [[ -d "$DEST" ]]; then
    echo "==> Removing $DEST"
    rm -rf "$DEST"
else
    echo "==> Not installed: $DEST"
fi

echo "==> Restarting coreaudiod"
killall coreaudiod 2>/dev/null || true
echo "==> Done."
