# Crisp — 구현 현황 & 작업 계획

PRD(`krisp_like_mac_prd_workplan.docx`)의 M0–M6 마일스톤을 **검증 가능한 슬라이스**로 구체화하고
각 단계의 pass/fail 근거를 기록한다.

범례: ✅ 완료·검증됨 · 🔶 구현됨, 사용자 액션 필요 · ⏳ 예정

## 진행 요약

| Phase | PRD | 내용 | 상태 | 검증 |
|---|---|---|---|---|
| 0 | WBS 1.2 | Repo & 빌드 스켈레톤 | ✅ | 새 checkout에서 `./build.sh`/`./build-app.sh` 빌드 |
| 1a | M1 / VM-* | HAL 가상 마이크 (loopback) | 🔶 | 빌드·서명·검증 완료, **설치는 sudo 필요** |
| 1b | M1 | DeepFilterNet3 추론 PoC | ✅ | **RTF 0.13**, 노이즈 ~30dB 감소 |
| 2 | M2 / RT-* | 실시간 엔진 | 🔶 | 임의 레이트/버퍼 검증, 저지연 모델, 출력 라우팅 코드 완성. end-to-end는 1a 설치 후 |
| 3 | M3 / APP-* | 앱 UI/온보딩 | ✅ | 컴파일·번들·실행, 로그인 항목, 저지연 설정 |
| 4 | M4 / FILE-* | 파일 처리 | ✅ | **ffmpeg-free**(AVFoundation+libdf), mp3→m4a, mp4→wav |
| 5 | M5 | 서명/notarization/패키징 | 🔶 | pkg 생성(앱+드라이버+2모델), **notarize는 Apple 계정 필요** |
| 6 | M6 | 문서/라이선스/리포트 | ✅ | architecture/install/LICENSES/known-issues |

## 검증된 성공 기준 (PRD 1.4 / 8장 대비)

- ✅ **실시간성** — DeepFilterNet3 RTF 0.13 (목표 RTF<1, 즉 80ms 예산 내 추론 여유 충분)
- ✅ **노이즈 감소** — 순수 노이즈 ~30dB 감소, clean speech 보존(전체 RMS 1.4dB만 변화)
- ✅ **강도 조절** — Low/Med/High → 11.6 / 21.7 / ~30dB 감소 (단조, PRD RT-04)
- ✅ **형식 지원** — wav/mp3/m4a/mp4 입력, wav/m4a 출력 (PRD FILE-01/형식지원)
- ✅ **앱 기본** — 메뉴바 상주 agent, 설정 4탭, 온보딩 3스텝, 설정 영속화 (PRD APP-01/03)
- ✅ **개인정보** — 모든 처리 로컬, 진단 로그에 음성 미포함 (PRD SET-03)

## 드라이버 설치 + 실측 완료 (이번 세션)

- ✅ 설치 패키지: 앱→/Applications, 드라이버→/Library (relocation 버그 수정 후 검증), 앱 실행 확인
- ✅ 가상 마이크 system/avfoundation 노출 + 녹음
- ✅ end-to-end 실시간: model→VirtualMicOutput→HAL loopback→입력→recorder (RMS −24.4dB)
- ✅ **30분 연속 안정성: crash 0 · dropout 0** (PASS)
- ✅ 객관 음질 DNSMOS: OVRL +0.55, BAK +1.45

## 남은 항목 — 사람/계정/GUI 앱 필요 (자동화 불가)

절차: [`docs/acceptance-checklist.md`](acceptance-checklist.md)

1. **회의 앱 실사용** (Zoom/Meet/Teams/Slack/Discord/OBS) — 앱 실행 + 사람. (가상 마이크는 목록에 노출됨)
2. **A/B blind 청취 ≥80%** — 사람 청취. 일괄 처리는 `filetool`로 가능, 판정은 사람.
3. **Developer ID 서명 + notarization** — Apple 계정. `scripts/package.sh` 환경변수로 준비됨.

## 다음 작업

- end-to-end 실시간 검증 (마이크→모델→가상마이크→회의앱) — **드라이버 설치 후 가능**
- limiter/AGC (PRD 6.2) — 선택적 음질 보호
- Developer ID 서명 + notarization (Apple 계정)
