# PMD: Explorers of Sky ROM 자산 추출기

SkyTemple의 코어 라이브러리(`skytemple-files`)를 사용해 *포켓몬 초불가사의 던전: 하늘의 탐험대* ROM에서
기술 이펙트 스프라이트, 애니메이션 매핑 테이블, 기술 데이터, 게임 문자열을 추출합니다.

> **주의**: ROM은 직접 소유한 카트리지에서 합법적으로 덤프한 파일을 사용하세요.
> ROM과 추출 결과물(`out/`, `*.nds`)은 `.gitignore`로 커밋에서 제외됩니다. 재배포하지 마세요.

## 사용법

```sh
# 1. ROM을 이 폴더에 rom.nds 이름으로 복사 (US/EU/JP 모두 지원)
cp /path/to/eos.nds rom-extract/rom.nds

# 2. 데이터/문자열/애니메이션 테이블 추출
rom-extract/.venv/bin/python rom-extract/extract.py --only strings,moves,anim

# 3. 이펙트 스프라이트 → PNG 시트 렌더링 (메모리 감시 포함, 중단 시 재실행하면 이어서 진행)
rom-extract/.venv/bin/python rom-extract/render_all.py

# 4. 개별 프레임 PNG + 애니메이션 메타데이터 분리
rom-extract/.venv/bin/python rom-extract/split_frames.py
```

> macOS는 `setrlimit` 메모리 상한을 강제하지 않으므로, `render_all.py`가 항목마다
> 자식 프로세스를 띄우고 실제 RSS를 0.5초마다 폴링해 1.2GB 초과 시 그 항목만 강제
> 종료합니다 (`--mem-mb`, `--timeout`으로 조절). 일부 이펙트가 팔레트 버그로 메모리를
> 폭주시켜 시스템 셧다운까지 일으켰던 것의 안전장치입니다 (팔레트 버그 자체도 수정됨).
> 진행 상황은 `out/effects/_status/`에 기록되어 재실행 시 완료 항목은 건너뜁니다.

의존성은 `rom-extract/.venv`에 이미 설치되어 있습니다 (Python 3.12 + skytemple-files 1.8.5).
venv를 다시 만들려면:

```sh
/opt/homebrew/opt/python@3.12/bin/python3.12 -m venv rom-extract/.venv
rom-extract/.venv/bin/pip install skytemple-files
```

## 출력 구조 (`out/`)

```
meta.json                          # ROM 버전/리전, 언어 목록
moves/
  moves.json                       # 기술 559개 전체 데이터: 위력, 타입, 분류, PP, 명중률,
                                   #   크리티컬 확률, 사거리 설정, 다국어 이름/설명 등
  learnsets.json                   # 포켓몬별 레벨업/TM·HM/알 기술 목록 (다국어 이름 포함)
anim/
  anim.bin                         # overlay10에서 재구성한 원본 애니메이션 테이블 (SkyTemple 호환)
  move_animations.json             # 기술 ID → 애니메이션 ID(anim1~4), 속도, 방향, 효과음(sfx) 매핑
  general_animations.json          # 애니메이션 ID → effect.bin 파일 인덱스 + 타입(WAN/SCREEN/…) + 루프 여부
  special_move_animations.json     # 특정 포켓몬 전용 기술 애니메이션 오버라이드
  trap_animations.json             # 함정 애니메이션 매핑
  item_animations.json             # 아이템(투척 등) 애니메이션 매핑
effects/
  effect_NNNN.bin                  # EFFECT/effect.bin 안의 개별 파일 (원본)
  effect_NNNN/
    A-AA-??-D.png                  # 애니메이션별 가로 프레임 시트 (D: 방향 N/F/B 등)
    frames/F-NN.png                # 개별 프레임 PNG (모두 같은 크기, 앱에서 바로 사용)
    animations.json                # frame_size + 애니메이션별 {frame, duration(1/60초), offset}
  effects_index.json               # 크기, 사용 타입, 내보내기 방식, palette(exact|approx_common)
  _status/                         # 재개용 진행 마커 (완료 후 삭제해도 무방)
strings/
  all_strings_<lang>.json          # 언어별 전체 문자열 (message_id 인덱스와 일치)
  move_names.json / move_descriptions.json / monster_names.json / item_names.json / type_names.json
```

