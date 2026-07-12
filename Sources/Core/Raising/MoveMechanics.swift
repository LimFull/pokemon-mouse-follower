// Raising mode — special move mechanics (mainline behavior for the moves the
// simplified engine used to skip or flatten into plain hits).
//
// The extracted move data only carries power/accuracy/ailment, so everything
// mechanical lives in this curated table, keyed by the English move name (the
// stable key across the EoS export). Moves that appear in learnsets but can't
// mean anything in a 1v1 auto battle with no switching/held items (Baton Pass,
// Spikes, Follow Me, ...) stay unmapped — they're never selected, and a mon
// whose whole set is unmapped falls back to Struggle like the mainline games.

import Foundation

/// A battle-local stat whose stage (-6...+6) multiplies the flat stat.
enum BattleStat: CaseIterable {
    case atk, def, spa, spd, spe, acc, eva

    var label: String {
        switch self {
        case .atk: return "ATK"; case .def: return "DEF"
        case .spa: return "SP.ATK"; case .spd: return "SP.DEF"
        case .spe: return "SPEED"; case .acc: return "ACC"; case .eva: return "EVA"
        }
    }
}

enum MoveMechanic {
    // damage variants (power ignored or reinterpreted)
    case fixedDamage(Int)                 // Sonic Boom 20 / Dragon Rage 40
    case levelDamage                      // Seismic Toss / Night Shade
    case psywave                          // 0.5–1.5 × level
    case superFang                        // half the target's current HP
    case endeavor                         // target HP drops to user's HP
    case ohko                             // level-gated one-hit KO
    case plain(Int)                       // mainline-power plain hit (data has 0)
    case multiHit(Int, Int, Int)          // (min, max hits, mainline per-hit power)
    case drain(Double, Int)               // heal fraction of damage; mainline power
    case recoil(Double, Int?)             // user takes fraction; mainline power
    case crashOnMiss                      // Jump Kick family: miss = quarter max HP
    case recharge                         // Hyper Beam family: next turn lost
    case charge                           // two-turn: charge, then hit
    case explosion(Int)                   // mainline power; user faints
    case counterPhysical, counterSpecial  // return 2× damage taken this round
    case bide                             // store 2 rounds, return 2× total
    case payback, revenge                 // conditional double power
    // non-damage
    case healSelf(Double)                 // fraction of max HP
    case rest                             // full heal + 2-turn sleep
    case wish                             // half max HP at end of NEXT round
    case cureStatus                       // Refresh / Heal Bell / Aromatherapy
    case statSelf([(BattleStat, Int)])
    case statFoe([(BattleStat, Int)])
    case bellyDrum                        // atk +6, pay half max HP
    case haze                             // both sides' stages reset
    case screen(physical: Bool)           // Reflect / Light Screen (5 rounds)
    case safeguard                        // block new ailments (5 rounds)
    case mist                             // block foe stat drops (5 rounds)
    case leechSeed                        // 1/8 chip to foe, healed to user
    case trap(Int)                        // mainline power + 1/16 chip 2–5 rounds
    case furyCutter(Int)                  // power doubles per consecutive hit (cap x4)
    case curse                            // ghost: pay half, curse foe; else stats
    case nightmare                        // sleeping foe loses 1/4 per round
    case yawn                             // foe sleeps at end of next round
    case futureSight                      // 80-power hit lands 2 rounds later
    case perishSong                       // both sides faint in 3 rounds
    case destinyBond                      // if user faints to foe next, foe faints
    case painSplit                        // HP averaged between the two
    case memento                          // foe atk/spa -2, user faints
    case present                          // random: 40/80/120 damage or 25% heal
    case magnitude                        // random 10...150 power
    case transform                        // copy foe stats/types/moves/stages
    case metronome                        // execute a random damaging move
    case mirrorMove                       // execute the foe's last damaging move
    case mimic                            // copy foe's last move into this slot
    case fleeSelf                         // Teleport: the user escapes the battle
    case fleeFoe                          // Roar / Whirlwind: the foe is blown out
    case noEscape                         // Mean Look / Spider Web / Block: the foe can't flee
    case splash                           // usable, does nothing at all
    // wave 2 — crit/evasion package, move-choice control, type shifts
    case acupressure                      // a random stat +2
    case captivate                        // opposite gender: SP.ATK -2
    case psychUp                          // copy the foe's stat stages
    case guardSwap                        // trade DEF/SP.DEF stages
    case powerSwap                        // trade ATK/SP.ATK stages
    case aquaRing                         // Aqua Ring / Ingrain: 1/16 heal per round
    case stockpile                        // DEF/SP.DEF +1, count up to 3
    case swallow                          // heal by stockpile count, spend it
    case psychoShift                      // pass own major status to the foe
    case healBlock                        // foe can't restore HP for 5 rounds
    case disable                          // foe's last move sealed 4 rounds
    case encore                           // foe repeats its last move 3 rounds
    case taunt                            // foe limited to damaging moves 3 rounds
    case imprison                         // foe can't use moves the user knows
    case sleepTalk                        // acts with a random own move while asleep
    case magicCoat                        // bounces status moves back this round
    case conversion                       // type becomes one of the user's moves'
    case conversion2                      // type becomes one resisting foe's last move
    case magnetRise                       // 5 rounds of Ground immunity
    case focusEnergy                      // crit stage +2
    case luckyChant                       // foe can't crit the user for 5 rounds
    case identify                         // Foresight/Odor Sleuth: evasion ignored, Ghost hittable
    case miracleEye                       // evasion ignored, Dark hittable by Psychic
    case lockOn                           // Lock-On/Mind Reader: next attacks can't miss
}

