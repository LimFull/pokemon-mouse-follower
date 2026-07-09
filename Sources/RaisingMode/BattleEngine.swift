// Raising mode — auto turn-based battle engine (Phase 2, design D3/D4/D6/D19).
//
// Pure logic: given the player's active mon and a wild mon, it simulates a
// spectator auto-battle (simple AI, simplified mainline damage + type chart +
// STAB + accuracy) and returns a structured event log + EXP. Includes the full
// status set (D19): sleep/paralysis/poison/burn/freeze plus the volatile
// confusion/infatuation (gender-checked, D19-2). The on-overlay playback
// (Phase 2d) consumes the event log.

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

// MARK: - Status conditions (D19)

/// The five persistent ("major") conditions. They survive the battle on the
/// player's mon; a wild despawns with them. String raw values match the
/// PokeAPI ailment names bundled in moves.json and OwnedPokemon.status.
enum Ailment: String {
    case burn, poison, paralysis, sleep, freeze
}

// MARK: - Battler

final class Battler {
    let dex: Int
    let name: String
    let level: Int
    let type1: String
    let type2: String?
    let stats: Stats
    let gender: Gender
    let baseExp: Int
    var currentHP: Int
    let moves: [Int]

    // Status state (D19). `status` persists across battles for the player's mon;
    // the volatile pair below is battle-local.
    var status: Ailment?
    var sleepTurns = 0           // remaining turns asleep
    var confusionTurns = 0       // remaining turns confused (0 = not confused)
    var infatuated = false

    var maxHP: Int { stats.hp }
    var isFainted: Bool { currentHP <= 0 }
    /// Speed after status penalties (paralysis quarters it, gen-4 style).
    var effectiveSpeed: Int { status == .paralysis ? stats.spe / 4 : stats.spe }

    init(dex: Int, name: String, level: Int, type1: String, type2: String?,
         stats: Stats, gender: Gender, baseExp: Int, currentHP: Int, moves: [Int],
         status: Ailment? = nil) {
        self.dex = dex; self.name = name; self.level = level
        self.type1 = type1; self.type2 = type2; self.stats = stats
        self.gender = gender; self.baseExp = baseExp
        self.currentHP = currentHP; self.moves = moves.isEmpty ? [154] : moves
        self.status = status
        if status == .sleep { sleepTurns = Int.random(in: 1...3) }
    }

    convenience init?(mon: OwnedPokemon) {
        guard let s = mon.species else { return nil }
        self.init(dex: mon.dex, name: Characters.displayName(s.id), level: mon.level,
                  type1: s.type1, type2: s.type2, stats: GameData.stats(s, level: mon.level),
                  gender: mon.gender, baseExp: s.baseExp ?? 60,
                  currentHP: mon.currentHP, moves: mon.moves,
                  status: mon.status.flatMap(Ailment.init(rawValue:)))
    }

    /// A wild encounter of `dex` at `level`, full HP, level-appropriate moveset,
    /// ratio-respecting random gender (G).
    convenience init?(wildDex dex: Int, level: Int) {
        guard let s = GameData.species[dex] else { return nil }
        let st = GameData.stats(s, level: level)
        let mv = Array(s.levelUpMoves.filter { $0.level <= level }.map { $0.moveId }.suffix(4))
        self.init(dex: dex, name: Characters.displayName(s.id), level: level,
                  type1: s.type1, type2: s.type2, stats: st,
                  gender: Gender.random(genderRate: s.genderRate), baseExp: s.baseExp ?? 60,
                  currentHP: st.hp, moves: mv)
    }
}

// MARK: - Result

struct BattleEvent {
    enum Kind {
        case attack          // a move connected (damage and/or status)
        case miss            // a move was used but missed / had no effect
        case skip            // turn lost (asleep / frozen / paralyzed / infatuated)
        case selfHit         // hurt itself in confusion
        case residual        // end-of-round burn/poison chip damage
        case recover         // woke up / thawed / snapped out of confusion
        case ball            // a ball was thrown at the wild (D11)
    }
    let kind: Kind
    let actorIsPlayer: Bool     // whose action (or affliction) this is
    let moveId: Int             // 0 when not a move
    let moveName: String        // move, ball name, or a short reason ("asleep", ...)
    let damage: Int
    let effectiveness: Double   // 0 / 0.25 / 0.5 / 1 / 2 / 4 (1 when n/a)
    let targetIsPlayer: Bool    // whose HP/status changed
    let targetHP: Int
    let targetMaxHP: Int
    let fainted: Bool
    let statusApplied: String?  // ailment/volatile inflicted on the target, if any
    // Which simulated round this event belongs to. Turn order is recomputed
    // every round from effectiveSpeed (paralysis — and any future speed
    // changes — can flip it), so playback must use this stamp, never guess
    // boundaries from actor order. A mid-battle recall waits for the stamped
    // turn to finish (mainline flee timing).
    var turn: Int = 0
    var shakes: Int = 0         // .ball: how many of the 4 shake checks passed
    var caught: Bool = false    // .ball: capture succeeded
    var ballId: Int = 0         // .ball: GameItem raw value (for the icon)
    // Sleep snapshots at this moment — the playback keeps a sleeping side in
    // its sleep pose across everyone's beats (it only flinches when hit).
    var playerAsleep: Bool = false
    var wildAsleep: Bool = false
}

