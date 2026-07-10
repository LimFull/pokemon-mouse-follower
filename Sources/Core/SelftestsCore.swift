// Debug hook: `--selftest-core` exercises the platform-neutral core (game
// data, growth/evolution, one battle, battle-log composition, save write)
// against the bundled resources, prints a PASS/FAIL report, and exits. Runs
// identically on macOS and Windows — the parity gate for CI (W15/W18).

import Foundation

func runCoreSelftestsIfRequested() {
    runParityDumpIfRequested()   // --dump-parity <seed> (exits in here)
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

// MARK: - Cross-OS parity fixture (design/windows-port.md W18-②)

/// `--dump-parity <seed>`: run a fixed set of seeded battles and print one
/// normalized line per event. CI runs this on macOS and Windows with the same
/// seed and diffs the outputs — the engine is shared code, so any divergence
/// (Foundation numerics, RNG, dictionary ordering) fails the build. Output is
/// locale-independent by construction: dex numbers, enum case names and
/// fixed-format floats only. Touches no save state.
func runParityDumpIfRequested() {
    guard let i = CommandLine.arguments.firstIndex(of: "--dump-parity"),
          CommandLine.arguments.count > i + 1,
          let seed = UInt64(CommandLine.arguments[i + 1]) else { return }

    // (player dex, level) vs (wild dex, level), plus the follower's ball
    // stock — statused kinds, Transform, Sketch, captures and level spreads.
    let matchups: [(p: Int, pl: Int, w: Int, wl: Int, balls: [GameItem])] = [
        (1, 5, 16, 4, []),
        (4, 8, 19, 7, []),
        (7, 10, 10, 5, []),
        (25, 20, 16, 18, []),     // paralysis kit
        (96, 22, 25, 20, []),     // hypnosis
        (37, 18, 152, 16, []),    // burn
        (132, 25, 16, 20, []),    // Transform
        (235, 12, 19, 10, []),    // Smeargle -> Struggle
        (2, 20, 5, 20, []),
        (3, 40, 6, 40, []),
        (9, 45, 34, 42, []),
        (150, 70, 149, 65, []),
        (94, 35, 65, 33, []),
        (130, 30, 59, 28, []),
        (143, 40, 68, 38, []),
        (23, 14, 43, 12, []),     // poison
        (124, 28, 126, 26, []),   // ice + infatuation
        (120, 15, 54, 14, []),
        (25, 30, 16, 5, [.pokeBall, .pokeBall, .pokeBall, .greatBall]),   // capture
        (6, 50, 147, 20, [.greatBall, .greatBall]),                       // capture
    ]

    guard GameData.species.count > 0 else {
        print("PARITY ERROR: game data missing")
        exit(2)
    }
    print("PARITY v1 seed=\(seed) species=\(GameData.species.count) moves=\(GameData.moves.count)")

    for (n, m) in matchups.enumerated() {
        // Reseed per battle so one battle's roll count can't shift the rest.
        BattleRNG.reseed(seed &+ UInt64(n))
        guard let p = Battler(wildDex: m.p, level: m.pl),
              let w = Battler(wildDex: m.w, level: m.wl) else {
            print("B\(n)|SKIP p\(m.p)@\(m.pl) w\(m.w)@\(m.wl)")
            continue
        }
        print("B\(n)|p\(m.p)@\(m.pl)|w\(m.w)@\(m.wl)|balls=\(m.balls.map { String($0.rawValue) }.joined(separator: ","))")
        let r = BattleEngine.run(player: p, wild: w, balls: m.balls)
        for e in r.events {
            let eff = String(format: "%.4f", e.effectiveness)
            print("E|t\(e.turn)|\(e.kind)|a\(e.actorIsPlayer ? 1 : 0)|m\(e.moveId)|d\(e.damage)|x\(eff)"
                + "|tg\(e.targetIsPlayer ? 1 : 0)|hp\(e.targetHP)/\(e.targetMaxHP)|f\(e.fainted ? 1 : 0)"
                + "|s\(e.statusApplied ?? "-")|c\(e.crit ? 1 : 0)|sh\(e.shakes)|ct\(e.caught ? 1 : 0)|b\(e.ballId)")
        }
        print("R|won\(r.playerWon ? 1 : 0)|exp\(r.expGained)|cap\(r.captured ? 1 : 0)"
            + "|pf\(r.playerFled ? 1 : 0)|wf\(r.wildFled ? 1 : 0)"
            + "|hp\(r.playerEndHP)/\(r.playerMaxHP)|s\(r.playerEndStatus ?? "-")"
            + "|balls\(r.ballsUsed.map { String($0.rawValue) }.joined(separator: ","))")
    }
    print("PARITY END")
    exit(0)
}
