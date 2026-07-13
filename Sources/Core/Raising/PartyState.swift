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
    /// The settings checkbox toggled the raising shortcut icon on/off.
    static let raisingIconChanged = Notification.Name("raisingIconChanged")
}

enum Gender: String, Codable {
    case male, female, genderless

    /// Random gender respecting the species ratio (design G / D17).
    /// `genderRate` is PokeAPI-style female eighths; -1 (or nil) = genderless.
    static func random(genderRate: Int?) -> Gender {
        guard let r = genderRate, r >= 0 else { return .genderless }
        // Drawn from the battle RNG so a seeded fixture rolls identical
        // battlers on both platforms (W18-②).
        return Int.random(in: 0..<8, using: &BattleRNG.g) < r ? .female : .male
    }
}

/// One owned Pokémon instance (a raised/caught team member).
struct OwnedPokemon: Codable {
    var dex: Int
    var level: Int
    var exp: Int              // total accumulated experience
    var currentHP: Int {
        // Every faint/revive flows through here (battle outcome write-back,
        // items, heals), so the timestamp can't be missed. Observers don't
        // fire during decode, which keeps the stored faintedAt of a loaded
        // fainted mon intact.
        didSet {
            if currentHP <= 0, oldValue > 0 { faintedAt = Date() }
            else if currentHP > 0 { faintedAt = nil }
        }
    }
    var faintedAt: Date?      // when it fainted (nil while conscious)
    var moves: [Int]          // up to 4 move ids
    var disabledMoves: [Int]? // PMD-style OFF toggles — still known, AI won't pick them
    var gender: Gender
    var status: String?       // volatile/major status (nil = healthy); detailed in Phase 2
    var ivs: Stats?           // mainline IVs (0...31 each); nil in pre-IV saves,
                              // rolled once on load so old catches get theirs too

    var species: SpeciesData? { GameData.species[dex] }
    var stats: Stats? { species.map { GameData.stats($0, level: level, ivs: ivs) } }
    var maxHP: Int { stats?.hp ?? max(currentHP, 1) }
    var isFainted: Bool { currentHP <= 0 }

    /// PMD-style toggle: an OFF move stays known, the battle AI just never
    /// picks it. All OFF -> the mon falls back to the weak typeless
    /// regular attack (MoveMechanics.basicAttackId).
    func isMoveEnabled(_ moveId: Int) -> Bool {
        !(disabledMoves ?? []).contains(moveId)
    }

    /// Fully restore HP and clear status.
    mutating func heal() {
        currentHP = maxHP
        status = nil
    }

    /// A fainted mon gets back up on its own this long after fainting
    /// (was: at the next local midnight via the daily heal).
    static let reviveDelay: TimeInterval = 3 * 60 * 60

    /// "2h 12m" until this fainted mon revives — shown for fainted members
    /// so a reset isn't tempting.
    var timeUntilRevive: String {
        let end = (faintedAt ?? Date()).addingTimeInterval(Self.reviveDelay)
        let mins = max(0, Int(end.timeIntervalSince(Date())) / 60)
        return mins >= 60 ? "\(mins / 60)h \(mins % 60)m" : "\(mins)m"
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
    var ballsEnabled: Bool? = nil      // throw balls in battle (nil = off)
}

/// Owns the raising-mode save: load/persist, starter setup, party ops, daily heal.
final class RaisingState {
    static let shared = RaisingState()
    static let maxParty = 6

    private(set) var save: RaisingSave

    private init() {
        save = RaisingState.loadFromDisk() ?? RaisingSave()
        // Normalize a stale index (older saves / corruption). -1 = recalled.
        if save.activeIndex >= save.party.count {
            save.activeIndex = save.party.isEmpty ? -1 : 0
        }
        // Pre-IV saves: every existing catch rolls its spread once, here —
        // stats only go UP from the IV-0 baseline, so current HP stays valid.
        if save.party.contains(where: { $0.ivs == nil }) {
            for i in save.party.indices where save.party[i].ivs == nil {
                save.party[i].ivs = GameData.rollIVs()
            }
            persist()
        }
    }

    var party: [OwnedPokemon] { save.party }
    var hasActiveGame: Bool { !save.party.isEmpty }

    /// The mon currently out on the desktop; nil while everyone is recalled.
    var active: OwnedPokemon? {
        guard save.activeIndex >= 0, save.party.indices.contains(save.activeIndex) else { return nil }
        return save.party[save.activeIndex]
    }
    var allFainted: Bool { !save.party.isEmpty && save.party.allSatisfy { $0.isFainted } }