struct BattleResult {
    let playerWon: Bool
    let events: [BattleEvent]
    let expGained: Int
    let playerEndStatus: String?   // major ailment the player's mon carries out
    let playerEndHP: Int
    let playerMaxHP: Int
    var captured: Bool = false     // wild was caught (D11)
    var ballsUsed: [GameItem] = []
}

enum BattleEngine {
    /// Simulate the whole battle. `player`/`wild` HP are mutated to the end
    /// state. `balls` is the throwable stock (D11) — the player side throws
    /// one instead of attacking when the wild looks catchable (hurt or
    /// statused); capture ends the battle immediately.
    static func run(player: Battler, wild: Battler,
                    balls: [GameItem] = []) -> BattleResult {
        var events: [BattleEvent] = []
        var stock = balls
        var used: [GameItem] = []
        var captured = false
        var turn = 0
        while !player.isFainted && !wild.isFainted && !captured && turn < 200 {
            turn += 1
            // Faster mon acts first (paralysis-adjusted; ties: player).
            let playerFirst = player.effectiveSpeed >= wild.effectiveSpeed
            let order: [(Battler, Battler, Bool)] = playerFirst
                ? [(player, wild, true), (wild, player, false)]
                : [(wild, player, false), (player, wild, true)]
            for (atk, def, isPlayer) in order {
                guard !atk.isFainted, !def.isFainted, !captured else { continue }
                // Throw a ball instead of attacking when the wild is catchable:
                // hurt to half or carrying a status (max 3 throws per battle —
                // threshold sized so mainline-power hits don't skip the window).
                if isPlayer, !stock.isEmpty, used.count < 3,
                   wild.currentHP * 100 <= wild.maxHP * 50 || wild.status != nil {
                    let ball = stock.removeFirst()
                    used.append(ball)
                    let (ok, shakes) = attemptCapture(wild: wild, ball: ball)
                    captured = ok
                    events.append(BattleEvent(
                        kind: .ball, actorIsPlayer: true, moveId: 0,
                        moveName: ball.displayName, damage: 0, effectiveness: 1,
                        targetIsPlayer: false, targetHP: wild.currentHP,
                        targetMaxHP: wild.maxHP, fainted: false, statusApplied: nil,
                        turn: turn, shakes: shakes, caught: ok, ballId: ball.rawValue,
                        playerAsleep: player.status == .sleep,
                        wildAsleep: wild.status == .sleep))
                    continue
                }
                act(attacker: atk, defender: def, actorIsPlayer: isPlayer,
                    turn: turn, events: &events)
            }
            guard !captured else { break }
            // End-of-round chip damage (burn 1/16, poison 1/8).
            for (b, isPlayer) in [(player, true), (wild, false)] {
                guard !b.isFainted, let s = b.status, s == .burn || s == .poison else { continue }
                let dmg = max(1, b.maxHP / (s == .burn ? 16 : 8))
                b.currentHP = max(0, b.currentHP - dmg)
                events.append(BattleEvent(
                    kind: .residual, actorIsPlayer: isPlayer, moveId: 0, moveName: s.rawValue,
                    damage: dmg, effectiveness: 1, targetIsPlayer: isPlayer,
                    targetHP: b.currentHP, targetMaxHP: b.maxHP, fainted: b.isFainted,
                    statusApplied: nil, turn: turn,
                    playerAsleep: player.status == .sleep,
                    wildAsleep: wild.status == .sleep))
            }
        }
        let playerWon = !player.isFainted && wild.isFainted
        return BattleResult(
            playerWon: playerWon, events: events,
            expGained: playerWon ? expFor(defeated: wild) : 0,
            playerEndStatus: player.status?.rawValue,
            playerEndHP: player.currentHP, playerMaxHP: player.maxHP,
            captured: captured, ballsUsed: used)
    }

