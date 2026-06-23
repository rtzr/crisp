# 평가 테스트셋 (PRD 8.1)

이 디렉터리의 WAV/manifest/리포트는 **생성물**이라 git에 포함하지 않는다(재현 가능).
레포의 실제 음성·노이즈 자산에서 다운로드 없이 구성한다.

## 재생성

```sh
# 소스 자산 준비(최초 1회): poc/model/in/speech.wav, noise.wav
./scripts/fetch-deps.sh

# 테스트셋 생성 → test/corpus/*.wav + manifest.csv
BIN="$(swift build --package-path app --show-bin-path)"
"$BIN/maketestset" test/corpus
```

## 카테고리 (PRD 8.1 대응)

| 파일 | 카테고리 | 구성 |
|---|---|---|
| `clean.wav` | clean | 원본 음성(−3 dBFS 정규화). SI-SDR 기준 reference |
| `noisy_snr{0,5,10,20}.wav` | noisy | 음성 + 실제 노이즈, 목표 SNR |
| `reverb.wav` | reverb | Schroeder 잔향(RT60≈0.6s) |
| `reverb_noisy_snr5.wav` | reverb+noise | 잔향 + 노이즈 |
| `clipped.wav` | clipping | 하드 클리핑(±0.4) |
| `lowband_8k.wav` / `lowband_16k.wav` | bandlimit | 4k/8k LPF(8/16 kHz 대역) — BWE 평가용 |
| `quiet.wav` | level | −22 dB 저음량 |
| `hum_snr15.wav` | hum | 60 Hz 험 + 노이즈 |

## 자동 평가 (PRD 8.2 / 9.4)

```sh
./scripts/quality-eval.sh                 # 기본 modes: noise voice clean
./scripts/quality-eval.sh noise clean     # 특정 모드만
# → test/corpus/quality-report.csv (LUFS/peak/SI-SDR), 비정상 출력 시 exit 1
```

> SI-SDR는 모델 지연 보정(정렬) 후 측정한다. 저-SNR 입력에서 denoise 이득이 보이고,
> 고-SNR(이미 깨끗한) 입력에서는 모델/인핸서의 재구성 한계로 SI-SDR이 상한(≈6 dB)에 수렴한다.
> 단일 화자 합성 테스트셋이며, PRD 8.3의 사람 blind 청취를 대체하지 않는다.