    /// The sprite folder the overlay should follow: the active raising mon when
    /// raising mode is on, otherwise the normal selected character.
    var followerFolder: String {
        if AppSettings.shared.raisingMode, let m = active {
            return Characters.folder(dex: m.dex)
        }
        return AppSettings.shared.selectedCharacter
    }

    private func notifyChanged() {
        NotificationCenter.default.post(name: .raisingChanged, object: nil)
    }

    // MARK: starter / reset

    /// Begin a new game with one of the classic starters at level 5 (D17, #2/#3).
    func startNewGame(dex: Int) {
        guard GameData.starterDexes.contains(dex), let s = GameData.species[dex] else { return }
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
        let ivs = GameData.rollIVs()
        let hp = GameData.stats(s, level: level, ivs: ivs).hp
        return OwnedPokemon(
            dex: s.dex,
            level: level,
            exp: s.expAt(level: level),
            currentHP: hp,
            moves: s.initialMoves(atLevel: level),
            gender: Gender.random(genderRate: s.genderRate),
            status: nil,
            ivs: ivs)
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
            exp: s.expAt(level: wild.level),
            currentHP: max(1, wild.currentHP),
            moves: wild.moves,
            gender: wild.gender,
            status: wild.status?.rawValue,
            ivs: wild.ivs ?? GameData.rollIVs())   // the caught individual keeps ITS spread
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
        // Sending someone out supersedes a flee that was waiting on the turn.
        LiveBattle.current?.cancelRecallRequest()
        save.activeIndex = index
        persist()
        notifyChanged()
    }