    /// One ball throw, mainline Gen-3/4 formula: modified rate from HP, catch
    /// rate, ball bonus and status bonus; then four 16-bit shake checks.
    /// Returns (caught, shakes passed 0...4).
    static func attemptCapture(wild: Battler, ball: GameItem) -> (Bool, Int) {
        let rate = Double(GameData.species[wild.dex]?.captureRate ?? 45)
        let m = Double(wild.maxHP), h = Double(max(1, wild.currentHP))
        var a = (3 * m - 2 * h) * rate * ball.ballBonus / (3 * m)
        switch wild.status {
        case .sleep, .freeze: a *= 2.0
        case .paralysis, .poison, .burn: a *= 1.5
        case nil: break
        }
        if a >= 255 { return (true, 4) }
        let b = 1048560.0 / (16711680.0 / max(1, a)).squareRoot().squareRoot()
        var shakes = 0
        for _ in 0..<4 {
            guard Double(Int.random(in: 0..<65536)) < b else { break }
            shakes += 1
        }
        return (shakes == 4, shakes)
    }

    /// One battler's action for the round: status gates, accuracy, damage, ailment.
    private static func act(attacker: Battler, defender: Battler,
                            actorIsPlayer: Bool, turn: Int, events: inout [BattleEvent]) {
        func emit(_ kind: BattleEvent.Kind, move: MoveData? = nil, reason: String = "",
                  damage: Int = 0, eff: Double = 1, targetIsPlayer: Bool? = nil,
                  status: String? = nil) {
            let tgtIsPlayer = targetIsPlayer ?? !actorIsPlayer
            let tgt = tgtIsPlayer == actorIsPlayer ? attacker : defender
            let player = actorIsPlayer ? attacker : defender
            let wild = actorIsPlayer ? defender : attacker
            events.append(BattleEvent(
                kind: kind, actorIsPlayer: actorIsPlayer,
                moveId: move?.moveId ?? 0, moveName: move?.displayName ?? reason,
                damage: damage, effectiveness: eff, targetIsPlayer: tgtIsPlayer,
                targetHP: tgt.currentHP, targetMaxHP: tgt.maxHP, fainted: tgt.isFainted,
                statusApplied: status, turn: turn,
                playerAsleep: player.status == .sleep, wildAsleep: wild.status == .sleep))
        }

        // --- major status action gates -------------------------------------
        switch attacker.status {
        case .sleep:
            attacker.sleepTurns -= 1
            if attacker.sleepTurns > 0 { emit(.skip, reason: "asleep"); return }
            attacker.status = nil
            emit(.recover, reason: "woke up", targetIsPlayer: actorIsPlayer)
        case .freeze:
            if Int.random(in: 0..<100) < 20 {
                attacker.status = nil
                emit(.recover, reason: "thawed", targetIsPlayer: actorIsPlayer)
            } else { emit(.skip, reason: "frozen"); return }
        case .paralysis:
            if Int.random(in: 0..<100) < 25 { emit(.skip, reason: "paralyzed"); return }
        default: break
        }

        // --- volatile gates -------------------------------------------------
        if attacker.confusionTurns > 0 {
            attacker.confusionTurns -= 1
            if attacker.confusionTurns == 0 {
                emit(.recover, reason: "snapped out", targetIsPlayer: actorIsPlayer)
            } else if Int.random(in: 0..<3) == 0 {
                // Hurt itself: typeless physical, power on the EoS scale (~40 mainline).
                let base = ((2.0 * Double(attacker.level) / 5.0 + 2.0) * 8.0
                            * Double(attacker.stats.atk) / Double(max(1, attacker.stats.def))) / 50.0 + 2.0
                let dmg = max(1, Int(base * Double.random(in: 0.85...1.0)))
                attacker.currentHP = max(0, attacker.currentHP - dmg)
                emit(.selfHit, reason: "hurt itself", damage: dmg, targetIsPlayer: actorIsPlayer)
                return
            }
        }
        if attacker.infatuated, Int.random(in: 0..<2) == 0 {
            emit(.skip, reason: "infatuated"); return
        }

        // --- pick + resolve the move ----------------------------------------
        let moveId = chooseMove(attacker: attacker, defender: defender)
        guard let m = GameData.moves[moveId] else { return }
        let eff = TypeChart.multiplier(m.type, vs: defender.type1, defender.type2)

        // Accuracy roll (EoS accuracy; values outside 1...100 always hit).
        if (1...100).contains(m.accuracy), Int.random(in: 1...100) > m.accuracy {
            emit(.miss, move: m); return
        }
        // Type immunity blocks damage and status alike (e.g. Thunder Wave on Ground).
        if eff == 0 { emit(.miss, move: m, eff: 0); return }

        var dmg = 0
        if m.power > 0 {
            dmg = computeDamage(attacker: attacker, defender: defender, move: m, eff: eff)
            defender.currentHP = max(0, defender.currentHP - dmg)
        }
        let inflicted = applyAilment(of: m, from: attacker, to: defender)
        if m.power <= 0 && inflicted == nil {
            // A status move that changed nothing (already statused / gender fail).
            emit(.miss, move: m); return
        }
        emit(.attack, move: m, damage: dmg, eff: eff, status: inflicted)
    }

