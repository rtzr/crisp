#!/usr/bin/env bash
#
# Batch quality evaluation (PRD 8.2 / 9.4 deliverable).
# Generates the test corpus (if missing), runs the Voice Enhancer pipeline over every
# corpus file in several modes, computes objective metrics (LUFS / peak / SI-SDR vs the
# clean reference), and writes a CSV report. Exits non-zero if any output is invalid
# (non-finite, or clipped above 0 dBFS) — so it doubles as a regression gate.
#
# Usage: ./scripts/quality-eval.sh [modes...]   (default: noise voice clean)
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
CORPUS="$ROOT/test/corpus"
OUTDIR="$CORPUS/out"
REPORT="$CORPUS/quality-report.csv"
MODES=("${@:-noise voice clean}")
read -r -a MODES <<< "${MODES[*]}"
QUALITY="hq"

echo "==> Building tools"
swift build --package-path "$ROOT/app" >/dev/null
BIN="$(swift build --package-path "$ROOT/app" --show-bin-path)"

if [[ ! -f "$CORPUS/manifest.csv" ]]; then
    echo "==> Generating corpus"
    "$BIN/maketestset" "$CORPUS" >/dev/null
fi
mkdir -p "$OUTDIR"

echo "==> Evaluating (modes: ${MODES[*]}, quality: $QUALITY)"
echo "file,category,snr_db,mode,in_lufs,out_lufs,in_peak_db,out_peak_db,in_sisdr_db,out_sisdr_db,sisdr_gain_db,finite" > "$REPORT"

REF="$CORPUS/clean.wav"
fail=0
# Skip the header line of the manifest.
tail -n +2 "$CORPUS/manifest.csv" | while IFS=, read -r file category snr reference; do
    [[ -z "$file" ]] && continue
    IN="$CORPUS/$file"
    [[ -f "$IN" ]] || continue
    # Baseline metrics of the unprocessed input vs the clean reference.
    in_csv="$("$BIN/evaltool" "$IN" "$REF" 2>/dev/null)"
    in_lufs="$(echo "$in_csv" | cut -d, -f1)"; in_peak="$(echo "$in_csv" | cut -d, -f2)"; in_sisdr="$(echo "$in_csv" | cut -d, -f7)"
    for mode in "${MODES[@]}"; do
        base="${file%.wav}"
        OUT="$OUTDIR/${base}__${mode}.wav"
        "$BIN/filetool" enhance "$IN" "$OUT" "$mode" "$QUALITY" natural podcast >/dev/null 2>&1
        out_csv="$("$BIN/evaltool" "$OUT" "$REF" 2>/dev/null)"
        out_lufs="$(echo "$out_csv" | cut -d, -f1)"; out_peak="$(echo "$out_csv" | cut -d, -f2)"
        out_sisdr="$(echo "$out_csv" | cut -d, -f7)"; finite="$(echo "$out_csv" | cut -d, -f8)"
        gain=""
        if [[ -n "$in_sisdr" && -n "$out_sisdr" ]]; then gain="$(awk "BEGIN{printf \"%.2f\", $out_sisdr-($in_sisdr)}")"; fi
        echo "$file,$category,$snr,$mode,$in_lufs,$out_lufs,$in_peak,$out_peak,$in_sisdr,$out_sisdr,$gain,$finite" >> "$REPORT"
        # Gate: finite and no clipping above 0 dBFS.
        if [[ "$finite" != "0" ]]; then echo "  FAIL non-finite: $OUT"; fail=1; fi
        if [[ -n "$out_peak" ]] && awk "BEGIN{exit !($out_peak > 0.1)}"; then echo "  FAIL clipping ($out_peak dBFS): $OUT"; fail=1; fi
    done
    echo "$fail" > /tmp/crisp_eval_fail   # propagate out of the subshell (pipe)
done
fail="$(cat /tmp/crisp_eval_fail 2>/dev/null || echo 0)"; rm -f /tmp/crisp_eval_fail

echo
echo "==> Report: $REPORT"
column -s, -t "$REPORT" | sed 's/^/    /'
echo
if [[ "$fail" != "0" ]]; then echo "RESULT: FAIL (invalid output detected)"; exit 1; fi
echo "RESULT: PASS — all outputs finite and within 0 dBFS"
