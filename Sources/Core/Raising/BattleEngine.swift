// Raising mode — auto turn-based battle engine (Phase 2, design D3/D4/D6/D19).
//
// Pure logic: given the player's active mon and a wild mon, it simulates a
// spectator auto-battle and returns a structured event log + EXP. Implements
// the full status set (D19), stat stages, priority brackets and the special
// move mechanics table (MoveMechanics) — fixed damage, OHKO, counters, drains,
// recoil, multi-hits, two-turn moves, heals, screens, seeds/traps, Transform,
// Metronome and friends. A mon with no usable move Struggles, mainline-style.
// The on-overlay playback (Phase 2d) consumes the event log.

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
        guard let u = Resources.url("typechart", ext: "json", subdir: "gamedata"),
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
    var type1: String            // var: Transform copies the foe's typing
    var type2: String?
    var stats: Stats             // var: Transform copies everything but HP
    let gender: Gender
    let baseExp: Int
    var currentHP: Int
    var moves: [Int]             // var: Mimic/Sketch rewrite a slot battle-locally
    var disabledMoves: Set<Int> = []   // PMD-style OFF toggles (player's mon only)

    // Status state (D19). `status` persists across battles for the player's mon;
    // everything below it is battle-local.
    var status: Ailment?
    var sleepTurns = 0           // remaining turns asleep
    var confusionTurns = 0       // remaining turns confused (0 = not confused)
    var infatuated = false

    // Battle-local mechanics state (the Battler itself is per-battle).
    var stages: [BattleStat: Int] = [:]
    var mustRecharge = false     // Hyper Beam family aftermath
    var chargingMove: Int? = nil // two-turn move wound up last turn
    var bideTurns = 0
    var bideStored = 0
    var physicalTakenThisRound = 0
    var specialTakenThisRound = 0
    var actedThisRound = false
    var destinyBond = false
    var safeguardRounds = 0
    var mistRounds = 0
    var reflectRounds = 0
    var lightScreenRounds = 0
    var seeded = false           // Leech Seed
    var trapRounds = 0           // Wrap/Bind/Fire Spin chip
    var ghostCursed = false
    var nightmared = false
    var yawnCounter = 0          // 2 → 1 → falls asleep
    var perishCount = -1         // ≥0: faints when it hits 0
    var lastMoveUsed: Int? = nil
    var transformed = false
    // wave 2: crit/evasion package, move-choice control, type shifts
    var critStage = 0            // Focus Energy
    var luckyChantRounds = 0     // foe can't crit this side
    var identified = false       // Foresight/Odor Sleuth landed on it
    var miracleEyed = false
    var lockedOnRounds = 0       // its own attacks can't miss
    var disabledMove: Int? = nil
    var disabledRounds = 0
    var encoreMove: Int? = nil
    var encoreRounds = 0
    var tauntRounds = 0
    var imprisonActive = false
    var magicCoatTurn = 0        // the round its coat is up
    var magnetRiseRounds = 0
    var aquaRing = false
    var stockpileCount = 0
    var healBlockRounds = 0

    var maxHP: Int { stats.hp }
    var isFainted: Bool { currentHP <= 0 }

    func stage(_ s: BattleStat) -> Int { stages[s] ?? 0 }
    /// Clamped stage bump; returns the delta actually applied.
    @discardableResult
    func bump(_ s: BattleStat, _ delta: Int) -> Int {
        let cur = stage(s)
        let next = max(-6, min(6, cur + delta))
        stages[s] = next
        return next - cur
    }

    /// Speed after stages and status (paralysis quarters it, gen-4 style).
    var effectiveSpeed: Int {
        let s = Double(stats.spe) * MoveMechanics.stageMultiplier(stage(.spe))
        return status == .paralysis ? Int(s) / 4 : Int(s)
    }

    init(dex: Int, name: String, level: Int, type1: String, type2: String?,
         stats: Stats, gender: Gender, baseExp: Int, currentHP: Int, moves: [Int],
         status: Ailment? = nil) {
        self.dex = dex; self.name = name; self.level = level
        self.type1 = type1; self.type2 = type2; self.stats = stats
        self.gender = gender; self.baseExp = baseExp
        self.currentHP = currentHP; self.moves = moves.isEmpty ? [154] : moves
        self.status = status
        if status == .sleep { sleepTurns = Int.random(in: 1...3, using: &BattleRNG.g) }
    }

    convenience init?(mon: OwnedPokemon) {
        guard let s = mon.species else { return nil }
        self.init(dex: mon.dex, name: Characters.displayName(s.id), level: mon.level,
                  type1: s.type1, type2: s.type2, stats: GameData.stats(s, level: mon.level),
                  gender: mon.gender, baseExp: s.baseExp ?? 60,
                  currentHP: mon.currentHP, moves: mon.moves,
                  status: mon.status.flatMap(Ailment.init(rawValue:)))
        disabledMoves = Set(mon.disabledMoves ?? [])
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

    /// A wild battler at the END of a battle: same identity (species, level,
    /// gender), carried HP and major ailment — every battle-local effect gone.
    /// Transform/Mimic overwrote stats/types/moves in place, so they are
    /// recomputed from species data — mainline behavior, where Transform ends
    /// with the battle. Used for rematches and for the caught mon.
    convenience init?(resetting w: Battler) {
        guard let s = GameData.species[w.dex] else { return nil }
        let st = GameData.stats(s, level: w.level)
        let mv = Array(s.levelUpMoves.filter { $0.level <= w.level }.map { $0.moveId }.suffix(4))
        self.init(dex: w.dex, name: w.name, level: w.level,
                  type1: s.type1, type2: s.type2, stats: st,
                  gender: w.gender, baseExp: w.baseExp,
                  currentHP: min(w.currentHP, st.hp), moves: mv,
                  status: w.status)
    }
}

// MARK: - Result

struct BattleEvent {
    enum Kind {
        case attack          // a move connected (damage and/or status/stages)
        case miss            // a move was used but missed / had no effect
        case skip            // turn lost (asleep/frozen/... or charging/recharging)
        case selfHit         // hurt itself (confusion, recoil, crash, self-pay)
        case item            // the trainer used a healing item on the follower
        case residual        // end-of-round chip damage (burn/poison/seed/trap/curse)
        case recover         // woke up / thawed / snapped out / HP restored
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
    let statusApplied: String?  // ailment inflicted, or a display tag ("DEF -1")
    // Which simulated round this event belongs to. Turn order is recomputed
    // every round (speed stages and priority can flip it), so playback must
    // use this stamp, never guess boundaries from actor order. A mid-battle
    // recall waits for the stamped turn to finish (mainline flee timing).
    var turn: Int = 0
    var crit: Bool = false      // .attack: a critical hit landed
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
    var playerFled: Bool = false   // Teleport, or blown out by Roar/Whirlwind
    var wildFled: Bool = false     // the wild escaped — it leaves, no EXP
    var wildFainted: Bool = false  // the wild went down too (double KO, e.g. Explosion)
}

/// A stepwise battle: one nextRound() call simulates one round, so playback
/// can feed mid-battle decisions (healing items) in between rounds.
/// BattleEngine.run wraps it for one-shot simulations.
final class BattleSession {
    let player: Battler
    let wild: Battler
    private var stock: [GameItem]
    private(set) var used: [GameItem] = []
    private(set) var captured = false
    private(set) var playerFled = false
    private(set) var wildFled = false
    private(set) var turn = 0
    private(set) var allEvents: [BattleEvent] = []
    private var roundEvents: [BattleEvent] = []
    // Delayed effects: (resolveAtRoundEnd, damage>0 hit / damage<0 heal, target)
    private var pending: [(round: Int, amount: Int, targetIsPlayer: Bool, name: String)] = []

    init(player: Battler, wild: Battler, balls: [GameItem] = []) {
        self.player = player
        self.wild = wild
        self.stock = balls
    }

    /// Replace the remaining ball stock mid-battle — the bag's capture toggle
    /// is live, so the controller re-syncs this at every round boundary.
    func setBallStock(_ balls: [GameItem]) { stock = balls }

    var isOver: Bool {
        player.isFainted || wild.isFainted || captured || playerFled || wildFled || turn >= 200
    }

    func makeResult() -> BattleResult {
        let playerWon = !player.isFainted && wild.isFainted
        return BattleResult(
            playerWon: playerWon, events: allEvents,
            expGained: playerWon ? BattleEngine.expFor(defeated: wild) : 0,
            playerEndStatus: player.status?.rawValue,
            playerEndHP: player.currentHP, playerMaxHP: player.maxHP,
            captured: captured, ballsUsed: used,
            playerFled: playerFled, wildFled: wildFled,
            wildFainted: wild.isFainted)
    }