enum MoveMechanics {
    /// Mechanic by English move name. Resolved to move ids once at load.
    private static let byName: [String: MoveMechanic] = [
        // --- fixed / computed damage --------------------------------------
        "SonicBoom": .fixedDamage(20), "Dragon Rage": .fixedDamage(40),
        "Seismic Toss": .levelDamage, "Night Shade": .levelDamage,
        "Psywave": .psywave, "Super Fang": .superFang, "Endeavor": .endeavor,
        "Fissure": .ohko, "Guillotine": .ohko, "Horn Drill": .ohko, "Sheer Cold": .ohko,
        "Knock Off": .plain(20), "Pursuit": .plain(40), "Rage": .plain(20),
        "Vital Throw": .plain(70), "Revenge": .revenge, "Payback": .payback,
        "Beat Up": .plain(30), "Uproar": .plain(50), "Focus Punch": .plain(150),
        "Magnitude": .magnitude, "Present": .present,
        "Counter": .counterPhysical, "Mirror Coat": .counterSpecial, "Bide": .bide,
        "Explosion": .explosion(250), "Selfdestruct": .explosion(200),
        "Memento": .memento, "Pain Split": .painSplit,
        // --- multi-hit (per-hit mainline power) ---------------------------
        "Double Kick": .multiHit(2, 2, 30), "Bonemerang": .multiHit(2, 2, 50),
        "Twineedle": .multiHit(2, 2, 25), "DoubleSlap": .multiHit(2, 5, 15),
        "Comet Punch": .multiHit(2, 5, 18), "Fury Attack": .multiHit(2, 5, 15),
        "Fury Swipes": .multiHit(2, 5, 18), "Pin Missile": .multiHit(2, 5, 14),
        "Spike Cannon": .multiHit(2, 5, 20), "Barrage": .multiHit(2, 5, 15),
        "Bone Rush": .multiHit(2, 5, 25), "Arm Thrust": .multiHit(2, 5, 15),
        "Triple Kick": .multiHit(3, 3, 20),
        // --- drain / recoil / crash ---------------------------------------
        "Absorb": .drain(0.5, 20), "Mega Drain": .drain(0.5, 40),
        "Giga Drain": .drain(0.5, 60), "Leech Life": .drain(0.5, 20),
        "Dream Eater": .drain(0.5, 100),   // usable only on a sleeping foe
        "Take Down": .recoil(0.25, 90), "Double-Edge": .recoil(1.0 / 3.0, 120),
        "Submission": .recoil(0.25, 80), "Volt Tackle": .recoil(1.0 / 3.0, 120),
        "Struggle": .recoil(0.25, 50),
        "Jump Kick": .crashOnMiss, "Hi Jump Kick": .crashOnMiss,
        // --- two-turn / recharge ------------------------------------------
        "Hyper Beam": .recharge, "Giga Impact": .recharge,
        "Blast Burn": .recharge, "Hydro Cannon": .recharge, "Frenzy Plant": .recharge,
        "Solar Beam": .charge, "SolarBeam": .charge, "Razor Wind": .charge,
        "Skull Bash": .charge, "Sky Attack": .charge,
        "Fly": .charge, "Dig": .charge, "Dive": .charge, "Bounce": .charge,
        // --- healing / status care ----------------------------------------
        "Recover": .healSelf(0.5), "Softboiled": .healSelf(0.5),
        "Milk Drink": .healSelf(0.5), "Slack Off": .healSelf(0.5),
        "Roost": .healSelf(0.5), "Moonlight": .healSelf(0.5),
        "Morning Sun": .healSelf(0.5), "Synthesis": .healSelf(0.5),
        "Rest": .rest, "Wish": .wish,
        "Refresh": .cureStatus, "Heal Bell": .cureStatus, "Aromatherapy": .cureStatus,
        // --- self stat boosts ----------------------------------------------
        "Swords Dance": .statSelf([(.atk, 2)]), "Sharpen": .statSelf([(.atk, 1)]),
        "Meditate": .statSelf([(.atk, 1)]), "Howl": .statSelf([(.atk, 1)]),
        "Growth": .statSelf([(.spa, 1)]), "Nasty Plot": .statSelf([(.spa, 2)]),
        "Calm Mind": .statSelf([(.spa, 1), (.spd, 1)]),
        "Amnesia": .statSelf([(.spd, 2)]),
        "Cosmic Power": .statSelf([(.def, 1), (.spd, 1)]),
        "Stockpile": .stockpile,
        "Iron Defense": .statSelf([(.def, 2)]), "Acid Armor": .statSelf([(.def, 2)]),
        "Barrier": .statSelf([(.def, 2)]), "Harden": .statSelf([(.def, 1)]),
        "Withdraw": .statSelf([(.def, 1)]), "Defense Curl": .statSelf([(.def, 1)]),
        "Agility": .statSelf([(.spe, 2)]), "Rock Polish": .statSelf([(.spe, 2)]),
        "Dragon Dance": .statSelf([(.atk, 1), (.spe, 1)]),
        "Bulk Up": .statSelf([(.atk, 1), (.def, 1)]),
        "Charge": .statSelf([(.spd, 1)]),
        "Double Team": .statSelf([(.eva, 1)]), "Minimize": .statSelf([(.eva, 1)]),
        "Belly Drum": .bellyDrum,
        // --- foe stat drops -------------------------------------------------
        "Growl": .statFoe([(.atk, -1)]), "Charm": .statFoe([(.atk, -2)]),
        "FeatherDance": .statFoe([(.atk, -2)]),
        "Leer": .statFoe([(.def, -1)]), "Tail Whip": .statFoe([(.def, -1)]),
        "Screech": .statFoe([(.def, -2)]),
        "Metal Sound": .statFoe([(.spd, -2)]), "Fake Tears": .statFoe([(.spd, -2)]),
        "String Shot": .statFoe([(.spe, -1)]), "Scary Face": .statFoe([(.spe, -2)]),
        "Cotton Spore": .statFoe([(.spe, -2)]),
        "Sand-Attack": .statFoe([(.acc, -1)]), "SmokeScreen": .statFoe([(.acc, -1)]),
        "Kinesis": .statFoe([(.acc, -1)]), "Flash": .statFoe([(.acc, -1)]),
        "Sweet Scent": .statFoe([(.eva, -1)]),
        "Tickle": .statFoe([(.atk, -1), (.def, -1)]),
        // --- field / volatile ----------------------------------------------
        "Haze": .haze,
        "Reflect": .screen(physical: true), "Light Screen": .screen(physical: false),
        "Safeguard": .safeguard, "Mist": .mist,
        "Leech Seed": .leechSeed,
        "Fury Cutter": .furyCutter(40),
        "Wrap": .trap(15), "Bind": .trap(15), "Fire Spin": .trap(35),
        "Clamp": .trap(35), "Whirlpool": .trap(35), "Sand Tomb": .trap(35),
        "Curse": .curse, "Nightmare": .nightmare, "Yawn": .yawn,
        "Future Sight": .futureSight, "Perish Song": .perishSong,
        "Destiny Bond": .destinyBond,
        // --- odd ones -------------------------------------------------------
        "Transform": .transform, "Metronome": .metronome,
        "Mirror Move": .mirrorMove, "Copycat": .mirrorMove, "Me First": .mirrorMove,
        "Mimic": .mimic, "Sketch": .mimic,
        "Teleport": .fleeSelf, "Roar": .fleeFoe, "Whirlwind": .fleeFoe,
        "Mean Look": .noEscape, "Spider Web": .noEscape, "Block": .noEscape,
        "Splash": .splash,
        // --- wave 2 ---------------------------------------------------------
        "Acupressure": .acupressure, "Captivate": .captivate,
        "Psych Up": .psychUp, "Guard Swap": .guardSwap, "Power Swap": .powerSwap,
        "Aqua Ring": .aquaRing, "Ingrain": .aquaRing,
        "Swallow": .swallow, "Psycho Shift": .psychoShift, "Heal Block": .healBlock,
        "Disable": .disable, "Encore": .encore, "Taunt": .taunt,
        "Imprison": .imprison, "Sleep Talk": .sleepTalk, "Magic Coat": .magicCoat,
        "Conversion": .conversion, "Conversion 2": .conversion2,
        "Magnet Rise": .magnetRise,
        "Focus Energy": .focusEnergy, "Lucky Chant": .luckyChant,
        "Foresight": .identify, "Odor Sleuth": .identify, "Miracle Eye": .miracleEye,
        "Lock-On": .lockOn, "Mind Reader": .lockOn,
    ]

