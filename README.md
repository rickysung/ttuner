# ttuner

A full-screen, glass-morphic iOS tuner & metronome built around a Metal spectrogram.
See `ttuner-design-spec.docx` for the full design spec.

> 새로 macOS 환경에서 작업을 이어 받는다면 먼저 [`HANDOFF.md`](./HANDOFF.md) 를 읽어 주세요.
> 첫 빌드 체크리스트, 동작 확인 시나리오, 미완 작업 후보가 정리되어 있습니다.

## 빌드 & 실행

이 저장소는 macOS의 **Xcode 15.3+** 가 필요합니다.

```bash
git clone <repo>
cd ttuner
open ttuner.xcodeproj
```

Xcode에서:

1. 좌측 상단 타깃 선택기에서 `ttuner` 스킴이 선택되어 있는지 확인합니다.
2. 디바이스 드롭다운에서 실기기(iOS 17.0+) 또는 시뮬레이터(iPhone 15 등) 선택.
3. `⌘R` 빌드 & 실행. 테스트는 `⌘U`.

### 실기기 빌드 체크리스트

- Apple ID 로그인 (`Xcode › Settings › Accounts`)
- `Signing & Capabilities` 탭에서 **Team** 을 자신의 개발 계정으로 변경
- 마이크 권한 다이얼로그 허용

### 시뮬레이터 한계

시뮬레이터는 호스트 Mac의 마이크를 쓸 수 있으나 환경에 따라 입력이 잡히지 않거나
Metal 첫 프레임 출력이 늦을 수 있습니다. 실기기 사용을 권장합니다.

## 아키텍처 한눈에 보기

```
ttuner/
├── App/              SwiftUI entry (ttunerApp, ContentView)
├── Audio/            AVAudioEngine 캡처, lock-경량 ring buffer, WAV writer
├── DSP/              vDSP FFT, YIN, log binning, AnalysisEngine
├── Domain/           AppState, TimelineRingBuffer, IntonationHistory, 값 타입
├── Metronome/        샘플 정확 스케줄링 (simple/polyrhythm/gradual),
│                    count-in, subdivision, click 합성, tap tempo, haptics
├── Rendering/        Metal renderer + shader (스펙트로그램 / 박자 마커 /
│                    피치 트레일 / Intonation Heatmap), Exporter
├── Tuner/            노트 매핑, TunerState
├── UI/               GlassCard, TunerCard, MetronomeCard, MetronomeSheet,
│                    SettingsView, LoudnessGlowOverlay
├── Settings/         AppSettings + UserDefaults 영속화
└── Resources/        Info.plist, Assets.xcassets
ttunerTests/          유닛 테스트 (FFT, YIN, ring buffer, NoteMapper, …)
```

데이터 흐름 (스펙 §3.2):

```
Mic Input (AVAudioEngine)
   │  PCM Float32 / 48kHz
   ▼
AudioRingBuffer (10 s)
   ├──▶ FFTProcessor (vDSP, N=4096, hop=512)
   │       ▼
   │   TimelineRingBuffer (압축, 최대 10분)
   │       ▼
   │   SpectrogramRenderer (Metal 링 텍스처)
   │       ▼
   │   ▶ 스펙트로그램 패스
   │   ▶ 박자 마커 패스 (primary / secondary / subdivision / count-in)
   │   ▶ 피치 트레일 패스
   │   ▶ Intonation Heatmap 패스 (scrub 모드)
   │
   └──▶ YINPitchDetector → TunerState → SwiftUI glass overlays

MetronomeEngine (자체 스케줄러)
   ├──▶ AVAudioPlayerNode (생성된 클릭 버퍼)
   └──▶ BeatMarker queue → SpectrogramRenderer 오버레이
```

## 구현 마일스톤 현황

설계 문서 17주 풀스펙 기준의 진행 상태:

- ✅ M0 프로토타입 셸: AVAudioSession, mic capture, ring buffer
- ✅ M1 스펙트로그램: vDSP FFT, Metal 링 텍스처, 4가지 컬러맵, 글래스 카드
- ✅ M2 튜너: YIN 피치 디텍션, 노트 매핑, 트레일, Stable Note Detection
- ✅ M3 메트로놈 v1: 샘플 정확 스케줄링, accent 패턴, tap tempo, fadeOut, 햅틱
- ✅ M4 타임라인 링버퍼 + 스크럽 (시간축 드래그 포함) + Auto Export (PNG + WAV)
- ✅ M5 핀치 줌, Landscape 자동 전환
- ✅ M6 고급 메트로놈: **Polyrhythm**(흰색 / 시안 마커 트랙), **Gradual Tempo**,
       **Subdivision Visualization**, **Anacrusis Count-in**, Tap Tempo
- ✅ M7 편의 기능: Auto-tune-in, Silence pause, Movement-aware pause,
       **Intonation Heatmap GPU 패스**, **Loudness Glow**, **Discreet Mode** (밝기 자동)