## 데이터 연결 방법 (기술 → 이펙트 그래픽)

1. `moves/moves.json`에서 기술을 찾는다 (`move_id`).
2. `anim/move_animations.json`의 같은 인덱스에서 `anim1`(주 애니메이션 ID)을 읽는다.
3. `anim/general_animations.json[anim1]` 항목의 해석:
   - `anim_type == WAN_FILE0` → 공용 파일 `effect_0000` 사용, **`unk1`이 그 안의 애니메이션 번호**
     (`effect_0000/animations.json`의 `anim_id`). 전 항목 검증 완료.
   - `anim_type == WAN_FILE1` → 공용 파일 `effect_0001` 사용, `unk1` = 애니메이션 번호. 검증 완료.
   - `anim_type == WAN_OTHER` → `anim_file`이 전용 `effects/effect_NNNN/` 폴더 번호.
     이 경우 `unk1`의 의미는 미해독 (커뮤니티에서도 unknown 필드).
   - `SCREEN`/`WBA` → 전체 화면 이펙트.
4. `sfx` 필드는 효과음 ID (사운드는 이 스크립트 범위 밖).

예) 10만볼트(Thunderbolt) → `anim1=22` → general[22] = WAN_FILE0, unk1=3
    → `effect_0000/animations.json`의 anim_id 3 프레임 시퀀스 재생.

## 이펙트 색상(팔레트)에 대해

이펙트 스프라이트는 팔레트를 VRAM 절대 슬롯 번호로 참조합니다. 각 파일은 자기 팔레트
행(보통 슬롯 13~15)만 담고 있고, 프레임이 낮은 슬롯(0~12)을 참조하면 그 색은 게임이
**실행 시점에 다른 파일의 팔레트를 VRAM 공용 뱅크에 로드**해 채웁니다.

`effect_palette.py`가 이를 재구성합니다: 공용 팔레트(`effect_0292`, 마스터 16행) 위에
각 이펙트의 고유 행을 얹은 16행 뱅크를 만들고, 프레임의 절대 인덱스로 조회합니다.
결과는 `effects_index.json`의 `palette` 필드로 표시됩니다:

- **`exact` (76개)**: 프레임이 자기 팔레트만 참조 → 게임과 동일한 정확한 색.
- **`approx_common` (214개)**: 공용 슬롯을 참조하는 "템플릿" 이펙트 → 공용 팔레트(292번)의
  실제 게임 색을 입히지만, 기술별로 런타임에 덧입히는 고유 색조는 스프라이트만으로 복원
  불가. **모양·프레임·타이밍은 정확**합니다.

  예) 거품(Bubble, `effect_0102`)은 모양은 정확하나 게임에서 물색(파랑)으로 로드되는
  팔레트가 파일에 없어 공용 팔레트의 색으로 나옵니다. 앱에서 이런 템플릿 이펙트는
  원하는 색으로 틴트해서 쓰는 것을 권장합니다 (프레임이 그레이스케일에 가까운 명암 구조).

- 290, 291번 항목은 SIR0 그래픽이 아닌 데이터 파일이라 원본 `.bin`만 보존됩니다.
- WAN_OTHER 항목의 `unk1`~`unk5` 필드 의미는 미해독입니다.

## 참고

- 포켓몬 본체의 걷기/공격 모션 스프라이트(monster.bin / m_attack.bin)는
  PMDCollab SpriteCollab(https://sprites.pmdcollab.org)이 이미 같은 데이터를 정리·보정해 배포하므로
  여기서는 추출하지 않습니다. 필요하면 `skytemple_files.graphics.chara_wan`으로 추가 가능.
- `anim.bin`은 SkyTemple의 `ExtractAnimData` 패치와 동일한 방식으로 overlay10에서 재구성합니다.
  패치가 이미 적용된 ROM이면 ROM 안의 `BALANCE/anim.bin`을 그대로 사용합니다.
