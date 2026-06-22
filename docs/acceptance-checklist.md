# PRD §8 인수 체크리스트 (사람 검증 항목)

자동 검증은 `docs/test-report.md`에 정리됨. 이 문서는 **사람·계정·GUI 앱이 필요해 자동화할 수 없는**
항목의 실행 절차다. 각 항목은 PRD 8장/16장 기준.

## 사전 준비
```sh
./scripts/package.sh
open build/Crisp-0.1.0.pkg        # 앱(/Applications) + 드라이버(/Library) 설치, 관리자 암호
open -a /Applications/Crisp.app   # 메뉴바 아이콘 확인
```

## A. 회의/녹음 앱 호환성 (PRD 8.1 / 8.4 — 필수 5/7, Zoom·Chrome Meet·QuickTime 필수)

각 앱의 마이크 입력에서 "Noise Cancelled Microphone" 선택 후 통화/녹음:

| 앱 | 입력 목록 노출 | 음성 전달 | 결과 |
|---|---|---|---|
| Zoom | □ | □ | □ Pass □ Fail |
| Google Meet (Chrome) | □ | □ | □ Pass □ Fail |
| QuickTime Player | □ | □ | □ Pass □ Fail |
| Slack | □ | □ | □ Pass □ Fail |
| Discord | □ | □ | □ Pass □ Fail |
| Microsoft Teams | □ | □ | □ Pass □ Fail |
| OBS | □ | □ | □ Pass □ Fail |

> 가상 마이크는 시스템 오디오 장치 목록에 등록되므로 위 앱들의 입력 선택기에 자동 노출됨(검증됨).
> 실제 통화 품질/노출은 각 앱 실행 + 사람 확인 필요.

## B. A/B blind 청취 품질 (PRD 8.2 / 8.3 — 80% 이상 개선 판정)

테스트셋(PRD 8.2의 6개 카테고리, 각 3개 이상) 준비 후, 각 샘플을 파일 탭으로 처리하고
원본/개선본을 blind 비교:

```
# 또는 CLI로 일괄 처리
for f in testset/*.wav; do
  "$(cd app && swift build --show-bin-path)/filetool" "$f" "out/$(basename "$f")" wav
done
```

| 카테고리 | 샘플수 | 개선 판정 | 합격(8.2 기준) |
|---|---|---|---|
| Stationary (팬/에어컨) | | /3 | noise floor 감소 |
| Transient (키보드/클릭) | | /3 | 음성 손상 없이 억제 |
| Outdoor/traffic | | /3 | 말소리 이해도 유지 |
| Cafe/office | | /3 | 3명 중 2명 개선 |
| Interfering speech | | /3 | 시도(완전제거 불요) |
| Clean speech | | /3 | 왜곡 최소 |

전체 80% 이상 개선 → Pass. (청취자 ≥3명 권장)

## C. 안정성 (PRD 8.3 — 30분/2시간 무크래시·무dropout)

```sh
./scripts/stability-test.sh 1800    # 30분 (자동, dropout/crash 체크)
./scripts/stability-test.sh 7200    # 2시간
```
실제 회의 시나리오 안정성은 B의 앱들로 30분 연속 통화 3회(PRD 8.4) 병행 권장.

## D. 배포 (PRD 8.4 / 16 — 서명·notarization·신규 Mac 설치)

```sh
export DEVELOPER_ID_APP="Developer ID Application: NAME (TEAMID)"
export DEVELOPER_ID_INSTALLER="Developer ID Installer: NAME (TEAMID)"
export NOTARY_PROFILE="<notarytool 프로필>"
./scripts/package.sh                # 서명 + notarize + staple
```
□ Gatekeeper 경고 없이 신규 Mac에서 설치/실행  □ 삭제 후 잔여 가상 장치 없음
