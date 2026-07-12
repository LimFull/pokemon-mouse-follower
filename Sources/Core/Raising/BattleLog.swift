// Raising mode — battle log line composer (PMD-style scrolling log).
//
// Pure string composition: BattleEvent (+ combatant names) -> localized lines,
// with no AppKit or controller state, so the selftest can exercise every path
// headlessly. The playback controller schedules each line inside the event's
// beat via Phase, keeping the text in sync with the on-screen action.
// All templates use positional %@ specifiers (numbers are passed as strings)
// so ko/ja can reorder arguments freely.

import Foundation

enum BattleLog {
    /// When within the event's playback beat a line should surface:
    /// .start -> the attack/reason is announced, .impact -> the hit lands,
    /// .resolve -> the HP drain finished (damage numbers, statuses, faints).
    enum Phase { case start, impact, resolve }
    struct Entry { let text: String; let phase: Phase }

    // MARK: - event -> lines

    static func lines(for e: BattleEvent, playerName: String, wildName: String) -> [Entry] {
        let actor = e.actorIsPlayer ? playerName : wildName
        let target = e.targetIsPlayer ? playerName : wildName
        var out: [Entry] = []
        func add(_ text: String, _ phase: Phase) { out.append(Entry(text: text, phase: phase)) }

        switch e.kind {
        case .attack:
            // Explosion moves already announced on their detonation beat
            // (the selfHit that precedes this event), and a multi-hit
            // follow-up strike continues the announced move — don't repeat.
            if e.moveId > 0, !e.followUp, !EffectPlayer.isExplosionMove(e.moveId) {
                add(LF("log.attack", actor, e.moveName), .start)
            }
            if e.damage > 0 {
                if e.crit { add(L("log.crit"), .impact) }
                if e.effectiveness > 1 { add(L("log.eff.super"), .impact) }
                else if e.effectiveness > 0, e.effectiveness < 1 { add(L("log.eff.notvery"), .impact) }
                add(LF("log.damage", target, String(e.damage)), .resolve)
            }
            for line in statusLines(e.statusApplied, name: target) { add(line, .resolve) }
            if e.fainted { add(LF("log.faint", target), .resolve) }
        case .miss:
            if e.moveId > 0, !EffectPlayer.isExplosionMove(e.moveId) {
                add(LF("log.attack", actor, e.moveName), .start)
            }
            add(e.effectiveness == 0 ? LF("log.noeffect", target) : L("log.missed"), .impact)
        case .skip:
            add(reasonLine("skip", e.moveName, name: actor), .start)
        case .selfHit:
            // A selfHit carrying a move is a detonation beat (Selfdestruct &
            // co): announce the move like an attack — the whole-HP "damage"
            // number is noise, the faint line tells the story.
            if e.moveId > 0 { add(LF("log.attack", actor, e.moveName), .start) }
            else {
                add(reasonLine("selfhit", e.moveName, name: target), .start)
                if e.damage > 0 { add(LF("log.damage", target, String(e.damage)), .resolve) }
            }
            if e.fainted { add(LF("log.faint", target), .resolve) }
        case .residual:
            add(reasonLine("residual", e.moveName, name: target), .start)
            if e.damage > 0 { add(LF("log.damage", target, String(e.damage)), .resolve) }
            if e.fainted { add(LF("log.faint", target), .resolve) }
        case .recover:
            // Heal moves announce like an attack; passive recoveries (woke up,
            // drain beneficiary, Aqua Ring...) go through the reason table.
            if e.moveId > 0 { add(LF("log.attack", actor, e.moveName), .start) }
            else { add(reasonLine("recover", e.moveName, name: target), .start) }
            for line in statusLines(e.statusApplied, name: target) { add(line, .resolve) }
        case .item:
            add(LF("log.item", e.moveName), .start)   // moveName = localized item name
        case .ball:
            add(LF("log.ball.throw", e.moveName), .start)
            add(e.caught ? LF("log.ball.caught", wildName)
                         : LF("log.ball.broke", wildName), .resolve)
        }
        return out
    }

