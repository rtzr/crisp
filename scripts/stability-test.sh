#!/usr/bin/env bash
#
# PRD §8 stability: run the real-time core (model → VirtualMicOutput → HAL loopback)
# continuously and spot-check the virtual mic for crashes and dropouts.
#   stability-test.sh [seconds]   (default 1800 = 30 min)
#
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
FF="/opt/homebrew/opt/ffmpeg@5/bin/ffmpeg"
BIN="$(cd "$ROOT/app" && swift build --show-bin-path)"
DURATION=${1:-1800}
INTERVAL=180

rms() { "$FF" -hide_banner -i "$1" -af astats=metadata=1 -f null - 2>&1 | grep -m1 'RMS level dB' | grep -oE '[-0-9.]+|-inf' | tail -1; }
idx() { "$FF" -hide_banner -f avfoundation -list_devices true -i "" 2>&1 | sed -n '/audio devices:/,$p' | grep "Noise Cancelled" | grep -oE '\[[0-9]+\]' | tail -1 | tr -dc 0-9; }

"$BIN/mictool" "$ROOT/build/in.f32" denoise $((DURATION + 60)) 2>"$ROOT/build/stability_mictool.log" &
MICPID=$!
START=$(date +%s)
echo "STABILITY START dur=${DURATION}s pid=$MICPID"
sleep 5

dropouts=0; checks=0
while [ $(( $(date +%s) - START )) -lt "$DURATION" ]; do
    T=$(( $(date +%s) - START ))
    if ! kill -0 "$MICPID" 2>/dev/null; then echo "CRASH: mictool exited at ${T}s"; exit 1; fi
    I=$(idx)
    "$FF" -hide_banner -loglevel error -f avfoundation -i ":$I" -t 2 -ac 1 -ar 48000 -y "$ROOT/build/spot.wav" </dev/null 2>/dev/null
    R=$(rms "$ROOT/build/spot.wav")
    checks=$((checks+1))
    if [ "$R" = "-inf" ]; then dropouts=$((dropouts+1)); echo "[${T}s] DROPOUT spot RMS=$R"; else echo "[${T}s] OK spot RMS=$R dB"; fi
    sleep "$INTERVAL"
done
kill "$MICPID" 2>/dev/null
echo "STABILITY DONE: ran ${DURATION}s, checks=$checks, dropouts=$dropouts, mictool=$(kill -0 $MICPID 2>/dev/null && echo alive || echo exited)"
[ "$dropouts" -eq 0 ] && echo "STABILITY PASS (no crash, no dropout)" || echo "STABILITY: $dropouts dropout(s)"
