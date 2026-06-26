# 한계 극복 리서치 — Voice Enhancer 차세대 모델 (2024–2026)

[`enhance-behavior.md`](enhance-behavior.md)에 정리한 현재 DSP 인핸서의 한계(대역폭 복원·
디클리핑·dereverb·생성형 복원·적응형·true-peak·SI-SDR 상한)를 **넘기 위한** SOTA 조사.
다중 소스 웹 리서치 + 주장별 적대적 검증(3표 중 2표) 결과를 우리 코드베이스 기준으로 합성했다.

> **신뢰도 표기** — ✅ 검증됨(3-0 적대적 통과) · ⚠️ 1차 소스 수집됨·검증 미완(세션 한도로 verify
> 중단) · 💡 도메인 지식 보강. **라이선스/수치는 출시 전 원문 재확인 필수**(PRD §7.2). 본 리포트는
> 합성 단계가 세션 한도로 중단돼 **수동 합성**했다 — verify 보강 재실행 가능.

---

## 한 줄 결론

| 경로 | 지금 도입 가능 | 차기(검증 후) | 레퍼런스/보류 |
|---|---|---|---|
| **실시간(causal)** | DeepFilter 유지 + **true-peak 리미터 자체 구현** | **AP-BWE**(경량 BWE, MIT, CPU 빠름)·WPE dereverb | Stream.FM(32ms 생성형, 연구최전선) |
| **파일 HQ** | — | **Resemble Enhance**·**ClearerVoice-Studio**(라이선스 검증 후) | FINALLY·Miipher-2(가중치/라이선스)·AnyEnhance·RE-USE(비상용) |

핵심: **생성형 통합 복원은 거의 다 파일(offline) 전용**이고, **실시간 생성형은 이제 막
연구 단계(Stream.FM, 2025.12)**다. 실시간에서 당장 넘을 수 있는 한계는 **BWE(AP-BWE)**와
**true-peak**뿐이며, 디클리핑·강한 dereverb·studio급 복원은 **파일 모드의 생성형 모델**로 가야 한다.

---

## 한계별 SOTA & 권고

### 1. 대역폭 복원 / 음성 초해상 (BWE/SR)
- **SOTA 방향**: 판별형(discriminative) 매핑은 regression-to-mean → 고역 over-smoothing.
  필드가 **생성형(diffusion/flow/bridge)** 으로 이동 중. ⚠️(출처 arxiv 2605.16681)
