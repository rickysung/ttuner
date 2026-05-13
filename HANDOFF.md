# Handoff to a macOS Xcode Session

이 문서는 Linux 기반의 Claude 세션에서 작업된 ttuner 코드를 macOS Xcode 환경에서
이어 받기 위해 만들어졌습니다. 한 번 훑어보고 빌드 → 동작 확인 → 다음 작업 흐름으로
이동할 수 있도록 설계되어 있습니다.

## 1. 현재 깃 상태

- 기본 브랜치: `main`
- 작업 브랜치: `claude/update-app-name-mZg9H` (HEAD: `ebe23f6`)
- 머지된 PR
  - **#1** RESONA → ttuner 리네이밍 (머지됨)
  - **#2** iOS 앱 1차 스켈레톤 (M0–M5, M6–M8 일부) (머지됨)
- 미머지 PR
  - **#3** 잔여 마일스톤 마무리 (M6 / M7 / M9) — _현재 open / clean_

새 세션을 시작하기 전 PR #3을 **머지 또는 닫고** 시작하는 것을 권장합니다.
머지 후에는 `main`에 모든 변경이 반영되어 있으므로 작업 브랜치 없이 바로
`git checkout main`으로 시작할 수 있습니다.

```bash
git fetch origin
git checkout main
git pull --ff-only origin main
```

## 2. 첫 빌드 체크리스트 (Xcode 15.3+)

```bash
open ttuner.xcodeproj
```

1. **Team 설정**: `ttuner` 타깃 → Signing & Capabilities → Team을 본인 계정으로
2. **Bundle Identifier 변경**: 필요 시 `com.ttuner.app` 을 본인 식별자로 변경
3. **iOS Deployment Target 확인**: 17.0 (Observation 프레임워크 의존)
4. **빌드 타깃 선택**: 시뮬레이터(iPhone 15 등) 또는 실기기. 실기기 권장.
5. **⌘R**: 첫 실행 시 마이크 권한 다이얼로그 허용

### 빌드 실패 시 살펴볼 곳

| 증상 | 의심 |
| --- | --- |
| `Could not load module 'Observation'` | Deployment Target < 17.0 |
| `'@Observable' is not available` | Swift 5.9 / Xcode 15+ 필요 |
| `cannot find type 'Bindable' in scope` | iOS 17.0+ SDK 필요 |
| `MTL_FAST_MATH` 관련 경고 | 무시 가능 (Build Settings에서 NO로 변경 가능) |
| 시뮬레이터 화면 검정 | 1–2초 대기 (Metal 첫 프레임 지연) |
| 시뮬레이터에서 마이크 입력 없음 | 시뮬레이터 한계. 실기기로 전환 |
| 권한 다이얼로그가 안 뜸 | Info.plist 권한 문구 누락 — 본 저장소는 포함되어 있음 |
| `.pbxproj` 파싱 실패 / 그룹 누락 | `python3 scripts/gen_xcodeproj.py` 재실행 |

`.pbxproj`는 손으로 만들어 두지 않고 `scripts/gen_xcodeproj.py` 가 결정적 UUID로
재생성하도록 되어 있습니다. **새 파일을 추가했다면 반드시 스크립트를 다시 돌리고**
변경된 `.xcodeproj` 산출물을 함께 커밋하세요.

## 3. 동작 확인 시나리오

```
실기기 권장 (시뮬레이터는 마이크가 비어있을 수 있음)
```

1. 앱 실행 → 마이크 권한 허용 → 스펙트로그램이 흐르기 시작하는지
2. 입에서 가까이 "아—" 소리 → 튜너 카드에 노트/센트 표시되는지
3. 메트로놈 카드 ▶ → 박자 마커가 스펙트로그램 위에 흐르는지
4. 메트로놈 카드 [⇒] → MetronomeSheet 열림
   - Mode = Polyrhythm, secondary=3 → 시안 마커 트랙 추가 확인
   - Mode = Gradual, start=80 end=160 bars=8 적용 → BPM 슬라이더가 점차 증가
   - Subdivision = 2/3/4 → 박 사이 가는 마커 표시
   - Count-in = 1 → "Count-in" 배지 + 호박색 마커 1바
