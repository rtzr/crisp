#!/usr/bin/env python3
"""File-in/file-out adapter for ClearerVoice-Studio (ClearVoice), matching Crisp's
ExternalEnhancer {in}/{out} contract so it can be driven by `filetool external` and
`scripts/hq-model-poc.sh`.

    clearvoice-wrapper.py <in.wav> <out.wav> [model_name]

Default model: MossFormer2_SE_48K (48 kHz speech enhancement). Pass MossFormer2_SR_48K for
super-resolution / bandwidth extension. Weights download on first run to checkpoints/.
ClearerVoice code and MossFormer2_SE_48K weights are Apache-2.0; confirm any other model
weight license before shipping.
"""
import sys
from pathlib import Path

from clearvoice import ClearVoice

def main():
    if len(sys.argv) < 3:
        sys.exit("usage: clearvoice-wrapper.py <in.wav> <out.wav> [model_name]")
    inp, outp = sys.argv[1], sys.argv[2]
    model = sys.argv[3] if len(sys.argv) > 3 else "MossFormer2_SE_48K"
    task = "speech_super_resolution" if "_SR_" in model else "speech_enhancement"
    out = Path(outp)
    if out.exists() and out.is_dir():
        sys.exit(f"output path is a directory, expected file: {outp}")
    out.parent.mkdir(parents=True, exist_ok=True)

    cv = ClearVoice(task=task, model_names=[model])
    result = cv(input_path=inp, online_write=False)
    cv.write(result, output_path=outp)
    if not out.is_file():
        sys.exit(f"clearvoice did not create output file: {outp}")

if __name__ == "__main__":
    main()
