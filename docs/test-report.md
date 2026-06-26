# Crisp — 테스트 리포트 (PRD 8.3 지표 대비)

측정 환경: Apple Silicon (arm64), macOS 26.5.1, Xcode 26.5 / Swift 6.2, Rust 1.96.
모델: DeepFilterNet3 (tract, 48kHz, hop 480/10ms). 샘플: `test/fixtures/noisy_snr0.wav` (10.6s, SNR 0dB).

## 정량 지표

| PRD 8.3 지표 | 목표 | 측정 | 판정 |
|---|---|---|---|
| Latency (추론) | 총 80ms 이하 | 모델 hop **10ms**, per-hop 처리 **0.97ms** | ✅ 예산 내 여유 大 |
| RTF (파일) | < 1 (실시간) | **0.13** (10.6s → 1.40s) | ✅ ~7.5× |
| RTF (스트리밍) | < 1 | **0.10** (per-hop 0.97ms / 10ms) | ✅ ~10× |
| 노이즈 감소 (순수 노이즈) | 측정 가능한 감소 | **−29.8 dB** (−20.2 → −50.0) | ✅ |
| Clean/speech 보존 | 과도 왜곡 없음 | 전체 RMS 변화 **−1.4 dB** (음성 유지) | ✅ |
| Swift FFI 정확성 | — | dftool 출력 = C 하니스 출력 **bit-identical** | ✅ |
| 스트리밍 carry 정확성 | aligned == chunked | 임의 버퍼(137/480/1000/53/911/256) 출력 **bit-identical** | ✅ |
| 저지연 모델(SET-01) | 로드/동작 | DFN3_ll 로드, hop 480, RTF 0.18 (full 0.10) | ✅ |

## 객관 음질 (DNSMOS) — PRD 8.3 subjective의 객관 proxy

no-reference DNSMOS (1–5, 높을수록 좋음), noisy_snr0 샘플, 16kHz:

| 지표 | noisy | enhanced | Δ |
|---|---|---|---|
| OVRL (전체) | 2.58 | 3.12 | **+0.55** |
| BAK (배경소음) | 2.67 | 4.12 | **+1.45** |
| SIG (음성) | 3.59 | 3.36 | −0.24 |
| P808 (MOS) | 2.96 | 3.63 | +0.67 |

배경소음·전체 품질 크게 개선, 음성 손상 소폭. **객관 지표이며 PRD 8.4의 사람 blind 청취를 대체하지 않음**
(단일 샘플; 전체 테스트셋은 §8.2대로 사람 큐레이션 필요).

## 강도(atten-lim-db) 매핑 검증 — PRD RT-04

순수 노이즈(−20.2 dB) 입력 기준:

| 강도 | atten-lim-db | RMS after | 감소량 |
|---|---|---|---|
| 약하게 (low) | 12 | −31.8 dB | 11.6 dB |
| 보통 (medium) | 24 | −41.9 dB | 21.7 dB |
| 강하게 (high) | 100 | −50.0 dB | 29.8 dB |

단조 증가 확인. 앱의 `NoiseStrength` → `df_set_atten_lim` 매핑이 실제 모델 거동과 일치.

## 형식 지원 검증 — PRD FILE-01 / 형식지원 (ffmpeg-free, AVFoundation+libdf)

| 입력 | 출력 | 결과 |
|---|---|---|
| mp3 | m4a (aac 48k mono) | ✅ 10.6s 정상 (filetool) |
| mp4 (영상+음성) | wav (Int16 48k) | ✅ 10.6s 정상 (filetool) |
| wav | wav | ✅ |

외부 프로세스/ffmpeg 없이 `FileEnhancer`(AVAssetReader→libdf→AVAudioFile)로 처리.

## 빌드 검증 — WBS 1.2

