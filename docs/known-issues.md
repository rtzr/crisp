# Known Issues & 남은 작업 (PRD 10 운영 / M6)

검증된 것과 아직 남은 것을 솔직하게 구분한다.

## 검증 완료 (이 저장소에서 재현 가능)

- ✅ HAL 드라이버 빌드/서명, 번들 구조, 팩토리 심볼 export
- ✅ DeepFilterNet3 추론: RTF 0.13(파일), 0.10(스트리밍), 노이즈 ~30dB 감소
- ✅ 스트리밍 프레임 처리: per-hop 0.97ms << 10ms 예산 (실시간 여유 ~10배)
- ✅ Swift FFI(libdf) — dftool 출력이 C 하니스와 bit-identical
- ✅ **스트리밍 carry 정확성** — 임의 버퍼 크기(chunked) 출력이 aligned와 bit-identical
- ✅ **입력 샘플레이트 변환** — AVAudioConverter로 임의 레이트→48kHz mono (carry로 임의 버퍼 처리)
- ✅ **저지연 모델(SET-01)** — DeepFilterNet3_ll 로드/선택, 앱 설정 + 번들
- ✅ **실시간 출력 라우팅 코드** — AUHAL 출력 유닛 → Crisp 장치 (VirtualMicOutput)
- ✅ 앱 컴파일/번들/실행(메뉴바 agent), libdf @rpath 로딩, 로그인 항목
- ✅ **파일 처리 ffmpeg-free** — AVFoundation decode/encode + libdf, mp3→m4a / mp4→wav 검증
- ✅ 설치 pkg 생성(앱 + 드라이버 + postinstall, 2개 모델 번들)

## 드라이버 설치 후 실측 (이번 세션)

- ✅ **가상 마이크 설치/노출** — pkg(admin 인증) 설치, system_profiler/avfoundation 노출, 녹음 가능
- ✅ **end-to-end 실시간** — model→VirtualMicOutput→HAL loopback→입력→recorder, 녹음 RMS −24.4dB(denoised −25.3dB 일치)
- ⏳ **30분 연속 안정성** — `scripts/stability-test.sh` 실행 중 (model+AUHAL+driver 연속, 3분 간격 dropout 체크)
- 🐛→✅ **pkg relocation 버그 수정** — 앱이 /Applications 대신 기존 번들 위치로 relocate 되던 문제.
  `BundleIsRelocatable=false` 적용(component-plist) → `<relocate/>` 비움. 앱이 /Applications로 설치됨.

## 남은 작업 (사람/계정 필요 — 자동화 불가)

- A/B blind 청취 ≥80% (PRD 8.4) — 사람 청취. 객관 proxy(DNSMOS) 별도 가능.
- GUI 회의 앱(Zoom/Meet/Teams/Slack/Discord/OBS) 실사용 — 앱 실행+사람.
- Developer ID 서명 + notarization — Apple 계정.
- (선택) limiter/AGC (PRD 6.2) — 실오디오 기준 튜닝 필요.

## 사용자/계정이 필요해 자동화 불가

- 🔶 **드라이버 설치** — `sudo` 또는 pkg 더블클릭(관리자 암호). 내가 비번 입력 불가.
- 🔶 **Developer ID 서명 + notarization** — Apple Developer 계정 필요. `scripts/package.sh` 준비됨.
- 🔶 **실제 회의 앱 호환성 / 30분 안정성 / 청취 품질 평가** — 사람 검증 필요 (PRD 8장).

## 리스크 메모 (PRD 11 대비)

- AEC/에코 제거: MVP 제외 유지 (헤드폰 권장). Phase 2+ PoC.
- 주변 사람 목소리 제거: MVP 제외 (DeepFilterNet은 일반 노이즈 억제, target speaker 아님).
- Bluetooth 마이크 latency: 별도 검수 필요.
