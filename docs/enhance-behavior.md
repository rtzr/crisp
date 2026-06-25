# Voice Enhancer — 현재 동작 느낌 & 한계 요약

현재 구현된 Voice Enhancer(순수 DSP)가 **실제로 소리에 어떤 변화를 주는지**, 그리고
**무엇을 못 하는지**를 측정값과 함께 정리한 문서. 설계/구현 상세는
[`voice-enhancer.md`](voice-enhancer.md), 측정 방법은 [`test-report.md`](test-report.md).

> 한 줄 요약: 지금의 인핸서는 **"믹싱 엔지니어의 기본 채널 스트립"** 에 가깝다 —
> 저역 정리(HPF) → 톤 보정(EQ) → 음량 고르기(컴프레서) → 치찰음 제어(디에서) →
> 음량 맞추고 클립 방지(LUFS 정규화 + 리미터). **없는 정보를 만들어내지는 않는다.**

## 1. 단계별로 무엇이 들리는가

| 단계 | 처리 | 귀로 느끼는 변화 |
|---|---|---|
| High-pass 80Hz | 초저역/DC 제거 | 책상 울림·에어컨 럼블·"웅—" 저역이 사라져 **깔끔/타이트**해짐 |
| Tone EQ | 프리셋별 EQ | 톤이 **자연/따뜻/밝게** 중 하나로 살짝 기움(아래 §3) |
| Compressor | 1.5:1~3:1, makeup ≤+2dB | 큰 소리는 누르고 작은 소리는 올려 **음량이 고르게**, 또렷해짐 |
| De-esser | 5kHz 사이드체인 → 동적 high-shelf 컷 | "스/시/ㅊ" **치찰음이 덜 쏘게** |
| Limiter −1dBFS | 피크 천장 | 갑작스런 피크에도 **클리핑/찢어짐 없이** 안전 |
| (HQ만) LUFS 정규화 | −16/−18 LUFS | 파일 음량이 **방송/팟캐스트 수준으로 일정**하게 |

## 2. 모드별 느낌

- **Off** — 원본 그대로(A/B 비교용).
- **Noise Cancellation** — 기존 DeepFilter 잡음 제거만. 톤/음량 **무채색**(인핸서 미적용).
- **Voice Enhancer** — 약한 잡음 제거 + 위 DSP. "마이크 톤만 다듬는" 느낌. 조용한 방에 적합.
- **Clean + Enhance** (기본 추천) — 풀 잡음 제거 후 DSP까지. 가장 **또렷하고 다듬어진** 결과.

## 3. 강도/톤 — 실측 (clean 음성, voice/fast, 정규화 OFF로 인핸서 고유 효과만)

| 케이스 | LUFS | peak | rms | crest(피크-rms) | 저역(<500Hz) | 고역(>4kHz) |
|---|---|---|---|---|---|---|
| 원본(baseline) | −23.0 | −3.0 | −23.3 | **20.3** | −25.4 | −33.7 |
| voice/natural | −26.0 | −7.7 | −27.3 | 19.6 | −29.5 | −38.2 |
| voice/**warm** | −26.1 | −8.1 | −27.1 | **19.0** | −29.1 | **−38.6** |
| voice/**bright** | −26.0 | −7.5 | −27.3 | 19.7 | −29.5 | **−37.6** |
| clean/**hq**/podcast | −19.4 | **−1.0** | −20.7 | 19.7 | −22.9 | −31.8 |

읽는 법:
- **톤이 의도대로 작동** — warm은 고역이 가장 낮고(−38.6, 가장 어두움), bright는 가장 높다(−37.6, 가장 밝음). 차이는 **0.5~1dB로 미묘**(PRD 6.2 "기본값 보수적" 준수).
- **컴프레션은 약하게** — crest factor 20.3 → 19.0~19.7dB(약 0.6~1.3dB↓). 과하지 않음.
- **Fast 모드는 오히려 음량이 낮아진다**(−23 → −26 LUFS): 정규화가 없고 HPF+약denoise가 에너지를 덜어내기 때문. **HQ 모드는 −19 LUFS·피크 −1dBFS로 크고 일정**하게 맞춰진다. → 음량 일관성이 필요하면 **HQ + LUFS 정규화 권장**.

