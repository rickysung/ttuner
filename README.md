# ttuner

A full-screen, glass-morphic iOS tuner & metronome built around a Metal spectrogram.
See `ttuner-design-spec.docx` for the design spec.

## 빌드 & 실행

이 저장소는 macOS의 **Xcode 15.3+** 가 필요합니다.

```bash
git clone <repo>
cd ttuner
open ttuner.xcodeproj
```

Xcode가 열리면:

1. 좌측 상단 타깃 선택기에서 `ttuner` 스킴이 선택되어 있는지 확인합니다.
2. 상단 디바이스 드롭다운에서 실기기(iOS 17.0+) 또는 시뮬레이터(iPhone 15 등)를 선택합니다.
3. `⌘R` 로 빌드 & 실행.

### 실기기 빌드 시 필요한 것

- Apple ID 로그인이 되어 있는 Xcode (`Xcode › Settings › Accounts`)
- `Signing & Capabilities` 탭에서 **Team** 을 자신의 개발 계정으로 변경
- 마이크 권한 다이얼로그 허용

### 시뮬레이터 한계

iOS 시뮬레이터는 호스트 Mac의 마이크를 사용하지만 일부 환경에서 입력이 잡히지 않을 수 있습니다.
스펙트로그램과 튜너의 실제 동작을 확인하려면 실기기 사용을 권장합니다.

## 아키텍처 한눈에 보기

```
ttuner/
├── App/              SwiftUI entry (ttunerApp, ContentView)
├── Audio/            AVAudioEngine 캡처 + lock-free ring buffer
├── DSP/              vDSP FFT, YIN pitch detector, log binning, AnalysisEngine
├── Domain/           AppState, TimelineRingBuffer, 값 타입(PitchEvent, SpectrumFrame…)
├── Metronome/        샘플 정확 스케줄링, 클릭 사운드 합성, tap tempo, haptics
├── Rendering/        Metal renderer + shader (스펙트로그램 + 박자 마커 + 피치 트레일)
├── Tuner/            노트 매핑, TunerState
├── UI/               GlassCard, TunerCard, MetronomeCard, MetronomeSheet, SettingsView
├── Settings/         AppSettings (UserDefaults persistence)
└── Resources/        Info.plist, Assets.xcassets
```

데이터 흐름 (스펙 §3.2):

```
Mic Input (AVAudioEngine)
   │  PCM Float32 / 48kHz
   ▼
AudioRingBuffer (10 s)
   ├──▶ FFTProcessor (vDSP, N=4096, hop=512)
   │       ▼
   │   TimelineRingBuffer (Spec §6.2 압축본, 최대 10분)
   │       ▼
   │   SpectrogramRenderer (r16Float 링 텍스처, Metal)
   │
   └──▶ YINPitchDetector → TunerState → SwiftUI glass overlays

MetronomeEngine (자체 스케줄러)
   ├──▶ AVAudioPlayerNode (생성된 클릭 버퍼)
   └──▶ BeatMarker queue → SpectrogramRenderer 오버레이
```

## 구현 범위

설계 문서 17주짜리 풀스펙 중 다음을 1차 컷으로 구현했습니다:

- ✅ M0 프로토타입 셸: AVAudioSession, mic capture, ring buffer
- ✅ M1 스펙트로그램: vDSP FFT, Metal 링 텍스처, 4가지 컬러맵, 글래스 카드
- ✅ M2 튜너: YIN 피치 디텍션, 노트 매핑, 트레일, Stable Note Detection
- ✅ M3 메트로놈: 샘플 정확 스케줄링, accent 패턴, tap tempo, fadeOut, 햅틱 옵션
- ✅ M4 (부분) 타임라인 링버퍼 + 스크럽 토글 (시간축 드래그 포함)
- ✅ M5 핀치 줌, Landscape 자동 전환
- ⚠️ M6 고급 메트로놈: Polyrhythm/Gradual/Subdivision은 자리만 있음 (M3 단순 모드 사용)
- ⚠️ M7 편의 기능: Auto-tune-in, Silence pause, Movement-aware pause 구현. Heatmap/Discreet mode는 부분 구현
- ✅ M8 설정 화면: 전 섹션 토글 + 영속화 (UserDefaults JSON)

해야 할 일 (Known TODOs):

- Polyrhythm 두 번째 트랙
- Intonation Heatmap GPU 패스
- Discreet mode (ALS 기반 자동 톤 다운)
- 디바이스 매트릭스 자동 성능 측정
- iPad에서의 풀스크린 트레이 슬라이드

## 권한 / 프라이버시

- **NSMicrophoneUsageDescription**: 마이크 입력은 RAM에서만 처리, 외부 전송 없음
- **NSMotionUsageDescription**: 메트로놈 자이로 자동 일시정지에 사용
- **UIBackgroundModes = audio**: 메트로놈 재생 중 백그라운드에서도 클릭 유지
- 네트워크 권한 자체를 요청하지 않습니다. 네트워킹 라이브러리도 포함되어 있지 않습니다.

## 테스트

설계 §16의 유닛/통합 테스트는 별도 타깃이 아직 구성되어 있지 않습니다. 추가 마일스톤에서:

- `FFTProcessor`: 정현파 입력 → 정확한 빈 검출 + SNR 검증
- `YINPitchDetector`: 30Hz~2kHz 합성 신호 → ±1¢ 이내
- `AudioRingBuffer`: 동시 push/pop 스트레스
- `MetronomeEngine`: fake host time 주입 후 100마디 드리프트 검증

## 빌드 트러블슈팅

- *"Could not load module 'Observation'"* → iOS Deployment Target ≥ 17.0 확인 (`PROJECT > Build Settings > iOS Deployment Target`)
- *"Permission denied: microphone"* → 시뮬레이터의 경우 Hardware › Audio Input 활성화, 실기기는 설정 앱에서 권한 재확인
- *Metal 셰이더 컴파일 에러* → `MTL_ENABLE_DEBUG_INFO = INCLUDE_SOURCE` (Debug 빌드 기본값) 또는 Xcode를 최신으로
- *시뮬레이터에서 화면이 까맣게만 보임* → 시뮬레이터는 Metal 성능 한계로 첫 프레임 출력이 늦을 수 있음. 1–2초 대기

## 라이선스

미정. 모든 외부 라이선스는 시스템 프레임워크(MIT 호환)에 의존하며 별도 third-party 의존이 없습니다.
