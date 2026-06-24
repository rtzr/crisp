# Crisp — Voice Enhancer 파이프라인 (PRD v0.2 구현)

`krisp_like_mac_voice_enhancer_prd_v02.docx` 의 Voice Enhancer 추가 요구사항을 기존
DeepFilterNet 노이즈 캔슬링 MVP 위에 구현한 내용. 본 문서는 PRD 각 절 ↔ 구현 매핑과
모델 선택 판단, 검증 결과를 기록한다. 실제 들리는 효과·한계 요약은
[`enhance-behavior.md`](enhance-behavior.md).

## 핵심 설계 결정 — 모델 vs DSP

PRD는 실시간 Voice Enhancer 후보로 **LocalVQE**, 파일 HQ 후보로 **Resemble Enhance /
ClearerVoice** 를 "1순위 PoC"(§1, §2.1, §9 M1)로 제시한다. 이들은 **다운로드·벤치마크·
라이선스 확인이 선행되어야 하는 별도 R&D 마일스톤**이며, 본 변경에서 가중치를 번들하지
않는다.

대신 PRD가 명시적으로 허용하는 경로를 택했다:

- §4.2 "Realtime: LocalVQE **or lightweight enhancer + DSP**"
- §4.5 "Noise Cancellation stage와 Voice Enhancer stage를 **독립 모듈로 교체 가능한 구조**"

→ Voice Enhancer stage를 **순수 Swift DSP 인핸서**(HPF·톤 EQ·컴프레서·디에서·리미터)로
구현하고, 동일한 `AudioProcessor` 스트리밍 인터페이스 뒤에 둔다. 추후 LocalVQE/Resemble
래퍼를 **같은 seam에 드롭인**할 수 있다(코드 변경 없이 stage 교체).

**이 선택의 이점**

- 신규 서드파티/모델 weight **0개** → 라이선스 BOM 변화 없음(PRD §0.3 상용성, §7.2).
- **생성형 아님** → 화자 정체성·발화 내용 보존(PRD §2.3, §6.2, 명시적 제외 범위).
- 추가 지연 **≈ 0 ms**(IIR, lookahead 없음) → PRD §6.1 실시간 예산 여유 유지.

## PRD ↔ 구현 매핑

| PRD | 요구 | 구현 |
|---|---|---|
| §2.2 / FR-RT-002 | Off / Noise Cancellation / Voice Enhancer / Clean + Enhance | `ProcessingMode` (`AudioProcessing.swift`), UI 4-mode picker |
| §4.1 | 2-stage 파이프라인 (Clean → Enhance + Post-DSP) | `PipelineProcessor` (suppressor → enhancer) |
| §4.2 | 실시간: HPF, mild compressor, de-esser, output limiter, preset EQ | `VoiceEnhancer` (Biquad HPF/EQ + comp + de-ess + limiter) |
| §4.2 | 모드 전환 30~80ms crossfade, pop/click 없음 | 항상 in-path + dry→wet 40ms 램프, atten 0 = bit-identical |
| §4.3 | 파일 HQ: decode → (de)noise → enhance → loudness → true-peak | `FileEnhancer.enhance(options:)` + `Loudness` |
| §4.5 | `AudioProcessingConfig` / `AudioProcessor` / 교체 가능 stage | `AudioProcessing.swift` (config + protocol) |
| §3.2 / FR-RT-003 | Enhance Strength Low/Med/High | `EnhanceStrength` (intensity 0.45/0.75/1.0) |
| §3.2 | Tone Preset 3종 | `TonePreset` natural/warm/bright |
| FR-FILE-002 | Fast / HQ | `FileQuality`; HQ에서만 loudness 정규화 적용 |
| FR-FILE-003 | 처리 전 15~30초 미리듣기 | `FileEnhanceOptions.previewSeconds` + UI "미리듣기(20초)" |
| FR-FILE-005 | 원본 비덮어쓰기, WAV/오디오교체 저장 | NSSavePanel 별도 출력, wav/m4a |
| FR-FILE-006 | before/after loudness/peak 리포트 | `FileEnhanceReport` (LUFS·peak·gain) UI 표기 |
| §4.3 step6 | -16 LUFS(podcast) / -18 LUFS(meeting) | `LoudnessTarget` (BS.1770 K-weighting + 게이팅) |
| §4.3 step7 | -1.0 dBTP true-peak | sample-peak 천장 -1 dBFS 근사(아래 한계 참고) |
| SET-02 | model/runtime/sr/latency 진단 | Diagnostics 확장 (mode/강도/톤/추정 지연) |
| §6.2 | High는 기본값 아님, 보수적 기본 | 기본 Clean+Enhance / Medium / Natural |