    /// High-critical-ratio moves (+1 crit stage, mainline).
    /// Semi-invulnerable charge turns: where the user hides on turn 1.
    static func hiddenState(forChargeOf name: String) -> HiddenState? {
        switch name {
        case "Dig": return .underground
        case "Fly": return .airborne
        case "Bounce": return .airborne
        case "Dive": return .underwater
        case "Shadow Force": return .vanished
        default: return nil
        }
    }

    /// Whether `name` reaches a mon hidden in `state`, and the damage
    /// multiplier when it does (mainline: Earthquake crushes a digger at
    /// double power; Gust/Twister swat a flier; Surf floods a diver).
    /// nil = the move can't touch it (auto-miss).
    static func pierceMultiplier(_ name: String, into state: HiddenState) -> Double? {
        switch state {
        case .underground:
            return ["Earthquake", "Magnitude", "Fissure"].contains(name) ? 2 : nil
        case .airborne:
            if ["Gust", "Twister"].contains(name) { return 2 }
            return ["Thunder", "Sky Uppercut", "Whirlwind"].contains(name) ? 1 : nil
        case .underwater:
            return ["Surf", "Whirlpool"].contains(name) ? 2 : nil
        case .vanished:
            return nil
        }
    }

    private static let critBonusByName: Set<String> = [
        "Karate Chop", "Razor Leaf", "Crabhammer", "Slash", "Aeroblast",
        "Cross Chop", "Night Slash", "Leaf Blade", "Blaze Kick", "Cross Poison",
        "Psycho Cut", "Shadow Claw", "Stone Edge", "Air Cutter", "Attack Order",
        "Razor Wind", "Sky Attack", "Spacial Rend",
    ]