5. 화면 탭 → "🔒 PAUSED" 토스트, 시간축 드래그로 과거 구간 스크럽
6. 스크럽 모드에서 두 손가락 0.8초 길게 누름 → PNG + WAV 공유 시트
7. 회전 → 카드 위치가 Portrait↔Landscape에서 부드럽게 재배치
8. 어두운 환경에서 화면 밝기 0.2 이하로 낮춰 Discreet Mode 작동 확인

## 4. 테스트

`⌘U` 로 `ttunerTests` 실행:

- `FFTProcessorTests` · `YINPitchDetectorTests` · `AudioRingBufferTests`
- `NoteMapperTests` · `LogBinnerTests` · `WAVWriterTests` · `TimeSignatureTests`

총 7개 테스트 클래스. CI는 아직 구성되어 있지 않으므로 로컬에서 수동 실행합니다.

## 5. 미완 / 다음 후보 작업

스펙 §16~17 기준 잔여 항목:

| 영역 | 상태 | 비고 |
| --- | --- | --- |
| Polyrhythm + Gradual 조합 | 부분 | secondary 트랙의 동적 BPM 보정 미구현 |
| 디바이스 매트릭스 자동 측정 | 미구현 | Instruments + Xcode UI 자동화 |
| TestFlight / App Store 제출 | 미구현 | M10 |
| 커스텀 박자/폴리리듬 프리셋 라이브러리화 | 미구현 | JSON 저장 위치까지만 설정에 있음 |
| iPad 사이드 트레이 풍부화 | 미구현 | 현재는 폰 레이아웃의 회전형만 |
| 통합 테스트 (오디오 골든 시퀀스) | 미구현 | 녹음 샘플 입력 → 골든 비교 |
| Loudness Glow 사용자 톤 다운 | 부분 | 알파 강도만 조절 가능, 색상 사용자화 X |

스펙 문서(`ttuner-design-spec.docx`)는 v1.0 그대로 두고, 본 구현 상태와의 차이는
README 의 "구현 마일스톤 현황" 절과 본 문서로 트래킹합니다.

## 6. 새 세션에서 처음에 묻기 좋은 질문

다음 세션에서 어디부터 잡을지 헷갈리면 아래 중 하나를 골라 시작하면 됩니다:

- "PR #3을 머지하고 main에서 새 작업을 시작해 줘"
- "Polyrhythm + Gradual 조합의 secondary 트랙 BPM 보정 버그를 고쳐 줘"
- "통합 테스트 타깃을 만들고 녹음된 기타/보컬 샘플로 골든 비교 테스트를 추가해 줘"
- "Instruments Time Profiler 결과를 분석해 fps 드롭 원인을 찾아 줘"
- "iPad Landscape 전용 사이드 트레이 UI를 다듬어 줘"

## 7. 파일 트리 요약

```
ttuner/
├── ttuner.xcodeproj/          # 자동 생성 — scripts/gen_xcodeproj.py가 재빌드
├── ttuner/                    # 앱 소스
│   ├── App/                   # SwiftUI 엔트리 (ttunerApp, ContentView)
│   ├── Audio/                 # AVAudioEngine 캡처 / ring buffer / WAV writer
│   ├── DSP/                   # vDSP FFT / YIN / log binning / AnalysisEngine
│   ├── Domain/                # AppState / TimelineRingBuffer / IntonationHistory 등
│   ├── Metronome/             # MetronomeEngine / MetronomeMode / 클릭 합성
│   ├── Tuner/                 # NoteMapping / TunerState
│   ├── Rendering/             # SpectrogramRenderer / Shaders.metal / Colormaps / Exporter
│   ├── UI/                    # GlassCard / TunerCard / MetronomeCard / SettingsView 등
│   ├── Settings/              # AppSettings (UserDefaults JSON)
│   └── Resources/             # Info.plist / Assets.xcassets
├── ttunerTests/               # 유닛 테스트 (7 classes)
├── scripts/
│   └── gen_xcodeproj.py       # .pbxproj + scheme + workspace 생성기
├── ttuner-design-spec.docx    # 원본 설계 스펙 v1.0
├── README.md                  # 빌드/실행/구현 범위 설명
└── HANDOFF.md                 # ← 본 문서
```
