#!/usr/bin/env bash
#
# Phase 1b PoC: verify DeepFilterNet3 meets the real-time + quality bar.
#   Success criteria: RTF < 1 (real-time capable) and measurable noise reduction.
#
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
BIN="$ROOT/poc/model/DeepFilterNet/target/release/deep-filter"
FIX="$ROOT/test/fixtures"
IN="$ROOT/poc/model/in"      # deep-filter writes <basename>.wav into the -o dir, so keep in/out separate
OUT="$ROOT/poc/model/out"
FFMPEG="$(command -v ffmpeg)"
rm -rf "$IN" "$OUT"; mkdir -p "$IN" "$OUT"

rms_db() { "$FFMPEG" -hide_banner -i "$1" -af astats=metadata=1 -f null - 2>&1 | grep -m1 'RMS level dB' | grep -oE '[-0-9.]+|-inf' | tail -1; }
dur()    { "$FFMPEG" -hide_banner -i "$1" 2>&1 | grep -oE 'Duration: [0-9:.]+' | head -1 | grep -oE '[0-9:.]+'; }
dur_s()  { "$FFMPEG" -hide_banner -i "$1" 2>&1 | grep -oE 'Duration: [0-9:.]+' | head -1 | awk -F'[:.]' '{print $2*3600+$3*60+$4"."$5}'; }

echo "============================================================"
echo " Phase 1b — DeepFilterNet3 inference PoC"
echo "============================================================"

# ---- Test 1: real noisy speech (SNR 0 dB) ----
echo
echo "[1] Real noisy speech (noisy_snr0.wav)"
cp "$FIX/noisy_snr0.wav" "$IN/speech.wav"
AUDIO_DUR="$(dur_s "$IN/speech.wav")"
START=$(date +%s.%N)
"$BIN" -o "$OUT" "$IN/speech.wav" >/dev/null 2>&1
END=$(date +%s.%N)
PROC=$(echo "$END - $START" | bc)
ENH="$OUT/speech.wav"
RTF=$(echo "scale=4; $PROC / $AUDIO_DUR" | bc)
echo "    audio duration  : ${AUDIO_DUR}s"
echo "    processing time : ${PROC}s"
echo "    RTF             : $RTF   (< 1.0 = faster than real time)"
echo "    RMS before      : $(rms_db "$IN/speech.wav") dB"
echo "    RMS after       : $(rms_db "$ENH") dB  (speech preserved → small overall change expected)"

# ---- Test 2: pure noise (clean attenuation number) ----
echo
echo "[2] Pure noise (5s pink noise) — expect strong attenuation"
"$FFMPEG" -hide_banner -y -f lavfi -i "anoisesrc=d=5:c=pink:a=0.5" -ar 48000 -ac 1 "$IN/noise.wav" >/dev/null 2>&1
"$BIN" -o "$OUT" "$IN/noise.wav" >/dev/null 2>&1
BEFORE=$(rms_db "$IN/noise.wav"); AFTER=$(rms_db "$OUT/noise.wav")
echo "    RMS before      : $BEFORE dB"
echo "    RMS after       : $AFTER dB"
echo "    attenuation     : $(echo "scale=1; $BEFORE - ($AFTER)" | bc) dB"

# ---- Test 3: strength mapping sanity (atten-lim-db) ----
echo
echo "[3] Strength mapping (atten-lim-db: low=12 / med=24 / high=100)"
for a in 12 24 100; do
    rm -rf "$OUT/s$a"; mkdir -p "$OUT/s$a"
    "$BIN" -a "$a" -o "$OUT/s$a" "$IN/noise.wav" >/dev/null 2>&1
    echo "    atten ${a}dB -> RMS after $(rms_db "$OUT/s$a/noise.wav") dB"
done

echo
echo "============================================================"
echo " Done."
echo "============================================================"
