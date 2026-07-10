# Windows 포팅 작업 계획서

> 상태: 확정 (2026-07-10) · **진행: Phase 0–5 완료 (2026-07-11)**.
> v2.0.0 릴리즈됨(zip+Setup.exe+dmg, CI 자동화). Phase 5 = 5a 로직 Core화(7461376) + 5b 배틀/아이템 렌더링(d16c4b5) + 5c 패널·프롬프트 UI(2f1c352), 전부 CI 그린.
> 남은 것: Phase 6 — 수동 QA 체크리스트(§3 W18-③), 시드 픽스처 macOS↔Windows 패리티(W18-②), 가상 데스크톱 폴백, 키우기 포함 v2.1.0 릴리즈. Mac 시각 스팟체크(--dump-effect/--dump-evolution) 잔여.
> 목표: **Windows에서도 macOS 버전(v1.8.0)과 최대한 똑같이 동작하는 릴리즈**.
> 스택(Swift on Windows)·단계적 출시·무서명 배포는 사용자 확정. 설계 결정 W1~W20은 권고안 채택 — 구현 중 문제가 드러나면 해당 항목만 재검토한다.

## 0. 한 줄 요약 / 범위

이 작업은 **UI 계층 전면 재작성 + 게임 코어 재사용**이다. 전체 약 9,179줄 중 순수 Foundation 코어(BattleEngine·GameData·PartyState·MoveMechanics·BattleLog·Characters ≈ 2,912줄)는 그대로 가져가고, AppKit 의존 ≈ 6,267줄 중 로직(CharacterController 조향 물리, BattleController 재생 상태머신, Items 카탈로그, WildMon 배회)은 얇은 추상화로 추출, 순수 UI(SpriteView, SettingsWindow, RaisingPanel 등)는 Win32로 재작성한다.

1차 Windows 릴리즈 범위 = **마우스 따라다니기 + 트레이 메뉴 + 설정 창 + 다국어 + 자동시작 + 자체 업데이터**. 키우기 모드는 후속 릴리즈(Phase 5).

---

## 1. 확정 사항 (재론 금지)

| # | 결정 | 내용 |
|---|---|---|
| C1 | 기술 스택 | **Swift on Windows** (swift.org 툴체인 + WinSDK). 단일 저장소, 파일 단위 플랫폼 분리 + 최소한의 `#if os(Windows)` |
| C2 | 출시 전략 | 1차 = follower+트레이+설정+다국어. 키우기 모드는 후속 Phase |
| C3 | 배포 | 코드 서명 없음. SmartScreen 우회 안내를 릴리즈 노트에 포함 (macOS Gatekeeper 안내 `release.sh:115-123`과 동일 패턴) |

선택 근거(C1): "맥과 최대한 똑같은 동작"이 목표일 때 가장 큰 패리티 리스크는 77KB 배틀 엔진을 포함한 게임 로직의 미묘한 어긋남이다. 게임 코어 6개 파일이 이미 Foundation-only라 Windows용 Swift로 무수정 컴파일이 가능하므로, 로직 이식을 아예 하지 않는 것이 최선의 패리티 전략이다.

---

## 2. 현황 감사 — 코드/메커니즘 인벤토리

### 2.1 이식성 등급 (import 전수조사 + 실측)

| 등급 | 파일 | 근거 |
|---|---|---|
| **A. 그대로 재사용** (import Foundation만) | `Sources/Characters.swift`(99줄), `RaisingMode/GameData.swift`(258), `PartyState.swift`(586), `BattleEngine.swift`(1475), `MoveMechanics.swift`(268), `BattleLog.swift`(226) | 단 `GameData.swift:222`, `BattleEngine.swift:27`, `Characters.swift:58`이 `Bundle.main` 리소스 조회, `Characters.swift:95`가 `AppSettings` 참조 → 얇은 래퍼 필요. **Phase 0에서 발견**: `PartyState.swift:231,243,430,439,459`가 `BattleController.current`(AppKit 파일)를 직접 참조(전투 중 회수/아이템 게이팅) → Phase 1에서 프로토콜 시임(`LiveBattleBridge`) 필요 |
| **B. 로직 추출** (AppKit 표피만 제거) | `CharacterController.swift`(300) — 조향 물리·수면·8방향 로우 선택은 순수 수학, AppKit 의존은 `CGImage` 프레임 저장뿐(:20-26). `WildMon.swift`(157) — 동일 구조. `BattleController.swift`(1014) — 재생 상태머신은 중립, 의존은 `NSColor` 태그 색(:426-501)·`NSScreen` 경계(:988-1002)·`BattleScene`의 `CGImage/CGColor`. `Items.swift`(268) — 카탈로그/스폰 로직 중립, 의존은 CGContext 아이콘 드로잉(:97-181)·`NSScreen` union. `Sprite.swift`(163) — 슬라이싱/마커 분석이 이미 바이트 버퍼 기반(:64-133), ImageIO 디코딩(:9-14)만 종속 |
| **C. 플랫폼별 재작성** | `main.swift`, `AppDelegate.swift`(428), `SpriteView.swift`(330, CALayer), `SettingsWindow.swift`(363), `CharacterPreviewView.swift`(98), `UIStyle.swift`, `Updater.swift`(262, DMG/hdiutil), `AppCore.swift`(128, UserDefaults+SMAppService), `RaisingPanel.swift`(950), `PromptCenter.swift`(168), `EvolutionAnimator.swift`(171), `EffectPlayer.swift`(401), `TypeStyle.swift`, `Selftests.swift`(682 — 헤드리스 부분 :183-330은 A등급 코드만 사용) |