        func emit(_ kind: BattleEvent.Kind, actorIsPlayer: Bool, move: MoveData? = nil,
                  reason: String = "", damage: Int = 0, eff: Double = 1,
                  targetIsPlayer: Bool? = nil, status: String? = nil, crit: Bool = false) {
            let tgtIsPlayer = targetIsPlayer ?? !actorIsPlayer
            let tgt = tgtIsPlayer ? player : wild
            let ev = BattleEvent(
                kind: kind, actorIsPlayer: actorIsPlayer,
                moveId: move?.moveId ?? 0, moveName: move?.displayName ?? reason,
                damage: damage, effectiveness: eff, targetIsPlayer: tgtIsPlayer,
                targetHP: tgt.currentHP, targetMaxHP: tgt.maxHP, fainted: tgt.isFainted,
                statusApplied: status, turn: turn, crit: crit,
                playerAsleep: player.status == .sleep, wildAsleep: wild.status == .sleep)
            roundEvents.append(ev)
            allEvents.append(ev)
        }

        /// Type effectiveness with the identification/levitation overrides:
        /// Magnet Rise blanks Ground; Foresight opens Ghost to Normal/Fighting
        /// and Miracle Eye opens Dark to Psychic (blocked component → neutral).
        func effectiveness(_ m: MoveData, _ def: Battler) -> Double {
            if m.type == "Ground", def.magnetRiseRounds > 0 { return 0 }
            var e = TypeChart.multiplier(m.type, vs: def.type1, def.type2)
            if e == 0 {
                let ghostOpen = def.identified && (m.type == "Normal" || m.type == "Fighting")
                    && (def.type1 == "Ghost" || def.type2 == "Ghost")
                let darkOpen = def.miracleEyed && m.type == "Psychic"
                    && (def.type1 == "Dark" || def.type2 == "Dark")
                if ghostOpen || darkOpen {
                    let blocker = ghostOpen ? "Ghost" : "Dark"
                    let otherType = def.type1 == blocker ? (def.type2 ?? "None") : def.type1
                    e = TypeChart.multiplier(m.type, vs: otherType, nil)
                    if e == 0 { e = 1 }
                }
            }
            return e
        }

        /// Critical roll: stage 0..4 → 1/16, 1/8, 1/4, 1/3, 1/2 (Gen 2 table).
        func rollCrit(_ atk: Battler, _ def: Battler, _ m: MoveData) -> Bool {
            guard def.luckyChantRounds == 0 else { return false }
            let stage = min(4, atk.critStage + MoveMechanics.critBonus(of: m.moveId))
            let denominators: [Double] = [16, 8, 4, 3, 2]
            return Double.random(in: 0..<1, using: &BattleRNG.g) < 1.0 / denominators[stage]
        }

        /// Apply direct move damage: records counter/bide bookkeeping and
        /// resolves Destiny Bond when the hit is fatal.
        func dealDamage(_ dmg: Int, from atk: Battler, to def: Battler, physical: Bool) {
            def.currentHP = max(0, def.currentHP - dmg)
            if physical { def.physicalTakenThisRound += dmg }
            else { def.specialTakenThisRound += dmg }
            if def.bideTurns > 0 { def.bideStored += dmg }
            if def.isFainted && def.destinyBond {
                atk.currentHP = 0
                emit(.selfHit, actorIsPlayer: atk === player, reason: "Destiny Bond",
                     damage: atk.maxHP, targetIsPlayer: atk === player, status: "Destiny Bond!")
            }
        }

        /// Accuracy roll with acc/eva stages (moves outside 1...100 always hit).
        /// Lock-On bypasses everything; an identified target loses its evasion.
        func rolls(_ m: MoveData, _ atk: Battler, _ def: Battler) -> Bool {
            if atk.lockedOnRounds > 0 { return true }
            guard (1...100).contains(m.accuracy) else { return true }
            let eva = (def.identified || def.miracleEyed) ? min(0, def.stage(.eva)) : def.stage(.eva)
            let stage = max(-6, min(6, atk.stage(.acc) - eva))
            let chance = Double(m.accuracy) * MoveMechanics.accuracyMultiplier(stage)
            return Double.random(in: 0..<100, using: &BattleRNG.g) < chance
        }

        func statTag(_ list: [(BattleStat, Int)]) -> String {
            list.map { "\($0.0.label) \($0.1 > 0 ? "+" : "")\($0.1)" }.joined(separator: " ")
        }

        /// One battler's action for the round. `planned` is the pre-picked move
        /// (nil = a forced non-move turn like recharging).
        func act(_ atk: Battler, _ def: Battler, isPlayer: Bool, planned: Int?) {
            atk.actedThisRound = true

            // --- major status action gates -------------------------------
            switch atk.status {
            case .sleep:
                atk.sleepTurns -= 1
                if atk.sleepTurns > 0 {
                    atk.chargingMove = nil; atk.bideTurns = 0
                    // Sleep Talk acts from within the nap with a random own move.
                    if let p = planned, case .sleepTalk? = MoveMechanics.mechanic(for: p) {
                        let pool = atk.moves.filter { id in
                            guard id != p, GameData.moves[id] != nil else { return false }
                            switch MoveMechanics.mechanic(for: id) {
                            case .sleepTalk?, .charge?, .bide?: return false
                            default: return true
                            }
                        }
                        if let pick = pool.randomElement(using: &BattleRNG.g), let pm = GameData.moves[pick] {
                            atk.lastMoveUsed = pick
                            execute(pm, atk, def, isPlayer: isPlayer, releasing: false)
                            return
                        }
                    }
                    emit(.skip, actorIsPlayer: isPlayer, reason: "asleep"); return
                }
                atk.status = nil
                atk.nightmared = false
                emit(.recover, actorIsPlayer: isPlayer, reason: "woke up", targetIsPlayer: isPlayer)
            case .freeze:
                if Int.random(in: 0..<100, using: &BattleRNG.g) < 20 {
                    atk.status = nil
                    emit(.recover, actorIsPlayer: isPlayer, reason: "thawed", targetIsPlayer: isPlayer)
                } else {
                    atk.chargingMove = nil; atk.bideTurns = 0
                    emit(.skip, actorIsPlayer: isPlayer, reason: "frozen"); return
                }
            case .paralysis:
                if Int.random(in: 0..<100, using: &BattleRNG.g) < 25 {
                    atk.chargingMove = nil; atk.bideTurns = 0
                    emit(.skip, actorIsPlayer: isPlayer, reason: "paralyzed"); return
                }
            default: break
            }

            // --- volatile gates -------------------------------------------
            if atk.confusionTurns > 0 {
                atk.confusionTurns -= 1
                if atk.confusionTurns == 0 {
                    emit(.recover, actorIsPlayer: isPlayer, reason: "snapped out", targetIsPlayer: isPlayer)
                } else if Int.random(in: 0..<3, using: &BattleRNG.g) == 0 {
                    let base = ((2.0 * Double(atk.level) / 5.0 + 2.0) * 40.0
                                * Double(atk.stats.atk) / Double(max(1, atk.stats.def))) / 50.0 + 2.0
                    let dmg = max(1, Int(base * Double.random(in: 0.85...1.0, using: &BattleRNG.g)))
                    atk.currentHP = max(0, atk.currentHP - dmg)
                    emit(.selfHit, actorIsPlayer: isPlayer, reason: "hurt itself",
                         damage: dmg, targetIsPlayer: isPlayer)
                    return
                }
            }
            if atk.infatuated, Int.random(in: 0..<2, using: &BattleRNG.g) == 0 {
                emit(.skip, actorIsPlayer: isPlayer, reason: "infatuated"); return
            }

            // --- forced turns ----------------------------------------------
            if atk.mustRecharge {
                atk.mustRecharge = false
                emit(.skip, actorIsPlayer: isPlayer, reason: "recharging"); return
            }
            if atk.bideTurns > 0 {
                atk.bideTurns -= 1
                if atk.bideTurns > 0 {
                    emit(.skip, actorIsPlayer: isPlayer, reason: "storing"); return
                }
                // release: double everything it soaked (typeless)
                let dmg = max(1, atk.bideStored * 2)
                atk.bideStored = 0
                if let m = GameData.moves.first(where: { $0.value.englishName == "Bide" })?.value {
                    dealDamage(dmg, from: atk, to: def, physical: true)
                    emit(.attack, actorIsPlayer: isPlayer, move: m, damage: dmg)
                }
                return
            }

            // Charge release keeps the wound-up move regardless of `planned`.
            let moveId = atk.chargingMove ?? planned ?? MoveMechanics.struggleId
            guard let m = GameData.moves[moveId] else { return }
            let releasing = atk.chargingMove != nil
            atk.chargingMove = nil
            atk.lastMoveUsed = moveId

            execute(m, atk, def, isPlayer: isPlayer, releasing: releasing)
        }

