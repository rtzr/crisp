# 오픈소스 라이선스 고지 (PRD 10 / 13 — 상용 사용 가능성 메모)

Crisp가 사용하는 서드파티 구성요소와 상용 배포 가능 여부.

| 구성요소 | 용도 | 라이선스 | 상용 배포 |
|---|---|---|---|
| **DeepFilterNet** (libDF + DeepFilterNet3 모델 weight) | 노이즈 억제 모델 (실시간·파일) | MIT / Apache-2.0 (dual) | ✅ 가능 |
| **tract** (tract-onnx/core/pulse) | 순수 Rust ONNX 추론 엔진 | MIT / Apache-2.0 (dual) | ✅ 가능 |
| Crisp HAL 드라이버 코드 | 가상 마이크 | 자체 작성(원본). Apple Audio Server Plug-in 아키텍처 참고 | ✅ 자체 저작 |
| Crisp 앱/엔진 코드 | UI, 실시간/파일 처리 | 자체 작성 | ✅ 자체 저작 |
| Crisp Voice Enhancer DSP | EQ/컴프레서/디에서/리미터/LUFS (PRD v0.2) | 자체 작성(RBJ EQ cookbook·ITU-R BS.1770 공개 공식 기반, 코드 원본) | ✅ 자체 저작 |
| ClearerVoice-Studio `clearvoice` + MossFormer2_SE_48K | 선택적 파일 HQ 외부 모델(Python/Torch 프로세스) | Apache-2.0(코드·가중치 README 확인) | ✅ 가능, **제품 번들 아님** |

> **Voice Enhancer(PRD v0.2)는 신규 서드파티·모델 weight를 추가하지 않는다.** 인핸서를 생성형
> 모델 대신 순수 DSP(자체 코드)로 구현했기 때문이다. ClearerVoice는 설치된 외부 명령이 있을 때만
> out-of-process 파일 HQ 옵션으로 연결하며 앱/패키지에 Python·Torch·가중치를 번들하지 않는다. PRD가 후보로 든
> LocalVQE(Apache-2.0), Resemble Enhance(MIT)는 추후 동일 `AudioProcessor` seam에 드롭인할
> 수 있으나, 그 가중치·코드 라이선스는 **탑재 시점에 별도 BOM 확인 필요**(PRD §7.2, §9 M1).
> NVIDIA RE-USE 등 비상용 모델은 출시 빌드 제외 원칙 유지.

> **ffmpeg 의존 제거됨.** 파일 처리(Phase 4)는 AVFoundation(시스템 프레임워크) + libDF로 구현해
> 외부 프로세스/ffmpeg 없이 동작한다. ffmpeg는 테스트 픽스처 생성에만 쓰이며 제품에 포함되지 않는다.
> → 배포 시 LGPL/GPL 검토 대상 없음.

## DeepFilterNet
> Copyright (c) 2021 Hendrik Schröter — MIT / Apache-2.0 dual license.
> "All code in this repository is dual-licensed" — 저장소에 포함된 **모델 weight 포함** 상용 사용 가능.
전문: `poc/model/DeepFilterNet/LICENSE-MIT`, `LICENSE-APACHE`.

## tract
Sonos 의 순수 Rust 추론 엔진. MIT / Apache-2.0. onnxruntime 등 외부 런타임 의존 없음 →
서명/notarization 단순화.

## 파일 처리 — ffmpeg 대신 AVFoundation
`CrispEngine/FileEnhancer.swift`가 AVAssetReader(디코드+리샘플+다운믹스)와 AVAudioFile(인코드)로
wav/mp3/m4a/mp4 입력을 처리한다. 노이즈 억제는 실시간과 동일한 libDF 모델을 직접 호출한다.
ffmpeg/외부 바이너리 의존이 없어 배포 라이선스 제약이 없다.

## 빌드 시 라이선스 파일 동봉
배포 패키지에는 위 LICENSE 전문을 `Crisp.app/Contents/Resources/licenses/` 에 포함할 것
(Phase 5 패키징 시 추가 예정).
