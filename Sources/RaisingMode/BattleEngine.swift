// Raising mode — auto turn-based battle engine (Phase 2, design D3/D4/D6).
//
// Pure logic: given the player's active mon and a wild mon, it simulates a
// spectator auto-battle (simple AI, simplified mainline damage + type chart +
// STAB) and returns a structured event log + EXP. Status conditions (D19) and
// the on-overlay playback (Phase 2d) build on this.

import Foundation

// MARK: - Type chart (mainline, from gamedata/typechart.json)

enum TypeChart {
    static let chart: [String: [String: Double]] = load()

    /// Effectiveness of `moveType` against a defender's type(s).
    static func multiplier(_ moveType: String?, vs t1: String, _ t2: String?) -> Double {
        let row = chart[moveType ?? "Neutral"] ?? [:]
        var m = row[t1] ?? 1.0
        if let t2, t2 != "None", !t2.isEmpty { m *= row[t2] ?? 1.0 }
        return m
    }

    private static func load() -> [String: [String: Double]] {
        guard let u = Bundle.main.url(forResource: "typechart", withExtension: "json", subdirectory: "gamedata"),
              let d = try? Data(contentsOf: u),
              let j = try? JSONDecoder().decode([String: [String: Double]].self, from: d)
        else { NSLog("[TypeChart] load failed"); return [:] }
        return j
    }
}

// MARK: - Battler

final class Battler {
    let dex: Int
    let name: String
    let level: Int
    let type1: String
    let type2: String?
    let stats: Stats
    var currentHP: Int
    let moves: [Int]

    var maxHP: Int { stats.hp }
    var isFainted: Bool { currentHP <= 0 }

    init(dex: Int, name: String, level: Int, type1: String, type2: String?,
         stats: Stats, currentHP: Int, moves: [Int]) {
        self.dex = dex; self.name = name; self.level = level
        self.type1 = type1; self.type2 = type2; self.stats = stats
        self.currentHP = currentHP; self.moves = moves.isEmpty ? [154] : moves
    }

    convenience init?(mon: OwnedPokemon) {
        guard let s = mon.species else { return nil }
        self.init(dex: mon.dex, name: Characters.displayName(s.id), level: mon.level,
                  type1: s.type1, type2: s.type2, stats: GameData.stats(s, level: mon.level),
                  currentHP: mon.currentHP, moves: mon.moves)
    }

    /// A wild encounter of `dex` at `level`, full HP, level-appropriate moveset.
    convenience init?(wildDex dex: Int, level: Int) {
        guard let s = GameData.species[dex] else { return nil }
        let st = GameData.stats(s, level: level)
        let mv = Array(s.levelUpMoves.filter { $0.level <= level }.map { $0.moveId }.suffix(4))
        self.init(dex: dex, name: Characters.displayName(s.id), level: level,
                  type1: s.type1, type2: s.type2, stats: st, currentHP: st.hp, moves: mv)
    }
}

// MARK: - Result

struct BattleEvent {
    let playerActed: Bool       // true = player's mon attacked
    let moveId: Int
    let moveName: String
    let damage: Int
    let effectiveness: Double   // 0 / 0.25 / 0.5 / 1 / 2 / 4
    let defenderHP: Int
    let defenderMaxHP: Int
    let fainted: Bool
}

struct BattleResult {
    let playerWon: Bool
    let events: [BattleEvent]
    let expGained: Int
}

enum BattleEngine {
    /// Simulate the whole battle. `player`/`wild` HP are mutated to the end state.
    static func run(player: Battler, wild: Battler) -> BattleResult {
        var events: [BattleEvent] = []
        var turn = 0
        while !player.isFainted && !wild.isFainted && turn < 200 {
            turn += 1
            // Faster mon acts first (ties: player).
            let playerFirst = player.stats.spe >= wild.stats.spe
            let order: [(Battler, Battler, Bool)] = playerFirst
                ? [(player, wild, true), (wild, player, false)]
                : [(wild, player, false), (player, wild, true)]
            for (atk, def, isPlayer) in order {
                guard !atk.isFainted, !def.isFainted else { continue }
                let moveId = chooseMove(attacker: atk, defender: def)
                let (dmg, eff) = computeDamage(attacker: atk, defender: def, moveId: moveId)
                def.currentHP = max(0, def.currentHP - dmg)
                events.append(BattleEvent(
                    playerActed: isPlayer, moveId: moveId,
                    moveName: GameData.moves[moveId]?.displayName ?? "Move \(moveId)",
                    damage: dmg, effectiveness: eff,
                    defenderHP: def.currentHP, defenderMaxHP: def.maxHP, fainted: def.isFainted))
            }
        }
        let playerWon = !player.isFainted && wild.isFainted
        return BattleResult(playerWon: playerWon, events: events,
                            expGained: playerWon ? expFor(defeatedLevel: wild.level) : 0)
    }

    /// Pick the move with the best expected damage (power × type × STAB).
    static func chooseMove(attacker: Battler, defender: Battler) -> Int {
        var best = attacker.moves.first ?? 154
        var bestScore = -1.0
        for id in attacker.moves {
            guard let m = GameData.moves[id] else { continue }
            let eff = TypeChart.multiplier(m.type, vs: defender.type1, defender.type2)
            let stab = (m.type == attacker.type1 || m.type == attacker.type2) ? 1.5 : 1.0
            let score = Double(max(m.power, 1)) * eff * stab
            if score > bestScore { bestScore = score; best = id }
        }
        return best
    }

    /// Simplified mainline damage: level/stat/power scaling × STAB × type × random.
    static func computeDamage(attacker: Battler, defender: Battler, moveId: Int) -> (Int, Double) {
        guard let m = GameData.moves[moveId], m.power > 0 else { return (0, 1) }
        let eff = TypeChart.multiplier(m.type, vs: defender.type1, defender.type2)
        if eff == 0 { return (0, 0) }
        let physical = m.category == "Physical"
        let a = physical ? attacker.stats.atk : attacker.stats.spAtk
        let d = max(1, physical ? defender.stats.def : defender.stats.spDef)
        let base = ((2.0 * Double(attacker.level) / 5.0 + 2.0) * Double(m.power) * Double(a) / Double(d)) / 50.0 + 2.0
        let stab = (m.type == attacker.type1 || m.type == attacker.type2) ? 1.5 : 1.0
        let rand = Double.random(in: 0.85...1.0)
        return (max(1, Int(base * stab * eff * rand)), eff)
    }

    /// EXP for a win. Placeholder scaling until base_experience is bundled (D6-1).
    static func expFor(defeatedLevel: Int) -> Int { max(1, defeatedLevel * 10) }
}