        /// Resolve one selected move, mechanics table first.
        func execute(_ m: MoveData, _ atk: Battler, _ def: Battler,
                     isPlayer: Bool, releasing: Bool) {
            atk.destinyBond = false   // the bond lasts until the next action
            let eff = effectiveness(m, def)
            guard let mech = MoveMechanics.mechanic(for: m.moveId) else {
                executePlain(m, atk, def, isPlayer: isPlayer, eff: eff, powerOverride: nil)
                return
            }

            // Two-turn moves wind up first (unless this IS the release turn).
            if case .charge = mech, !releasing {
                atk.chargingMove = m.moveId
                emit(.skip, actorIsPlayer: isPlayer, reason: "charging")
                return
            }

            switch mech {
            case .plain(let p):
                executePlain(m, atk, def, isPlayer: isPlayer, eff: eff, powerOverride: p)

            case .trap(let p):
                let landed = executePlain(m, atk, def, isPlayer: isPlayer, eff: eff, powerOverride: p)
                if landed, !def.isFainted, def.trapRounds == 0 {
                    def.trapRounds = Int.random(in: 2...5, using: &BattleRNG.g)
                }

            case .charge:   // release turn
                executePlain(m, atk, def, isPlayer: isPlayer, eff: eff, powerOverride: nil)

            case .recharge:
                let landed = executePlain(m, atk, def, isPlayer: isPlayer, eff: eff, powerOverride: nil)
                if landed { atk.mustRecharge = true }

            case .multiHit(let lo, let hi, let per):
                guard eff > 0 else { emit(.miss, actorIsPlayer: isPlayer, move: m, eff: 0); return }
                guard rolls(m, atk, def) else { emit(.miss, actorIsPlayer: isPlayer, move: m); return }
                let hits = Int.random(in: lo...hi, using: &BattleRNG.g)
                var total = 0
                var anyCrit = false
                for _ in 0..<hits where !def.isFainted {
                    let crit = rollCrit(atk, def, m)
                    anyCrit = anyCrit || crit
                    total += BattleEngine.computeDamage(attacker: atk, defender: def, move: m,
                                           eff: eff, powerOverride: per, crit: crit)
                }
                dealDamage(total, from: atk, to: def, physical: m.category == "Physical")
                emit(.attack, actorIsPlayer: isPlayer, move: m, damage: total, eff: eff,
                     status: "\(hits) hits!", crit: anyCrit)

            case .drain(let frac, let p):
                guard eff > 0 else { emit(.miss, actorIsPlayer: isPlayer, move: m, eff: 0); return }
                guard rolls(m, atk, def) else { emit(.miss, actorIsPlayer: isPlayer, move: m); return }
                if m.englishName == "Dream Eater", def.status != .sleep {
                    emit(.miss, actorIsPlayer: isPlayer, move: m); return
                }
                let crit = rollCrit(atk, def, m)
                let dmg = BattleEngine.computeDamage(attacker: atk, defender: def, move: m,
                                        eff: eff, powerOverride: p, crit: crit)
                dealDamage(dmg, from: atk, to: def, physical: m.category == "Physical")
                emit(.attack, actorIsPlayer: isPlayer, move: m, damage: dmg, eff: eff, crit: crit)
                let heal = min(max(1, Int(Double(dmg) * frac)), atk.maxHP - atk.currentHP)
                if heal > 0, atk.healBlockRounds == 0 {
                    atk.currentHP += heal
                    emit(.recover, actorIsPlayer: isPlayer, reason: "drained", targetIsPlayer: isPlayer)
                }

            case .recoil(let frac, let power):
                let before = def.currentHP
                let landed = executePlain(m, atk, def, isPlayer: isPlayer, eff: eff, powerOverride: power)
                let dealt = before - def.currentHP
                if landed, dealt > 0 {
                    let recoil = max(1, Int(Double(dealt) * frac))
                    atk.currentHP = max(0, atk.currentHP - recoil)
                    emit(.selfHit, actorIsPlayer: isPlayer, reason: "recoil",
                         damage: recoil, targetIsPlayer: isPlayer)
                }

            case .crashOnMiss:
                guard eff > 0, rolls(m, atk, def) else {
                    emit(.miss, actorIsPlayer: isPlayer, move: m, eff: eff > 0 ? 1 : 0)
                    let crash = max(1, atk.maxHP / 4)
                    atk.currentHP = max(0, atk.currentHP - crash)
                    emit(.selfHit, actorIsPlayer: isPlayer, reason: "crashed",
                         damage: crash, targetIsPlayer: isPlayer)
                    return
                }
                let crit = rollCrit(atk, def, m)
                let dmg = BattleEngine.computeDamage(attacker: atk, defender: def, move: m,
                                        eff: eff, powerOverride: nil, crit: crit)
                dealDamage(dmg, from: atk, to: def, physical: true)
                emit(.attack, actorIsPlayer: isPlayer, move: m, damage: dmg, eff: eff, crit: crit)

            case .fixedDamage(let n):
                guard eff > 0 else { emit(.miss, actorIsPlayer: isPlayer, move: m, eff: 0); return }
                guard rolls(m, atk, def) else { emit(.miss, actorIsPlayer: isPlayer, move: m); return }
                dealDamage(n, from: atk, to: def, physical: m.category == "Physical")
                emit(.attack, actorIsPlayer: isPlayer, move: m, damage: n)

            case .levelDamage:
                guard eff > 0 else { emit(.miss, actorIsPlayer: isPlayer, move: m, eff: 0); return }
                guard rolls(m, atk, def) else { emit(.miss, actorIsPlayer: isPlayer, move: m); return }
                dealDamage(atk.level, from: atk, to: def, physical: m.category == "Physical")
                emit(.attack, actorIsPlayer: isPlayer, move: m, damage: atk.level)

            case .psywave:
                guard eff > 0 else { emit(.miss, actorIsPlayer: isPlayer, move: m, eff: 0); return }
                guard rolls(m, atk, def) else { emit(.miss, actorIsPlayer: isPlayer, move: m); return }
                let dmg = max(1, Int(Double(atk.level) * Double.random(in: 0.5...1.5, using: &BattleRNG.g)))
                dealDamage(dmg, from: atk, to: def, physical: false)
                emit(.attack, actorIsPlayer: isPlayer, move: m, damage: dmg)

            case .superFang:
                guard eff > 0 else { emit(.miss, actorIsPlayer: isPlayer, move: m, eff: 0); return }
                guard rolls(m, atk, def) else { emit(.miss, actorIsPlayer: isPlayer, move: m); return }
                let dmg = max(1, def.currentHP / 2)
                dealDamage(dmg, from: atk, to: def, physical: true)
                emit(.attack, actorIsPlayer: isPlayer, move: m, damage: dmg)

            case .endeavor:
                guard def.currentHP > atk.currentHP, rolls(m, atk, def) else {
                    emit(.miss, actorIsPlayer: isPlayer, move: m); return
                }
                let dmg = def.currentHP - atk.currentHP
                dealDamage(dmg, from: atk, to: def, physical: true)
                emit(.attack, actorIsPlayer: isPlayer, move: m, damage: dmg)

            case .ohko:
                guard eff > 0, def.level <= atk.level else {
                    emit(.miss, actorIsPlayer: isPlayer, move: m, eff: eff > 0 ? 1 : 0); return
                }
                let chance = 30 + (atk.level - def.level)
                guard atk.lockedOnRounds > 0 || Int.random(in: 0..<100, using: &BattleRNG.g) < chance else {
                    emit(.miss, actorIsPlayer: isPlayer, move: m); return
                }
                let dmg = def.currentHP
                dealDamage(dmg, from: atk, to: def, physical: m.category == "Physical")
                emit(.attack, actorIsPlayer: isPlayer, move: m, damage: dmg, status: "One-hit KO!")

            case .explosion(let p):
                // The user detonates FIRST — the selfHit carries the move so
                // the playback stages announce + blast + full HP drain as one
                // beat — and the damage lands on the foe after (that attack
                // event neither re-announces nor re-plays the boom). Fainting
                // costs the blast nothing: damage comes from stats, not HP.
                let pay = atk.currentHP
                atk.currentHP = 0
                emit(.selfHit, actorIsPlayer: isPlayer, move: m,
                     damage: pay, targetIsPlayer: isPlayer)
                _ = executePlain(m, atk, def, isPlayer: isPlayer, eff: eff, powerOverride: p)

            case .counterPhysical:
                guard atk.physicalTakenThisRound > 0 else {
                    emit(.miss, actorIsPlayer: isPlayer, move: m); return
                }
                let dmg = atk.physicalTakenThisRound * 2
                dealDamage(dmg, from: atk, to: def, physical: true)
                emit(.attack, actorIsPlayer: isPlayer, move: m, damage: dmg)

            case .counterSpecial:
                guard atk.specialTakenThisRound > 0 else {
                    emit(.miss, actorIsPlayer: isPlayer, move: m); return
                }
                let dmg = atk.specialTakenThisRound * 2
                dealDamage(dmg, from: atk, to: def, physical: false)
                emit(.attack, actorIsPlayer: isPlayer, move: m, damage: dmg)

            case .bide:
                atk.bideTurns = 2
                atk.bideStored = 0
                emit(.skip, actorIsPlayer: isPlayer, reason: "storing")

            case .payback:
                let doubled = def.actedThisRound
                executePlainScaled(m, atk, def, isPlayer: isPlayer, eff: eff,
                                   power: doubled ? 100 : 50)

            case .revenge:
                let doubled = atk.physicalTakenThisRound + atk.specialTakenThisRound > 0
                executePlainScaled(m, atk, def, isPlayer: isPlayer, eff: eff,
                                   power: doubled ? 120 : 60)

            case .magnitude:
                let table = [(10, 5), (30, 10), (50, 20), (70, 30), (90, 20), (110, 10), (150, 5)]
                var roll = Int.random(in: 0..<100, using: &BattleRNG.g), power = 70
                for (p, w) in table { if roll < w { power = p; break }; roll -= w }
                executePlainScaled(m, atk, def, isPlayer: isPlayer, eff: eff, power: power)

            case .present:
                guard rolls(m, atk, def) else { emit(.miss, actorIsPlayer: isPlayer, move: m); return }
                let roll = Int.random(in: 0..<100, using: &BattleRNG.g)
                if roll < 20 {   // a gift: heals the target a quarter
                    let heal = min(max(1, def.maxHP / 4), def.maxHP - def.currentHP)
                    def.currentHP += heal
                    emit(.recover, actorIsPlayer: isPlayer, move: m, targetIsPlayer: !isPlayer)
                } else {
                    let power = roll < 60 ? 40 : (roll < 90 ? 80 : 120)
                    executePlainScaled(m, atk, def, isPlayer: isPlayer, eff: eff, power: power)
                }

            case .memento:
                if def.mistRounds == 0 {
                    def.bump(.atk, -2); def.bump(.spa, -2)
                    emit(.attack, actorIsPlayer: isPlayer, move: m, status: "ATK -2 SP.ATK -2")
                } else {
                    emit(.miss, actorIsPlayer: isPlayer, move: m)
                }
                let pay = atk.currentHP
                atk.currentHP = 0
                emit(.selfHit, actorIsPlayer: isPlayer, reason: "gave everything",
                     damage: pay, targetIsPlayer: isPlayer)

            case .painSplit:
                guard def.currentHP > atk.currentHP else { emit(.miss, actorIsPlayer: isPlayer, move: m); return }
                let avg = (def.currentHP + atk.currentHP) / 2
                let dmg = def.currentHP - avg
                def.currentHP = avg
                emit(.attack, actorIsPlayer: isPlayer, move: m, damage: dmg)
                atk.currentHP = min(atk.maxHP, avg)
                emit(.recover, actorIsPlayer: isPlayer, reason: "shared the pain", targetIsPlayer: isPlayer)

            case .healSelf(let frac):
                guard atk.healBlockRounds == 0 else { emit(.miss, actorIsPlayer: isPlayer, move: m); return }
                let heal = min(max(1, Int(Double(atk.maxHP) * frac)), atk.maxHP - atk.currentHP)
                guard heal > 0 else { emit(.miss, actorIsPlayer: isPlayer, move: m); return }
                atk.currentHP += heal
                emit(.recover, actorIsPlayer: isPlayer, move: m, targetIsPlayer: isPlayer)

            case .rest:
                guard atk.healBlockRounds == 0,
                      atk.currentHP < atk.maxHP || (atk.status != nil && atk.status != .sleep) else {
                    emit(.miss, actorIsPlayer: isPlayer, move: m); return
                }
                atk.currentHP = atk.maxHP
                atk.status = .sleep
                atk.sleepTurns = 2
                emit(.recover, actorIsPlayer: isPlayer, move: m, targetIsPlayer: isPlayer, status: "sleep")

            case .wish:
                guard atk.healBlockRounds == 0 else { emit(.miss, actorIsPlayer: isPlayer, move: m); return }
                pending.append((turn + 1, -max(1, atk.maxHP / 2), isPlayer, m.displayName))
                emit(.attack, actorIsPlayer: isPlayer, move: m, targetIsPlayer: isPlayer, status: "made a wish")

            case .cureStatus:
                guard atk.status != nil else { emit(.miss, actorIsPlayer: isPlayer, move: m); return }
                atk.status = nil
                emit(.recover, actorIsPlayer: isPlayer, move: m, targetIsPlayer: isPlayer)

            case .statSelf(let list):
                var applied: [(BattleStat, Int)] = []
                for (s, d) in list { let got = atk.bump(s, d); if got != 0 { applied.append((s, got)) } }
                guard !applied.isEmpty else { emit(.miss, actorIsPlayer: isPlayer, move: m); return }
                emit(.attack, actorIsPlayer: isPlayer, move: m,
                     targetIsPlayer: isPlayer, status: statTag(applied))

            case .statFoe(let list):
                guard eff > 0 else { emit(.miss, actorIsPlayer: isPlayer, move: m, eff: 0); return }
                // Magic Coat bounces the drop back onto the user.
                let victim = def.magicCoatTurn == turn ? atk : def
                guard victim.mistRounds == 0, rolls(m, atk, def) else {
                    emit(.miss, actorIsPlayer: isPlayer, move: m); return
                }
                var applied: [(BattleStat, Int)] = []
                for (s, d) in list { let got = victim.bump(s, d); if got != 0 { applied.append((s, got)) } }
                guard !applied.isEmpty else { emit(.miss, actorIsPlayer: isPlayer, move: m); return }
                emit(.attack, actorIsPlayer: isPlayer, move: m,
                     targetIsPlayer: victim === player, status: statTag(applied))

            case .bellyDrum:
                guard atk.currentHP * 2 > atk.maxHP, atk.stage(.atk) < 6 else {
                    emit(.miss, actorIsPlayer: isPlayer, move: m); return
                }
                let pay = atk.maxHP / 2
                atk.currentHP -= pay
                emit(.selfHit, actorIsPlayer: isPlayer, reason: "drummed", damage: pay, targetIsPlayer: isPlayer)
                atk.stages[.atk] = 6
                emit(.attack, actorIsPlayer: isPlayer, move: m, targetIsPlayer: isPlayer, status: "ATK maxed!")

            case .haze:
                atk.stages = [:]; def.stages = [:]
                emit(.attack, actorIsPlayer: isPlayer, move: m, status: "stats reset")

            case .screen(let physical):
                if physical { atk.reflectRounds = 5 } else { atk.lightScreenRounds = 5 }
                emit(.attack, actorIsPlayer: isPlayer, move: m, targetIsPlayer: isPlayer,
                     status: physical ? "DEF wall up" : "SP.DEF wall up")

            case .safeguard:
                atk.safeguardRounds = 5
                emit(.attack, actorIsPlayer: isPlayer, move: m, targetIsPlayer: isPlayer, status: "protected")

            case .mist:
                atk.mistRounds = 5
                emit(.attack, actorIsPlayer: isPlayer, move: m, targetIsPlayer: isPlayer, status: "shrouded in mist")

            case .leechSeed:
                let victim = def.magicCoatTurn == turn ? atk : def
                guard victim.type1 != "Grass", victim.type2 != "Grass", !victim.seeded,
                      rolls(m, atk, def) else {
                    emit(.miss, actorIsPlayer: isPlayer, move: m); return
                }
                victim.seeded = true
                emit(.attack, actorIsPlayer: isPlayer, move: m,
                     targetIsPlayer: victim === player, status: "seeded")

            case .curse:
                if atk.type1 == "Ghost" || atk.type2 == "Ghost" {
                    guard !def.ghostCursed else { emit(.miss, actorIsPlayer: isPlayer, move: m); return }
                    let pay = max(1, atk.maxHP / 2)
                    atk.currentHP = max(0, atk.currentHP - pay)
                    emit(.selfHit, actorIsPlayer: isPlayer, reason: "cut its own HP",
                         damage: pay, targetIsPlayer: isPlayer)
                    def.ghostCursed = true
                    emit(.attack, actorIsPlayer: isPlayer, move: m, status: "cursed")
                } else {
                    atk.bump(.atk, 1); atk.bump(.def, 1); atk.bump(.spe, -1)
                    emit(.attack, actorIsPlayer: isPlayer, move: m,
                         targetIsPlayer: isPlayer, status: "ATK +1 DEF +1 SPEED -1")
                }

            case .nightmare:
                guard def.status == .sleep, !def.nightmared else {
                    emit(.miss, actorIsPlayer: isPlayer, move: m); return
                }
                def.nightmared = true
                emit(.attack, actorIsPlayer: isPlayer, move: m, status: "trapped in a nightmare")

            case .yawn:
                let victim = def.magicCoatTurn == turn ? atk : def
                guard victim.status == nil, victim.yawnCounter == 0, victim.safeguardRounds == 0 else {
                    emit(.miss, actorIsPlayer: isPlayer, move: m); return
                }
                victim.yawnCounter = 2
                emit(.attack, actorIsPlayer: isPlayer, move: m,
                     targetIsPlayer: victim === player, status: "drowsy")

            case .futureSight:
                let dmg = BattleEngine.computeDamage(attacker: atk, defender: def, move: m, eff: 1, powerOverride: 80)
                pending.append((turn + 2, dmg, !isPlayer, m.displayName))
                emit(.attack, actorIsPlayer: isPlayer, move: m, targetIsPlayer: isPlayer, status: "foresaw an attack")

            case .perishSong:
                guard atk.perishCount < 0, def.perishCount < 0 else {
                    emit(.miss, actorIsPlayer: isPlayer, move: m); return
                }
                atk.perishCount = 3; def.perishCount = 3
                emit(.attack, actorIsPlayer: isPlayer, move: m, status: "perish in 3")

            case .destinyBond:
                atk.destinyBond = true
                emit(.attack, actorIsPlayer: isPlayer, move: m, targetIsPlayer: isPlayer,
                     status: "bonded fates")

            case .transform:
                guard !atk.transformed else { emit(.miss, actorIsPlayer: isPlayer, move: m); return }
                atk.stats = Stats(hp: atk.stats.hp, atk: def.stats.atk, def: def.stats.def,
                                  spAtk: def.stats.spAtk, spDef: def.stats.spDef, spe: def.stats.spe)
                atk.type1 = def.type1; atk.type2 = def.type2
                atk.moves = def.moves
                atk.stages = def.stages
                atk.transformed = true
                emit(.attack, actorIsPlayer: isPlayer, move: m, targetIsPlayer: isPlayer, status: "transformed!")

            case .metronome:
                let pool = GameData.moves.values.filter {
                    $0.effectivePower > 0 && MoveMechanics.mechanic(for: $0.moveId) == nil
                        && $0.moveId != MoveMechanics.basicAttackId   // synthetic, not a real move
                }
                guard let pick = pool.randomElement(using: &BattleRNG.g) else {
                    emit(.miss, actorIsPlayer: isPlayer, move: m); return
                }
                executePlain(pick, atk, def, isPlayer: isPlayer,
                             eff: TypeChart.multiplier(pick.type, vs: def.type1, def.type2),
                             powerOverride: nil)

            case .mirrorMove:
                guard let lastId = def.lastMoveUsed, let last = GameData.moves[lastId],
                      last.effectivePower > 0 else {
                    emit(.miss, actorIsPlayer: isPlayer, move: m); return
                }
                executePlain(last, atk, def, isPlayer: isPlayer,
                             eff: TypeChart.multiplier(last.type, vs: def.type1, def.type2),
                             powerOverride: nil)

            case .mimic:
                guard let lastId = def.lastMoveUsed,
                      let slot = atk.moves.firstIndex(of: m.moveId) else {
                    emit(.miss, actorIsPlayer: isPlayer, move: m); return
                }
                atk.moves[slot] = lastId
                emit(.attack, actorIsPlayer: isPlayer, move: m, targetIsPlayer: isPlayer,
                     status: "copied \(GameData.moves[lastId]?.displayName ?? "a move")")

            case .fleeSelf:
                emit(.skip, actorIsPlayer: isPlayer, reason: "fled")
                if isPlayer { playerFled = true } else { wildFled = true }

            case .fleeFoe:
                emit(.skip, actorIsPlayer: isPlayer, reason: "fled")
                if isPlayer { wildFled = true } else { playerFled = true }

            case .splash:
                emit(.attack, actorIsPlayer: isPlayer, move: m, targetIsPlayer: isPlayer, status: "nothing happened")

            // ---- wave 2 -------------------------------------------------
            case .acupressure:
                guard let pick = BattleStat.allCases.filter({ atk.stage($0) < 6 }).randomElement(using: &BattleRNG.g) else {
                    emit(.miss, actorIsPlayer: isPlayer, move: m); return
                }
                atk.bump(pick, 2)
                emit(.attack, actorIsPlayer: isPlayer, move: m,
                     targetIsPlayer: isPlayer, status: "\(pick.label) +2")

            case .captivate:
                let opposite = (atk.gender == .male && def.gender == .female)
                    || (atk.gender == .female && def.gender == .male)
                guard opposite, def.mistRounds == 0, def.stage(.spa) > -6, rolls(m, atk, def) else {
                    emit(.miss, actorIsPlayer: isPlayer, move: m); return
                }
                def.bump(.spa, -2)
                emit(.attack, actorIsPlayer: isPlayer, move: m, status: "SP.ATK -2")

            case .psychUp:
                for s in BattleStat.allCases { atk.stages[s] = def.stage(s) }
                emit(.attack, actorIsPlayer: isPlayer, move: m,
                     targetIsPlayer: isPlayer, status: "copied the foe's stats")

            case .guardSwap:
                let d = atk.stage(.def), sd = atk.stage(.spd)
                atk.stages[.def] = def.stage(.def); atk.stages[.spd] = def.stage(.spd)
                def.stages[.def] = d; def.stages[.spd] = sd
                emit(.attack, actorIsPlayer: isPlayer, move: m, status: "guards swapped")

            case .powerSwap:
                let a = atk.stage(.atk), sa = atk.stage(.spa)
                atk.stages[.atk] = def.stage(.atk); atk.stages[.spa] = def.stage(.spa)
                def.stages[.atk] = a; def.stages[.spa] = sa
                emit(.attack, actorIsPlayer: isPlayer, move: m, status: "powers swapped")

            case .aquaRing:
                guard !atk.aquaRing else { emit(.miss, actorIsPlayer: isPlayer, move: m); return }
                atk.aquaRing = true
                emit(.attack, actorIsPlayer: isPlayer, move: m,
                     targetIsPlayer: isPlayer, status: "veiled in water")

            case .stockpile:
                guard atk.stockpileCount < 3 else { emit(.miss, actorIsPlayer: isPlayer, move: m); return }
                atk.stockpileCount += 1
                atk.bump(.def, 1); atk.bump(.spd, 1)
                emit(.attack, actorIsPlayer: isPlayer, move: m,
                     targetIsPlayer: isPlayer, status: "stockpiled x\(atk.stockpileCount)")

            case .swallow:
                guard atk.stockpileCount > 0, atk.currentHP < atk.maxHP,
                      atk.healBlockRounds == 0 else {
                    emit(.miss, actorIsPlayer: isPlayer, move: m); return
                }
                let frac = [0.25, 0.5, 1.0][atk.stockpileCount - 1]
                let heal = min(max(1, Int(Double(atk.maxHP) * frac)), atk.maxHP - atk.currentHP)
                atk.currentHP += heal
                atk.bump(.def, -atk.stockpileCount); atk.bump(.spd, -atk.stockpileCount)
                atk.stockpileCount = 0
                emit(.recover, actorIsPlayer: isPlayer, move: m, targetIsPlayer: isPlayer)

            case .psychoShift:
                guard let s = atk.status, def.status == nil, def.safeguardRounds == 0 else {
                    emit(.miss, actorIsPlayer: isPlayer, move: m); return
                }
                def.status = s
                if s == .sleep { def.sleepTurns = Int.random(in: 1...3, using: &BattleRNG.g) }
                atk.status = nil
                atk.nightmared = false
                emit(.attack, actorIsPlayer: isPlayer, move: m, status: s.rawValue)

            case .healBlock:
                guard def.healBlockRounds == 0 else { emit(.miss, actorIsPlayer: isPlayer, move: m); return }
                def.healBlockRounds = 5
                emit(.attack, actorIsPlayer: isPlayer, move: m, status: "healing blocked")

            case .disable:
                guard let last = def.lastMoveUsed, def.disabledMove == nil else {
                    emit(.miss, actorIsPlayer: isPlayer, move: m); return
                }
                def.disabledMove = last
                def.disabledRounds = 4
                emit(.attack, actorIsPlayer: isPlayer, move: m,
                     status: "\(GameData.moves[last]?.displayName ?? "its move") disabled")

            case .encore:
                guard let last = def.lastMoveUsed, def.encoreRounds == 0 else {
                    emit(.miss, actorIsPlayer: isPlayer, move: m); return
                }
                def.encoreMove = last
                def.encoreRounds = 3
                emit(.attack, actorIsPlayer: isPlayer, move: m, status: "encored")

            case .taunt:
                guard def.tauntRounds == 0 else { emit(.miss, actorIsPlayer: isPlayer, move: m); return }
                def.tauntRounds = 3
                emit(.attack, actorIsPlayer: isPlayer, move: m, status: "taunted")

            case .imprison:
                guard !atk.imprisonActive,
                      def.moves.contains(where: { atk.moves.contains($0) }) else {
                    emit(.miss, actorIsPlayer: isPlayer, move: m); return
                }
                atk.imprisonActive = true
                emit(.attack, actorIsPlayer: isPlayer, move: m, status: "moves sealed")

            case .sleepTalk:
                // Awake it does nothing — the sleep gate is where it acts.
                emit(.miss, actorIsPlayer: isPlayer, move: m)

            case .magicCoat:
                atk.magicCoatTurn = turn
                emit(.attack, actorIsPlayer: isPlayer, move: m,
                     targetIsPlayer: isPlayer, status: "coated")

            case .conversion:
                let candidates = atk.moves.compactMap { GameData.moves[$0]?.type }
                    .filter { !$0.isEmpty && $0 != atk.type1 }
                guard let t = candidates.randomElement(using: &BattleRNG.g) else {
                    emit(.miss, actorIsPlayer: isPlayer, move: m); return
                }
                atk.type1 = t; atk.type2 = nil
                emit(.attack, actorIsPlayer: isPlayer, move: m,
                     targetIsPlayer: isPlayer, status: "became \(t)")

            case .conversion2:
                guard let lastId = def.lastMoveUsed, let lt = GameData.moves[lastId]?.type,
                      let t = TypeChart.chart.keys.filter({ TypeChart.multiplier(lt, vs: $0, nil) < 1 })
                        .randomElement(using: &BattleRNG.g) else {
                    emit(.miss, actorIsPlayer: isPlayer, move: m); return
                }
                atk.type1 = t; atk.type2 = nil
                emit(.attack, actorIsPlayer: isPlayer, move: m,
                     targetIsPlayer: isPlayer, status: "became \(t)")

            case .magnetRise:
                guard atk.magnetRiseRounds == 0 else { emit(.miss, actorIsPlayer: isPlayer, move: m); return }
                atk.magnetRiseRounds = 5
                emit(.attack, actorIsPlayer: isPlayer, move: m,
                     targetIsPlayer: isPlayer, status: "floating")

            case .focusEnergy:
                guard atk.critStage == 0 else { emit(.miss, actorIsPlayer: isPlayer, move: m); return }
                atk.critStage = 2
                emit(.attack, actorIsPlayer: isPlayer, move: m,
                     targetIsPlayer: isPlayer, status: "getting pumped")

            case .luckyChant:
                guard atk.luckyChantRounds == 0 else { emit(.miss, actorIsPlayer: isPlayer, move: m); return }
                atk.luckyChantRounds = 5
                emit(.attack, actorIsPlayer: isPlayer, move: m,
                     targetIsPlayer: isPlayer, status: "shielded from crits")

            case .identify:
                guard !def.identified else { emit(.miss, actorIsPlayer: isPlayer, move: m); return }
                def.identified = true
                emit(.attack, actorIsPlayer: isPlayer, move: m, status: "identified")

            case .miracleEye:
                guard !def.miracleEyed else { emit(.miss, actorIsPlayer: isPlayer, move: m); return }
                def.miracleEyed = true
                emit(.attack, actorIsPlayer: isPlayer, move: m, status: "exposed")

            case .lockOn:
                guard atk.lockedOnRounds == 0 else { emit(.miss, actorIsPlayer: isPlayer, move: m); return }
                atk.lockedOnRounds = 2
                // The no-miss state lives on the USER, but the reticle (and
                // the "locked on" tag) belongs on the FOE being sighted —
                // default event target, like identify/miracleEye.
                emit(.attack, actorIsPlayer: isPlayer, move: m, status: "locked on")
            }
        }