### 2.2 macOS 메커니즘 → Windows 대응표

| macOS (근거) | Windows 대응 | 결정 |
|---|---|---|
| 스크린마다 borderless 투명 클릭통과 NSWindow, overlayWindow 레벨, canJoinAllSpaces/fullScreenAuxiliary (`AppDelegate.swift:67-91`) | `WS_EX_LAYERED\|WS_EX_TRANSPARENT\|WS_EX_TOOLWINDOW\|WS_EX_NOACTIVATE` + `HWND_TOPMOST` | W2, W3 |
| NSStatusItem + SF Symbol pawprint (`AppDelegate.swift:106-136`) | `Shell_NotifyIcon`(v4) + `TrackPopupMenuEx` + .ico | W7 |
| 60fps `Timer` + `NSEvent.mouseLocation` 폴링 (`AppDelegate.swift:171-184`) | 고해상도 waitable timer 루프 + `GetCursorPos` | W5, W6 |
| `NSScreen.screens` + `didChangeScreenParametersNotification` | `EnumDisplayMonitors` + `WM_DISPLAYCHANGE`/`WM_DPICHANGED` | W4 |
| 전역 좌표 y-up, 하단좌측 원점 (`CharacterController.swift:39`, `SpriteView.swift:8-10`) | 가상 스크린 y-down·음수 좌표 → 어댑터에서 flip | W4 |
| UserDefaults 설정 (`AppCore.swift:41-128`) | `%LOCALAPPDATA%\PokemonMouseFollower\settings.json` | W9 |
| `~/Library/Application Support/PokemonMouseFollower/raising.json` (`PartyState.swift:556-577`) | `.applicationSupportDirectory`→`%LOCALAPPDATA%` 매핑 — **Phase 0에서 무수정 동작 확인** | — |
| SMAppService 자동시작 (`AppCore.swift:12-29`) | `HKCU\...\CurrentVersion\Run` 키 | W11 |
| NSLocalizedString + 3개 .lproj (en 156키) | 커스텀 .strings 파서 (Core 공용) | W10 |
| DMG 자체 업데이터: 분리 셸 스크립트가 종료 대기 후 번들 교체 (`Updater.swift:103-139`) | Setup.exe 다운로드 후 사일런트 실행 | W14 |
| 60fps 렌더: CALayer.contents=CGImage, nearest 확대 (`SpriteView.swift:47-49,282-329`) | UpdateLayeredWindow premultiplied BGRA DIB 블릿 | W3 |

### 2.3 리소스

- `animations/` 41MB (251마리 PNG 시트 + AnimData.xml) — 플랫폼 중립, 그대로 사용
- `gamedata/` 800KB (JSON 4종) — 플랫폼 중립, 그대로 사용
- `Localizable/{en,ko,ja}.lproj/Localizable.strings` — W10 채택 시 `locale/{en,ko,ja}.strings`로 배치 단순화
- `icon/AppIcon.icns` → `.ico` 변환 필요 (앱 아이콘 + 트레이 16·20·24·32px)
- `icon/backpack.svg` (키우기 패널용) → Phase 5에서 사전 렌더 PNG로 대체
- `Info.plist`가 버전의 단일 출처(`release.sh:24`) → 공용 버전 상수로 이전 (W16)

---

## 3. 설계 결정 트리 (W1~W20)

### 코드 재구성

- **W1. 디렉토리 구조 / 빌드 단위** — 채택: **디렉토리 3분할 + 플랫폼별 swiftc 파일 목록**. `Sources/Core`(+`Core/Raising`), `Sources/macOS`, `Sources/Windows`. build.sh/build.ps1이 `Core + <platform>` 소스를 컴파일(현 `build.sh:13-14` 방식 유지). 단일 모듈이라 typealias 트릭이 그대로 작동.
  - 기각: SwiftPM 멀티 타깃(리소스 번들링·앱 패키징은 어차피 수동인데 Windows SwiftPM 리스크만 추가), `#if os()`만으로 한 디렉토리 유지(대형 UI 파일에서 지저분).