    /// Move priority by English name (mainline brackets; 0 when absent).
    private static let priorityByName: [String: Int] = [
        "Quick Attack": 1, "Mach Punch": 1, "ExtremeSpeed": 1, "Extreme Speed": 1,
        "Aqua Jet": 1, "Bullet Punch": 1, "Ice Shard": 1, "Shadow Sneak": 1,
        "Sucker Punch": 1, "Protect": 4, "Detect": 4, "Magic Coat": 4,
        "Vital Throw": -1, "Focus Punch": -3, "Revenge": -4, "Avalanche": -4,
        "Counter": -5, "Mirror Coat": -5, "Roar": -6, "Whirlwind": -6,
    ]

    static let byMoveId: [Int: MoveMechanic] = {
        var out: [Int: MoveMechanic] = [:]
        for (id, m) in GameData.moves {
            if let mech = byName[m.englishName] { out[id] = mech }
        }
        return out
    }()

    static let priorityByMoveId: [Int: Int] = {
        var out: [Int: Int] = [:]
        for (id, m) in GameData.moves {
            if let p = priorityByName[m.englishName] { out[id] = p }
        }
        return out
    }()

    static let critBonusByMoveId: Set<Int> = {
        Set(GameData.moves.compactMap { critBonusByName.contains($0.value.englishName) ? $0.key : nil })
    }()

    /// +1 crit stage for the high-ratio moves, else 0.
    static func critBonus(of moveId: Int) -> Int { critBonusByMoveId.contains(moveId) ? 1 : 0 }

    /// Struggle's move id (typeless fallback when nothing else is usable).
    static let struggleId: Int = {
        GameData.moves.first(where: { $0.value.englishName == "Struggle" })?.key ?? 154
    }()

    /// Synthetic id of the PMD "regular attack" — thrown when the player has
    /// toggled every move OFF. Injected into GameData.moves at load; the id
    /// sits far above the real EoS move-id range.
    static let basicAttackId = 9999

    static func mechanic(for moveId: Int) -> MoveMechanic? { byMoveId[moveId] }
    static func priority(of moveId: Int) -> Int { priorityByMoveId[moveId] ?? 0 }

    /// Mainline stage multiplier for regular stats.
    static func stageMultiplier(_ stage: Int) -> Double {
        stage >= 0 ? Double(2 + stage) / 2.0 : 2.0 / Double(2 - stage)
    }

    /// Mainline stage multiplier for accuracy/evasion.
    static func accuracyMultiplier(_ stage: Int) -> Double {
        stage >= 0 ? Double(3 + stage) / 3.0 : 3.0 / Double(3 - stage)
    }
}