        /// The plain damaging path (accuracy, damage, secondary ailment) shared
        /// by unmapped power moves and by mechanics that ride on it.
        /// Returns true when the move connected.
        @discardableResult
        func executePlain(_ m: MoveData, _ atk: Battler, _ def: Battler,
                          isPlayer: Bool, eff: Double, powerOverride: Int?) -> Bool {
            guard rolls(m, atk, def) else { emit(.miss, actorIsPlayer: isPlayer, move: m); return false }
            if eff == 0 { emit(.miss, actorIsPlayer: isPlayer, move: m, eff: 0); return false }
            var dmg = 0
            var crit = false
            if m.effectivePower > 0 || powerOverride != nil {
                crit = rollCrit(atk, def, m)
                dmg = BattleEngine.computeDamage(attacker: atk, defender: def, move: m,
                                    eff: eff, powerOverride: powerOverride, crit: crit)
                dealDamage(dmg, from: atk, to: def, physical: m.category == "Physical")
            }
            // A pure status move bounces off a Magic Coat back onto its user.
            let bounced = dmg == 0 && def.magicCoatTurn == turn
            let inflicted = bounced ? BattleEngine.applyAilment(of: m, from: def, to: atk)
                                    : BattleEngine.applyAilment(of: m, from: atk, to: def)
            if dmg == 0 && inflicted == nil {
                emit(.miss, actorIsPlayer: isPlayer, move: m)
                return false
            }
            emit(.attack, actorIsPlayer: isPlayer, move: m, damage: dmg, eff: eff,
                 targetIsPlayer: bounced ? isPlayer : !isPlayer, status: inflicted, crit: crit)
            return true
        }