    /// Recall the follower — nobody is out until the player sends one again.
    /// Mid-battle this works like the mainline RUN command: the recall waits
    /// until the turn in progress fully plays out (the controller calls back
    /// here at the turn boundary, or after the outcome if the battle ends
    /// first); only then is the battle broken off and the follower recalled.
    func recall() {
        if LiveBattle.current?.requestRecall() == true {
            notifyChanged()   // panels show the pending state (buttons disable)
            return
        }
        save.activeIndex = -1
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

            let beforeHP = GameData.stats(s, level: save.party[i].level, ivs: save.party[i].ivs).hp
            save.party[i].level = next
            r.leveledTo = next
            let afterHP = GameData.stats(s, level: next, ivs: save.party[i].ivs).hp
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
                save.party[i].currentHP = min(save.party[i].currentHP, GameData.stats(s, level: next, ivs: save.party[i].ivs).hp)
            }
        }
        persist()
        if let from = r.evolvedFrom, let to = r.evolvedTo {
            notifyChanged()   // follower sprite changed
            NotificationCenter.default.post(name: .raisingEvolved, object: nil,
                                            userInfo: ["from": from, "to": to])
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
        // A fainted mon stays out where it fell — no auto-switch. The player
        // sends out a replacement from the party panel when they want to.
        persist()
        notifyChanged()
        return result
    }

    /// A battle broken off mid-way (mid-battle recall/flee): the follower
    /// keeps the HP and major ailment its gauge was showing — mirroring the
    /// wild, which already keeps its gauge HP. Fleeing can't faint (min 1 HP)
    /// and grants nothing else (no EXP, outcome discarded).
    func applyFleeState(hp: Int, status: String?) {
        let i = save.activeIndex
        guard save.party.indices.contains(i) else { return }
        save.party[i].currentHP = max(1, min(save.party[i].maxHP, hp))
        save.party[i].status = status
        persist()
        notifyChanged()
    }

    /// Resolve a queued move: replace the move at `slot` (0–3) with `moveId`,
    /// or pass slot = nil to decline learning it (#5). `index` targets a
    /// specific party member (default: the active one).
    func learnMove(_ moveId: Int, replacing slot: Int?, at index: Int? = nil) {
        let i = index ?? save.activeIndex
        guard save.party.indices.contains(i) else { return }
        if let slot, save.party[i].moves.indices.contains(slot) {
            save.party[i].moves[slot] = moveId
            // The forgotten move's OFF toggle must not linger (or shadow the
            // same move if relearned later). Snapshot the moves first: the
            // removeAll closure reading save.party[i] while disabledMoves is
            // being mutated is an exclusivity violation — a guaranteed crash
            // on both platforms (Swift enforces it at runtime).
            let known = save.party[i].moves
            save.party[i].disabledMoves?.removeAll { !known.contains($0) }
            persist()
            notifyChanged()
        }
    }

    /// Moves this member could relearn (move-reminder, user feature):
    /// every level-up move of its CURRENT species learnable at or below its
    /// level and not currently known — so a wild caught with the last-4
    /// window regains access to its whole learnset. Sorted by learn level.
    func relearnableMoves(at index: Int) -> [(moveId: Int, level: Int)] {
        guard save.party.indices.contains(index),
              let s = save.party[index].species else { return [] }
        let mon = save.party[index]
        var seen = Set<Int>()
        var out: [(Int, Int)] = []
        for lm in s.levelUpMoves.sorted(by: { $0.level < $1.level })
        where lm.level <= mon.level
            && !mon.moves.contains(lm.moveId)
            && GameData.moves[lm.moveId] != nil
            && seen.insert(lm.moveId).inserted {
            out.append((lm.moveId, lm.level))
        }
        return out
    }

    /// Relearn `moveId`: straight into an empty slot, or through the same
    /// replace prompt a level-up's fifth move uses when all four are taken.
    func relearn(_ moveId: Int, at index: Int) {
        guard save.party.indices.contains(index),
              relearnableMoves(at: index).contains(where: { $0.moveId == moveId }) else { return }
        if save.party[index].moves.count < 4 {
            save.party[index].moves.append(moveId)
            persist()
            notifyChanged()
        } else {
            PromptRelay.enqueue(.learnMove(monIndex: index, moveId: moveId))
        }
    }

    /// PMD-style move toggle (per member): OFF moves stay known but the
    /// battle AI never picks them; all OFF -> the weak regular attack.
    func setMoveEnabled(_ moveId: Int, _ on: Bool, at index: Int) {
        guard save.party.indices.contains(index),
              save.party[index].moves.contains(moveId) else { return }
        var off = Set(save.party[index].disabledMoves ?? [])
        if on { off.remove(moveId) } else { off.insert(moveId) }
        off.formIntersection(save.party[index].moves)   // drop stale ids
        save.party[index].disabledMoves = off.isEmpty ? nil : off.sorted()
        persist()
    }

    // MARK: capture toggle (balls only fly when the player wants a catch)

    var captureEnabled: Bool { save.ballsEnabled ?? false }

    func setCaptureEnabled(_ on: Bool) {
        save.ballsEnabled = on
        persist()
        notifyChanged()
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
        if item.healAmount > 0 {
            // Mid-battle the panel's saved HP is stale — gate potions on the
            // LIVE gauge, one queued item at a time (an item costs the turn).
            if index == save.activeIndex, let bc = LiveBattle.current,
               let gauge = bc.playerGaugeFraction {
                return !bc.itemPending && gauge < 1.0
            }
            return !mon.isFainted && mon.currentHP < mon.maxHP
        }
        if item.curesStatus {
            // Mid-battle the saved status is stale too — gate on the ailment
            // the playback has actually shown so far.
            if index == save.activeIndex, let bc = LiveBattle.current,
               bc.playerGaugeFraction != nil {
                return !bc.itemPending && bc.playerLiveStatus != nil
            }
            return !mon.isFainted && mon.status != nil
        }
        if item == .revive { return mon.isFainted }
        if item.isEvolutionItem { return evolution(for: item, of: mon) != nil }
        return false
    }

    /// Use `item` on the party member at `index`. Returns the evolved-to dex
    /// for evolution items (nil otherwise); false-y (nil + no change) if unusable.
    @discardableResult
    func useItem(_ item: GameItem, at index: Int) -> Int? {
        guard canUseItem(item, at: index) else { return nil }
        // Mid-battle potion: queue it as the follower's next ACTION (mainline:
        // the item spends the turn). The controller consumes it from the bag
        // when the round simulates; the icon floats overhead during playback.
        if item.healAmount > 0 || item.curesStatus, index == save.activeIndex,
           LiveBattle.current?.requestItem(item) == true {
            notifyChanged()   // panels show the queued state
            return nil
        }
        guard consumeItem(item) else { return nil }
        let fromDex = save.party[index].dex
        var evolvedTo: Int? = nil
        if item.healAmount > 0 {
            save.party[index].currentHP = min(save.party[index].maxHP,
                                              save.party[index].currentHP + item.healAmount)
        } else if item.curesStatus {
            save.party[index].status = nil
        } else if item == .revive {
            save.party[index].currentHP = max(1, save.party[index].maxHP / 2)
            save.party[index].status = nil
        } else if let evo = evolution(for: item, of: save.party[index]),
                  let to = GameData.species[evo.toDex] {
            save.party[index].dex = evo.toDex
            let cap = GameData.stats(to, level: save.party[index].level, ivs: save.party[index].ivs).hp
            save.party[index].currentHP = min(save.party[index].currentHP, cap)
            evolvedTo = evo.toDex
        }
        persist()
        notifyChanged()
        if let to = evolvedTo, index == save.activeIndex {
            NotificationCenter.default.post(name: .raisingEvolved, object: nil,
                                            userInfo: ["from": fromDex, "to": to])
        }
        return evolvedTo
    }

    /// Debug: force a major status on the active mon (nil clears). It carries
    /// into the next battle, so skip/residual visuals are testable on demand.
    func setStatusDebug(_ status: String?) {
        let i = save.activeIndex
        guard save.party.indices.contains(i), !save.party[i].isFainted else { return }
        save.party[i].status = status
        persist()
        notifyChanged()
    }

    // MARK: passive regen (out of battle)

    /// Slow out-of-battle recovery: +1 HP to every hurt, conscious member.
    /// Called every ~30s by the app loop while not battling. Fainted mons stay
    /// down (revive/daily heal only, D10).
    func regenTick() {
        var changed = false
        for i in save.party.indices
        where !save.party[i].isFainted && save.party[i].currentHP < save.party[i].maxHP {
            save.party[i].currentHP += 1
            changed = true
        }
        if changed {
            persist()
            notifyChanged()
        }
    }

    // MARK: timed revive + daily heal (D23)

    /// Revive (full heal) every member fainted at least reviveDelay ago —
    /// called from the same ~10s app poll as the daily heal. A fainted mon
    /// from a pre-timestamp save starts its countdown here.
    @discardableResult
    func timedReviveIfNeeded() -> Bool {
        var changed = false
        for i in save.party.indices where save.party[i].isFainted {
            guard let t = save.party[i].faintedAt else {
                save.party[i].faintedAt = Date()
                changed = true
                continue
            }
            if Date().timeIntervalSince(t) >= OwnedPokemon.reviveDelay {
                save.party[i].heal()
                changed = true
            }
        }
        if changed {
            persist()
            notifyChanged()
        }
        return changed
    }

    /// Fully heal the conscious party members if the local calendar day
    /// changed since the last heal. Fainted members are NOT revived here —
    /// they get back up on their own 3h timer (timedReviveIfNeeded).
    /// Returns true if a heal happened. Notifies so panels redraw even when
    /// the heal fires from the app tick at midnight (the nested panel
    /// refresh this can cause is a one-shot: the second call is a no-op).
    @discardableResult
    func dailyHealIfNeeded() -> Bool {
        let today = RaisingState.today()
        guard save.lastHealDay != today else { return false }
        for i in save.party.indices where !save.party[i].isFainted { save.party[i].heal() }
        save.lastHealDay = today
        persist()
        notifyChanged()
        return true
    }

    // MARK: persistence (D21)

    func persist() {
        guard let data = try? JSONEncoder().encode(save) else { return }
        try? data.write(to: RaisingState.saveURL(), options: .atomic)
    }

    private static func loadFromDisk() -> RaisingSave? {
        if let data = try? Data(contentsOf: saveURL()) {
            return try? JSONDecoder().decode(RaisingSave.self, from: data)
        }
        // First dev run: read the release save as a starting snapshot (never
        // written back — persist() targets the dev file). PMF_SAVE_DIR runs
        // stay fully isolated and get no seed.
        guard PMF.isDevRun,
              ProcessInfo.processInfo.environment["PMF_SAVE_DIR"] == nil,
              let data = try? Data(contentsOf: saveURL(dev: false))
        else { return nil }
        return try? JSONDecoder().decode(RaisingSave.self, from: data)
    }

    private static func saveURL() -> URL { saveURL(dev: PMF.isDevRun) }

    private static func saveURL(dev: Bool) -> URL {
        let fm = FileManager.default
        // PMF_SAVE_DIR redirects ALL persistence. Selftests must set it: a
        // debug run resets the party, and without the override it writes to
        // the real save (overriding $HOME does NOT move applicationSupport).
        // Dev runs without the override write under a dev/ subfolder so the
        // release save is never touched.
        let dir: URL
        if let scratch = ProcessInfo.processInfo.environment["PMF_SAVE_DIR"] {
            dir = URL(fileURLWithPath: scratch, isDirectory: true)
        } else {
            var base = (fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
                        ?? fm.temporaryDirectory)
                .appendingPathComponent("PokemonMouseFollower", isDirectory: true)
            if dev { base = base.appendingPathComponent("dev", isDirectory: true) }
            dir = base
        }
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
