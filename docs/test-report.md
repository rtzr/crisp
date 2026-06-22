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

## 미검증 (사람/계정 필요 — 자동화 불가)

- A/B blind 청취 ≥80% 개선 (PRD 8.3/8.4) — **사람 청취 필요**. 객관 proxy(DNSMOS)는 별도 측정 가능.
- GUI 회의 앱(Zoom/Meet/Teams/Slack/Discord/OBS) 실사용 — 앱 실행 + 사람 상호작용 필요.
  (가상 마이크는 시스템 장치 목록에 노출되므로 이들 앱의 입력 목록에 표시됨.)
- Developer ID 서명 + notarization 후 신규 Mac 설치 — Apple 계정 필요.
- 30분/2시간 연속 안정성 — 자동화 가능, 별도 실행(`scripts/stability-test.sh`).