        func executePlainScaled(_ m: MoveData, _ atk: Battler, _ def: Battler,
                                isPlayer: Bool, eff: Double, power: Int) {
            executePlain(m, atk, def, isPlayer: isPlayer, eff: eff, powerOverride: power)
        }

        /// End-of-round upkeep: chips, seeds, delayed hits, perish, timers.
        func endOfRound() {
            for (b, isPlayer) in [(player, true), (wild, false)] {
                guard !isOver else { return }
                guard !b.isFainted else { continue }
                let other = isPlayer ? wild : player
                // burn / poison
                if let s = b.status, s == .burn || s == .poison {
                    let dmg = max(1, b.maxHP / (s == .burn ? 16 : 8))
                    b.currentHP = max(0, b.currentHP - dmg)
                    emit(.residual, actorIsPlayer: isPlayer, reason: s.rawValue,
                         damage: dmg, targetIsPlayer: isPlayer)
                }
                // leech seed drains toward the other side
                if b.seeded, !b.isFainted {
                    let dmg = max(1, b.maxHP / 8)
                    b.currentHP = max(0, b.currentHP - dmg)
                    emit(.residual, actorIsPlayer: isPlayer, reason: "leech seed",
                         damage: dmg, targetIsPlayer: isPlayer)
                    if !other.isFainted, other.currentHP < other.maxHP, other.healBlockRounds == 0 {
                        other.currentHP = min(other.maxHP, other.currentHP + dmg)
                        emit(.recover, actorIsPlayer: !isPlayer, reason: "sapped", targetIsPlayer: !isPlayer)
                    }
                }
                // Aqua Ring / Ingrain trickle heal
                if b.aquaRing, !b.isFainted, b.currentHP < b.maxHP, b.healBlockRounds == 0 {
                    b.currentHP = min(b.maxHP, b.currentHP + max(1, b.maxHP / 16))
                    emit(.recover, actorIsPlayer: isPlayer, reason: "aqua ring", targetIsPlayer: isPlayer)
                }
                // trap chip (Wrap and friends)
                if b.trapRounds > 0, !b.isFainted {
                    b.trapRounds -= 1
                    let dmg = max(1, b.maxHP / 16)
                    b.currentHP = max(0, b.currentHP - dmg)
                    emit(.residual, actorIsPlayer: isPlayer, reason: "trap",
                         damage: dmg, targetIsPlayer: isPlayer)
                }
                // ghost curse
                if b.ghostCursed, !b.isFainted {
                    let dmg = max(1, b.maxHP / 4)
                    b.currentHP = max(0, b.currentHP - dmg)
                    emit(.residual, actorIsPlayer: isPlayer, reason: "curse",
                         damage: dmg, targetIsPlayer: isPlayer)
                }
                // nightmare (only while it stays asleep)
                if b.nightmared {
                    if b.status == .sleep, !b.isFainted {
                        let dmg = max(1, b.maxHP / 4)
                        b.currentHP = max(0, b.currentHP - dmg)
                        emit(.residual, actorIsPlayer: isPlayer, reason: "nightmare",
                             damage: dmg, targetIsPlayer: isPlayer)
                    } else { b.nightmared = false }
                }
                // yawn resolves into sleep
                if b.yawnCounter > 0 {
                    b.yawnCounter -= 1
                    if b.yawnCounter == 0, b.status == nil {
                        b.status = .sleep
                        b.sleepTurns = Int.random(in: 1...3, using: &BattleRNG.g)
                        emit(.residual, actorIsPlayer: isPlayer, reason: "asleep",
                             targetIsPlayer: isPlayer, status: "sleep")
                    }
                }
                // perish count
                if b.perishCount >= 0 {
                    b.perishCount -= 1
                    if b.perishCount < 0, !b.isFainted {
                        let dmg = b.currentHP
                        b.currentHP = 0
                        emit(.residual, actorIsPlayer: isPlayer, reason: "perish song",
                             damage: dmg, targetIsPlayer: isPlayer)
                    }
                }
                // field timers
                if b.safeguardRounds > 0 { b.safeguardRounds -= 1 }
                if b.mistRounds > 0 { b.mistRounds -= 1 }
                if b.reflectRounds > 0 { b.reflectRounds -= 1 }
                if b.lightScreenRounds > 0 { b.lightScreenRounds -= 1 }
                if b.luckyChantRounds > 0 { b.luckyChantRounds -= 1 }
                if b.lockedOnRounds > 0 { b.lockedOnRounds -= 1 }
                if b.tauntRounds > 0 { b.tauntRounds -= 1 }
                if b.magnetRiseRounds > 0 { b.magnetRiseRounds -= 1 }
                if b.healBlockRounds > 0 { b.healBlockRounds -= 1 }
                if b.disabledRounds > 0 {
                    b.disabledRounds -= 1
                    if b.disabledRounds == 0 { b.disabledMove = nil }
                }
                if b.encoreRounds > 0 {
                    b.encoreRounds -= 1
                    if b.encoreRounds == 0 { b.encoreMove = nil }
                }
            }
            // delayed hits/heals (Future Sight / Wish)
            for (i, p) in pending.enumerated().reversed() where p.round == turn {
                pending.remove(at: i)
                let tgt = p.targetIsPlayer ? player : wild
                guard !tgt.isFainted else { continue }
                if p.amount >= 0 {
                    tgt.currentHP = max(0, tgt.currentHP - p.amount)
                    emit(.residual, actorIsPlayer: !p.targetIsPlayer, reason: p.name,
                         damage: p.amount, targetIsPlayer: p.targetIsPlayer)
                } else {
                    tgt.currentHP = min(tgt.maxHP, tgt.currentHP - p.amount)
                    emit(.recover, actorIsPlayer: p.targetIsPlayer, reason: p.name,
                         targetIsPlayer: p.targetIsPlayer)
                }
            }
        }

