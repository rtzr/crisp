# 파일 HQ 외부 모델 통합 (PoC)

[`enhance-limitations-research.md`](enhance-limitations-research.md)의 권고를 실행하기 위한
**파일 HQ 생성형 모델 통합 seam**과 벤치 스캐폴드. 한계(대역폭 복원·디클리핑·dereverb)는
파일 경로의 신경망 모델로 넘어가야 하는데, 그 모델은 PyTorch라 Swift/tract 런타임에 번들할 수
없다 → **out-of-process worker**로 붙인다(PRD §4.4 "PyTorch helper … 파일 HQ beta까지만 허용").

## Seam 구조

```
입력파일 → decode(48k mono) → in.wav
        → [외부 모델 프로세스]  (Resemble Enhance / ClearerVoice / …)  → out.wav
        → HQ post-DSP: LUFS 정규화 + true-peak(−1 dBTP) 천장
        → 최종 파일 + before/after 리포트
        (temp WAV는 완료/실패 시 삭제 — PRD §7.1 프라이버시)
```

- `ExternalEnhancer`(`CrispEngine/ExternalEnhancer.swift`) — `{in}`/`{out}` placeholder를 가진
  argv를 `/usr/bin/env`로 실행. 비정상 종료/미생성 시 throw(앱 크래시 없음).
- `FileEnhancer.enhanceExternal(input:output:model:options:)` — decode→외부실행→post-DSP→write.
- 모델 미설치 시 파일 경로는 **기존 내장 DSP 인핸서**를 그대로 사용(graceful).

**핵심**: 외부 모델은 레포에 포함하지 않는다. 운영자가 **상용 라이선스를 확인하고** 설치한
명령을 가리킬 뿐이다.

CLI: `filetool external <in> <out> <fast|hq> <podcast|meeting|none> <cmd> [args…]`
(검증: `cp {in} {out}` 패스스루로 plumbing + post-DSP(−1 dBTP) 동작 테스트 통과)

## 벤치마크 (PRD M1 "동일 테스트셋 비교")

```sh
./scripts/hq-model-poc.sh --print-setup     # Resemble/ClearerVoice 설치·래퍼 방법 출력
# 외부 모델을 file-in/out 명령으로 export 후:
export RESEMBLE_CMD="$PWD/resemble-enhance-file {in} {out}"
export CLEARERVOICE_CMD="$PWD/.clearvoice.venv/bin/python $PWD/scripts/clearvoice-wrapper.py {in} {out}"
./scripts/hq-model-poc.sh                    # 내장 DSP + 외부 모델 비교 → test/corpus/hq-poc-report.csv
```

스캐폴드는 코퍼스 × 엔진(dsp + 설치된 외부) 처리 → `evaltool`로 LUFS/peak/true-peak/SI-SDR 채점.
외부 모델 미설정이면 **내장 DSP만** 돌리고 건너뛴다(실패 아님).

### ClearerVoice PoC 결과 (2026-06-25)

환경: Apple Silicon CPU, `clearvoice==0.1.2`, `MossFormer2_SE_48K`,
`scripts/clearvoice-wrapper.py` → `filetool external` → HQ post-DSP.

| 엔진 | 샘플 수 | 평균 SI-SDR | 평균 LUFS | true-peak | finite |
|---|---:|---:|---:|---:|---:|
| 내장 DSP HQ | 12 | **2.55 dB** | −19.41 | −1.00 dBTP | 12/12 |
| ClearerVoice HQ | 12 | **6.04 dB** | −20.34 | −1.00 dBTP | 12/12 |

ClearerVoice는 전체 샘플에서 DSP보다 SI-SDR이 높았다(평균 **+3.50 dB**, 최소 +1.92 dB
`reverb_noisy_snr5`, 최대 +7.25 dB `quiet`). 특히 bandlimit(평균 6.11 vs 1.96 dB),
clipping(6.14 vs 2.86 dB), noisy(5.62 vs 2.59 dB)에서 파일 HQ 후보로 의미 있는 개선을 보였다.