## 실시간 파이프라인 (PRD §4.2)

```
mic → AVAudioConverter(48k mono)
    → DeepFilterSuppressor  (Noise Cancellation stage; atten = mode별)
    → VoiceEnhancer         (HPF → 톤 EQ → compressor → de-esser → limiter; dry→wet 램프)
    → ring → AUHAL → 가상 마이크
```

**클릭 없는 모드 전환의 핵심**: 두 stage는 모든 모드에서 **구조적으로 항상 신호 경로에
존재**한다. 모드는 파라미터만 바꾼다 — suppressor의 attenuation(0dB=패스스루)과 enhancer의
dry→wet 블렌드(40ms 램프). 라우팅이 재구성되지 않으므로 샘플 수 불연속이나 클릭이 원천적으로
발생하지 않는다(PRD §8.4). `wetMix==0`이면 enhancer 출력은 입력과 **bit-identical**(검증됨).

## Voice Enhancer DSP 체인

1. **High-pass** ~80Hz (rumble/DC 제거; PRD §4.2 "60~80 Hz HPF")
2. **Tone EQ** — natural(presence +), warm(low-shelf +, high-shelf −), bright(presence + air +)
3. **Compressor** — downward, ratio 1.5~3:1(강도별), makeup ≤+2dB → 음량 균일도
4. **De-esser** — 5kHz 사이드체인 검출 → 고정 high-shelf cut(≤−8dB)을 사이빌런스 비례 블렌드
5. **Output limiter** — −1 dBFS 천장 + 하드 클램프(클립 방지)

전 단계 `Biquad`(RBJ cookbook, transposed DF-II) + `EnvelopeFollower` 기반, **할당 없는 per-sample**
처리. 강도/톤 변경은 계수만 재계산(딜레이 상태 보존) → 라이브 변경도 클릭 없음.

## 검증 결과

`vetool`(DSP/파이프라인 검증 CLI, `dftool`의 enhancer 버전):

```
$ vetool                                      # DSP 단독 (모델 불필요)
PASS 1/4 — inactive enhancer is exact passthrough        # wetMix=0 bit-identical
PASS 2/4 — enhancer output is independent of buffer chunking   # 스트리밍 결정성
PASS 3/4 — output peak 0.7537 within full scale (limiter ok)   # 리미터/클램프
PASS 4/4 — active enhancer changes signal
RTF enhancer-only: 0.0119                     # ≈ 84× 실시간

$ vetool engine/models/DeepFilterNet3_onnx.tar.gz
RTF clean+enhance pipeline: 0.1126            # ≈ 8.9× 실시간 (denoise+enhance)
```

`filetool enhance` (파일 HQ 파이프라인, `test/fixtures/noisy_snr0.wav` 10.6s):

| 모드 | 품질 | 출력 LUFS | peak(in→out) | gain | 비고 |
|---|---|---|---|---|---|
| clean+enhance | HQ podcast | −19.3 | −3.5 → −1.0 dBFS | +6.9 dB | peak 천장에 의해 −16 미달(클립 방지) |
| voice/warm | HQ meeting | −19.0 | −3.5 → −1.0 dBFS | +7.3 dB | |
| noise | Fast | −23.7 | −3.5 → −3.9 dBFS | +0.0 dB | Fast=정규화 미적용 |
| off | HQ podcast | −21.0 | −3.5 → −1.0 dBFS | +2.5 dB | 변환+정규화만 |