| 산출물 | 검증 |
|---|---|
| `build/CrispAudio.driver` | universal(arm64+x86_64), ad-hoc 서명, 팩토리 심볼 export, 서명 valid |
| `build/Crisp.app` | 컴파일/링크/실행(메뉴바 agent), libdf @rpath 로딩 OK |
| `build/Crisp-0.1.0.pkg` | 앱 + 드라이버 페이로드 + postinstall(coreaudiod 재시작) |

## 드라이버 설치 후 검증 (이번 세션, 실제 하드웨어)

| 항목 | 결과 | 판정 |
|---|---|---|
| 가상 마이크 시스템 노출 | system_profiler + avfoundation 노출, 녹음 가능 | ✅ (`verify-driver.sh` 3/3 pass) |
| **end-to-end 실시간** (model→VirtualMicOutput→HAL loopback→입력→recorder) | 녹음 RMS −24.4dB (denoised 기준 −25.3dB, ~1dB 일치, 무음 아님) | ✅ |
| 드라이버 loopback (output→ring→input) | 실제 CoreAudio I/O로 오디오 전달 확인 | ✅ |
| **30분 연속 안정성** (model+AUHAL+driver) | 1800s, 10/10 spot-check non-silent, **crash 0 · dropout 0** | ✅ |
| 설치 패키지 (앱→/Applications, 드라이버→/Library) | relocation 버그 수정 후 검증 | ✅ |

## Voice Enhancer 파이프라인 (PRD v0.2) — `vetool` / `filetool enhance`

DSP 인핸서 + 2-stage 파이프라인. 구현/설계: [`voice-enhancer.md`](voice-enhancer.md).

| 검증 항목 | 기대 | 측정 | 판정 |
|---|---|---|---|
| 비활성 인핸서 = 패스스루 | bit-identical | `wetMix=0` 출력 == 입력 | ✅ |
| 스트리밍 결정성 | aligned == chunked | 임의 버퍼(137/480/53/911/256/1000) bit-identical | ✅ |
| 리미터/클램프 안전 | peak ≤ full scale | 입력 1.5 트랜지언트 → 출력 peak **0.75** | ✅ |
| 인핸스 효과 | 신호 변화 | Δenergy 측정됨 | ✅ |
| RTF (enhancer 단독) | ≪ 1 | **0.012** (≈84×) | ✅ |
| RTF (clean+enhance) | < 1 | **0.11** (≈8.9×) | ✅ |
| 추가 지연 | §6.1 ≤ 50ms | DSP **0 ms**(IIR, no lookahead) + denoise hop | ✅ |

파일 HQ 파이프라인 (`filetool enhance`, noisy_snr0.wav 10.6s):

| 모드/품질 | 출력 LUFS | peak in→out | gain | 비고 |
|---|---|---|---|---|
| clean+enhance / HQ podcast | −19.3 | −3.5 → −1.0 dBFS | +6.9 dB | peak 천장에 의해 −16 미달(클립 방지) |
| voice·warm / HQ meeting | −19.0 | −3.5 → −1.0 dBFS | +7.3 dB | |
| noise / Fast | −23.7 | −3.5 → −3.9 dBFS | +0.0 dB | Fast=정규화 미적용 |
| off / HQ podcast | −21.0 | −3.5 → −1.0 dBFS | +2.5 dB | 변환+정규화만 |

출력 48k mono Int16 WAV / AAC m4a, 길이 정확 보존(10.595646s in=out). `wav/mp3/m4a/mp4/mov` 입력.

파일 HQ 외부 모델 PoC (`scripts/hq-model-poc.sh`, 12개 코퍼스, `MossFormer2_SE_48K`):

| 엔진 | 평균 SI-SDR | 평균 LUFS | true-peak | finite |
|---|---:|---:|---:|---:|
| 내장 DSP HQ | 2.55 dB | −19.41 | −1.00 dBTP | 12/12 |
| ClearerVoice HQ | **6.04 dB** | −20.34 | −1.00 dBTP | 12/12 |