- **W2. 이미지/프레임 추상화** — 채택: **2층 구조**. ① 디코딩·분석은 Core 소유 `RGBABuffer`(w·h·[UInt8])로 통일 — `Sprite.swift`의 shadowMarker/opaqueBBox(:64-133)는 이미 버퍼 연산이라 자연스러운 이관. ② 렌더 핸들은 `typealias PMFImage`(macOS=`CGImage`, Windows=premultiplied DIB 래퍼) — `Core/Platform.swift` 한 파일에서만 `#if os()` 분기. CharacterController/WildMon/BattleScene은 `PMFImage`만 보유.
  - 주의: `CGVector`(`CharacterController.swift:40`)는 corelibs-foundation 미제공 가능성 — Phase 0 확인, 미제공 시 Core에 `Vec2` 정의. `CGPoint/CGRect/CGFloat`는 제공됨.
- **W3. Windows 오버레이 렌더링 백엔드** ⭐ — 채택: **UpdateLayeredWindow + GDI DIB, "엔티티당 소형 창"**. 스프라이트 특성(수십 px 픽셀아트, nearest 1~5배, 프레임 교체 6~14틱 주기)상 GPU 불필요. 창 크기 = 스프라이트 렌더 크기(±그림자), 이동은 `SetWindowPos`, 프레임 갱신만 ULW. COM/Direct2D 바인딩(Swift에서 가장 비싼 부분)을 통째로 회피. 창이 가상 스크린 좌표로 움직이므로 **멀티모니터 걸침이 공짜**(macOS의 스크린당 창+클리핑 트릭 자체가 불필요해짐).
  - 기각: Direct2D+DirectComposition 풀스크린 1창(기술적으로 우월하나 Swift COM 호출 비용, 1차 범위에 과함 — 단 `Renderer` 시임을 유지해 후일 교체 가능), ULW 풀 가상스크린 1창(4K 프레임당 ~33MB 업로드 낭비).
  - 키우기 모드 대비: 렌더 소비자를 `OverlaySprite` 핸들 단위로 설계 — 배틀 시 야생·이펙트·볼이 각각 창 하나. HP바·플로팅 텍스트·배틀 로그는 GDI `DrawTextW`로 DIB에 직접 그림.
- **W4. 좌표계 / DPI** — 채택: **Core 월드 좌표 = 현행 y-up 전역 좌표 유지**, Windows 어댑터에서만 flip(`worldY = virtualBottom - nativeY`). CharacterController(:171 커서 아래 배치)·octant 매핑·그림자 y-up 오프셋(`Sprite.swift:125`)이 전부 y-up 가정이라 Core 무수정이 최선. `ScreenAdapter` 프로토콜: `cursorWorld()`, `screensWorld`, `world↔native`.
  - DPI: **Per-Monitor V2 매니페스트 + 전 좌표 물리 픽셀**. PMv2 프로세스에선 GetCursorPos/모니터 좌표가 물리 픽셀로 일관 → 변환 없음. 스프라이트 크기는 기존 scale 슬라이더가 흡수. 창 UI(설정창)만 `GetDpiForWindow` 스케일링.
- **W5. 틱 루프** — 채택: 메인 스레드 `MsgWaitForMultipleObjectsEx` + **고해상도 waitable timer**(`CreateWaitableTimerExW(…HIGH_RESOLUTION)`, Win10 1803+) 16.67ms 주기 — 메시지 펌프와 게임 틱이 한 스레드(현 RunLoop 타이머 구조와 등가, `AppDelegate.swift:171-178`).
  - 기각: `SetTimer`(15.6ms 양자화·지터로 애니메이션 끊김).
- **W6. 마우스 추적** — 채택: `GetCursorPos` 60Hz 폴링(현행 `NSEvent.mouseLocation` 폴링과 동일 주기). 훅 불필요.
- **W7. 트레이** — 채택: `Shell_NotifyIconW`(NOTIFYICON_VERSION_4) + `WM_CONTEXTMENU`→`CreatePopupMenu`/`TrackPopupMenuEx`. 항목 = 현행 메뉴(`AppDelegate.swift:117-135`) 미러(설정/일시정지/버전/업데이트 확인/종료 + PMF_DEV 디버그 서브메뉴). 트레이 아이콘은 `icon-1024.png`에서 .ico 생성(SF Symbol pawprint 대체).
- **W8. 설정 창** — 채택: **프로그래매틱 Win32 + comctl32 v6**(trackbar·combobox·checkbox, 매니페스트로 비주얼 스타일). `SettingsWindow.swift`(363줄) 규모면 다이얼로그 리소스 없이 코드 레이아웃으로 충분 — .rc 다이얼로그는 런타임 다국어·DPI 대응이 오히려 번거로움. 캐릭터 프리뷰는 자식 창 WM_PAINT에서 `StretchBlt`(HALFTONE off = nearest).
  - `uiScale` 설정(:110-113)은 Windows에선 시스템 DPI가 역할을 대신 → **Windows에서는 항목 숨김**.
