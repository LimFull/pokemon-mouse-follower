// Raising mode — party & save state (Phase 0 data/persistence layer).
//
// Holds the player's team (<=6), inventory, and the daily-heal bookkeeping,
// persisted as JSON under Application Support. Battle-specific logic lives
// elsewhere; this file owns the durable model and its core mutations.
// Design: design/raising-mode.md (D14 party, D21 save, D23 daily heal, D16 reset).

import Foundation

enum Gender: String, Codable {
    case male, female, genderless
}

/// One owned Pokémon instance (a raised/caught team member).
struct OwnedPokemon: Codable {
    var dex: Int
    var level: Int
    var exp: Int              // total accumulated experience
    var currentHP: Int
    var moves: [Int]          // up to 4 move ids
    var gender: Gender
    var status: String?       // volatile/major status (nil = healthy); detailed in Phase 2

    var species: SpeciesData? { GameData.species[dex] }
    var stats: Stats? { species.map { GameData.stats($0, level: level) } }
    var maxHP: Int { stats?.hp ?? max(currentHP, 1) }
    var isFainted: Bool { currentHP <= 0 }

    /// Fully restore HP and clear status.
    mutating func heal() {
        currentHP = maxHP
        status = nil
    }
}

/// The persisted save document.
struct RaisingSave: Codable {
    var party: [OwnedPokemon] = []
    var activeIndex: Int = 0
    var items: [Int: Int] = [:]        // itemId -> count
    var lastHealDay: String? = nil     // local yyyy-MM-dd of last daily heal (D23)
}

/// Owns the raising-mode save: load/persist, starter setup, party ops, daily heal.
final class RaisingState {
    static let shared = RaisingState()
    static let maxParty = 6

    private(set) var save: RaisingSave

    private init() {
        save = RaisingState.loadFromDisk() ?? RaisingSave()
    }

    var party: [OwnedPokemon] { save.party }
    var hasActiveGame: Bool { !save.party.isEmpty }
    var active: OwnedPokemon? {
        guard save.party.indices.contains(save.activeIndex) else { return save.party.first }
        return save.party[save.activeIndex]
    }
    var allFainted: Bool { !save.party.isEmpty && save.party.allSatisfy { $0.isFainted } }

    // MARK: starter / reset

    /// Begin a new game with a base-form starter at level 5 (D17, #2/#3).
    func startNewGame(dex: Int) {
        guard let s = GameData.species[dex], s.isBaseForm else { return }
        let mon = makeMon(species: s, level: 5)
        save = RaisingSave(party: [mon], activeIndex: 0, items: [:], lastHealDay: RaisingState.today())
        persist()
    }

    /// Reset raising mode entirely (D16 / #1).
    func reset() {
        save = RaisingSave()
        persist()
    }

    /// Build a fresh mon of `species` at `level` with a level-appropriate moveset
    /// and a random, ratio-respecting gender (D17). Gender ratios beyond the
    /// simple 50/50 fallback arrive with the PokéAPI supplement (design 2.2-H).
    func makeMon(species s: SpeciesData, level: Int) -> OwnedPokemon {
        let hp = GameData.stats(s, level: level).hp
        return OwnedPokemon(
            dex: s.dex,
            level: level,
            exp: s.expCurve.indices.contains(level - 1) ? s.expCurve[level - 1] : 0,
            currentHP: hp,
            moves: s.initialMoves(atLevel: level),
            gender: RaisingState.randomGender(),
            status: nil)
    }

    // MARK: party ops (D14)

    /// True if a caught mon can be added without a release decision.
    var partyHasRoom: Bool { save.party.count < RaisingState.maxParty }

    /// Add a caught mon (caller must ensure room, else use replace flow — #14).
    @discardableResult
    func addToParty(_ mon: OwnedPokemon) -> Bool {
        guard partyHasRoom else { return false }
        save.party.append(mon)
        persist()
        return true
    }

    /// Release the party member at `index` (#14).
    func release(at index: Int) {
        guard save.party.indices.contains(index) else { return }
        save.party.remove(at: index)
        if save.activeIndex >= save.party.count { save.activeIndex = max(0, save.party.count - 1) }
        persist()
    }

    // MARK: daily heal (D23)

    /// Fully heal the whole party if the local calendar day changed since the
    /// last heal. Returns true if a heal happened.
    @discardableResult
    func dailyHealIfNeeded() -> Bool {
        let today = RaisingState.today()
        guard save.lastHealDay != today else { return false }
        for i in save.party.indices { save.party[i].heal() }
        save.lastHealDay = today
        persist()
        return true
    }

    // MARK: persistence (D21)

    func persist() {
        guard let data = try? JSONEncoder().encode(save) else { return }
        try? data.write(to: RaisingState.saveURL(), options: .atomic)
    }

    private static func loadFromDisk() -> RaisingSave? {
        guard let data = try? Data(contentsOf: saveURL()) else { return nil }
        return try? JSONDecoder().decode(RaisingSave.self, from: data)
    }

    private static func saveURL() -> URL {
        let fm = FileManager.default
        let dir = (fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
                   ?? fm.temporaryDirectory)
            .appendingPathComponent("PokemonMouseFollower", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("raising.json")
    }

    private static func today() -> String {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: Date())
    }

    private static func randomGender() -> Gender {
        // Phase 0 placeholder: 50/50. Species gender ratio (incl. genderless /
        // gender-locked) folds in with the PokéAPI supplement (design 2.2-H, G).
        Bool.random() ? .male : .female
    }
}
