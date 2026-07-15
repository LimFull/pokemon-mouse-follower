// Dev-run debug actions (PMF.isDevRun): ONE catalog both platforms render as
// an always-open button panel — the old tray/menu route needed a submenu dive
// per test (user request: keep the panel open, fire tests with single
// clicks). Platform-owned controllers (battle, item spawner) come in as
// closures; party/bag/EXP/status actions run here on RaisingState +
// PromptRelay, so the logic isn't duplicated per platform anymore.

import Foundation

struct DebugAction {
    let title: String
    let run: () -> Void
}

struct DebugSection {
    let title: String
    let actions: [DebugAction]
}

enum DebugCatalog {
    /// Curated instant battles — each opponent exercises a specific
    /// status/effect path (showcase moves pinned in BattlePlayback).
    static let encounters: [(String, Int)] = [
        ("랜덤", 0),
        ("피카츄 (마비)", 25),
        ("슬리프 (최면술·에스퍼)", 96),
        ("식스테일 (화상)", 37),
        ("아보 (독)", 23),
        ("루주라 (얼음·헤롱헤롱)", 124),
        ("별가사리 (물대포)", 120),
        ("메타몽 (변신)", 132),
        ("피콘 (자폭)", 204),
        ("뚜벅쵸 (흡수·드레인)", 43),
        ("삐삐 (작아지기)", 35),
        ("루기아 (날려버리기·강제교체)", 249),
        ("캐이시 (순간이동 도주)", 63),
        ("뿔카노 (뿔찌르기)", 111),
    ]

    static let statuses: [(String, String)] = [
        ("마비", "paralysis"), ("화상", "burn"), ("독", "poison"),
        ("수면", "sleep"), ("얼음", "freeze"), ("상태 해제", ""),
    ]

    /// All species pickable in the custom-battle UI (dex order, localized
    /// display names — every gen1-2 species ships sprites).
    static var speciesChoices: [(name: String, dex: Int)] {
        GameData.species.values
            .sorted { $0.dex < $1.dex }
            .map { (Characters.displayName($0.id), $0.dex) }
    }

    /// Real battle moves only: the ROM's move table is padded with dummy
    /// slots ("[M:D1]", "$$$") and EoS dungeon utilities (See-Trap, Warp...)
    /// that mean nothing to this engine — keep a move iff the mainline knows
    /// it (accuracy_main merged) or some species actually learns it.
    private static var battleMoveIds: Set<Int> = {
        var learnable = Set<Int>()
        for s in GameData.species.values {
            for m in s.levelUpMoves { learnable.insert(m.moveId) }
        }
        return Set(GameData.moves.values
            .filter { $0.accuracyMain != nil || learnable.contains($0.moveId) }
            .map(\.moveId))
    }()

    /// All moves pickable in the custom-battle UI — alphabetized in the UI
    /// language (가나다순 for Korean) so a move is findable by name.
    static var moveChoices: [(name: String, id: Int)] {
        GameData.moves.values
            .filter { battleMoveIds.contains($0.moveId) }
            .map { ($0.displayName, $0.moveId) }
            .sorted { $0.0.localizedStandardCompare($1.0) == .orderedAscending }
    }

    /// A fully random opponent: any species, four distinct random battle
    /// moves — fuzzing fuel for effect/mechanic bug hunts.
    static func randomLoadout() -> (dex: Int, moves: [Int]) {
        let dex = GameData.species.keys.randomElement() ?? 25
        let moves = Array(battleMoveIds.shuffled().prefix(4))
        return (dex, moves)
    }