- **W20. PNG 디코딩(Windows)** — 채택: **GDI+ flat C API**(`GdiplusStartup`/`GdipCreateBitmapFromStreamICM`/`GdipBitmapLockBits`) → RGBABuffer. COM 인터페이스 호출 없이 C 함수만으로 디코딩 — WIC(COM 필수)·서드파티(stb_image 번들) 대비 의존성 0. AnimData.xml은 기존 문자열 파서(`Sprite.swift:136-155`)가 Foundation-only라 그대로.

### 플랫폼 서비스

- **W9. 설정 저장** — 채택: **`SettingsStore` 프로토콜**. Windows = `%LOCALAPPDATA%\PokemonMouseFollower\settings.json` (Foundation `.applicationSupportDirectory`가 `%LOCALAPPDATA%`로 매핑 — Phase 0 실측; 세이브와 같은 폴더) (corelibs-foundation UserDefaults의 Windows 저장 위치/신뢰성이 불명확 — 검증 비용보다 JSON 대체가 쌈). macOS = 기존 UserDefaults 백엔드 유지(기존 사용자 설정 보존, dev suite 로직 포함).
- **W10. 로컬라이제이션** — 채택: **커스텀 .strings 파서를 Core에 두고 양 플랫폼 공용**. `L()`을 Core로 이동. 포맷이 단순(`"key" = "value";` + `\n`/`\"` 이스케이프)해 파서 ~50줄. `.lproj` 언어 선택이 Windows Foundation에서 동작할지 불확실한 도박을 제거하고 macOS와 문자열 선택 로직이 100% 일치. 언어 결정: Windows `GetUserPreferredUILanguages` → ko/ja/en 매칭 + 설정에 수동 오버라이드 항목(신규). `%@`/`%d` 포맷 치환은 기존 `String(format:)` 그대로.
- **W11. 자동시작** — 채택: `HKCU\Software\Microsoft\Windows\CurrentVersion\Run`에 exe 경로 등록/삭제(`RegSetValueExW`). `LoginItem` 프로토콜화(`AppCore.swift:12-29` 대응).
- **W12. 리소스 배치/로딩** — 채택: exe 옆 폴더 구조 `{ PokemonMouseFollower.exe, *.dll(Swift 런타임), characters/, gamedata/, locale/{en,ko,ja}.strings, LICENSE }`. corelibs-foundation `Bundle.main.resourceURL` = exe 디렉토리라 기존 호출이 동작할 가능성 높으나, **Core에 `Resources.url(name,ext,subdir)` 래퍼**를 도입해 exe-상대 경로 폴백을 심어 불확실성 제거(Phase 0 검증).
- **W19. 폰트/아이콘 대체** — 채택: `NSFont.rounded` → Segoe UI (Variable), monospaced → Consolas. SF Symbol(주사위 `SettingsWindow.swift:229-239`, 발자국) → 텍스트/자체 .ico/생략. `backpack.svg`(`RaisingPanel.swift:245`)는 Phase 5에서 사전 렌더 PNG.

### 빌드/배포

