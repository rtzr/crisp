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
./scripts/hq-model-poc.sh                    # 내장 DSP + 외부 모델 비교 → test/corpus/hq-poc-report.csv
```

스캐폴드는 코퍼스 × 엔진(dsp + 설치된 외부) 처리 → `evaltool`로 LUFS/peak/true-peak/SI-SDR 채점.
외부 모델 미설정이면 **내장 DSP만** 돌리고 건너뛴다(실패 아님).

## 후보별 통합 메모 (라이선스 검증 결과)

| 모델 | 통합 방식 | 라이선스 | 비고 |
|---|---|---|---|
| **Resemble Enhance** | dir-CLI → file-in/out 래퍼 | 코드 MIT(검증서 **반박** 이력) · **가중치 출시 전 확인** | denoise+왜곡복원+BWE 일괄, 파일 전용 |
| **ClearerVoice-Studio** | Python API → 래퍼 | **코드 Apache-2.0 ✅** · 가중치(ModelScope) 확인 | FRCRN denoise / 16k→48k SR |
| **AP-BWE** | (파일은 가능하나) **실시간은 네이티브 ONNX/CoreML stage 권장** | **코드+가중치 MIT ✅** · CPU 18.1×RT | BWE 전용, 실시간 후보 → 별도 작업 |
| AnyEnhance | — | 재현코드 MIT, **가중치 무라이선스** → 배포불가 | 레퍼런스만 |
| NVIDIA RE-USE | — | **NSCLv1 비상용** | 출시 제외 |

## 실시간은 이 seam이 아니다

본 seam은 **파일 전용**(subprocess + PyTorch, 지연 무제한). 실시간 BWE(AP-BWE)는 subprocess가
아니라 **`VoiceEnhancer` 자리에 들어가는 네이티브 causal 스테이지**(ONNX Runtime/CoreML, 무할당)
로 가야 한다 — 별도 PoC. true-peak 리미터는 이미 실시간/파일 공통 DSP로 구현됨.

## 다음 단계

1. 상용 라이선스 확정된 모델 1종(우선 ClearerVoice = Apache-2.0) 설치 → `hq-model-poc.sh`로
   내장 DSP 대비 품질(LUFS/true-peak/SI-SDR/WER) 벤치.
2. 이기면 `FileTabView`에 "HQ 모델" 옵션 노출(설치 시에만), 미설치 시 DSP fallback.
3. 실시간 BWE는 AP-BWE causal/ONNX PoC를 별도 트랙으로.