    // MARK: - battle lifecycle lines

    static func battleStart(wildName: String) -> String { LF("log.appear", wildName) }

    /// Post-battle lines. Faint lines are NOT produced here — the fainting
    /// event already carried one; capture success rides the ball event.
    static func outcome(won: Bool, expGained: Int, levelUpTo: Int?,
                        captured: Bool, wildFled: Bool, playerFled: Bool = false,
                        playerName: String, wildName: String) -> [String] {
        var out: [String] = []
        if wildFled { out.append(LF("log.wildfled", wildName)) }
        else if playerFled { out.append(LF("log.wildleft", wildName)) }   // it blew US out and left
        if won, expGained > 0 { out.append(LF("log.exp", playerName, String(expGained))) }
        if let lv = levelUpTo { out.append(LF("log.levelup", playerName, String(lv))) }
        return out
    }

    static func recallLine(playerName: String) -> String { LF("log.recalled", playerName) }

    /// Wild Roar/Whirlwind dragged this member into the fight.
    static func draggedOutLine(playerName: String) -> String { LF("log.draggedout", playerName) }

    // MARK: - internals

    /// String(format: L(key), args) — the app's existing formatting idiom,
    /// plus Korean particle resolution after substitution.
    private static func LF(_ key: String, _ args: CVarArg...) -> String {
        resolveKoreanJosa(String(format: L(key), arguments: args))
    }

    /// Korean templates write particles as both-forms markers ("는(은)",
    /// "를(을)", "가(이)") right after a substituted name; pick the correct
    /// one from the preceding syllable's final consonant. A marker following
    /// a non-Hangul character (latin names, digits) keeps both forms.
    private static let josaMarkers: [(marker: String, withFinal: String, withoutFinal: String)] = [
        ("는(은)", "은", "는"), ("은(는)", "은", "는"),
        ("를(을)", "을", "를"), ("을(를)", "을", "를"),
        ("가(이)", "이", "가"), ("이(가)", "이", "가"),
    ]

    private static func resolveKoreanJosa(_ s: String) -> String {
        guard s.contains("(") else { return s }
        var out = ""
        var rest = Substring(s)
        outer: while !rest.isEmpty {
            for (marker, withFinal, withoutFinal) in josaMarkers where rest.hasPrefix(marker) {
                if let sc = out.last?.unicodeScalars.first?.value, (0xAC00...0xD7A3).contains(sc) {
                    out += (sc - 0xAC00) % 28 != 0 ? withFinal : withoutFinal
                } else {
                    out += marker
                }
                rest = rest.dropFirst(marker.count)
                continue outer
            }
            out.append(rest.removeFirst())
        }
        return out
    }

    /// Non-move events carry an English reason string in moveName. The same
    /// reason can mean different things per kind ("asleep" as a skip = still
    /// sleeping, as a residual = Yawn put it to sleep), so keys are kind-scoped.
    private static let reasonKey: [String: String] = [
        // skip (lost turn)
        "skip.asleep": "log.skip.asleep",
        "skip.frozen": "log.skip.frozen",
        "skip.paralyzed": "log.skip.paralyzed",
        "skip.infatuated": "log.skip.infatuated",
        "skip.recharging": "log.skip.recharging",
        "skip.charging": "log.skip.charging",
        "skip.storing": "log.skip.storing",
        "skip.fled": "log.skip.fled",
        "skip.blown away": "log.skip.blownaway",
        "skip.cant flee": "log.skip.cantflee",
        "skip.confused": "log.skip.confused",
        "skip.dug in": "log.skip.dugin",
        "skip.flew up": "log.skip.flewup",
        "skip.dove under": "log.skip.doveunder",
        "skip.vanished": "log.skip.vanished",
        // selfHit (hurt itself / self-pay)
        "selfhit.Destiny Bond": "log.selfhit.destinybond",
        "selfhit.hurt itself": "log.selfhit.hurtitself",
        "selfhit.recoil": "log.selfhit.recoil",
        "selfhit.crashed": "log.selfhit.crashed",
        "selfhit.fainted from the blast": "log.selfhit.blast",
        "selfhit.cut its own HP": "log.selfhit.cutownhp",
        "selfhit.drummed": "log.selfhit.drummed",
        "selfhit.gave everything": "log.selfhit.memento",
        // residual (end-of-round chip)
        "residual.burn": "log.residual.burn",
        "residual.poison": "log.residual.poison",
        "residual.leech seed": "log.residual.seed",
        "residual.trap": "log.residual.trap",
        "residual.curse": "log.residual.curse",
        "residual.nightmare": "log.residual.nightmare",
        "residual.asleep": "log.residual.asleep",       // Yawn caught up
        "residual.perish song": "log.residual.perish",
        // recover
        "recover.woke up": "log.recover.wokeup",
        "recover.thawed": "log.recover.thawed",
        "recover.snapped out": "log.recover.snapped",
        "recover.drained": "log.recover.drained",
        "recover.sapped": "log.recover.sapped",
        "recover.shared the pain": "log.recover.sharedpain",
        "recover.aqua ring": "log.recover.aquaring",
    ]