- **AP-BWE** ✅검증(2026-06-25 재확인) (arxiv [2401.06387](https://arxiv.org/abs/2401.06387),
  [github.com/yxlu-0102/AP-BWE](https://github.com/yxlu-0102/AP-BWE)) — 진폭·위상 **병렬 예측
  GAN**(dual-stream). 입력 **8/12/16/24 kHz → 48 kHz**(및 2/4/8k→16k). 논문 명시
  **CPU에서 18.1× 실시간**(48k 생성), GPU 292.3×. all-conv 구조 → ONNX 변환 친화적.
  **라이선스: 코드+가중치 모두 MIT**(`weights_LICENSE.txt`로 확인) → 상용 가능.
  → **실시간 BWE 1순위 후보** (단 공개 체크포인트는 causal/streaming이 아님 → causal PoC 필요).
- ClearerVoice-Studio에 16k→48k **super-resolution** 포함 ⚠️ (파일 경로).
- 후보(💡): mdctGAN, NU-Wave2, AudioSR(diffusion, 파일·느림). Resemble Enhance enhancer가 BWE 내장 ✅.
- **권고**: 실시간 = AP-BWE를 causal/스트리밍으로 만들 수 있는지 PoC(현재 코드의 enhancer stage 자리).
  파일 = Resemble/ClearerVoice가 이미 BWE 포함 → 별도 모델 불필요.

### 2. 디클리핑 / 새츄레이션 복구
- 단독 경량 상용 모델은 두드러진 것이 없음. **통합 생성형 모델의 부분기능**으로 해결되는 추세:
  **AnyEnhance**(declip 포함) ✅, **FINALLY**(digital distortion 학습) ✅, Resemble Enhance(distortion 복원) ✅.
- 고전 DSP(A-SPADE 등)는 경미한 클리핑만. 💡
- **권고**: 디클리핑은 **파일 HQ 생성형 모델에 위임**(전용 모델 도입 안 함). 실시간은 보류.

### 3. 잔향 제거 (Dereverberation)
- **실시간**: **WPE / NARA-WPE**(통계적 적응형, MIT) — 다채널 강점, 단채널도 가능하나 분석버퍼
  지연·이득 제한. 💡 DeepFilter가 약한 dereverb 이미 수행.
- **파일/통합**: FINALLY·AnyEnhance·Resemble가 dereverb 포함 ✅.
- **권고**: 실시간 강한 dereverb는 난제 → 보류(또는 NARA-WPE 실험). 파일은 통합 모델로 해결.

### 4. 생성형 "스튜디오급" 통합 복원 (denoise+dereverb+declip+BWE 동시)
이번 리서치의 핵심 영역. **거의 전부 파일 전용**이며 접근법이 갈린다:

| 모델 | 접근 | 통합 범위 | 스트리밍 | 속도 | 라이선스 | 판정 |
|---|---|---|---|---|---|---|
| **Resemble Enhance** ✅ | latent **flow matching**(생성형) | denoise+왜곡복원+BWE | ❌ 없음(PyTorch CLI) | RTF 미공개 | 코드 MIT 주장 **반박됨**⚠️ → 검증 | **파일 1순위 후보**(라이선스 확인) |
| **FINALLY** ✅ | **GAN**(HiFi++ +WavLM, 1-pass) | noise+reverb+BWE+mic | ❌(WavLM 미래컨텍스트) | RTF 0.03@V100 | 연구·가중치/라이선스 미확인 | **품질 최상**(MOS 4.54>Miipher), 파일·검증 |
| **AnyEnhance** ✅ | masked generative | denoise+dereverb+declip+SR+TSE | ❌ | RTF 0.254@GPU, 363.6M | 재현코드 MIT, **가중치 라이선스 없음**⚠️검증 | **레퍼런스만**(가중치 미라이선스 → 배포 불가) |
| **Miipher-2** ✅ | **feature regression**(USM+WaveFit) | 범용 복원 | ❌ | RTF **0.0078**@가속기 | Google, 공개 상용가중치 없음 | **레퍼런스**(배포 불가) |
| **NVIDIA RE-USE** | 범용 SE+BWE | 범용 | — | — | **NSCLv1 비상용** | **출시 제외**(PRD 확정) |
| **Stream.FM** ✅ | frame-causal **flow matching** | SE 중심(통합은 반박 1-2) | ✅ **32ms/48ms**(24ms SE변형) | — | 연구최전선(2025.12) | **실시간 생성형의 미래** — watch |

- **품질 vs 보존**: FINALLY는 "새 음성 생성이 아니라 정제"를 목표로 main-mode 회귀 → **화자/내용
  보존**, WER 0.18로 입력(0.23)·Miipher(0.22)보다 우수 ✅. 우리 "화자 보존" 제약에 부합.
- **권고**: **파일 HQ = Resemble Enhance 도입 PoC**(BWE+왜곡복원 한번에, 라이선스 확정 선행).
  품질 상한이 필요하면 FINALLY를 벤치 레퍼런스로. AnyEnhance/Miipher-2/RE-USE는 **상용 배포 불가/
  불확실** → 비교용. 실시간 생성형은 Stream.FM 성숙까지 보류.

### 5. 적응형 / 콘텐츠 인지 (자동 EQ·게인, 화자/언어/마이크 적응)
- **무참조 품질 예측기**를 루프에 사용: **DNSMOS**(MS), **NISQA**, **UTMOS**.
  ⚠️ **NISQA 가중치는 별도 제한 라이선스**(코드≠가중치) → **내부 평가용만, 출시 비포함**.
- 자동 게인은 이미 보유(LUFS 정규화). 자동 EQ는 스펙트럼 분석 기반 DSP로 자체 구현 가능 💡.
- **권고**: 품질 예측기는 **오프라인 튜닝/회귀 게이트**(이미 있는 `quality-eval.sh`에 DNSMOS 연동)
  로만. 실시간 적응 EQ는 경량 스펙트럼 타겟 매칭으로 점진 도입.

### 6. True-peak 리미팅 (−1 dBTP)
- **ITU-R BS.1770-4/5**: 4× 오버샘플링 후 피크 검출 = inter-sample peak 포함. ✅(ITU 원문 확보)
- 현재 우리는 **sample-peak** 근사 → **자체 구현으로 즉시 해소 가능**(오버샘플 리미터).
- **권고**: **지금 바로 자체 구현**(외부 의존 0). 한계 7개 중 **유일하게 모델 없이 해결**되는 항목.

### 7. 마스크 기반 denoiser의 fidelity 상한 (SI-SDR caps)
- 판별형은 regression-to-mean으로 상한 → **생성형(GAN/flow/diffusion)** 이 돌파. FINALLY가 GAN
  1-pass로 회귀형 Miipher 대비 MOS/WER 우위 입증 ✅.
- **평가지표**: SI-SDR 단독 금지 → **UTMOS/DNSMOS/PESQ/NISQA + WER** 병행(이미 enhance-behavior에
  명시). 💡
- **권고**: 파일 경로를 생성형으로 옮기면 자연히 해소. 평가를 perceptual+WER로 확장.

---

## 런타임 / 변환 feasibility (Apple Silicon)

| 경로 | 적합 모델 | 비고 |
|---|---|---|
| **tract(순수 Rust)** | DeepFilter류 conv/GRU | 생성형/대형 op 미지원 → 신규 생성형엔 부적합 💡 |
| **ONNX Runtime + CoreML EP** | all-conv(AP-BWE) ✅ 친화 | STFT/dynamic shape op가 변환 난관(HT-Demucs 사례) ⚠️ |
| **Core ML** | 변환되면 ANE 가속 | stateful streaming 변환 검증 필요 |
| **MLX / mlx-audio** | Apple Silicon 네이티브 오디오 | [github.com/Blaizzy/mlx-audio](https://github.com/Blaizzy/mlx-audio) — 온디바이스 후보 ⚠️ |
| **PyTorch(번들)** | Resemble/FINALLY PoC | 앱 번들 크기·cold start 큼 → 파일 beta까지만(PRD 4.4) |

- **변환 난이도**: AP-BWE(all-conv) < ClearerVoice(FRCRN) < Resemble Enhance(CFM+vocoder, 다단·반복) < diffusion.
- 실시간 후보는 **ONNX/CoreML 변환성 + causal 가능성**을 PoC 1순위 기준으로.

## 라이선스 함정 (출시 전 필수 확인)

- **코드 ≠ 가중치**: Resemble Enhance(MIT 주장 **반박** → 재확인), NISQA(가중치 제한), RE-USE(NSCLv1 비상용),
  AnyEnhance(코드 MIT지만 **가중치 무라이선스**). HuggingFace/ModelScope 모델카드 license 별도 확인.
- **비상용/배포불가 → 출시 제외**: NVIDIA RE-USE(NSCLv1) ✅확정, AnyEnhance 가중치 무라이선스 ✅확정, NISQA 가중치 ⚠️.
- **상용 가능 확인됨**: **AP-BWE 코드+가중치 MIT** ✅검증, **ClearerVoice 코드+MossFormer2_SE_48K 가중치 Apache-2.0** ✅검증,
  DeepFilter(현행 사용중) ✅.

> **검증 보강(2026-06-25)**: 세션 한도로 미검증이던 ⚠️ 항목을 1차 소스(GitHub/arxiv) 직접 확인.
> AP-BWE = MIT(코드+가중치)·CPU 18.1×RT·8/12/16/24k→48k 확정. ClearerVoice = Apache-2.0·SR 16→48k 확정.
> AnyEnhance = 재현 코드 MIT지만 공개 가중치에 라이선스 명시 없음 → 가중치 배포 불가(레퍼런스).

## 우선순위 로드맵

1. ~~**지금(자체)** — true-peak 오버샘플 리미터~~ **✅ 완료**(`TruePeak.swift`, BS.1770 4×, 파일 HQ가
   −1 dBTP 준수·테스트 통과). 평가에 DNSMOS 연동은 추가 TODO.
2. ~~**다음(검증 후 PoC)** — 파일 HQ에 **ClearerVoice-Studio**(Apache-2.0 ✅) 우선~~ **✅ 완료**:
   `ExternalEnhancer` + `scripts/clearvoice-wrapper.py` + `scripts/hq-model-poc.sh`로 DSP 대비 벤치 완료
   (12개 코퍼스 평균 SI-SDR 2.55→6.04 dB, +3.50 dB). 상세:
   [`hq-model-integration.md`](hq-model-integration.md).
   `FileTabView` UI 노출도 완료(설치 시 ClearerVoice 선택, 미설치 시 DSP fallback).
   남은 일: 사람/인식 품질 검증.
3. **다음(실시간)** — **AP-BWE**(MIT ✅, CPU 18.1×RT) causal/ONNX PoC, DeepFilter 뒤 BWE stage로.
4. **watch(보류)** — Resemble Enhance(가중치 라이선스 확인), Stream.FM(실시간 생성형),
   FINALLY(품질 상한 레퍼런스), Miipher-2/AnyEnhance/RE-USE(라이선스).

## 출처 (1차)

- Miipher-2: arxiv [2505.04457](https://arxiv.org/abs/2505.04457) · [google.github.io/df-conformer/miipher2](https://google.github.io/df-conformer/miipher2/)
- Resemble Enhance: [github.com/resemble-ai/resemble-enhance](https://github.com/resemble-ai/resemble-enhance)
- Stream.FM: arxiv [2512.19442](https://arxiv.org/abs/2512.19442)
- FINALLY: NeurIPS 2024 [proceedings](https://proceedings.neurips.cc/paper_files/paper/2024/file/01b3dea1871f7cea1e0e6be1f2f085bc-Paper-Conference.pdf)
- AnyEnhance: arxiv [2501.15417](https://arxiv.org/abs/2501.15417)
- AP-BWE: arxiv [2401.06387](https://arxiv.org/abs/2401.06387)
- ClearerVoice-Studio: [github.com/modelscope/ClearerVoice-Studio](https://github.com/modelscope/ClearerVoice-Studio)
- NVIDIA RE-USE: [huggingface.co/nvidia/RE-USE](https://huggingface.co/nvidia/RE-USE) (NSCLv1)
- ITU-R BS.1770-5 (true-peak): [itu.int](https://www.itu.int/dms_pubrec/itu-r/rec/bs/R-REC-BS.1770-5-202311-I!!PDF-E.pdf)
- 런타임: [mlx-audio](https://github.com/Blaizzy/mlx-audio) · [ONNX Runtime CoreML EP](https://onnxruntime.ai/docs/execution-providers/CoreML-ExecutionProvider.html) · DeepFilterNet ONNX export

> 검증 미완(⚠️) 항목은 세션 한도(KST 01:10 리셋) 이후 verify 재실행으로 보강 가능. 특히
> AP-BWE 속도/라이선스, ClearerVoice 라이선스, AnyEnhance 라이선스는 도입 결정 전 재확인 권장.
