// Raising mode — static game data loaded from the bundled gamedata/ JSON.
// (species.json, moves.json — factual data derived from the EoS extracts.)
//
// Design: design/raising-mode.md. This is the Phase 0 read-only data layer;
// the party/battle/state models build on top of it.

import Foundation

// MARK: - Codable models (match gamedata/*.json)

struct Evolution: Codable {
    let toDex: Int
    let method: String          // LEVEL / IQ / ITEMS / RECRUITED / NO_REQ
    let param1: Int             // level, item id, or IQ depending on method
    let requirement: String     // NONE / LINK_CABLE / MALE / FEMALE / ...
    enum CodingKeys: String, CodingKey {
        case toDex = "to_dex", method, param1, requirement
    }
}

struct LevelUpMove: Codable {
    let level: Int
    let moveId: Int
    enum CodingKeys: String, CodingKey { case level, moveId = "move_id" }
}

struct BaseStats: Codable {
    let hp, atk, def, spAtk, spDef: Int
    enum CodingKeys: String, CodingKey {
        case hp, atk, def, spAtk = "sp_atk", spDef = "sp_def"
    }
}

struct Growth: Codable {
    let hp, atk, spAtk, def, spDef: [Int]   // per-level deltas, index 0 == level 1
    enum CodingKeys: String, CodingKey {
        case hp, atk, spAtk = "sp_atk", def, spDef = "sp_def"
    }
}

/// Mainline base stats (Gen1-2, from PokeAPI). Drives stat computation (D4 revised).
struct MainlineBase: Codable {
    let hp, atk, def, spa, spd, spe: Int
}

struct SpeciesData: Codable {
    let dex: Int
    let id: String                      // zero-padded dex, matches animations/<id>/
    let names: [String: String]         // lang -> name (EoS NA ROM: "e" only)
    let type1: String
    let type2: String?
    let baseStats: BaseStats            // EoS md base stats (legacy / fallback)
    let base: MainlineBase?             // mainline base stats (preferred)
    let baseExp: Int?                   // mainline base experience yield (D6-1)
    let captureRate: Int?               // mainline catch rate (D11, Phase 3)
    let genderRate: Int?                // female eighths; -1 = genderless (G)
    let isBaseForm: Bool
    let preEvoDex: Int?
    let evolutions: [Evolution]
    let levelUpMoves: [LevelUpMove]
    let expCurve: [Int]                 // total exp required to reach L1..L100
    let growth: Growth
    enum CodingKeys: String, CodingKey {
        case dex, id, names, type1, type2, base
        case baseStats = "base_stats"
        case baseExp = "base_exp"
        case captureRate = "capture_rate"
        case genderRate = "gender_rate"
        case isBaseForm = "is_base_form"
        case preEvoDex = "pre_evo_dex"
        case evolutions
        case levelUpMoves = "level_up_moves"
        case expCurve = "exp_curve"
        case growth
    }

    /// English (default) display name; UI may override via app localization.
    var displayName: String { names["e"] ?? id }

    /// Level-up moves a mon knows at `level`: all moves with level <= it,
    /// keeping at most the latest 4 (design D17-1 / #2, #5).
    func initialMoves(atLevel level: Int) -> [Int] {
        let learned = levelUpMoves.filter { $0.level <= level }.map { $0.moveId }
        return Array(learned.suffix(4))
    }

    /// The evolution that triggers at `level` (LEVEL method only), if any.
    func levelEvolution(atLevel level: Int) -> Evolution? {
        evolutions.first { $0.method == "LEVEL" && $0.param1 <= level }
    }
}

struct MoveData: Codable {
    let moveId: Int
    let names: [String: String]
    let type: String?
    let category: String?       // Physical / Special / Status
    let power: Int
    let pp: Int
    let accuracy: Int
    let desc: String?
    let ailment: String?        // mainline status it can inflict (D19-1), if any
    let ailmentChance: Int?     // %; 0 on a Status-category move = always
    enum CodingKeys: String, CodingKey {
        case moveId = "move_id", names, type, category, power, pp, accuracy, desc
        case ailment
        case ailmentChance = "ailment_chance"
    }
    var displayName: String { names["e"] ?? "Move \(moveId)" }

