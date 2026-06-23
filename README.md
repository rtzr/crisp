# Crisp — macOS 실시간 노이즈 캔슬링 + 보이스 인핸서

물리 마이크 입력을 **온디바이스 AI(DeepFilterNet3)** 로 실시간 노이즈 억제하고, **DSP 보이스
인핸서**(EQ·컴프레서·디에서·리미터)로 명료도·음량을 다듬은 뒤, Zoom·Meet·Slack·Discord·Teams
등에서 선택할 수 있는 **가상 마이크("Noise Cancelled Microphone")** 로 출력. 로컬 파일 음성 개선(파일 HQ)도 지원.

**처리 모드**: Off · Noise Cancellation · Voice Enhancer · Clean + Enhance (PRD v0.2 —
[`docs/voice-enhancer.md`](docs/voice-enhancer.md)). 두 stage(denoise → enhance)는 교체 가능하며
보이스 인핸서는 생성형이 아니라 화자/발화를 보존한다.

## 빌드 & 설치 — 복사해서 실행 (또는 AI 에이전트에 붙여넣기)

```sh
# ============================================================
#  Crisp 빌드 & 설치  (macOS 13+, Apple Silicon)
#  요구: Xcode 15+ / Swift 5.9+, Rust(cargo: https://rustup.rs), ffmpeg(검증용)
# ============================================================

git clone https://github.com/rtzr/crisp.git && cd crisp
chmod +x build.sh build-app.sh scripts/*.sh poc/model/run_poc.sh

# 1) 의존성 준비 (최초 1회): DeepFilterNet 클론 + libdf.dylib/모델 vendoring.
#    tract를 컴파일하므로 수 분 소요. 이 단계가 없으면 앱 빌드가 실패한다.
./scripts/fetch-deps.sh

# 2) 빌드
./build.sh         # → build/CrispAudio.driver   (HAL 가상 마이크, universal, ad-hoc 서명)
./build-app.sh     # → build/Crisp.app           (메뉴바 앱 + 모델 번들)

# 3) 설치: 앱→/Applications, 드라이버→/Library, coreaudiod 재시작 (GUI 관리자 인증 필요)
./scripts/package.sh
open build/Crisp-0.1.0.pkg

# 4) 검증: 가상 마이크 노출 + 녹음
./scripts/verify-driver.sh

# 사용: 회의/녹음 앱의 마이크에서 "Noise Cancelled Microphone" 선택
#       메뉴바 Crisp 아이콘에서 ON/강도/바이패스/저지연 조절
#
# (개발 중 드라이버만 빠르게)   sudo ./scripts/install-driver.sh
# (제거)                        sudo ./scripts/uninstall-driver.sh
```

> 모든 처리는 **로컬**(서버 업로드 없음, 순수 Rust `tract` 추론 — 외부 런타임 불필요).
> 검증: 가상 마이크 설치/녹음, end-to-end 실시간 loopback, 30분 무중단(crash 0·dropout 0),
> 모델 RTF ≈ 0.10, DNSMOS OVRL +0.55 / BAK +1.45 — [`docs/test-report.md`](docs/test-report.md).
> 구현 현황: [`docs/STATUS.md`](docs/STATUS.md).

---

## 요구 환경

| 도구 | 용도 | 비고 |
|---|---|---|
| macOS 13+ (Apple Silicon) | 타깃 OS | universal 빌드 |
| Xcode 15+ / Swift 5.9+ | 앱·드라이버 빌드 | |
| Rust (cargo) | DeepFilterNet `libdf` 빌드 | https://rustup.rs |
| ffmpeg | **테스트 픽스처 생성·검증용만** | 제품 미포함 |

## 사용법

**실시간**: 메뉴바 Crisp → 실시간 처리 ON + 입력 마이크 선택 → 회의 앱 마이크에서 "Noise Cancelled Microphone" 선택.
**처리 모드**(Off/Noise/Voice/Clean+Enhance), 노이즈 강도, 인핸스 강도, 톤(자연/따뜻/밝게),
바이패스(A/B), 저지연 모드를 조절. 모드/강도/톤 전환은 클릭 없이 라이브 적용.