- **W13. 패키징** — 채택: **Inno Setup 인스톨러(per-user, `%LOCALAPPDATA%\Programs\`, 관리자 권한 불필요) + zip 병행 배포**. MSIX는 서명 필수(C3 위배)라 탈락. Inno는 시작 메뉴·업데이트 덮어쓰기·실행 중 앱 종료 처리를 공짜로 제공하고 자체 업데이터(W14)의 기반.
- **W14. 자체 업데이터(Windows)** — 채택: GitHub API 버전 확인(기존 `Updater.fetchLatest` :63-88 재사용 — URLSession은 Windows에서 curl 백엔드로 동작) → `PokemonMouseFollower-Setup.exe` 다운로드 → `/VERYSILENT /SUPPRESSMSGBOXES /CLOSEAPPLICATIONS` 실행 → 인스톨러가 교체+재실행. macOS의 분리 셸 스크립트 스왑과 달리 스왑 로직을 직접 짤 필요 없음. 릴리즈 자산에 버전리스 stable 링크 포함(macOS `STABLE_DMG` 패턴 :26 미러). zip 사용자용 수동 업데이트는 문서화만.
- **W15. CI** — 채택: **GitHub Actions 도입**. `windows-latest`: Swift 툴체인 설치 → `build.ps1` → 헤드리스 `--selftest-core`; `macos-latest`: `build.sh` + 기존 셀프테스트(Core 리팩터가 macOS를 깨지 않는지 매 push 검증). 태그 push 시 Windows 아티팩트(Setup.exe+zip) 자동 빌드.
- **W16. 버전 단일 출처** — 채택: `Sources/Core/Version.swift`(`let appVersion`)를 진실로. build.sh가 Info.plist와 동기화, build.ps1이 .rc `VERSIONINFO`와 Inno `.iss`에 주입. `Updater.currentVersion`(:27-29, Info.plist 의존)을 이 상수로 교체.
- **W17. exe 메타데이터** — 채택: `.rc` 리소스(.ico 앱 아이콘 + VERSIONINFO)를 `rc.exe`로 컴파일 후 링크, `app.manifest`(PMv2 DPI + comctl32 v6 + UTF-8 activeCodePage) 임베드, `-Xlinker /SUBSYSTEM:WINDOWS`(콘솔 창 숨김 — 엔트리 포인트는 Phase 0 검증).

### 패리티 검증

- **W18. 검증 전략** — 채택: 3층.
  1. **공용 헤드리스 셀프테스트**: `Selftests.swift:183-330`(GameData/성장/배틀/BattleLog/MoveMechanics — A등급 코드만 사용)를 `Core/SelftestsCore.swift`로 분리, `--selftest-core` + `PMF_SAVE_DIR`로 양 OS CI에서 실행. UI 덤프 훅(--dump-*)은 macOS 잔류.
  2. **시드 고정 배틀 픽스처**: 엔진의 `Int.random`을 주입 가능한 seeded RNG로 스위치(테스트 시에만), 동일 시드 배틀 이벤트 로그를 macOS↔Windows 비교해 수치 패리티 증명(Phase 5 게이트).
  3. **수동 QA 체크리스트**: 멀티모니터(음수 좌표·모니터 간 이동·핫플러그), DPI 100/150/200% + 혼합, 전체화면(exclusive/borderless), 절전 복귀, 가상 데스크톱, 한글 경로(현 저장소 `C:\가득\` 자체가 테스트 케이스), ko/ja/en, 트레이 전 메뉴, 자동시작, 업데이트 플로우.

---

## 4. 아키텍처 노트

### 4.1 디렉토리 구조 (W1)

```
Sources/
  Core/                      # 플랫폼 중립 (Foundation only)
    Platform.swift           # typealias PMFImage, Vec2, RGBABuffer — 유일한 #if os() 허브
    Version.swift            # 버전 단일 출처 (W16)
    Resources.swift          # Bundle/exe-상대 리소스 로케이터 (W12)
    Localization.swift       # L() + .strings 파서 + 언어 선택 (W10)
    Settings.swift           # AppSettings → SettingsStore 프로토콜 (W9)
    Characters.swift         # 이동
    SpriteSheet.swift        # Sprite.swift의 슬라이싱/마커/AnimData 파서 → RGBABuffer 기반 (W2)
    FollowerBrain.swift      # CharacterController 로직부 (프레임 = PMFImage)
    SelftestsCore.swift      # 헤드리스 셀프테스트 (W18)
    Raising/                 # BattleEngine·GameData·PartyState·MoveMechanics·BattleLog (사실상 이동만)
      # Phase 5에서 추가: BattlePlayback.swift(BattleController 로직부), ItemCatalog.swift,
      #                   WildBrain.swift, EffectCompositor.swift(RGBABuffer 틴트/합성)
  macOS/                     # 기존 파일 이동: main, AppDelegate, SpriteView, SettingsWindow,
                             # Updater, UIStyle, CharacterPreviewView, Selftests(UI 훅), RaisingMode UI
  Windows/
    WinMain.swift            # 엔트리 + 메시지 루프 + 틱 (W5)
    OverlaySprite.swift      # 엔티티당 layered window + ULW 블릿 (W3)
    ImageDecode.swift        # GDI+ flat API → RGBABuffer, DIB 변환 (W20)
    ScreenAdapterWin.swift   # 가상 스크린, y-flip, WM_DISPLAYCHANGE (W4)
    CursorTracker.swift      # GetCursorPos (W6)
    TrayIcon.swift           # Shell_NotifyIcon + 팝업 메뉴 (W7)
    SettingsDialog.swift     # Win32 설정 창 (W8)
    SettingsStoreWin.swift   # settings.json (W9)
    AutoStart.swift          # HKCU Run (W11)
    UpdaterWin.swift         # Setup.exe 사일런트 업데이트 (W14)
    Win32Util.swift          # 창 클래스 등록, 에러 헬퍼, 유니코드 변환
```

### 4.2 핵심 시임(seam) 4개

1. **PMFImage / RGBABuffer** (W2): Core는 픽셀 분석(RGBABuffer)과 불투명 렌더 핸들(PMFImage)만 안다.
2. **ScreenAdapter** (W4): 월드 y-up 좌표 고정, 커서/스크린 목록/변환만 플랫폼이 제공.
3. **SettingsStore / LoginItem / Resources / L()** (W9~W12): 서비스 프로토콜.
4. **Renderer(OverlaySprite)**: "핸들 생성 → frame·pos·alpha 설정" 인터페이스. macOS 구현 = CALayer(현 SpriteView 재배선), Windows = ULW. 후일 DComp 백엔드로 교체 가능(W3).

### 4.3 Windows 틱 루프 (`AppDelegate.tick` :183-269의 이식)

`waitable timer 60Hz → GetCursorPos → adapter.flip → FollowerBrain.update → OverlaySprite.present(frame, pos)`. 일시정지 = 창 숨김(현 `toggleRunning` :278-282와 동일). 키우기 모드 합류 시 battle/items 틱을 같은 자리에 얹음(현 구조 그대로).

---

## 5. 수정·생성할 파일 목록

| 구분 | 파일 | 시기 |
|---|---|---|
| 이동+소폭 수정 | `Characters.swift`, `RaisingMode/{GameData,PartyState,BattleEngine,MoveMechanics,BattleLog}.swift` → `Sources/Core(/Raising)`. `Bundle.main`→`Resources` 래퍼 | Phase 1 |
| 추출 리팩터 | `CharacterController.swift`→`Core/FollowerBrain.swift`, `Sprite.swift`→`Core/SpriteSheet.swift`+`macOS/ImageDecodeMac.swift`, `AppCore.swift`→`Core/Settings.swift`+`Core/Localization.swift`+`macOS/LoginItemMac.swift`, `Selftests.swift`→`Core/SelftestsCore.swift`+`macOS/SelftestsUI.swift` | Phase 1 |
| 신규 (Core) | `Platform.swift`, `Version.swift`, `Resources.swift` | Phase 1 |
| 신규 (Windows) | §4.1의 Windows/ 11개 파일 | Phase 2~4 |
| 신규 (빌드/배포) | `build.ps1`, `res/PokemonMouseFollower.rc`, `res/app.manifest`, `res/app.ico`+`tray.ico`, `installer.iss`, `.github/workflows/ci.yml` | Phase 0/4 |
| 수정 | `build.sh`·`dev.sh`(소스 경로), `release.sh`(버전 출처 W16), `README*.md`(Windows 설치·SmartScreen 안내), docs 사이트 다운로드 링크 | Phase 1/4 |
| Phase 5 (키우기) | `BattleController.swift` 로직/색상 추출, `Items.swift`(아이콘은 기존 `--dump-icons` 훅으로 PNG 사전 생성해 리소스화 — 드로잉 코드 이식 회피), `WildMon.swift`, `EffectPlayer.swift`(CGContext 틴트→RGBABuffer 연산), `EvolutionAnimator.swift`, `RaisingPanel`/`PromptCenter`/`TypeStyle` Win32 버전 | Phase 5 |

---

## 6. macOS와 불가피하게 달라지는 것 (릴리즈 노트/README 고지 사항)

1. **Exclusive fullscreen 게임 위에는 오버레이 불가**(Windows 합성 우회). borderless-windowed 전체화면 위에는 표시됨. macOS `fullScreenAuxiliary`의 등가물 없음.
2. **가상 데스크톱**: `canJoinAllSpaces` 등가 API 없음 — `IVirtualDesktopManager.IsWindowOnCurrentVirtualDesktop` 감지 후 자기 창 재배치 폴백 시도, 실패 시 현재 데스크톱에만 표시 (Phase 6).
3. **topmost z-순서 경쟁**: 다른 HWND_TOPMOST 앱과의 상하가 비결정적(작업표시줄·알림 위 표시 보장 없음).
4. 트레이 아이콘이 **overflow 영역에 숨을 수 있음**(첫 실행 안내).
5. SmartScreen "알 수 없는 게시자" 경고(C3) — "추가 정보 → 실행" 안내.
6. 시스템 폰트(SF Rounded→Segoe UI)·컨트롤 룩이 다름. `uiScale` 설정은 시스템 DPI로 대체(W8).
7. 설치 UX: DMG 드래그 → Inno 인스톨러/zip.

---

## 7. 리스크 (Swift on Windows)

| 리스크 | 완화 |
|---|---|
| corelibs-foundation 격차: UserDefaults 저장 위치 불명확, `.lproj` 선택 불확실, `CGVector` 부재 가능성, DateFormatter(`PartyState.swift:579-585`)·applicationSupportDirectory 매핑 | W9/W10으로 의존 자체를 제거, 나머지는 Phase 0 스파이크의 명시적 체크리스트 |
| URLSession(curl 백엔드) TLS/프록시 특이점 | Phase 4에서 실 GitHub API 통합 테스트 |
| 디버깅 경험(Windows LLDB 미성숙) | print/NSLog 중심 + 헤드리스 셀프테스트 우선 개발 |
| WinSDK 모듈이 GDI+ flat API·일부 매크로를 노출 안 할 수 있음 | Phase 0에서 브리징 헤더/modulemap 보강으로 확인 |
| 툴체인 설치 마찰(VS Build Tools + Windows SDK 선행) | build.ps1이 사전 조건 검사 + 안내, CI로 재현성 확보 |
| Swift 런타임 DLL 동봉 크기(수십 MB) | zip/인스톨러에 포함(고정 비용, 수용) |
| 비ASCII 경로(`C:\가득\`)·유니코드 W-API 변환 실수 | QA 체크리스트 항목화, UTF-8 codepage 매니페스트 |
| macOS 회귀(Core 추출 중 파손) | Phase 1 완료 기준 = 기존 셀프테스트 전체 통과 + CI macOS 잡 |

---

## 8. 결정 요약표 (확인용)

| ID | 결정 | 채택안 |
|---|---|---|
| W1 | 구조/빌드 | Core·macOS·Windows 3분할 + 플랫폼별 swiftc 목록 (SwiftPM 미도입) |
| W2 | 이미지 추상화 | RGBABuffer(분석) + PMFImage typealias(렌더) |
| W3 | 렌더 백엔드 | ULW+GDI, 엔티티당 소형 창. Renderer 시임으로 DComp 교체 여지 |
| W4 | 좌표/DPI | Core y-up 유지 + 어댑터 flip, PMv2 물리 픽셀 |
| W5 | 틱 | 고해상도 waitable timer 60Hz, 단일 스레드 |
| W6 | 마우스 | GetCursorPos 폴링(현행과 동일 주기) |
| W7 | 트레이 | Shell_NotifyIcon v4 + TrackPopupMenuEx + .ico |
| W8 | 설정 창 | 프로그래매틱 Win32 + comctl32 v6, uiScale 항목 숨김 |
| W9 | 설정 저장 | SettingsStore 프로토콜: Windows=JSON(%APPDATA%), macOS=UserDefaults 유지 |
| W10 | 다국어 | 커스텀 .strings 파서 Core 공용 + 언어 수동 오버라이드 |
| W11 | 자동시작 | HKCU Run 키 |
| W12 | 리소스 | exe 옆 폴더 + Resources 래퍼 |
| W13 | 패키징 | Inno Setup(per-user) + zip, MSIX 탈락 |
| W14 | 업데이터 | Setup.exe 다운로드 후 사일런트 실행 |
| W15 | CI | GitHub Actions windows+macos, 태그 시 아티팩트 |
| W16 | 버전 | Core/Version.swift 단일 출처 |
| W17 | exe 메타 | .rc(icon+VERSIONINFO) + manifest(PMv2·comctl32·UTF-8) + /SUBSYSTEM:WINDOWS |
| W18 | 패리티 | 공용 헤드리스 셀프테스트 + 시드 픽스처 + 수동 QA 체크리스트 |
| W19 | 폰트/아이콘 | Segoe UI/Consolas, SF Symbol 대체 |
| W20 | PNG 디코딩 | GDI+ flat C API (COM/서드파티 회피) |

---

## 9. 단계별 로드맵

- **Phase 0 — 툴체인 검증 스파이크** (PoC, 버려도 되는 코드): Windows에 Swift 툴체인 설치 → ① A등급 코어 6파일 + gamedata를 그대로 컴파일해 미니 셀프테스트(배틀 1판 + 세이브 라운드트립) 실행, ② 단일 스프라이트 ULW 클릭통과 창이 커서를 60fps로 따라다니는 PoC exe.
  검증 체크리스트: Bundle 리소스 조회 / %APPDATA% 경로 / .strings 파싱 / CGVector 유무 / GDI+ flat API 노출 / /SUBSYSTEM:WINDOWS 엔트리 / 비ASCII 경로.
  **완료 기준**: 코어 셀프테스트 Windows 통과 + PoC가 멀티모니터에서 매끄럽게 동작.
- **Phase 1 — 코드 재구성 (macOS 무변화 리팩터)**: §5의 이동/추출 전부, build.sh·dev.sh 경로 수정, CI(macOS 잡) 도입.
  **완료 기준**: macOS 앱 동작·외형 v1.8.0과 동일, 기존 셀프테스트 전체 통과.
- **Phase 2 — Windows follower 코어**: WinMain·틱 루프·OverlaySprite·ImageDecode·ScreenAdapter·CursorTracker·TrayIcon(설정 제외 메뉴), FollowerBrain 연결(걷기/잠들기/그림자/altcolor).
  **완료 기준**: follower가 멀티모니터·DPI 혼합 환경에서 macOS와 동일 거동, 일시정지/종료 동작.
- **Phase 3 — 설정 + 플랫폼 서비스**: SettingsDialog(캐릭터 픽커+프리뷰, 슬라이더, 토글, 언어), settings.json, HKCU 자동시작, 다국어 3종 적용.
  **완료 기준**: QA 체크리스트의 설정/서비스 섹션 통과, ko/ja/en 전환 즉시 반영.
- **Phase 4 — 빌드/배포 → 1차 Windows 릴리즈**: build.ps1, .rc/.ico/manifest, installer.iss+zip, UpdaterWin, CI windows 잡+릴리즈 파이프라인, README·릴리즈 노트(SmartScreen 안내), docs 사이트에 Windows 다운로드 추가.
  **완료 기준**: 태그 → CI 산출물 → 신규 PC에서 인스톨러 설치 → 구버전에서 자체 업데이트 성공. **v2.0.0 Windows 1차 릴리즈**.
- **Phase 5 — 키우기 모드 포팅**: BattleController/Items/WildMon/EffectPlayer/EvolutionAnimator 로직 추출, 배틀 크롬(HP바·Lv태그·플로팅 텍스트·배틀 로그) GDI 텍스트 렌더, RaisingPanel·PromptCenter Win32 재작성(가장 큰 덩어리), 아이템 아이콘 PNG화.
  **완료 기준**: 시드 픽스처 배틀 로그 macOS↔Windows 일치(W18-②), 키우기 QA 시나리오(스타터→배틀→포획→진화→프롬프트) 통과.
- **Phase 6 — 완전 패리티 & 폴리시**: 전체 QA 체크리스트, 가상 데스크톱 폴백, 세이브 상호 호환 확인(raising.json 스키마 동일), 성능 프로파일(ULW 채우기율 — 필요 시 DComp 백엔드 전환 판단), 패리티 릴리즈.

---

## 10. Phase 0 검증 결과 (2026-07-10, ✅ 완료)

환경: Windows 11 Pro, Swift 6.3.3 (winget `Swift.Toolchain`), VS Build Tools 2022 (MSVC 14.44) + Windows SDK 10.0.26100. 검증 코드: `spike/windows-phase0/`.

| 체크리스트 항목 | 결과 |
|---|---|
| 코어 6파일 무수정 컴파일 | ✅ 스텁 4개(L/PMF/AppSettings/GameItem 로직부/BattleController)만으로 컴파일·실행 |
| 미니 셀프테스트 | ✅ 전부 통과 — GameData(251종/544기술/19타입) 로드, 새 게임→Lv22 성장→L16 진화, 배틀 1판(턴 스탬프 단조), 한국어 배틀 로그 52줄 미해석 키 0, 세이브 기록 |
| `Bundle.main` 리소스 조회 | ✅ `resourceURL` = exe 디렉토리. exe 옆 `gamedata/` 폴더에서 기존 호출이 그대로 동작 |
| `.applicationSupportDirectory` | ✅ `%LOCALAPPDATA%`(`C:\Users\<u>\AppData\Local`)로 매핑 — W9/세이브 경로 확정 |
| 커스텀 `.strings` 파서 (W10) | ✅ ~40줄 정규식 파서로 ko 1,217키 파싱, `String(format:)` 포맷 치환 정상 |
| `CGVector` | ❌ 부재 (`CGPoint`/`CGRect`/`CGFloat`는 있음) → Phase 1에서 Core `Vec2` 정의 확정 |
| GDI+ flat API (W20) | ✅ WinSDK 모듈에는 미노출(gdiplus.h가 C++) → `LoadLibrary`/`GetProcAddress` 동적 바인딩으로 검증 완료. 주의: Swift 정의 구조체는 `@convention(c)` 시그니처에 못 들어감 → raw pointer로 전달 |
| ULW 오버레이 (W3) | ✅ 클릭통과 레이어드 창이 60fps로 커서 추적, 741틱 ULW 실패 0. PNG 시트 디코딩→PARGB 프레임 슬라이스→2x nearest→per-pixel alpha 전 과정 검증 |
| 고해상도 타이머 (W5) | ✅ `CreateWaitableTimerExW(HIGH_RESOLUTION)` 사용 가능 |
| `/SUBSYSTEM:WINDOWS` (W17) | ✅ `-Xlinker /SUBSYSTEM:WINDOWS -Xlinker /ENTRY:mainCRTStartup` 링크 성공 |
| 비ASCII 경로 | ✅ `C:\가득\` 소스 컴파일, `save-테스트\` 디렉토리 세이브 정상 |
| DateFormatter | ✅ 동작 |
| 멀티모니터 | ⏳ 이 머신은 모니터 1대(2560×1440) — 멀티모니터 실측은 QA 체크리스트로 이월 |

**Phase 1에 미치는 영향**:
1. `PartyState.swift` → `BattleController` 커플링 발견(§2.1) — `LiveBattleBridge` 프로토콜 시임 추가.
2. `Vec2` 대체 확정 (CGVector 부재).
3. W20은 동적 바인딩 방식으로 확정 (modulemap C 심 불필요 — 검증된 코드를 `Windows/ImageDecode.swift`가 그대로 흡수).
4. 설정/세이브 디렉토리는 `%LOCALAPPDATA%\PokemonMouseFollower\`로 통일.
5. **macOS 검증 제약**: 현 개발 머신이 Windows라 Phase 1의 "macOS 무변화" 완료 기준(빌드+셀프테스트)은 Mac에서 실행해야 확정됨 — Phase 1 커밋 후 Mac에서 `./dev.sh` + `--selftest-raising` 확인 필요.