    static func sections(forceEncounter: @escaping (Int?, [Int]?) -> Void,
                         spawnWild: @escaping () -> Void,
                         spawnItem: @escaping (GameItem?) -> Void) -> [DebugSection] {
        [
            DebugSection(title: "즉시 배틀", actions: encounters.map { (title, dex) in
                DebugAction(title: title) { forceEncounter(dex > 0 ? dex : nil, nil) }
            }),
            DebugSection(title: "파티·아이템", actions: [
                DebugAction(title: "테스트 아이템 지급") { giveTestItems() },
                DebugAction(title: "파티 전체 회복") {
                    let st = RaisingState.shared
                    for i in st.party.indices { st.healMon(at: i) }
                },
                DebugAction(title: "활성 +1 레벨") { levelUpActive() },
                DebugAction(title: "활성 진화 레벨까지") { levelToEvolution() },
                DebugAction(title: "야생 스폰 (배회)") { spawnWild() },
                DebugAction(title: "필드 아이템: 랜덤") { spawnItem(nil) },
                DebugAction(title: "필드 아이템: 몬스터볼") { spawnItem(.pokeBall) },
            ]),
            // Switch / EXP-share / evolution-queue test bench: switch mid-
            // battle (defers to the turn boundary), then win — every
            // participant shares the EXP; the level-to-evolution actions
            // exercise the sequential evolution scenes (active mon first).
            DebugSection(title: "교체·경험치·진화 테스트", actions: [
                DebugAction(title: "다음 포켓몬으로 교체 (배틀 중: 턴 종료 후)") { switchToNext() },
                DebugAction(title: "파티 전원 +1 레벨") {
                    for i in RaisingState.shared.party.indices { levelUp(at: i) }
                },
                DebugAction(title: "파티 전원 진화 레벨까지") {
                    for i in RaisingState.shared.party.indices { levelToEvolution(at: i) }
                },
                DebugAction(title: "파티 전원 레벨업 1 남기기") {
                    for i in RaisingState.shared.party.indices { primeNearLevelUp(at: i) }
                },
            ]),
            // Forced status carries into the next battle, so the
            // skip/residual visuals are testable without RNG.
            DebugSection(title: "내 포켓몬 상태이상", actions: statuses.map { (title, key) in
                DebugAction(title: title) {
                    RaisingState.shared.setStatusDebug(key.isEmpty ? nil : key)
                }
            }),
        ]
    }

    // MARK: shared action bodies (were duplicated in AppDelegate + main.swift)

    private static func giveTestItems() {
        let st = RaisingState.shared
        st.addItem(.pokeBall, 5)
        st.addItem(.greatBall, 2)
        st.addItem(.potion, 3)
        st.addItem(.superPotion, 2)
        st.addItem(.fullHeal, 2)
        st.addItem(.revive, 2)
        for stone: GameItem in [.fireStone, .thunderStone, .waterStone, .leafStone,
                                .moonStone, .sunStone, .linkCord, .friendCandy] {
            st.addItem(stone, 1)
        }
    }

    /// Grant EXP through the real growth path (level-ups, move prompts,
    /// evolution scene) — exactly what a battle win's share would do.
    private static func gainExp(_ amount: Int, at idx: Int) {
        let st = RaisingState.shared
        guard st.save.party.indices.contains(idx), amount > 0 else { return }
        let result = st.gainExp(amount, at: idx)
        for moveId in result.pendingMoves {
            PromptRelay.enqueue(.learnMove(monIndex: idx, moveId: moveId))
        }
    }

    private static func levelUp(at idx: Int) {
        let st = RaisingState.shared
        guard st.save.party.indices.contains(idx) else { return }
        gainExp(st.party[idx].expToNext.remaining, at: idx)
    }

    private static func levelUpActive() {
        levelUp(at: RaisingState.shared.save.activeIndex)
    }

    /// Leave the member 1 EXP short of its next level — the smallest battle
    /// share then levels it up (benched level-up / prompt-order testing).
    private static func primeNearLevelUp(at idx: Int) {
        let st = RaisingState.shared
        guard st.save.party.indices.contains(idx) else { return }
        gainExp(st.party[idx].expToNext.remaining - 1, at: idx)
    }

    private static func levelToEvolution(at idx: Int) {
        let st = RaisingState.shared
        guard st.save.party.indices.contains(idx) else { return }
        let mon = st.party[idx]
        guard let s = mon.species, mon.level < 100 else { return }
        // Jump to the nearest LEVEL-evolution threshold above the current
        // level; species without one just gain a single level.
        let target = s.evolutions
            .filter { $0.method == "LEVEL" && $0.param1 > mon.level }
            .map(\.param1)
            .min()
        guard let target, s.expCurve.indices.contains(target - 1) else {
            levelUp(at: idx)
            return
        }
        gainExp(s.expCurve[target - 1] - mon.exp, at: idx)
    }

    private static func levelToEvolution() {
        levelToEvolution(at: RaisingState.shared.save.activeIndex)
    }

    /// Cycle the active follower to the next conscious member — mid-battle
    /// this queues the mainline turn-boundary switch (the real code path).
    private static func switchToNext() {
        let st = RaisingState.shared
        let n = st.party.count
        guard n > 1 else { return }
        let cur = max(0, st.save.activeIndex)
        for step in 1..<n {
            let i = (cur + step) % n
            if !st.party[i].isFainted { st.setActive(i); return }
        }
    }
}
