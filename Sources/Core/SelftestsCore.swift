// Debug hook: `--selftest-core` exercises the platform-neutral core (game
// data, growth/evolution, one battle, battle-log composition, save write)
// against the bundled resources, prints a PASS/FAIL report, and exits. Runs
// identically on macOS and Windows — the parity gate for CI (W15/W18).

import Foundation

func runCoreSelftestsIfRequested() {
    guard CommandLine.arguments.contains("--selftest-core") else { return }
    // The selftest RESETS the party. Refuse to touch the real save: it only
    // runs against a scratch directory (PMF_SAVE_DIR redirects persistence).
    guard let saveDir = ProcessInfo.processInfo.environment["PMF_SAVE_DIR"] else {
        print("refusing --selftest-core: it resets the save. Set PMF_SAVE_DIR to a scratch directory first.")
        exit(2)
    }

    var failures = 0
    func check(_ cond: Bool, _ label: String) {
        print("\(cond ? "PASS" : "FAIL")  \(label)")
        if !cond { failures += 1 }
    }

    print("=== core selftest ===")
    print("resources: \(Resources.root.path)")
    print("language: \(Localization.pickLanguage())")

    // Localization: the shared .strings parser resolves keys.
    check(L("log.crit") != "log.crit", "strings table resolves (log.crit = \(L("log.crit")))")

    // Game data from the bundle.
    print("GameData: species=\(GameData.species.count) moves=\(GameData.moves.count) starters=\(GameData.starters.count) typechart=\(TypeChart.chart.count)")
    check(GameData.species.count == 251, "species.json loaded (251)")
    check(GameData.moves.count > 500, "moves.json loaded")
    check(TypeChart.chart.count >= 17, "typechart.json loaded")

    // Raising state: new game, growth, L16 evolution.
    let st = RaisingState.shared
    st.reset()
    st.startNewGame(dex: 1)
    check(st.active != nil, "startNewGame -> active mon")
    st.setActive(0)
    let g = st.gainExp(50000)
    if let m = st.active {
        let evo = (g.evolvedFrom != nil) ? "\(g.evolvedFrom!)->\(g.evolvedTo!)" : "none"
        print("train: Lv\(m.level) dex=\(m.dex) \(Characters.displayName(dex: m.dex)) evolved=\(evo)")
        check(m.level > 5, "gainExp levels up")
        check(g.evolvedTo != nil, "L16 evolution fired")
    }

    // One battle + battle-log composition (no unresolved localization keys).
    if let p = Battler(mon: st.active!), let w = Battler(wildDex: 16, level: 12) {
        let r = BattleEngine.run(player: p, wild: w)
        print("battle: \(p.name) L\(p.level) vs wild \(w.name) L\(w.level) -> \(r.playerWon ? "WIN" : "LOSE") in \(r.events.count) events, exp=\(r.expGained)")
        check(!r.events.isEmpty, "battle produced events")
        let turns = r.events.map(\.turn)
        check(zip(turns, turns.dropFirst()).allSatisfy { $0 <= $1 }, "turn stamps monotonic")
        var logs = [BattleLog.battleStart(wildName: w.name)]
        logs += r.events.flatMap { BattleLog.lines(for: $0, playerName: p.name, wildName: w.name) }
                        .map { $0.text }
        let unresolved = logs.filter { $0.contains("log.") }
        check(unresolved.isEmpty, "battle log resolves all keys (\(logs.count) lines)")
    } else {
        check(false, "battlers construct")
    }

    // Save landed in the scratch directory.
    let saveFile = URL(fileURLWithPath: saveDir, isDirectory: true).appendingPathComponent("raising.json")
    check(FileManager.default.fileExists(atPath: saveFile.path), "save file written")

    print(failures == 0 ? "=== core selftest: ALL PASS ===" : "=== core selftest: \(failures) FAILURES ===")
    exit(failures == 0 ? 0 : 1)
}