    /// Try to inflict `m`'s ailment on `def`; returns its name when applied.
    private static func applyAilment(of m: MoveData, from atk: Battler, to def: Battler) -> String? {
        guard let name = m.ailment, !def.isFainted,
              Int.random(in: 1...100) <= m.effectiveAilmentChance else { return nil }
        switch name {
        case "confusion":
            guard def.confusionTurns == 0 else { return nil }
            def.confusionTurns = Int.random(in: 2...5)
            return name
        case "infatuation":
            // Opposite genders only (D19-2); genderless never qualifies.
            let ok = (atk.gender == .male && def.gender == .female)
                  || (atk.gender == .female && def.gender == .male)
            guard ok, !def.infatuated else { return nil }
            def.infatuated = true
            return name
        default:
            guard let ail = Ailment(rawValue: name), def.status == nil else { return nil }
            // Type-based immunities: Fire can't burn, Electric can't be paralyzed
            // by electric moves is a gen-6 rule — keep just the classic pair.
            if ail == .burn, def.type1 == "Fire" || def.type2 == "Fire" { return nil }
            if ail == .poison, ["Poison", "Steel"].contains(def.type1) ||
                               ["Poison", "Steel"].contains(def.type2 ?? "") { return nil }
            if ail == .freeze, def.type1 == "Ice" || def.type2 == "Ice" { return nil }
            def.status = ail
            if ail == .sleep { def.sleepTurns = Int.random(in: 1...3) }
            return name
        }
    }

    /// Mainline wild-Pokémon behavior: no AI, a uniformly random pick from the
    /// known moves (no PP — moves are usable without limit, by design). Only
    /// moves that can DO something in this engine are candidates — damaging
    /// moves always; a status move only while its (supported) ailment could
    /// still land (unimplemented stat-stage moves like Tail Whip would just
    /// burn the turn, so they're excluded).
    static func chooseMove(attacker: Battler, defender: Battler) -> Int {
        let usable = attacker.moves.filter { id in
            guard let m = GameData.moves[id] else { return false }
            if m.power > 0 { return true }
            switch m.ailment {
            case "confusion": return defender.confusionTurns == 0
            case "infatuation": return !defender.infatuated
            case .some(let a) where Ailment(rawValue: a) != nil: return defender.status == nil
            default: return false
            }
        }
        return usable.randomElement() ?? attacker.moves.first ?? 154
    }

    /// Simplified mainline damage: level/stat/power scaling × STAB × type × random,
    /// with mainline base powers (effectivePower). Burn halves physical attack (D19).
    static func computeDamage(attacker: Battler, defender: Battler, move m: MoveData, eff: Double) -> Int {
        let physical = m.category == "Physical"
        var a = Double(physical ? attacker.stats.atk : attacker.stats.spAtk)
        if physical && attacker.status == .burn { a /= 2 }
        let d = Double(max(1, physical ? defender.stats.def : defender.stats.spDef))
        let base = ((2.0 * Double(attacker.level) / 5.0 + 2.0) * Double(m.effectivePower) * a / d) / 50.0 + 2.0
        let stab = (m.type == attacker.type1 || m.type == attacker.type2) ? 1.5 : 1.0
        let rand = Double.random(in: 0.85...1.0)
        return max(1, Int(base * stab * eff * rand))
    }

    /// EXP for a win: the mainline formula, base experience × level / 7 (D6-1).
    static func expFor(defeated: Battler) -> Int {
        max(1, defeated.baseExp * defeated.level / 7)
    }
}