    // ------------------------- the rounds -----------------------------

    /// Simulate ONE round and return its events. `playerItem` replaces the
    /// follower's action with a healing item (mainline: an item costs the
    /// turn) and resolves before moves.
    func nextRound(playerItem: GameItem? = nil) -> [BattleEvent] {
        roundEvents = []
        guard !isOver else { return [] }
        turn += 1
        for b in [player, wild] {
            b.physicalTakenThisRound = 0
            b.specialTakenThisRound = 0
            b.actedThisRound = false
        }
        let pPlan: (moveId: Int?, priority: Int) =
            playerItem != nil ? (nil, 6) : BattleEngine.plan(player, vs: wild)
        let wPlan = BattleEngine.plan(wild, vs: player)
        let pFirst = pPlan.priority != wPlan.priority
            ? pPlan.priority > wPlan.priority
            : player.effectiveSpeed >= wild.effectiveSpeed
        let order: [(Battler, Battler, Bool, Int?)] = pFirst
            ? [(player, wild, true, pPlan.moveId), (wild, player, false, wPlan.moveId)]
            : [(wild, player, false, wPlan.moveId), (player, wild, true, pPlan.moveId)]

        for (atk, def, isPlayer, planned) in order {
            guard !isOver, !atk.isFainted, !def.isFainted else { continue }
            if isPlayer, let item = playerItem {
                useHealingItem(item)
                continue
            }
            // Throw a ball instead of attacking when the wild is catchable:
            // hurt to half or carrying a status (max 3 throws per battle).
            if isPlayer, !stock.isEmpty, used.count < 3,
               wild.currentHP * 100 <= wild.maxHP * 50 || wild.status != nil {
                let ball = stock.removeFirst()
                used.append(ball)
                let (ok, shakes) = BattleEngine.attemptCapture(wild: wild, ball: ball)
                captured = ok
                let ev = BattleEvent(
                    kind: .ball, actorIsPlayer: true, moveId: 0,
                    moveName: ball.displayName, damage: 0, effectiveness: 1,
                    targetIsPlayer: false, targetHP: wild.currentHP,
                    targetMaxHP: wild.maxHP, fainted: false, statusApplied: nil,
                    turn: turn, shakes: shakes, caught: ok, ballId: ball.rawValue,
                    playerAsleep: player.status == .sleep,
                    wildAsleep: wild.status == .sleep)
                roundEvents.append(ev)
                allEvents.append(ev)
                continue
            }
            act(atk, def, isPlayer: isPlayer, planned: planned)
        }
        if !captured { endOfRound() }
        return roundEvents
    }

