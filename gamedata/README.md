# gamedata — 키우기 모드 게임 데이터 번들

앱(키우기 모드)이 번들해 로드하는 **사실(factual) 게임 데이터**입니다.
`rom-extract/build_gamedata.py`가 EoS 추출물(`rom-extract/out/`)에서 생성합니다.

재생성:

```sh
rom-extract/.venv/bin/python rom-extract/build_gamedata.py
```

## 파일

- **`species.json`** — 1·2세대 251종. 종별: 이름(다국어), 타입1/2, 종족값(hp/atk/def/sp_atk/sp_def),
  base form 여부, 이전 진화, 진화 목록(대상·방법·조건), 레벨업 기술(레벨+move_id),
  레벨별 필요 경험치(`exp_curve` — 본가 성장 곡선, PokeAPI growth-rate에서 수집(`fetch_growth.py`);
  2026-07-18 이전에는 EoS 롬의 `exp_required` 곡선이었음), 성장 곡선 이름(`growth_rate`),
  레벨별 스탯 성장치(`growth`). 스프라이트 id = 3자리 도감번호(`animations/<id>/`와 일치).
- **`moves.json`** — 기술별 move_id → 이름(다국어)·타입·분류·위력·PP·명중률.

## 정책

- **사실 데이터(수치/타입/이름)만** 포함합니다. 저작권이 있는 **설명문(flavor text)은 넣지 않습니다.**
- ROM 자체나 `rom-extract/out/`의 대량 추출물(스프라이트/이펙트/문자열 덤프)은 번들하지 않습니다.
- **`effects/`는 ROM 추출 스프라이트라 git에 올리지 않습니다** (.gitignore). 로컬 빌드에는 필요하므로
  본인 ROM에서 직접 생성하세요: `rom-extract/.venv/bin/python rom-extract/build_effects.py`
  (앱은 `effects/`가 없으면 이펙트 없이 동작합니다 — EffectPlayer가 클립 없음으로 폴백).
- 포획률·기초경험치·성비·기술 상태이상 등 **본가 기준 값**은 전투/포획을 만드는 단계에서
  PokéAPI 1회 수집분으로 별도 추가됩니다(설계 문서 `design/raising-mode.md` 2.2-H 참고).