- ✅ M8 설정 화면: 전 섹션 토글 + 영속화 (UserDefaults JSON)
- ✅ M9 (초기) 유닛 테스트 타깃: `ttunerTests` (FFT, YIN, ring buffer, NoteMapper,
       LogBinner, WAVWriter, TimeSignature)
- ⚠️ M10 베타/릴리즈: TestFlight·App Store 단계는 미수행

추후 보강 후보:

- 매트릭스 디바이스 자동 성능 측정 (Instruments 자동화)
- 폴리리듬 + Gradual 조합 시 secondary 트랙의 동적 BPM 보정
- 커스텀 박자/폴리리듬 프리셋 라이브러리화
- iPad에서의 사이드 트레이 슬라이드 인터랙션 다듬기

## 권한 / 프라이버시

- **NSMicrophoneUsageDescription**: 마이크 입력은 RAM에서만 처리, 외부 전송 없음
- **NSMotionUsageDescription**: 메트로놈 자이로 자동 일시정지에 사용
- **UIBackgroundModes = audio**: 메트로놈 재생 중 백그라운드에서도 클릭 유지
- 네트워크 권한 자체를 요청하지 않습니다. 네트워킹 라이브러리도 포함되어 있지 않습니다.

## 새 기능 사용 가이드

- **Polyrhythm**: 메트로놈 시트 → Mode = `Polyrhythm` → secondary beats 설정. Primary는
  흰색, secondary는 시안색 라인으로 스펙트로그램 위에 그려집니다.
- **Gradual Tempo**: Mode = `Gradual` → start/end BPM과 bar 수를 지정하고 `적용` 탭.
  재생 후 박이 진행됨에 따라 BPM이 선형으로 증감합니다.
- **Subdivision**: 메트로놈 시트 → Subdivision = 2/3/4. 박 사이에 가는 마커가
  시각화되며, `Subdivision 소리도 같이` 토글로 오디오 동기화 가능.
- **Count-in**: 메트로놈 시트 → Count-in bar = 1~4. 시작 직후 N마디 동안 호박색
  마커로 카운트인이 진행되고, 화면 상단에 "Count-in" 배지가 노출됩니다.
- **Auto Export**: 스크럽 모드에서 화면을 **두 손가락(0.8초 길게 누름)** → 현재 보이는
  스펙트로그램 PNG + 최근 10초 WAV 가 임시 디렉터리에 저장되고 공유 시트가 열립니다.
- **Intonation Heatmap**: 설정에서 켠 후 (기본 ON) 스크럽 모드 진입 시 화면 가장자리
  6% 영역에 |cents| 값이 녹/호박/적 색띠로 표시됩니다.
- **Loudness Glow**: 입력 RMS가 너무 작으면 노란 글로우, 너무 크면 적색 글로우가
  화면 가장자리에 잠시 떠오릅니다. 기본 OFF.
- **Discreet Mode**: 자동 모드(기본 ON) — 환경 밝기가 0.25 미만이면 글래스 카드와
  스펙트로그램이 자연스럽게 어두워집니다.

## 테스트

`⌘U` 로 `ttunerTests` 타깃을 실행하면 다음 유닛 테스트가 돌아갑니다:

- `FFTProcessorTests`: 사인 입력 → 정확한 피크 bin, 0 입력 → 스푸리어스 없음
- `YINPitchDetectorTests`: 30Hz~2kHz 합성 사인 → ±10¢, 무음 → nil 반환
- `AudioRingBufferTests`: 순차 push/pop, overflow 시 최신 유지, peek 비소비
- `NoteMapperTests`: 440 / 442 / transpose -2 / Flat 표기
- `LogBinnerTests`: 단조성, max pooling
- `WAVWriterTests`: 헤더 라운드트립
- `TimeSignatureTests`: 4/4, 3/4, 6/8 기본 강세 패턴

## 프로젝트 파일 재생성

`ttuner.xcodeproj/project.pbxproj` 는 손으로 두지 않고 결정적 UUID로 생성합니다.
새 소스 파일을 추가했다면 다음을 실행하고 산출물을 함께 커밋하세요:

```bash
python3 scripts/gen_xcodeproj.py
```

스크립트는 `ttuner/`와 `ttunerTests/` 디렉터리를 스캔하여 `.swift`와 `.metal`
파일을 자동으로 발견합니다.

## 빌드 트러블슈팅

- *"Could not load module 'Observation'"* → iOS Deployment Target ≥ 17.0 확인
- *"Permission denied: microphone"* → 시뮬레이터 Hardware › Audio Input 활성화,
   실기기는 설정 앱에서 마이크 권한 재확인
- *Metal 셰이더 컴파일 에러* → `MTL_ENABLE_DEBUG_INFO = INCLUDE_SOURCE` 확인,
   Xcode 최신 권장
- *시뮬레이터 화면 까맣게만 보임* → 1~2초 대기 (시뮬레이터 Metal 첫 프레임 지연)

## 라이선스

미정. 외부 의존 없음 (모두 시스템 프레임워크).
