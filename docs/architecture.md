# Crisp — 아키텍처

PRD 6장(권장 기술 아키텍처)을 구현 기준으로 구체화한 문서.

## 계층 구조

```
┌─────────────────────────────────────────────────────────────┐
│  UI 앱  (SwiftUI, app/)                                       │
│   · MenuBarExtra 팝오버  · 설정창(Audio/File/Diagnostics/About)│
│   · 온보딩  · 상태/레벨 미터  · UserDefaults 영속화            │
└───────────────┬──────────────────────────┬──────────────────┘
                │                          │
   ┌────────────▼───────────┐   ┌──────────▼─────────────────┐
   │ 실시간 엔진 (Phase 2)   │   │ 파일 처리 (Phase 4)         │
   │ AVAudioEngine 캡처      │   │ AVAssetReader decode/48k    │
   │ → AVAudioConverter 48k  │   │ → DeepFilter(libdf) enhance │
   │ → DeepFilter 추론       │   │ → AVAudioFile encode wav/m4a│
   │ → ring → AUHAL 출력     │   │ (ffmpeg 불필요)             │
   └────────────┬───────────┘   └──────────┬─────────────────┘
                │                          │
        ┌───────▼──────────────────────────▼───────┐
        │  ML 추론: DeepFilterNet3 (libDF, tract)    │
        │  · 실시간+파일 공통: libdf C-API           │
        │    (DeepFilterSuppressor, df_process_frame) │
        │  · 순수 Rust 추론(tract) — 외부 런타임 불필요│
        └────────────────────────────────────────────┘
                              ▲
        ┌─────────────────────┴──────────────────────┐
        │  가상 마이크 (Phase 1a, driver/)             │
        │  HAL Audio Server Plug-in (C)                │
        │  "Noise Cancelled Microphone"                │
        │  output stream → ring buffer → input stream  │
        └──────────────────────────────────────────────┘
```

## 핵심 기술 결정 (PRD 0.3 / 6장 대비)

| 항목 | PRD 권장 | 구현 결정 | 근거 |
|---|---|---|---|
| 가상 마이크 | Audio Server Plug-in/HAL 우선 | **HAL Audio Server Plug-in (C)** | entitlement 부담 없이 로컬 설치/검증 가능, NullAudio 검증된 아키텍처 |
| 실시간 모델 | DeepFilterNet3 우선 | **DeepFilterNet3 (libDF + tract)** | PoC에서 RTF 0.13 측정(7.5× 실시간), 순수 Rust = 패키징 단순 |
| 추론 런타임 | ONNX/CoreML/Rust 중 PoC 후 | **tract (순수 Rust)** | onnxruntime 등 외부 .dylib 의존 없음 → 서명/notarization 단순 |
| 파일 처리 모델 | 실시간 모델 재사용 | **동일 libdf 모델(AVFoundation I/O)** | 코드/품질 일관성, ffmpeg 불필요 |
| 강도 조절 | 3단계 또는 slider | **Low/Med/High → atten-lim-db 12/24/100** | 모델의 `--atten-lim-db`에 직접 매핑(검증 완료) |

## 실시간 파이프라인 (PRD 6.2)

1. 물리 마이크 캡처 (AVAudioEngine inputNode, 선택 장치)
2. (Phase 2) ring buffer + 48kHz 정합
3. DeepFilter streaming 추론 — `df_process_frame` 프레임 단위, 실시간 안전(무할당)
4. (Phase 2) limiter
5. 가상 마이크 output stream에 기록 → loopback → 회의 앱이 input stream에서 읽음

### 가상 마이크 데이터 경로
앱이 처리된 오디오를 Crisp 가상 장치의 **output stream**에 쓰면, 드라이버의 ring buffer를 거쳐
**input stream**으로 loopback 되어 회의 앱이 "Noise Cancelled Microphone"으로 수신한다.
(`driver/CrispAudioDriver/CrispAudioDriver.c` 의 `Crisp_DoIOOperation`)

## Voice Enhancer 2-stage 파이프라인 (PRD v0.2)

기존 단일 denoiser를 **교체 가능한 2-stage 그래프**로 확장했다(PRD §4.1/4.5). 상세:
[`docs/voice-enhancer.md`](voice-enhancer.md).

```
입력(48k mono)
   → [Stage 1] Noise Cancellation : DeepFilterSuppressor (atten = mode별, 0 = passthrough)
   → [Stage 2] Voice Enhancer     : VoiceEnhancer (HPF→톤EQ→comp→de-ess→limiter, dry→wet 램프)
   → 출력
```

| 구성 | 파일 | 역할 |
|---|---|---|
| `ProcessingMode` / `AudioProcessingConfig` / `AudioProcessor` | `CrispEngine/AudioProcessing.swift` | 모드·설정·교체 가능 stage 인터페이스(PRD §4.5) |
| `PipelineProcessor` | `CrispEngine/PipelineProcessor.swift` | stage 그래프, 모드→파라미터 매핑, flush |
| `VoiceEnhancer` | `CrispEngine/VoiceEnhancer.swift` | DSP 인핸서(zero-latency, 생성형 아님) |
| `Biquad` / `EnvelopeFollower` | `CrispEngine/Biquad.swift` | RBJ 필터 + 엔벨로프(할당 없는 per-sample) |
| `Loudness` | `CrispEngine/Loudness.swift` | BS.1770 LUFS 측정 + 정규화 + peak 천장(파일 HQ) |

**모드는 라우팅을 바꾸지 않는다.** 두 stage 모두 항상 경로에 있고, 모드는 suppressor의
attenuation과 enhancer의 dry→wet 블렌드만 조정한다 → 모드 전환 시 샘플 불연속/클릭 없음(§8.4).
`wetMix==0`이면 enhancer 출력은 입력과 bit-identical(`vetool` 검증). 라이브 강도/톤 변경은
필터 계수만 재계산(상태 보존)하므로 역시 클릭이 없다.

## libDF C-API (Phase 2 연동 지점)

```c
DFState* df_create(const char* model_path, float atten_lim);
size_t   df_get_frame_length(DFState*);             // hop size (samples)
void     df_set_atten_lim(DFState*, float lim_db);  // = NoiseStrength
float    df_process_frame(DFState*, float* input, float* output);  // in-place per hop
void     df_free(DFState*);
```
Swift는 `DeepFilterSuppressor`(NoiseSuppressor 프로토콜 구현)에서 위 함수를 호출한다.

## 빌드 산출물

| 스크립트 | 산출물 |
|---|---|
| `./build.sh` | `build/CrispAudio.driver` (HAL 플러그인, universal, ad-hoc 서명) |
| `./build-app.sh` | `build/Crisp.app` (메뉴바 앱 + 번들된 deep-filter) |
| `poc/model/run_poc.sh` | 모델 RTF/노이즈 감소 측정 리포트 |
