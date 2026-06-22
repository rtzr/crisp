#!/usr/bin/env bash
#
# PRD §8 end-to-end: model → VirtualMicOutput → HAL loopback → virtual-mic input → recorder.
# mictool sustains denoised audio on the virtual mic; a recorder captures a window from it.
#
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
FF="/opt/homebrew/opt/ffmpeg@5/bin/ffmpeg"
BIN="$(cd "$ROOT/app" && swift build --show-bin-path)"
REC="$ROOT/build/rec.wav"

rms() { "$FF" -hide_banner -i "$1" -af astats=metadata=1 -f null - 2>&1 | grep -m1 'RMS level dB' | grep -oE '[-0-9.]+|-inf' | tail -1; }

# Sustain denoised audio on the virtual mic for 18s (background).
"$BIN/mictool" "$ROOT/build/in.f32" denoise 18 2>"$ROOT/build/mictool.log" &
MICPID=$!
sleep 4   # let playback stabilize

# Look up the (drifting) avfoundation index fresh, then record a 6s window.
IDX=$("$FF" -hide_banner -f avfoundation -list_devices true -i "" 2>&1 | sed -n '/audio devices:/,$p' | grep "Noise Cancelled" | grep -oE '\[[0-9]+\]' | tail -1 | tr -dc 0-9)
echo "virtual mic index = [$IDX]"
"$FF" -hide_banner -loglevel error -f avfoundation -i ":$IDX" -t 6 -ac 1 -ar 48000 -y "$REC" </dev/null
wait $MICPID 2>/dev/null

echo "=== RESULT ==="
echo "mictool: $(tail -1 "$ROOT/build/mictool.log")"
echo "recorded: $("$FF" -hide_banner -i "$REC" 2>&1 | grep -oE 'Duration: [0-9:.]+' | head -1)"
echo "recorded RMS: $(rms "$REC") dB   (silence=-inf; denoised speech ≈ -25dB)"
echo "reference denoised RMS: $(rms "$ROOT/build/stream_enhanced.wav" 2>/dev/null || echo n/a) dB"