    /// The follower's trainer uses a potion or Full Heal: heal/cure, and the
    /// turn is spent.
    private func useHealingItem(_ item: GameItem) {
        player.actedThisRound = true
        let heal = min(item.healAmount, player.maxHP - player.currentHP)
        if heal > 0 { player.currentHP += heal }
        if item.curesStatus { player.status = nil; player.confusionTurns = 0 }
        var ev = BattleEvent(
            kind: .item, actorIsPlayer: true, moveId: 0,
            moveName: item.displayName, damage: 0, effectiveness: 1,
            targetIsPlayer: true, targetHP: player.currentHP, targetMaxHP: player.maxHP,
            fainted: false, statusApplied: nil, turn: turn,
            playerAsleep: player.status == .sleep, wildAsleep: wild.status == .sleep)
        ev.ballId = item.rawValue
        roundEvents.append(ev)
        allEvents.append(ev)
    }
}

enum BattleEngine {
    /// Simulate the whole battle in one shot (selftests, forced encounters).
    /// `player`/`wild` HP are mutated to the end state.
    static func run(player: Battler, wild: Battler,
                    balls: [GameItem] = []) -> BattleResult {
        let session = BattleSession(player: player, wild: wild, balls: balls)
        while !session.isOver { _ = session.nextRound() }
        return session.makeResult()
    }

    /// Pre-pick a battler's action so priority can order the round. Forced
    /// turns (recharge, charging release, bide) carry their own priority.
    static func plan(_ atk: Battler, vs def: Battler) -> (moveId: Int?, priority: Int) {
        if atk.mustRecharge { return (nil, 0) }
        if let charging = atk.chargingMove { return (charging, MoveMechanics.priority(of: charging)) }
        if atk.bideTurns > 0 { return (nil, 1) }   // Bide releases at +1 (Gen 1/2)
        if atk.encoreRounds > 0, let encore = atk.encoreMove {
            return (encore, MoveMechanics.priority(of: encore))
        }
        let id = chooseMove(attacker: atk, defender: def)
        return (id, MoveMechanics.priority(of: id))
    }

    /// Does `id` deal direct damage? (Taunt allows only these.)
    static func isDamaging(_ id: Int) -> Bool {
        guard let m = GameData.moves[id] else { return false }
        switch MoveMechanics.mechanic(for: id) {
        case .fixedDamage, .levelDamage, .psywave, .superFang, .endeavor, .ohko,
             .plain, .multiHit, .drain, .recoil, .crashOnMiss, .recharge, .charge,
             .explosion, .counterPhysical, .counterSpecial, .bide, .payback,
             .revenge, .magnitude, .present, .trap, .memento:
            return true
        case .none:
            return m.effectivePower > 0
        default:
            return false
        }
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
        case .burn, .poison, .paralysis: a *= 1.5
        default: break
        }
        if a >= 255 { return (true, 4) }
        let b = 1_048_560.0 / (16_711_680.0 / a).squareRoot().squareRoot()
        var shakes = 0
        while shakes < 4, Double.random(in: 0..<65_536, using: &BattleRNG.g) < b {
            shakes += 1
        }
        return (shakes == 4, shakes)
    }