주의: SI-SDR은 객관 proxy일 뿐이다. 실제 제품 노출 전에는 사람 A/B 청취, WER, DNSMOS/PESQ/NISQA
같은 지각/인식 지표를 추가해야 한다. ClearerVoice는 Python+Torch+체크포인트를 요구하므로 현재 앱
번들에 포함하지 않고, 설치된 외부 명령이 있을 때만 file-HQ beta로 연결하는 구조가 맞다.

### 앱 노출 방식

`FileTabView`는 HQ 품질에서만 "HQ 모델" Picker를 보인다. 발견 순서:

1. `CRISP_CLEARERVOICE_CMD` 또는 `CLEARERVOICE_CMD` 환경변수
2. 현재 작업 디렉터리/실행 파일 상위 경로에서 `.clearvoice.venv/bin/python`,
   `scripts/clearvoice-wrapper.py`, `checkpoints/MossFormer2_SE_48K/last_best_checkpoint.pt` 동시 발견

ClearerVoice가 없으면 Picker가 나타나지 않고 기존 내장 DSP 경로를 그대로 쓴다. ClearerVoice 선택 시
내장 DSP의 모드/강도/톤 컨트롤은 숨기고, 외부 모델 출력 뒤 Crisp의 LUFS/true-peak post-DSP만 적용한다.

## 후보별 통합 메모 (라이선스 검증 결과)

| 모델 | 통합 방식 | 라이선스 | 비고 |
|---|---|---|---|
| **Resemble Enhance** | dir-CLI → file-in/out 래퍼 | 코드 MIT(검증서 **반박** 이력) · **가중치 출시 전 확인** | denoise+왜곡복원+BWE 일괄, 파일 전용 |
| **ClearerVoice-Studio** | Python API → 래퍼 | **코드 Apache-2.0 ✅** · MossFormer2_SE_48K 가중치 README Apache-2.0 ✅ | FRCRN denoise / 16k→48k SR |
| **AP-BWE** | (파일은 가능하나) **실시간은 네이티브 ONNX/CoreML stage 권장** | **코드+가중치 MIT ✅** · CPU 18.1×RT | BWE 전용, 실시간 후보 → 별도 작업 |
| AnyEnhance | — | 재현코드 MIT, **가중치 무라이선스** → 배포불가 | 레퍼런스만 |
| NVIDIA RE-USE | — | **NSCLv1 비상용** | 출시 제외 |

## 실시간은 이 seam이 아니다

본 seam은 **파일 전용**(subprocess + PyTorch, 지연 무제한). 실시간 BWE(AP-BWE)는 subprocess가
아니라 **`VoiceEnhancer` 자리에 들어가는 네이티브 causal 스테이지**(ONNX Runtime/CoreML, 무할당)
로 가야 한다 — 별도 PoC. true-peak 리미터는 이미 실시간/파일 공통 DSP로 구현됨.

## 다음 단계

1. ~~상용 라이선스 확정된 모델 1종(우선 ClearerVoice = Apache-2.0) 설치 → `hq-model-poc.sh` 벤치~~
   **완료**: ClearerVoice가 SI-SDR 기준 DSP 대비 평균 +3.50 dB.
2. ~~`FileTabView`에 "HQ 모델" 옵션 노출 방식 설계~~ **완료**: 설치된 외부 명령/venv/체크포인트를
   발견할 때만 ClearerVoice 선택지를 보이고, 미설치 시 DSP fallback. 앱 번들에 Python/Torch를 포함하지 않는다.
3. 사람 A/B 청취 + WER/DNSMOS/PESQ 등 추가 지표로 제품 노출 여부 결정.
4. 실시간 BWE는 AP-BWE causal/ONNX PoC를 별도 트랙으로.