    /// "87%" for a real accuracy roll, "—" for moves that never miss
    /// (mirrors the battle engine's 1...100 check).
    var accuracyText: String { (1...100).contains(accuracy) ? "\(accuracy)%" : "—" }

    /// Effective % chance to inflict `ailment` on a hit (status moves: always).
    var effectiveAilmentChance: Int {
        guard ailment != nil else { return 0 }
        let c = ailmentChance ?? 0
        return c == 0 ? 100 : c
    }
}

/// Concrete stats of a mon at a given level.
struct Stats {
    let hp, atk, def, spAtk, spDef, spe: Int
}

// MARK: - Loader

enum GameData {
    static let species: [Int: SpeciesData] = load("species")
    static let moves: [Int: MoveData] = loadMoves()

    /// Base-form species (valid starters), sorted by dex — design D1-2 / #3.
    static let starters: [SpeciesData] = species.values
        .filter { $0.isBaseForm }
        .sorted { $0.dex < $1.dex }

    /// Lowest level a wild of `dex` may appear at: an evolved form can't show
    /// up below the LEVEL-evolution thresholds along its pre-evo chain
    /// (no Lv5 Butterfree — design D1-3 refined). Item/trade stages add none.
    static let minWildLevel: [Int: Int] = {
        var out: [Int: Int] = [:]
        for dex in species.keys {
            var minL = 1
            var cur = dex
            while let pre = species[cur]?.preEvoDex {
                if let evo = species[pre]?.evolutions.first(where: { $0.toDex == cur }),
                   evo.method == "LEVEL" {
                    minL = max(minL, evo.param1)
                }
                cur = pre
            }
            out[dex] = minL
        }
        return out
    }()

    /// Wild species allowed to spawn at `level`.
    static func wildPool(atLevel level: Int) -> [Int] {
        species.keys.filter { (minWildLevel[$0] ?? 1) <= level }
    }

    /// Stats of `s` at `level`, from mainline base stats (IV/EV/nature omitted,
    /// design D4). Falls back to the EoS growth model if base stats are missing.
    static func stats(_ s: SpeciesData, level: Int) -> Stats {
        let lv = max(1, level)
        if let b = s.base {
            func st(_ base: Int) -> Int { (2 * base * lv) / 100 + 5 }
            return Stats(
                hp: (2 * b.hp * lv) / 100 + lv + 10,
                atk: st(b.atk), def: st(b.def), spAtk: st(b.spa), spDef: st(b.spd), spe: st(b.spe))
        }
        func cum(_ deltas: [Int], _ base: Int) -> Int {
            base + deltas.prefix(max(0, min(lv, deltas.count))).reduce(0, +)
        }
        return Stats(
            hp: cum(s.growth.hp, s.baseStats.hp), atk: cum(s.growth.atk, s.baseStats.atk),
            def: cum(s.growth.def, s.baseStats.def), spAtk: cum(s.growth.spAtk, s.baseStats.spAtk),
            spDef: cum(s.growth.spDef, s.baseStats.spDef), spe: 0)
    }

    // MARK: private

    private static func url(_ name: String) -> URL? {
        Bundle.main.url(forResource: name, withExtension: "json", subdirectory: "gamedata")
    }

    private static func load(_ name: String) -> [Int: SpeciesData] {
        guard let u = url(name), let data = try? Data(contentsOf: u),
              let dict = try? JSONDecoder().decode([String: SpeciesData].self, from: data)
        else {
            NSLog("[GameData] failed to load \(name).json")
            return [:]
        }
        var out: [Int: SpeciesData] = [:]
        for (_, v) in dict { out[v.dex] = v }
        return out
    }

    private static func loadMoves() -> [Int: MoveData] {
        guard let u = url("moves"), let data = try? Data(contentsOf: u),
              let dict = try? JSONDecoder().decode([String: MoveData].self, from: data)
        else {
            NSLog("[GameData] failed to load moves.json")
            return [:]
        }
        var out: [Int: MoveData] = [:]
        for (_, v) in dict { out[v.moveId] = v }
        return out
    }
}