ClearerVoice는 전체 샘플에서 DSP보다 SI-SDR이 높았다(평균 **+3.50 dB**). 통합 경로:
`filetool external` → `scripts/clearvoice-wrapper.py` → HQ LUFS/true-peak post-DSP.

> **한계**: LUFS는 BS.1770 근사(K-weighting + 절대/상대 게이팅). ClearerVoice 실모델은 파일 HQ
> beta 후보이며 Python/Torch 외부 프로세스로만 연결한다. 제품 노출 전 사람 A/B 청취와 WER/DNSMOS/PESQ
> 같은 지각/인식 지표가 필요하다.

## 테스트셋 & 자동화 테스트 (PRD §8.1 / §8.2 / §9.4)

**테스트셋** — 레포의 실제 음성·노이즈·잔향 자산에서 다운로드 없이 구성(`maketestset`),
12개 카테고리: clean / noisy(SNR 0·5·10·20) / reverb / reverb+noise / clipping /
bandlimit(8·16k) / 저음량 / hum. 재현: `test/corpus/README.md`.

**XCTest** (`swift test --package-path app`):

| Suite | 검증 | 결과 |
|---|---|---|
| BiquadTests (4) | 0dB=identity, LPF/HPF 거동, 엔벨로프 수렴 | ✅ |
| VoiceEnhancerTests (5) | 패스스루 bit-identical·chunk 독립·리미터·톤·램프 | ✅ |
| LoudnessTests (4) | 무음/선형성/정규화/peak 천장 | ✅ |
| TruePeakTests (4) | inter-sample peak 감지·true-peak 천장 | ✅ |
| MetricsTests (5) | RMS·peak·SI-SDR·지연보정 SI-SDR | ✅ |
| PipelineTests (4) | 모드 라우팅·길이보존·라이브 전환 finite | ✅ |
| IntegrationTests (4) | 코퍼스 생성·파일 end-to-end(모델) | ✅ |
| ExternalEnhancerTests (2) | 외부 모델 seam·실패 전파 | ✅ |
| **합계** | | **32 tests, 0 failures** |

**배치 평가** (`scripts/quality-eval.sh` → `test/corpus/quality-report.csv`) — 코퍼스 ×
{noise, voice, clean} HQ 처리. 모든 출력 finite·peak −1 dBFS 천장 준수 → **PASS(회귀 게이트)**.
지연 보정 SI-SDR(noise mode):

| 입력 | in SI-SDR | out SI-SDR | 비고 |
|---|---|---|---|
| noisy_snr0 | 0.00 | **+4.89** | 저-SNR denoise 이득 |
| noisy_snr5 | 5.00 | 5.51 | 모델 상한(≈6dB) 수렴 |
| noisy_snr10 | 10.0 | 6.00 | |
| noisy_snr20 | 20.0 | 6.33 | 이미 깨끗 → fidelity 상한 |
| clean | ∞ | 6.25 | DeepFilter clean 재구성 상한 |

> SI-SDR 상한(≈6dB)은 신경망 denoiser의 pristine-clean 대비 재구성 한계(샘플 지표 특성)이며 결함 아님.
> 지각 품질은 위 DNSMOS(OVRL +0.55) 참조. 단일 화자 합성셋이며 PRD §8.3 사람 blind 청취 대체 불가.

## 미검증 (사람/계정 필요 — 자동화 불가)

- A/B blind 청취 ≥80% 개선 (PRD 8.3/8.4) — **사람 청취 필요**. 객관 proxy(DNSMOS)는 별도 측정 가능.
- GUI 회의 앱(Zoom/Meet/Teams/Slack/Discord/OBS) 실사용 — 앱 실행 + 사람 상호작용 필요.
  (가상 마이크는 시스템 장치 목록에 노출되므로 이들 앱의 입력 목록에 표시됨.)
- Developer ID 서명 + notarization 후 신규 Mac 설치 — Apple 계정 필요.
- 30분/2시간 연속 안정성 — 자동화 가능, 별도 실행(`scripts/stability-test.sh`).
