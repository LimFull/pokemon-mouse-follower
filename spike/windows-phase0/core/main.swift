// Phase 0 spike ①: compile the six Foundation-only core files unmodified on
// Windows and run a mini selftest (game data load, growth+evolution, one
// battle, battle-log composition, save roundtrip). Mirrors the headless part
// of Selftests.swift.

import Foundation

var failures = 0
func check(_ cond: Bool, _ label: String) {
    print("\(cond ? "PASS" : "FAIL")  \(label)")
    if !cond { failures += 1 }
}

print("=== PMF Windows core spike ===")
print("Bundle.main.resourceURL: \(Bundle.main.resourceURL?.path ?? "nil")")
let appSup = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
print("applicationSupportDirectory: \(appSup?.path ?? "nil")")
check(appSup != nil, "applicationSupportDirectory resolves")

// 1. Localization via custom .strings parser (W10 probe)
print("strings table entries: \(stringsTable.count)")
let crit = L("log.crit")
print("L(\"log.crit\") = \(crit)")
check(crit != "log.crit", "ko .strings parsed and key resolves")
print("displayName(dex 25) = \(Characters.displayName(dex: 25))")
check(Characters.displayName(dex: 25) != "pokemon.025", "localized species name resolves")

// 2. Game data from Bundle.main (W12 probe)
print("GameData: species=\(GameData.species.count) moves=\(GameData.moves.count) starters=\(GameData.starters.count) typechart=\(TypeChart.chart.count)")
check(GameData.species.count == 251, "species.json loaded (251)")
check(GameData.moves.count > 500, "moves.json loaded")
check(TypeChart.chart.count >= 17, "typechart.json loaded")

// 3. Raising state: new game, growth, evolution
guard let saveDir = ProcessInfo.processInfo.environment["PMF_SAVE_DIR"] else {
    print("FAIL  PMF_SAVE_DIR not set — refusing to touch a real save")
    exit(2)
}
let st = RaisingState.shared
st.reset()
st.startNewGame(dex: 1)
check(st.active != nil, "startNewGame -> active mon")
if let m = st.active {
    print("start: dex=\(m.dex) Lv\(m.level) HP=\(m.currentHP)/\(m.maxHP) moves=\(m.moves)")
}
st.setActive(0)
let g = st.gainExp(50000)
if let m = st.active {
    let evo = (g.evolvedFrom != nil) ? "\(g.evolvedFrom!)->\(g.evolvedTo!)" : "none"
    print("train: Lv\(m.level) dex=\(m.dex) \(Characters.displayName(dex: m.dex)) evolved=\(evo)")
    check(m.level > 5, "gainExp levels up")
    check(g.evolvedTo != nil, "L16 evolution fired")
}

// 4. One battle + battle-log composition
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
    for l in logs.prefix(3) { print("  log: \(l)") }
}

// 5. Save roundtrip (%APPDATA%-style dir handled by PMF_SAVE_DIR; non-ASCII path)
let saveFile = URL(fileURLWithPath: saveDir, isDirectory: true).appendingPathComponent("raising.json")
check(FileManager.default.fileExists(atPath: saveFile.path), "save file written: \(saveFile.path)")
if let data = try? Data(contentsOf: saveFile) {
    print("save file size: \(data.count) bytes")
    check(data.count > 100, "save file non-trivial")
}

// 6. DateFormatter smoke (PartyState uses it)
let df = DateFormatter()
df.dateFormat = "yyyy-MM-dd HH:mm"
let stamp = df.string(from: Date(timeIntervalSince1970: 0))
print("DateFormatter: \(stamp)")
check(stamp.hasPrefix("19"), "DateFormatter works")

print(failures == 0 ? "=== ALL PASS ===" : "=== \(failures) FAILURES ===")
exit(failures == 0 ? 0 : 1)
