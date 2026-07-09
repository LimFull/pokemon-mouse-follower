// Raising mode — party & save state (Phase 0 data/persistence layer).
//
// Holds the player's team (<=6), inventory, and the daily-heal bookkeeping,
// persisted as JSON under Application Support. Battle-specific logic lives
// elsewhere; this file owns the durable model and its core mutations.
// Design: design/raising-mode.md (D14 party, D21 save, D23 daily heal, D16 reset).

import Foundation

/// Posted whenever the active follower may have changed (mode toggle, starter,
/// evolution, party edit) so the overlay can reload the right sprite.
extension Notification.Name {
    static let raisingChanged = Notification.Name("raisingChanged")
    /// Posted right after a mon evolves, so the overlay can play the burst.
    static let raisingEvolved = Notification.Name("raisingEvolved")
}

enum Gender: String, Codable {
    case male, female, genderless

    /// Random gender respecting the species ratio (design G / D17).
    /// `genderRate` is PokeAPI-style female eighths; -1 (or nil) = genderless.
    static func random(genderRate: Int?) -> Gender {
        guard let r = genderRate, r >= 0 else { return .genderless }
        return Int.random(in: 0..<8) < r ? .female : .male
    }
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

    /// Progress toward the next level: EXP still needed and the 0...1 fill of
    /// the current level's span (resets to 0 on level-up, full = level-up).
    var expToNext: (remaining: Int, fraction: Double) {
        guard let s = species, s.expCurve.indices.contains(level - 1) else { return (0, 1) }
        guard level < 100, s.expCurve.indices.contains(level) else { return (0, 1) }  // max level
        let base = s.expCurve[level - 1]
        let next = s.expCurve[level]
        let span = max(1, next - base)
        let into = min(max(0, exp - base), span)
        return (max(0, next - exp), Double(into) / Double(span))
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

    /// The sprite folder the overlay should follow: the active raising mon when
    /// raising mode is on, otherwise the normal selected character.
    var followerFolder: String {
        if AppSettings.shared.raisingMode, let m = active {
            return String(format: "%03d", m.dex)
        }
        return AppSettings.shared.selectedCharacter
    }

    private func notifyChanged() {
        NotificationCenter.default.post(name: .raisingChanged, object: nil)
    }

    // MARK: starter / reset

    /// Begin a new game with a base-form starter at level 5 (D17, #2/#3).
    func startNewGame(dex: Int) {
        guard let s = GameData.species[dex], s.isBaseForm else { return }
        let mon = makeMon(species: s, level: 5)
        save = RaisingSave(party: [mon], activeIndex: 0, items: [:], lastHealDay: RaisingState.today())
        persist()
        notifyChanged()
    }

    /// Reset raising mode entirely (D16 / #1).
    func reset() {
        save = RaisingSave()
        persist()
        notifyChanged()
    }

    /// Build a fresh mon of `species` at `level` with a level-appropriate moveset
    /// and a random, ratio-respecting gender (D17 / G — genderless and
    /// gender-locked species come out right via the species' gender_rate).
    func makeMon(species s: SpeciesData, level: Int) -> OwnedPokemon {
        let hp = GameData.stats(s, level: level).hp
        return OwnedPokemon(
            dex: s.dex,
            level: level,
            exp: s.expCurve.indices.contains(level - 1) ? s.expCurve[level - 1] : 0,
            currentHP: hp,
            moves: s.initialMoves(atLevel: level),
            gender: Gender.random(genderRate: s.genderRate),
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

    /// A caught wild as an owned mon — keeps its battle HP, moves, gender and
    /// status, like the mainline games (D11).
    func capturedMon(from wild: Battler) -> OwnedPokemon? {
        guard let s = GameData.species[wild.dex] else { return nil }
        return OwnedPokemon(
            dex: wild.dex,
            level: wild.level,
            exp: s.expCurve.indices.contains(wild.level - 1) ? s.expCurve[wild.level - 1] : 0,
            currentHP: max(1, wild.currentHP),
            moves: wild.moves,
            gender: wild.gender,
            status: wild.status?.rawValue)
    }

    /// Add a wild mon caught in battle (party must have room).
    @discardableResult
    func addCaptured(from wild: Battler) -> Bool {
        guard partyHasRoom, let mon = capturedMon(from: wild) else { return false }
        save.party.append(mon)
        persist()
        notifyChanged()
        return true
    }

    /// Full-party capture decision (D14/#14): release the member at `index`
    /// and keep the catch, or pass nil to let the new mon go.
    func resolveCapture(_ mon: OwnedPokemon, releasing index: Int?) {
        guard let index, save.party.indices.contains(index) else { return }
        save.party.remove(at: index)
        if save.activeIndex >= save.party.count { save.activeIndex = max(0, save.party.count - 1) }
        save.party.append(mon)
        persist()
        notifyChanged()
    }

    /// Release the party member at `index` (#14).
    func release(at index: Int) {
        guard save.party.indices.contains(index) else { return }
        save.party.remove(at: index)
        if save.activeIndex >= save.party.count { save.activeIndex = max(0, save.party.count - 1) }
        persist()
        notifyChanged()
    }

    /// Fully restore the party member at `index` (temporary heal affordance
    /// until items/revives exist; also covered by the daily heal, D23).
    func healMon(at index: Int) {
        guard save.party.indices.contains(index) else { return }
        save.party[index].heal()
        persist()
        notifyChanged()
    }

    /// Make the party member at `index` the active follower.
    func setActive(_ index: Int) {
        guard save.party.indices.contains(index) else { return }
        save.activeIndex = index
        persist()
        notifyChanged()
    }

    // MARK: growth (level up / move learning / evolution)

    struct GrowthResult {
        var leveledTo: Int?
        var learnedMoves: [Int] = []     // auto-added (had a free slot)
        var pendingMoves: [Int] = []     // new moves needing a replace decision (4 already)
        var evolvedFrom: Int?
        var evolvedTo: Int?
        var changed: Bool { leveledTo != nil || evolvedTo != nil || !learnedMoves.isEmpty }
    }

    /// Give the active mon `amount` EXP and apply every level-up it earns:
    /// stat/HP growth, level-up moves (auto-learn if a slot is free, otherwise
    /// queued in `pendingMoves`), and LEVEL-method evolution (design D6/D8/#9).
    func gainExp(_ amount: Int) -> GrowthResult {
        var r = GrowthResult()
        let i = save.activeIndex
        guard save.party.indices.contains(i), amount > 0 else { return r }
        guard var s = save.party[i].species else { return r }

        save.party[i].exp += amount
        while save.party[i].level < 100 {
            let next = save.party[i].level + 1
            let need = s.expCurve.indices.contains(next - 1) ? s.expCurve[next - 1] : Int.max
            if save.party[i].exp < need { break }

            let beforeHP = GameData.stats(s, level: save.party[i].level).hp
            save.party[i].level = next
            r.leveledTo = next
            let afterHP = GameData.stats(s, level: next).hp
            save.party[i].currentHP = min(afterHP, save.party[i].currentHP + max(0, afterHP - beforeHP))

            for m in s.levelUpMoves where m.level == next && !save.party[i].moves.contains(m.moveId) {
                if save.party[i].moves.count < 4 {
                    save.party[i].moves.append(m.moveId)
                    r.learnedMoves.append(m.moveId)
                } else {
                    r.pendingMoves.append(m.moveId)
                }
            }

            if let evo = s.levelEvolution(atLevel: next), let to = GameData.species[evo.toDex] {
                r.evolvedFrom = s.dex
                r.evolvedTo = evo.toDex
                save.party[i].dex = evo.toDex
                s = to
                save.party[i].currentHP = min(save.party[i].currentHP, GameData.stats(s, level: next).hp)
            }
        }
        persist()
        if r.evolvedTo != nil {
            notifyChanged()   // follower sprite changed
            NotificationCenter.default.post(name: .raisingEvolved, object: nil)
        }
        return r
    }

    /// Apply a finished battle to the active mon: set its end HP and carried
    /// major status (D19 — cleared by fainting), grant EXP on a win (level-ups/
    /// evolution via gainExp), and switch to the next non-fainted party member
    /// if it fainted (D10).
    @discardableResult
    func applyBattleOutcome(playerHP: Int, status: String?, won: Bool, expGained: Int) -> GrowthResult {
        var result = GrowthResult()
        let i = save.activeIndex
        guard save.party.indices.contains(i) else { return result }
        save.party[i].currentHP = max(0, min(save.party[i].maxHP, playerHP))
        save.party[i].status = save.party[i].isFainted ? nil : status
        if won && expGained > 0 { result = gainExp(expGained) }   // persists + may evolve/notify
        if save.party[i].isFainted, let next = save.party.indices.first(where: { !save.party[$0].isFainted }) {
            save.activeIndex = next
        }
        persist()
        notifyChanged()
        return result
    }

    /// Resolve a queued move: replace the move at `slot` (0–3) with `moveId`,
    /// or pass slot = nil to decline learning it (#5). `index` targets a
    /// specific party member (default: the active one).
    func learnMove(_ moveId: Int, replacing slot: Int?, at index: Int? = nil) {
        let i = index ?? save.activeIndex
        guard save.party.indices.contains(i) else { return }
        if let slot, save.party[i].moves.indices.contains(slot) {
            save.party[i].moves[slot] = moveId
            persist()
            notifyChanged()
        }
    }

    // MARK: inventory (D12)

    func itemCount(_ item: GameItem) -> Int { save.items[item.rawValue] ?? 0 }

    func addItem(_ item: GameItem, _ n: Int = 1) {
        save.items[item.rawValue, default: 0] += n
        persist()
        notifyChanged()
    }

    /// Remove one of `item` from the bag; false if none left.
    @discardableResult
    func consumeItem(_ item: GameItem) -> Bool {
        guard itemCount(item) > 0 else { return false }
        save.items[item.rawValue]! -= 1
        if save.items[item.rawValue] == 0 { save.items.removeValue(forKey: item.rawValue) }
        persist()
        return true
    }

    // MARK: item use on a mon (Phase 3c — D12 potions/revive, C3/D8-1 evolution)

    /// The evolution `item` would trigger for `mon`, honoring the D8-1 mapping:
    /// stones -> ITEMS evolutions, Link Cord -> any LINK_CABLE requirement,
    /// Friend Candy -> IQ evolutions (sun/lunar-ribbon split by local daytime).
    func evolution(for item: GameItem, of mon: OwnedPokemon) -> Evolution? {
        guard let s = mon.species else { return nil }
        if let eosId = GameItem.stoneEosIds[item] {
            return s.evolutions.first { $0.method == "ITEMS" && $0.param1 == eosId && $0.requirement != "LINK_CABLE" }
        }
        switch item {
        case .linkCord:
            return s.evolutions.first { $0.requirement == "LINK_CABLE" }
        case .friendCandy:
            let iq = s.evolutions.filter { $0.method == "IQ" }
            guard iq.count > 1 else { return iq.first }
            let day = (6..<18).contains(Calendar.current.component(.hour, from: Date()))
            return iq.first { $0.requirement == (day ? "SUN_RIBBON" : "LUNAR_RIBBON") } ?? iq.first
        default:
            return nil
        }
    }

    /// Whether `item` would do anything for the party member at `index`.
    func canUseItem(_ item: GameItem, at index: Int) -> Bool {
        guard save.party.indices.contains(index), itemCount(item) > 0 else { return false }
        let mon = save.party[index]
        if item.healAmount > 0 { return !mon.isFainted && mon.currentHP < mon.maxHP }
        if item == .revive { return mon.isFainted }
        if item.isEvolutionItem { return evolution(for: item, of: mon) != nil }
        return false
    }

    /// Use `item` on the party member at `index`. Returns the evolved-to dex
    /// for evolution items (nil otherwise); false-y (nil + no change) if unusable.
    @discardableResult
    func useItem(_ item: GameItem, at index: Int) -> Int? {
        guard canUseItem(item, at: index), consumeItem(item) else { return nil }
        var evolvedTo: Int? = nil
        if item.healAmount > 0 {
            save.party[index].currentHP = min(save.party[index].maxHP,
                                              save.party[index].currentHP + item.healAmount)
        } else if item == .revive {
            save.party[index].currentHP = max(1, save.party[index].maxHP / 2)
            save.party[index].status = nil
        } else if let evo = evolution(for: item, of: save.party[index]),
                  let to = GameData.species[evo.toDex] {
            save.party[index].dex = evo.toDex
            let cap = GameData.stats(to, level: save.party[index].level).hp
            save.party[index].currentHP = min(save.party[index].currentHP, cap)
            evolvedTo = evo.toDex
        }
        persist()
        notifyChanged()
        if evolvedTo != nil, index == save.activeIndex {
            NotificationCenter.default.post(name: .raisingEvolved, object: nil)
        }
        return evolvedTo
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
}