**파일**: 설정 창 → 파일 탭 → 오디오/비디오(wav/mp3/m4a/mp4/mov) 드래그앤드롭 →
처리 모드 + 품질(Fast/HQ) + 톤 + 음량 정규화(-16/-18 LUFS) 선택 → **미리듣기(20초)** 로 결과 방향 확인 후
**음성 개선 시작**. 원본은 덮어쓰지 않고 wav/m4a로 저장하며 before/after LUFS·peak 리포트를 표시.

## 검증 / 테스트

```sh
swift test --package-path app      # 단위·통합 테스트 (26개: DSP·파이프라인·LUFS·메트릭·파일 end-to-end)
./scripts/quality-eval.sh          # 테스트셋 생성+배치 처리 → quality-report.csv (회귀 게이트)
./poc/model/run_poc.sh             # 모델 RTF·노이즈 감소
./scripts/e2e-test.sh              # end-to-end: model→가상마이크→녹음 (드라이버 설치 필요)
./scripts/stability-test.sh 1800   # 30분 안정성 (crash/dropout)
BIN="$(cd app && swift build --show-bin-path)"
"$BIN/dftool"      engine/models/DeepFilterNet3_onnx.tar.gz 100 build/in.f32 out.f32 chunked  # 노이즈 stage 스트리밍 정확성
"$BIN/vetool"      engine/models/DeepFilterNet3_onnx.tar.gz                                   # 인핸서/파이프라인(결정성·리미터·RTF)
"$BIN/maketestset" test/corpus                                                               # PRD 8.1 테스트셋 생성(실제 자산 기반)
"$BIN/filetool"    enhance input.mp3 out.wav clean hq natural podcast                         # 파일 Voice Enhancer 파이프라인
```

## 프로젝트 구조

```
driver/CrispAudioDriver/   HAL Audio Server Plug-in (C) — 가상 마이크 (loopback)
app/Package.swift          SwiftPM: CDeepFilter / CrispEngine / CrispApp / dftool·filetool·mictool
  Sources/CDeepFilter/     libdf C 헤더(df.h) + modulemap
  Sources/CrispEngine/     순수 DSP/모델(AVFoundation): DeepFilterSuppressor, FileEnhancer,
                           VirtualMicOutput(AUHAL), CoreAudioDevices  ← 앱·CLI 공유
                           Voice Enhancer: AudioProcessing(모드/config/protocol), PipelineProcessor,
                           VoiceEnhancer, Biquad, Loudness · 평가: Metrics, AudioIO, TestCorpus
  Sources/CrispApp/        SwiftUI 메뉴바 앱 (AppState, AudioEngineController, Views)
  Sources/{dftool,vetool,filetool,mictool,maketestset,evaltool}/  검증·평가 CLI
  Tests/CrispEngineTests/  XCTest (swift test): DSP·파이프라인·LUFS·메트릭·파일 end-to-end
engine/CDeepFilter/lib/    libdf.dylib       (fetch-deps 생성, gitignore)
engine/models/             DeepFilterNet3 모델 (fetch-deps 생성, gitignore)
test/corpus/               평가 테스트셋 (maketestset 생성, gitignore) + README
scripts/                   fetch-deps / install / verify / package / e2e / stability / quality-eval
docs/                      architecture · voice-enhancer · STATUS · test-report · install · acceptance-checklist
poc/model/                 DeepFilterNet 클론(gitignore) + run_poc.sh
```

아키텍처: [`docs/architecture.md`](docs/architecture.md) · 사람/계정 필요 인수 항목: [`docs/acceptance-checklist.md`](docs/acceptance-checklist.md)

## 현재 상태