    /// Whether `id` can DO something right now — mechanics-aware (D19 + this
    /// change: the mechanics table makes most formerly-dead moves selectable).
    static func usable(_ id: Int, attacker: Battler, defender: Battler) -> Bool {
        guard let m = GameData.moves[id] else { return false }
        if let mech = MoveMechanics.mechanic(for: id) {
            switch mech {
            case .plain, .fixedDamage, .levelDamage, .psywave, .multiHit,
                 .recoil, .crashOnMiss, .recharge, .charge, .explosion,
                 .magnitude, .present, .payback, .revenge, .bide, .memento,
                 .metronome, .splash, .fleeSelf, .fleeFoe, .futureSight, .trap:
                return true
            case .counterPhysical, .counterSpecial:
                return true   // gambles on being hit first, like the games
            case .superFang: return defender.currentHP > 1
            case .ohko: return attacker.level >= defender.level
            case .endeavor: return defender.currentHP > attacker.currentHP
            case .drain:
                return m.displayName != "Dream Eater" || defender.status == .sleep
            case .healSelf, .wish:
                return attacker.currentHP * 3 <= attacker.maxHP * 2
            case .rest:
                return attacker.currentHP * 2 <= attacker.maxHP
                    || (attacker.status != nil && attacker.status != .sleep)
            case .cureStatus:
                return attacker.status != nil && attacker.status != .sleep
            case .statSelf(let list):
                return list.contains { $0.1 > 0 ? attacker.stage($0.0) < 6 : attacker.stage($0.0) > -6 }
            case .statFoe(let list):
                return defender.mistRounds == 0 && list.contains { defender.stage($0.0) > -6 }
            case .bellyDrum:
                return attacker.stage(.atk) < 6 && attacker.currentHP * 2 > attacker.maxHP
            case .haze:
                return attacker.stages.values.contains { $0 != 0 }
                    || defender.stages.values.contains { $0 != 0 }
            case .screen(let physical):
                return physical ? attacker.reflectRounds == 0 : attacker.lightScreenRounds == 0
            case .safeguard: return attacker.safeguardRounds == 0
            case .mist: return attacker.mistRounds == 0
            case .leechSeed:
                return !defender.seeded && defender.type1 != "Grass" && defender.type2 != "Grass"
            case .curse:
                let ghost = attacker.type1 == "Ghost" || attacker.type2 == "Ghost"
                return ghost ? !defender.ghostCursed
                             : (attacker.stage(.atk) < 6 || attacker.stage(.def) < 6)
            case .nightmare: return defender.status == .sleep && !defender.nightmared
            case .yawn:
                return defender.status == nil && defender.yawnCounter == 0
                    && defender.safeguardRounds == 0
            case .perishSong: return attacker.perishCount < 0 && defender.perishCount < 0
            case .destinyBond: return !attacker.destinyBond
            case .painSplit: return defender.currentHP > attacker.currentHP
            case .mirrorMove:
                return (defender.lastMoveUsed.flatMap { GameData.moves[$0]?.effectivePower } ?? 0) > 0
            case .mimic: return defender.lastMoveUsed != nil
            case .transform: return !attacker.transformed
            // ---- wave 2 ----
            case .acupressure: return BattleStat.allCases.contains { attacker.stage($0) < 6 }
            case .captivate:
                let opposite = (attacker.gender == .male && defender.gender == .female)
                    || (attacker.gender == .female && defender.gender == .male)
                return opposite && defender.mistRounds == 0 && defender.stage(.spa) > -6
            case .psychUp:
                return BattleStat.allCases.contains { attacker.stage($0) != defender.stage($0) }
            case .guardSwap:
                return attacker.stage(.def) != defender.stage(.def)
                    || attacker.stage(.spd) != defender.stage(.spd)
            case .powerSwap:
                return attacker.stage(.atk) != defender.stage(.atk)
                    || attacker.stage(.spa) != defender.stage(.spa)
            case .aquaRing: return !attacker.aquaRing
            case .stockpile: return attacker.stockpileCount < 3
            case .swallow:
                return attacker.stockpileCount > 0 && attacker.currentHP < attacker.maxHP
                    && attacker.healBlockRounds == 0
            case .psychoShift:
                return attacker.status != nil && defender.status == nil
                    && defender.safeguardRounds == 0
            case .healBlock: return defender.healBlockRounds == 0
            case .disable: return defender.lastMoveUsed != nil && defender.disabledMove == nil
            case .encore: return defender.lastMoveUsed != nil && defender.encoreRounds == 0
            case .taunt: return defender.tauntRounds == 0
            case .imprison:
                return !attacker.imprisonActive
                    && defender.moves.contains(where: { attacker.moves.contains($0) })
            case .sleepTalk: return attacker.status == .sleep
            case .magicCoat: return true
            case .conversion:
                return attacker.moves.compactMap { GameData.moves[$0]?.type }
                    .contains { !$0.isEmpty && $0 != attacker.type1 }
            case .conversion2: return defender.lastMoveUsed != nil
            case .magnetRise: return attacker.magnetRiseRounds == 0
            case .focusEnergy: return attacker.critStage == 0
            case .luckyChant: return attacker.luckyChantRounds == 0
            case .identify: return !defender.identified
            case .miracleEye: return !defender.miracleEyed
            case .lockOn: return attacker.lockedOnRounds == 0
            }
        }
        if m.power > 0 { return true }
        switch m.ailment {
        case "confusion":
            return defender.confusionTurns == 0 && defender.safeguardRounds == 0
        case "infatuation":
            return !defender.infatuated
        case .some(let a) where Ailment(rawValue: a) != nil:
            return defender.status == nil && defender.safeguardRounds == 0
        default:
            return false
        }
    }

    /// Mainline wild behavior: a uniformly random pick from the usable moves
    /// (no PP, by design). Nothing usable → Struggle, exactly like the games.
    /// PMD-style OFF toggles narrow the pool first; every move toggled OFF →
    /// the weak typeless regular attack instead of Struggle.
    static func chooseMove(attacker: Battler, defender: Battler) -> Int {
        let enabled = attacker.moves.filter { !attacker.disabledMoves.contains($0) }
        if enabled.isEmpty { return MoveMechanics.basicAttackId }
        let pool = enabled.filter { id in
            if id == attacker.disabledMove { return false }
            if defender.imprisonActive, defender.moves.contains(id) { return false }
            if attacker.tauntRounds > 0, !isDamaging(id) { return false }
            return usable(id, attacker: attacker, defender: defender)
        }
        return pool.randomElement(using: &BattleRNG.g) ?? MoveMechanics.struggleId
    }

    /// Simplified mainline damage: level/stat/power scaling × STAB × type ×
    /// random, with stat stages and Reflect/Light Screen. Burn halves physical
    /// attack (D19). `powerOverride` is on the mainline power scale.
    static func computeDamage(attacker: Battler, defender: Battler, move m: MoveData,
                              eff: Double, powerOverride: Int? = nil, crit: Bool = false) -> Int {
        let physical = m.category == "Physical"
        // A crit (x2) ignores the attacker's own debuffs, the defender's
        // buffs, and screens — mainline behavior.
        var aStage = attacker.stage(physical ? .atk : .spa)
        if crit { aStage = max(0, aStage) }
        var dStage = defender.stage(physical ? .def : .spd)
        if crit { dStage = min(0, dStage) }
        var a = Double(physical ? attacker.stats.atk : attacker.stats.spAtk)
        a *= MoveMechanics.stageMultiplier(aStage)
        if physical && attacker.status == .burn { a /= 2 }
        var d = Double(max(1, physical ? defender.stats.def : defender.stats.spDef))
        d *= MoveMechanics.stageMultiplier(dStage)
        let power = Double(powerOverride ?? m.effectivePower)
        var base = ((2.0 * Double(attacker.level) / 5.0 + 2.0) * power * a / d) / 50.0 + 2.0
        if !crit, physical ? defender.reflectRounds > 0 : defender.lightScreenRounds > 0 { base /= 2 }
        if crit { base *= 2 }
        let stab = (m.type == attacker.type1 || m.type == attacker.type2) ? 1.5 : 1.0
        let rand = Double.random(in: 0.85...1.0, using: &BattleRNG.g)
        return max(1, Int(base * stab * eff * rand))
    }

    /// Try to inflict `m`'s ailment on `def`; returns its name when applied.
    fileprivate static func applyAilment(of m: MoveData, from atk: Battler, to def: Battler) -> String? {
        guard let name = m.ailment, !def.isFainted,
              Int.random(in: 1...100, using: &BattleRNG.g) <= m.effectiveAilmentChance else { return nil }
        switch name {
        case "confusion":
            guard def.confusionTurns == 0, def.safeguardRounds == 0 else { return nil }
            def.confusionTurns = Int.random(in: 2...5, using: &BattleRNG.g)
            return name
        case "infatuation":
            // Opposite genders only (D19-2); genderless never qualifies.
            let ok = (atk.gender == .male && def.gender == .female)
                  || (atk.gender == .female && def.gender == .male)
            guard ok, !def.infatuated else { return nil }
            def.infatuated = true
            return name
        default:
            guard let ail = Ailment(rawValue: name), def.status == nil,
                  def.safeguardRounds == 0 else { return nil }
            // Type-based immunities: Fire can't burn, Electric can't be paralyzed
            // by electric moves is a gen-6 rule — keep just the classic pair.
            if ail == .burn, def.type1 == "Fire" || def.type2 == "Fire" { return nil }
            if ail == .poison, ["Poison", "Steel"].contains(def.type1) ||
                               ["Poison", "Steel"].contains(def.type2 ?? "") { return nil }
            if ail == .freeze, def.type1 == "Ice" || def.type2 == "Ice" { return nil }
            def.status = ail
            if ail == .sleep { def.sleepTurns = Int.random(in: 1...3, using: &BattleRNG.g) }
            return name
        }
    }

    /// EXP for a win: the mainline formula, base experience × level / 7 (D6-1).
    static func expFor(defeated: Battler) -> Int {
        max(1, defeated.baseExp * defeated.level / 7)
    }
}