    private static func reasonLine(_ kind: String, _ reason: String, name: String) -> String {
        guard let key = reasonKey["\(kind).\(reason)"] else {
            return LF("log.generic", name, reason)   // unmapped: still show something
        }
        return LF(key, name)
    }

    /// statusApplied carries three shapes: engine ailment names, stat-stage
    /// tags ("ATK -1", possibly several per tag), and free-form mechanic tags
    /// ("transformed!", "seeded", "3 hits!"). Unknown tags fall back to
    /// log.generic — same fidelity as today's English float tags.
    private static func statusLines(_ status: String?, name: String) -> [String] {
        guard let s = status else { return [] }
        if let key = ailmentKey[s] { return [LF(key, name)] }
        if let statLines = parseStatTag(s, name: name) { return statLines }
        if let key = mechanicKey[s] { return [LF(key, name)] }
        if s.hasSuffix(" hits!"), let n = Int(s.dropLast(6)) {
            return [LF("log.tag.multihit", String(n))]
        }
        return [LF("log.generic", name, s)]
    }

    private static let ailmentKey: [String: String] = [
        "burn": "log.ailment.burn",
        "poison": "log.ailment.poison",
        "paralysis": "log.ailment.paralysis",
        "sleep": "log.ailment.sleep",
        "freeze": "log.ailment.freeze",
        "confusion": "log.ailment.confusion",
        "infatuation": "log.ailment.infatuation",
    ]

    private static let mechanicKey: [String: String] = [
        "transformed!": "log.tag.transformed",
        "seeded": "log.tag.seeded",
        "protected": "log.tag.protected",
        "nothing happened": "log.tag.nothing",
        "One-hit KO!": "log.tag.ohko",
    ]

    private static let statNameKey: [String: String] = [
        "ATK": "log.statname.atk", "DEF": "log.statname.def",
        "SP.ATK": "log.statname.spatk", "SP.DEF": "log.statname.spdef",
        "SPEED": "log.statname.speed", "ACC": "log.statname.acc",
        "EVA": "log.statname.eva",
    ]

    /// "ATK -1", "DEF +2", "ATK +1 DEF +1 SPEED -1" -> one line per stat.
    /// Returns nil unless the WHOLE tag parses as (label, signed int) pairs.
    private static func parseStatTag(_ s: String, name: String) -> [String]? {
        let tokens = s.split(separator: " ").map(String.init)
        guard !tokens.isEmpty, tokens.count % 2 == 0 else { return nil }
        var out: [String] = []
        for i in stride(from: 0, to: tokens.count, by: 2) {
            guard let statKey = statNameKey[tokens[i]], let delta = Int(tokens[i + 1]),
                  delta != 0 else { return nil }
            let template = delta >= 2 ? "log.stat.rose2"
                         : delta == 1 ? "log.stat.rose"
                         : delta == -1 ? "log.stat.fell" : "log.stat.fell2"
            out.append(LF(template, name, L(statKey)))
        }
        return out
    }
}
