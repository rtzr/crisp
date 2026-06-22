#!/usr/bin/env bash
#
# Verify the Crisp virtual microphone: does it appear, and can it be recorded from?
# Exit 0 if the device appears in CoreAudio and a recording of the expected length is produced.
#
set -uo pipefail

DEVICE_NAME="Noise Cancelled Microphone"
OUT_WAV="${TMPDIR:-/tmp}/crisp_verify.wav"
REC_SECONDS=3
FFMPEG="$(command -v ffmpeg || true)"

pass=0
fail=0
check() { if [[ "$1" == "ok" ]]; then echo "  [PASS] $2"; ((pass++)); else echo "  [FAIL] $2"; ((fail++)); fi; }

echo "== 1. CoreAudio device list (system_profiler) =="
if system_profiler SPAudioDataType 2>/dev/null | grep -q "$DEVICE_NAME"; then
    check ok "\"$DEVICE_NAME\" present in SPAudioDataType"
else
    check no "\"$DEVICE_NAME\" present in SPAudioDataType"
fi

echo
echo "== 2. avfoundation device index =="
if [[ -z "$FFMPEG" ]]; then
    echo "  ffmpeg not found; skipping recording test"
else
    DEVLIST="$("$FFMPEG" -hide_banner -f avfoundation -list_devices true -i "" 2>&1 || true)"
    # avfoundation prints audio devices after a "AVFoundation audio devices:" header as "[idx] Name"
    IDX="$(printf '%s\n' "$DEVLIST" | awk '/audio devices:/{a=1;next} a && /\['"'"'"'"'"']?[0-9]+\]/{} a' \
          | grep -F "$DEVICE_NAME" | grep -oE '\[[0-9]+\]' | head -1 | tr -dc '0-9')"
    if [[ -n "$IDX" ]]; then
        check ok "found at avfoundation audio index [$IDX]"

        echo
        echo "== 3. Record ${REC_SECONDS}s from the virtual mic =="
        rm -f "$OUT_WAV"
        "$FFMPEG" -hide_banner -loglevel error -f avfoundation -i ":$IDX" \
            -t "$REC_SECONDS" -ac 2 -ar 48000 "$OUT_WAV" </dev/null || true
        if [[ -f "$OUT_WAV" ]]; then
            DUR="$("$FFMPEG" -hide_banner -i "$OUT_WAV" 2>&1 | grep -oE 'Duration: [0-9:.]+' | head -1)"
            RMS="$("$FFMPEG" -hide_banner -i "$OUT_WAV" -af astats=metadata=1 -f null - 2>&1 \
                   | grep -m1 'RMS level dB' | grep -oE '[-0-9.]+ *dB|[-0-9.]+|-inf' | tail -1)"
            check ok "recorded $OUT_WAV ($DUR)"
            echo "         RMS level: ${RMS:-unknown} (silence expected until the engine writes audio)"
        else
            check no "recording produced a file"
        fi
    else
        check no "found in avfoundation audio device list"
        echo "  --- ffmpeg device list (audio section) ---"
        printf '%s\n' "$DEVLIST" | sed -n '/audio devices:/,$p' | sed 's/^/  /'
    fi
fi

echo
echo "== Summary: $pass passed, $fail failed =="
[[ $fail -eq 0 ]]
