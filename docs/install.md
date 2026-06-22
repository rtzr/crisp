# 설치 · 삭제 · 문제 해결

## 설치 (권장: 설치 패키지)

```sh
./scripts/package.sh        # build/Crisp-0.1.0.pkg 생성
open build/Crisp-0.1.0.pkg  # 더블클릭 설치 (관리자 암호 입력)
```
패키지는 다음을 설치한다:
- `/Applications/Crisp.app` — 메뉴바 앱
- `/Library/Audio/Plug-Ins/HAL/CrispAudio.driver` — 가상 마이크
- 설치 후 `coreaudiod` 자동 재시작 (postinstall)

> 미서명 빌드는 Gatekeeper 경고가 날 수 있다. 배포용은 Developer ID 서명 + notarization 필요
> (`scripts/package.sh`의 환경변수 참고). 로컬 테스트는 우클릭 → 열기로 진행.

## 설치 (개발용: 드라이버만)

```sh
./build.sh
sudo ./scripts/install-driver.sh
./scripts/verify-driver.sh        # 장치 노출 + 녹음 검증
```

## 삭제

```sh
sudo ./scripts/uninstall-driver.sh   # 드라이버 제거 + coreaudiod 재시작
rm -rf /Applications/Crisp.app
```
패키지로 설치한 경우 드라이버 경로는 동일하므로 위 uninstall 스크립트로 제거된다.

## 검증

```sh
./scripts/verify-driver.sh
```
- system_profiler / Audio MIDI Setup 에 "Noise Cancelled Microphone" 표시
- ffmpeg avfoundation 으로 녹음되는지 확인

## 문제 해결 (PRD 7.2 / 2.2)

| 증상 | 원인 | 조치 |
|---|---|---|
| 가상 마이크가 안 보임 | coreaudiod 미재시작 / 드라이버 미서명 | `sudo killall coreaudiod`, 재설치, `log show --predicate 'subsystem=="com.apple.coreaudio"'` 확인 |
| 회의 앱에서 소리 없음 | 엔진 미작동 / 출력 라우팅 (Phase 2) | 메뉴바에서 노이즈 캔슬링 ON, 입력 마이크 선택 확인 |
| 마이크 권한 거부 | TCC 권한 | System Settings ▸ Privacy & Security ▸ Microphone 에서 Crisp 허용 |
| 앱이 실행 안 됨 (libdf) | dylib 로드 실패 | `otool -L`로 @rpath 확인, ad-hoc 빌드는 하드닝 런타임 끄기 |
| 음성이 로봇처럼 들림 | 강도 과다 | 강도를 보통/약하게로, 또는 바이패스 |

## coreaudiod 드라이버 로딩 로그 확인

```sh
log show --last 5m --predicate 'subsystem == "com.apple.coreaudio"' | grep -i crisp
sudo killall coreaudiod    # 재시작
```