## 4. 한계 — 못 하는 것 (degraded 입력, HQ clean 실측)

현재 인핸서는 **DSP 후처리**라, "이미 있는 소리를 다듬을" 뿐 **손상된/없는 정보를 복원하지 못한다.**

| 한계 | 실측 근거 | 설명 |
|---|---|---|
| **대역폭 복원(BWE) 없음** | lowband_8k 고역 −45.7 → −39.9 (정규화로 +5dB 올랐을 뿐, 풀밴드 −33.7엔 한참 못 미침) | 8/16kHz로 잘린 음성의 **잃어버린 고역을 만들어내지 못함**. 먹먹함이 크게 개선되지 않음 |
| **디클리핑 없음** | clipped crest 15.4 → 18.6 (음량만 올라감) | 클리핑으로 깨진 파형을 **복원하지 못함**. 왜곡(하모닉)은 남음 |
| **잔향 제거 거의 없음** | reverb 처리 후에도 잔향 꼬리 유지 | DSP에 dereverb 없음(DeepFilter가 소폭만). 울림이 크게 줄지 않음 |
| **생성형 복원 불가** | (설계상) | 화자/발화 보존이 원칙 → 없는 디테일을 **생성하지 않음**(보이스 클로닝·합성 제외) |
| **고정 프리셋** | — | 화자·언어·마이크별 **자동 적응 없음**. 3강도×3톤 수동 선택 |
| ~~true-peak 근사~~ **(해결됨)** | TruePeak.swift | **ITU-R BS.1770 4× 오버샘플 true-peak 구현 완료** → 파일 HQ 출력이 −1 dBTP 천장 준수(검증). 실시간 리미터도 공용 |
| **High 강도 주의** | — | 강하게는 아티팩트/부자연 가능 → **기본값 아님**(보통 권장) |
| **SI-SDR 상한 ≈6dB** | test-report 참조 | 신경망 denoiser의 pristine 대비 재구성 한계(샘플지표 특성, 결함 아님) |

요점: **잡음↓·톤 보정·음량 고르기·치찰음 제어·클립 방지**는 잘 한다.
**대역 복원·디클리핑·강한 dereverb·음질 "업스케일"** 은 못 한다(원리상).

## 5. 한계를 넘으려면 (후속)

BWE/디클리핑/강한 dereverb는 **신경망 모델**의 영역이다. 파이프라인의 Voice Enhancer는
교체 가능한 `AudioProcessor` stage이므로, 후보 모델을 **같은 seam에 드롭인**하면 위 한계를
보완할 수 있다. 어떤 모델을 실시간 vs 파일에 쓸지, 라이선스·온디바이스 실현성·통합 경로를
조사한 결과는 → **[`enhance-limitations-research.md`](enhance-limitations-research.md)**.
요약: 지금 자체로 해결 가능한 건 **true-peak 리미터**뿐이고, 파일 HQ는 **Resemble Enhance/
ClearerVoice**(라이선스 검증 후), 실시간 BWE는 **AP-BWE**(MIT, CPU 고속) PoC, 실시간 생성형
복원은 **Stream.FM** 성숙까지 보류. 현재 DSP 인핸서는 그 전까지의 **무의존·저지연·화자보존**
기본값으로 동작한다.

## 재현

```sh
BIN="$(swift build --package-path app --show-bin-path)"
"$BIN/maketestset" test/corpus
# 인핸서 고유 효과(정규화 OFF):
"$BIN/filetool" enhance test/corpus/clean.wav /tmp/warm.wav voice fast warm none
"$BIN/evaltool" /tmp/warm.wav        # LUFS/peak/rms/crest/low/high 출력
# 한계(대역복원 안 됨):
"$BIN/filetool" enhance test/corpus/lowband_8k.wav /tmp/lb.wav clean hq natural podcast
"$BIN/evaltool" /tmp/lb.wav test/corpus/clean.wav
```
