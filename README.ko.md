<p align="center">
  <img src="icon/icon-1024.png" width="160" alt="Pokémon Mouse Follower app icon">
</p>

<p align="center">
  <a href="README.md">English</a> · <b>한국어</b> · <a href="README.ja.md">日本語</a>
</p>

# Pokémon Mouse Follower

macOS 메뉴바 앱으로, 화면 위를 돌아다니는 포켓몬 캐릭터가 마우스 커서를 따라다닙니다.
Dock에는 표시되지 않고 상단 메뉴바에만 아이콘(🐾)이 뜨는 백그라운드 앱입니다.

- 🐾 **메뉴바 전용** — Dock 아이콘 없음 (`LSUIElement`)
- 🎯 **고유 물리 기반 추적** — 커서와 거리를 두고, 캐릭터 자신의 속도/가속도로 부드럽게 따라옴
- 🧭 **8방향 애니메이션** — 이동 방향에 맞춰 스프라이트가 회전
- 😴 **대기 → 수면** — 일정 시간 멈춰 있으면 잠들고, 커서가 움직이면 다시 따라옴
- 🐱 **포켓몬 251마리 (1·2세대)** — GUI에서 선택
- 🎨 **다른 색상(altColor)** — 대체 색상이 있는 124마리는 다른 팔레트로 표시 가능
- 🌏 **다국어** — 영어 / 한국어 / 일본어 (UI + 포켓몬 이름)
- 🖥️ **투명 클릭 통과 오버레이** — 아래 앱 조작을 방해하지 않음
- 🖥️🖥️ **멀티 모니터 지원** — 디스플레이 사이를 자연스럽게 넘나듦

## 요구 사항

- macOS 13 (Ventura) 이상
- Apple Silicon / Intel 모두 지원 (universal 빌드)
- Xcode Command Line Tools (`swiftc`) — **소스에서 직접 빌드할 때만** 필요 (`xcode-select --install`)

## 설치 (개발자 도구 없이)

[Releases](https://github.com/LimFull/pokemon-mouse-follower/releases/latest)에서 `.dmg`를 받아 설치합니다. Xcode / Swift 없이 바로 실행됩니다.

1. `PokemonMouseFollower-<version>.dmg` 다운로드 후 열기
2. **Pokémon Mouse Follower** 아이콘을 **Applications** 폴더로 드래그
3. Launchpad / 응용 프로그램에서 실행

## 설치 (소스에서 빌드)

```bash
./build.sh install
```

`PokemonMouseFollower.app`을 universal 바이너리로 빌드하고 ad-hoc 서명 후 `/Applications`에 복사하고 실행합니다.
메뉴바에 🐾 아이콘이 뜨고, 마우스를 움직이면 캐릭터가 따라다닙니다.

빌드만 하려면:

```bash
./build.sh          # ./PokemonMouseFollower.app 생성
open ./PokemonMouseFollower.app
```

> 소스 빌드는 ad-hoc 서명이라 Finder에서 처음 열 때 "확인되지 않은 개발자" 경고가 뜨면 우클릭 → **열기** 한 번이면 됩니다.
> 로그인 시 자동 실행은 설정 창의 **로그인 시 자동 실행** 옵션으로 켤 수 있습니다.

## 개발

빠른 반복용 스크립트. arm64 디버그 빌드로 컴파일해 포그라운드로 실행하며, 로그가 터미널에 출력되고 Ctrl+C로 종료합니다.

```bash
./dev.sh
```

## 설정

메뉴바 🐾 → **Settings…** (`⌘,`), 또는 실행 중인 앱을 다시 실행하면 설정 창이 열립니다.
값은 즉시 반영되고 `UserDefaults`에 저장됩니다.

창 최상단에는 선택된 캐릭터의 미리보기(아래방향 대기 애니메이션)와 **◀ ▶** 이전/다음 화살표, **랜덤** 버튼이 있습니다.

| 항목 | 범위 | 기본값 | 설명 |
|---|---|---|---|
| 캐릭터 | 251마리 | 007 꼬부기 | 따라다닐 포켓몬 |
| 커서와의 거리 | 0–200 px | 100 | 커서와 유지할 간격 |
| 최대 속도 | 2–25 | 5 | 캐릭터 이동 속도 상한 |
| 캐릭터 크기 | 1.0×–5.0× | 2.0× | 스프라이트 배율 |
| 잠들기까지 시간 | 5–120초 | 30 | 멈춘 뒤 수면까지의 시간 |
| 다른 색상 | 켜기/끄기 | 끄기 | 대체 색상(altColor) 스프라이트 사용 (있는 포켓몬만, 124마리) |
| 그림자 | 켜기/끄기 | 끄기 | 캐릭터 발밑에 그림자 타원 표시 (크기는 포켓몬별 `ShadowSize` 반영) |
| 로그인 시 자동 실행 | 켜기/끄기 | 끄기 | PC 시작(로그인) 시 자동 실행 |

## 동작 흐름

```
걷기(walk) → 멈춤 → 대기(idle) → [잠들기까지 시간] → 수면(sleep)
                                              ↓ 커서 이동
                                            걷기(walk)
```

- 이동 속도는 마우스 속도와 무관합니다. 마우스가 너무 빠르면 캐릭터가 뒤처졌다가 자신의 속도로 따라잡습니다.
- 정지 상태에서 출발할 때 속도 0에서 부드럽게 가속하고, 커서 근처에서 감속해 멈춥니다.

## 프로젝트 구조

```
Sources/main.swift        앱 본체 (오버레이 윈도우, 스프라이트 애니메이션, 물리, 설정 GUI)
Info.plist                번들 설정 (LSUIElement, 현지화 목록)
build.sh                  universal .app 빌드 + ad-hoc 서명 (+ install)
release.sh                빌드 + 서명 + .dmg 패키징 + 발행
dev.sh                    빠른 arm64 디버그 빌드 + 포그라운드 실행
fetch-shadows.sh          -Shadow 마커 시트 다운로드
fetch-altcolors.sh        다른 색상(altColor) 스프라이트 다운로드
Localizable/*.lproj       en / ko / ja 문자열
animations/<번호>/        캐릭터별 스프라이트 시트 + AnimData.xml
```

각 캐릭터 폴더에는 `Idle-Anim.png`, `Walk-Anim.png`, `Sleep-Anim.png`와 프레임 크기 정보가 담긴 `AnimData.xml`이 들어 있습니다. 프레임 크기는 캐릭터마다 다르며, 앱이 `AnimData.xml`을 읽어 동적으로 슬라이스합니다.

## 크레딧

- 스프라이트: [PMD Sprite Collab](https://sprites.pmdcollab.org/#/) — 커뮤니티가 제작한 도트 애니메이션 (에셋은 `spriteserver.pmdcollab.org`에서 내려받음).
- Pokémon © Nintendo / Creatures Inc. / GAME FREAK inc.

이 프로젝트는 **비상업적 개인 팬 프로젝트**입니다. 포켓몬 및 관련 이름·이미지의 권리는 각 권리자에게 있습니다.