출력은 48k mono Int16 WAV / AAC m4a, **길이 정확 보존**(10.595646s in=out → hop carry+flush
샘플 정확). 모든 모드 정상.

## 테스트셋 & 자동화 테스트

PRD §8.1 테스트셋과 §8.2 자동 평가, §9.4 "batch 처리 스크립트 + 결과 CSV" 납품물을 구현했다.

**테스트셋** — 레포의 실제 음성·노이즈 자산으로 다운로드 없이 구성(`TestCorpus`):
clean / noisy(SNR 0·5·10·20) / reverb / reverb+noise / clipping / bandlimit(8·16k) / 저음량 / hum.
생성: `maketestset test/corpus` (`test/corpus/README.md` 참고).

**XCTest 스위트** (`swift test`) — **26개 테스트, 0 실패**:
- `BiquadTests` — 0dB peaking=identity, LPF가 HF 감쇠, HPF가 DC 제거, 엔벨로프 수렴
- `VoiceEnhancerTests` — 비활성 패스스루 bit-identical, chunk 독립성, 리미터 full-scale 이내, 톤 프리셋 finite, 램프 클릭 없음
- `LoudnessTests` — 무음=-inf, 음량 선형성(+20LU), 정규화 목표 도달, peak 천장 준수
- `MetricsTests` — RMS/peak, SI-SDR(동일=∞, 노이즈↑=점수↓), **지연 보정 SI-SDR**(순수 지연 복원)
- `PipelineTests` — Off/Noise 무채색, Clean+Enhance 변화+길이보존, 라이브 모드 전환 finite
- `IntegrationTests`(자산/모델 있을 때) — 코퍼스 생성 유효성, 파일 end-to-end(길이 보존·천장·finite)

**배치 평가** (`scripts/quality-eval.sh`) — 코퍼스 × 모드 처리 → `quality-report.csv`
(LUFS/peak/SI-SDR). 비정상 출력(non-finite·클리핑) 시 exit 1 → **회귀 게이트**.
SI-SDR은 모델 지연을 cross-correlation으로 정렬 후 측정. 측정 결과:

| 입력 | noise mode SI-SDR(in→out) | 해석 |
|---|---|---|
| noisy_snr0 | 0.00 → **+4.89** | 저-SNR에서 denoise 이득 큼 |
| noisy_snr5 | 5.00 → 5.51 | 모델 상한(≈6dB)에 수렴 |
| noisy_snr20 | 20.0 → 6.33 | 이미 깨끗 → 처리가 재구성 한계로 fidelity 소폭↓ |
| clean | (∞) → 6.25 | DeepFilter의 clean 재구성 상한 |

> SI-SDR 상한(≈6dB)은 신경망 denoiser가 pristine clean 대비 갖는 재구성 한계(샘플 단위 지표 특성)이며
> 결함이 아니다. 지각 품질은 DNSMOS(`poc/model/run_poc.sh`)로 별도 측정(OVRL +0.55).

## 한계 / 후속

- **True-peak(-1 dBTP)** 는 4× 오버샘플링 없이 **sample-peak 천장**으로 근사(음성에서 보수적).
  방송 수준 정밀 true-peak가 필요하면 oversampling 리미터로 교체.
- **LUFS** 게이팅은 절대(-70)·상대(-10 LU) 게이트 구현, K-weighting은 BS.1770 근사 계수.
- **LocalVQE / Resemble / ClearerVoice 실모델**: 동일 `AudioProcessor` seam에 래퍼로 드롭인
  가능. 가중치 다운로드·벤치마크·라이선스 확인은 PRD §9 M1 별도 마일스톤.
- A/B blind 청취(PRD §8.3) 및 회의 앱 실사용은 사람 검수 필요(`docs/acceptance-checklist.md`).
