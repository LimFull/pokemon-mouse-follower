# Phase 0 스파이크 — Swift on Windows 툴체인 검증 (2026-07-10)

Windows 포팅 계획서(`design/windows-port.md` §10)의 검증 코드 스냅샷.
버려도 되는 PoC지만, `overlay/main.swift`의 GDI+ 동적 바인딩·ULW 코드는
Phase 2의 `Windows/ImageDecode.swift`·`OverlaySprite.swift`가 흡수한다.

## 사전 조건 (Windows)

- Visual Studio Build Tools 2022 (MSVC C++ 툴셋 + Windows SDK)
- `winget install Swift.Toolchain` (Swift 6.3.3 검증)
- 새 셸 또는 PATH/SDKROOT 반영:
  `%LOCALAPPDATA%\Programs\Swift\Toolchains\<ver>\usr\bin`,
  `%LOCALAPPDATA%\Programs\Swift\Runtimes\<ver>\usr\bin`,
  `SDKROOT=%LOCALAPPDATA%\Programs\Swift\Platforms\<ver>\Windows.platform\Developer\SDKs\Windows.sdk\`

## core — 코어 6파일 무수정 컴파일 + 미니 셀프테스트

```powershell
swiftc -O core\main.swift core\Stub.swift core\GameItemStub.swift core\BattleControllerStub.swift `
  ..\..\Sources\Characters.swift ..\..\Sources\RaisingMode\GameData.swift `
  ..\..\Sources\RaisingMode\PartyState.swift ..\..\Sources\RaisingMode\BattleEngine.swift `
  ..\..\Sources\RaisingMode\MoveMechanics.swift ..\..\Sources\RaisingMode\BattleLog.swift `
  -o spike.exe
Copy-Item -Recurse ..\..\gamedata .\gamedata   # exe 옆에 리소스
$env:PMF_SAVE_DIR = ".\save-scratch"; New-Item -ItemType Directory -Force $env:PMF_SAVE_DIR
.\spike.exe   # 기대: === ALL PASS ===
```

## overlay — 클릭통과 ULW 오버레이 PoC (꼬부기가 커서를 20초간 따라다님)

```powershell
swiftc -O overlay\main.swift -o overlay.exe
.\overlay.exe
# 콘솔 창 숨김 링크 프로브:
swiftc -O overlay\main.swift -Xlinker /SUBSYSTEM:WINDOWS -Xlinker /ENTRY:mainCRTStartup -o overlay-gui.exe
```

결과 요약은 `design/windows-port.md` §10 참고.