| Phase | 내용 | 상태 |
|---|---|---|
| 1a 가상 마이크 | HAL Audio Server Plug-in | ✅ 설치·노출·녹음 |
| 1b 모델 | DeepFilterNet3 추론 | ✅ RTF 0.10, 노이즈 ~30dB↓ |
| 2 실시간 엔진 | capture→model→가상마이크 | ✅ end-to-end loopback |
| 3 앱 | 메뉴바/온보딩/설정 | ✅ |
| 4 파일 처리 | ffmpeg-free (AVFoundation) | ✅ mp3→m4a, mp4→wav |
| VE Voice Enhancer (v0.2) | 2-stage 파이프라인 + DSP 인핸서, 4모드, 파일 HQ | ✅ vetool 검증, RTF 0.11 |
| 5 패키징 | 서명/notarization/pkg | 🔶 pkg ✅, notarize는 Apple 계정 |

---

## For LLM agents

> AI 코딩 에이전트가 안전하게 작업하기 위한 지침. 빌드/설치는 맨 위 코드블록 참조.

**Repo map (수정 위치):**
- 가상 마이크 동작 → `driver/CrispAudioDriver/CrispAudioDriver.c` (`Crisp_DoIOOperation`의 loopback ring)
- 모델 추론(노이즈 stage) → `app/Sources/CrispEngine/DeepFilterSuppressor.swift` (libdf C-API)
- 보이스 인핸서(DSP) → `app/Sources/CrispEngine/VoiceEnhancer.swift` · 필터 `Biquad.swift` · LUFS `Loudness.swift`
- 파이프라인 그래프/모드 → `app/Sources/CrispEngine/{PipelineProcessor,AudioProcessing}.swift`
- 파일 처리 → `app/Sources/CrispEngine/FileEnhancer.swift` (AVAssetReader→pipeline→AVAudioFile)
- 가상 마이크 출력 → `app/Sources/CrispEngine/VirtualMicOutput.swift` (AUHAL)
- 실시간 캡처/라우팅 → `app/Sources/CrispApp/Audio/AudioEngineController.swift`
- UI/상태 → `app/Sources/CrispApp/{Views,Model}`

**Invariants — 깨면 안 됨:**
- 장치 UID `"CrispAudioDevice:0"` 는 드라이버(`kDevice_UID`)와 Swift(`CoreAudioDevices.crispVirtualUID`)에서 동일.
- 모델은 48 kHz mono, hop 480(=10ms). 다른 레이트는 `AVAudioConverter`로 48k 변환 후 처리.
- `DeepFilterSuppressor`는 stateful 스트리밍 — hop을 연속·순서대로 공급(carry 버퍼 보장). 검증: `dftool ... chunked` 출력이 aligned와 bit-identical.
- 두 stage(denoise→enhance)는 모든 모드에서 항상 신호 경로에 존재 — 모드는 파라미터(atten·dry/wet)만 바꿈. `VoiceEnhancer`는 `wetMix==0`에서 bit-identical 패스스루여야 함(클릭 방지). 검증: `vetool` (aligned==chunked, 패스스루, 리미터).
- 실시간/파일 경로에 ffmpeg·외부 프로세스 의존 금지 (파일도 AVFoundation).
- UI 메터 갱신은 ~15Hz throttle + `MeterState` 격리 (오디오 탭 ~100Hz → 메인스레드 폭주 방지). 되돌리지 말 것.
- HAL 드라이버는 Apple Silicon에서 서명 필수(ad-hoc 가능), 팩토리 심볼 `CrispAudioDriver_Create` export 유지(`CRISP_EXPORT`).
- `libdf.dylib`는 `@rpath/libdf.dylib` install name + 앱 `Resources/lib` rpath로 로드.

**에이전트가 할 수 없는 것 (사람/계정):** 드라이버 설치(관리자 인증), Developer ID notarization(Apple 계정), GUI 회의앱 실통화·A/B blind 청취 → `docs/acceptance-checklist.md`.

## 라이선스

DeepFilterNet(libDF + 모델 weight), tract: **MIT / Apache-2.0** (상용 가능). Crisp 드라이버/앱/엔진(보이스 인핸서 DSP 포함): 자체 작성 — Voice Enhancer 추가로 **서드파티/모델 weight 변화 없음**. 상세: [`LICENSES.md`](LICENSES.md)
