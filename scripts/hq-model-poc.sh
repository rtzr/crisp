#!/usr/bin/env bash
#
# File-HQ model PoC / benchmark (PRD M1 "동일 테스트셋으로 비교").
# Runs the built-in DSP enhancer AND any installed external HQ model (Resemble Enhance /
# ClearerVoice / …) over the test corpus, scores every output with evaltool (LUFS / peak /
# true-peak / SI-SDR vs clean), and writes a comparison CSV. External models are OPTIONAL:
# point env vars at a file-in/file-out command; if unset, that engine is skipped (not failed).
#
#   ./scripts/hq-model-poc.sh                 # baseline DSP + whatever external cmds are set
#   ./scripts/hq-model-poc.sh --print-setup   # how to install Resemble/ClearerVoice as a wrapper
#
# External command env vars (use {in}/{out} placeholders; must accept/produce a 48k mono WAV):
#   RESEMBLE_CMD="resemble-enhance-file {in} {out}"
#   CLEARERVOICE_CMD="clearvoice-sr {in} {out}"
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"; cd "$ROOT"
CORPUS="$ROOT/test/corpus"; OUT="$CORPUS/hq-poc"; REPORT="$CORPUS/hq-poc-report.csv"

if [[ "${1:-}" == "--print-setup" ]]; then
cat <<'SETUP'
# ── Resemble Enhance (flow-matching; denoise+왜곡복원+BWE; 파일 전용) ──────────────
python3 -m venv .venv-resemble && source .venv-resemble/bin/activate
pip install resemble-enhance --upgrade        # 가중치 자동 다운로드(최초). 라이선스 출시 전 확인!
# resemble-enhance는 디렉터리 단위 CLI → file-in/out 래퍼:
cat > resemble-enhance-file <<'EOF'
#!/usr/bin/env bash
set -e; d=$(mktemp -d); cp "$1" "$d/a.wav"
resemble-enhance "$d" "$d/out" >/dev/null 2>&1
mv "$d/out/a.wav" "$2"; rm -rf "$d"
EOF
chmod +x resemble-enhance-file
export RESEMBLE_CMD="$PWD/resemble-enhance-file {in} {out}"

# ── ClearerVoice-Studio (Apache-2.0; FRCRN denoise / MossFormer2 / 16k→48k SR) ──────
git clone https://github.com/modelscope/ClearerVoice-Studio   # 가중치는 ModelScope, 라이선스 확인
# clearvoice Python API를 file-in/out 래퍼로 감싸 CLEARERVOICE_CMD 로 export (repo 예제 참고)
SETUP
exit 0
fi

echo "==> Building tools"; swift build --package-path "$ROOT/app" >/dev/null
BIN="$(swift build --package-path "$ROOT/app" --show-bin-path)"
[[ -f "$CORPUS/manifest.csv" ]] || { echo "==> Generating corpus"; "$BIN/maketestset" "$CORPUS" >/dev/null; }
mkdir -p "$OUT"; REF="$CORPUS/clean.wav"

# engine list: built-in DSP always; external engines only if their env var is set.
declare -a ENGINES=("dsp")
[[ -n "${RESEMBLE_CMD:-}" ]] && ENGINES+=("resemble")
[[ -n "${CLEARERVOICE_CMD:-}" ]] && ENGINES+=("clearervoice")
echo "==> Engines: ${ENGINES[*]}"
[[ ${#ENGINES[@]} -eq 1 ]] && echo "    (no external model configured — run with --print-setup to add one)"

echo "file,category,snr_db,engine,lufs,peak_db,true_peak_db,si_sdr_db,finite" > "$REPORT"
score(){ "$BIN/evaltool" "$1" "$REF" 2>/dev/null; }   # CSV: lufs,peak,rms,crest,low,high,sisdr,nonfinite,truepeak

tail -n +2 "$CORPUS/manifest.csv" | while IFS=, read -r file category snr reference; do
  [[ -z "$file" || ! -f "$CORPUS/$file" ]] && continue
  IN="$CORPUS/$file"; base="${file%.wav}"
  for eng in "${ENGINES[@]}"; do
    OUTF="$OUT/${base}__${eng}.wav"
    case "$eng" in
      dsp)          "$BIN/filetool" enhance "$IN" "$OUTF" clean hq natural podcast >/dev/null 2>&1 || continue ;;
      resemble)     "$BIN/filetool" external "$IN" "$OUTF" hq podcast ${RESEMBLE_CMD} >/dev/null 2>&1 || { echo "  resemble failed on $file"; continue; } ;;
      clearervoice) "$BIN/filetool" external "$IN" "$OUTF" hq podcast ${CLEARERVOICE_CMD} >/dev/null 2>&1 || { echo "  clearervoice failed on $file"; continue; } ;;
    esac
    c="$(score "$OUTF")"
    lufs=$(echo "$c"|cut -d, -f1); peak=$(echo "$c"|cut -d, -f2); tp=$(echo "$c"|cut -d, -f9)
    sisdr=$(echo "$c"|cut -d, -f7); fin=$(echo "$c"|cut -d, -f8)
    echo "$file,$category,$snr,$eng,$lufs,$peak,$tp,$sisdr,$fin" >> "$REPORT"
  done
done

echo; echo "==> Report: $REPORT"; column -s, -t "$REPORT" | sed 's/^/    /'
