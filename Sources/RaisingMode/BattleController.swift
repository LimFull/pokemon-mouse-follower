// Raising mode — wild encounters + on-overlay battle playback (Phase 2c/2d).
//
// Wild encounters spawn at a random screen spot on a long timer (D9) and wander
// (stop-and-go). When the active mon walks near, both stop and face each other
// and BattleEngine runs, the turns playing back on the overlay; the outcome
// (EXP/HP/evolution) is applied and the wild despawns. Distances scale with the
// sprite scale. Set PMF_FAST_BATTLE=1 for quick testing.

import AppKit


/// What the overlay should draw for the current battle frame (nil = nothing).
struct BattleScene {
    let wildFrame: CGImage
    let wildPos: CGPoint
    let playerPos: CGPoint
    let playerHP: Double
    let wildHP: Double
    let flashPlayer: Bool
    let flashWild: Bool
    let playerAlpha: Double
    let wildAlpha: Double
    let showBars: Bool
    let effectFrame: CGImage?    // move-effect sprite over the hit target (D22)
    let effectPos: CGPoint
    var playerPose: BattlePose = .stand   // battle pose for the follower (D2-1)
    var playerPoseTick: Int = 0
    var wildLevel: Int?                   // shown above the wild's head
    var playerDodge: CGPoint = .zero      // sidestep offset while evading a miss
    var floatText: String?                // floating combat tag ("Miss", "Super Effective!", ...)
    var floatPos: CGPoint = .zero
    var floatAlpha: Double = 0
    var floatColor: CGColor = CGColor(gray: 1, alpha: 1)
    var screenFlash: Double = 0           // full-screen effect veil 0...1 (Psychic & co)
    var screenColor: CGColor = CGColor(gray: 1, alpha: 1)
}

final class BattleController {
    /// The live controller (owned by the app delegate) so PartyState can route
    /// a mid-battle recall through the turn machinery.
    private(set) static weak var current: BattleController?

    private enum Phase { case idle, present, battling, ending }
    private var phase: Phase = .idle

    private let fast = ProcessInfo.processInfo.environment["PMF_FAST_BATTLE"] != nil
    private let eventTicks = 20
    private var spawnCooldown = 0
    private var despawnTicks = 0

    private var wild: Battler?
    private var wildMon: WildMon?
    private var playerPos = CGPoint.zero

    private var events: [BattleEvent] = []
    private var evIdx = 0
    private var evTick = 0
    private var curTicks = 20            // current event's playback length
    private var impactAt = 0             // tick where the attack visually connects
    private var hitAt = 0                // tick where the HP drain may start (#9)
    private var drainEnd = 0             // tick where the HP drain finishes
    private var effects: [RunningEffect] = []   // phases: projectile, then hit
    private var ballFrame: CGImage?      // thrown ball being drawn (D11)
    private var ballPos = CGPoint.zero
    private var playerPose: (BattlePose, Int) = (.stand, 0)   // pose + its tick
    private var playerDodge = CGPoint.zero
    private var wildDodge = CGPoint.zero
    private var floatText: String?
    private var floatPos = CGPoint.zero
    private var floatAlpha = 0.0
    private var floatColor = CGColor(gray: 1, alpha: 1)
    private var screenFlash = 0.0
    private var screenColor = CGColor(gray: 1, alpha: 1)
    private var lastTracedWildPose = BattlePose.stand   // PMF_TRACE_BATTLE only
    private var curPHP = 1.0, curWHP = 1.0
    private var pFrom = 1.0, pTo = 1.0, wFrom = 1.0, wTo = 1.0
    private var flashP = false, flashW = false
    private var playerAlpha = 1.0
    private var wildAlpha = 1.0
    private var result: BattleResult?
    private var endTicks = 0
    private var endTotal = 1             // endTicks' starting value (tag timing)
    private var recallTurn: Int?         // flee after this simulated turn ends
    private var levelUpTo: Int?          // show a level-up tag while ending
    private var curPStatus: String?      // ailment the playback has shown on the follower

    init() {
        spawnCooldown = nextSpawnDelay()
        BattleController.current = self
    }

    var isBattling: Bool { phase == .battling || phase == .ending }

    /// A recall was accepted but is waiting for the current turn to finish.
    var recallPending: Bool { recallTurn != nil }

    /// Mainline flee timing: a recall during battle playback only takes effect
    /// once the turn in progress fully plays out (both sides acted, plus any
    /// end-of-round chip damage). Returns true when the recall was deferred —
    /// the controller will perform it at the turn boundary; false means no
    /// turn machinery applies and the caller should recall immediately.
    func requestRecall() -> Bool {
        guard phase == .battling else { return false }
        if recallTurn == nil {
            recallTurn = evIdx < events.count ? events[evIdx].turn
                                              : (events.last?.turn ?? 0)
        }
        return true
    }

    /// Drop a pending flee (e.g. the player sent out someone else instead).
    func cancelRecallRequest() { recallTurn = nil }

    /// Debug: spawn a wild encounter immediately; `at` pins its position
    /// (used by the selftest to force a contact battle deterministically).
    func forceSpawn(at pos: CGPoint? = nil) {
        guard phase == .idle, let a = RaisingState.shared.active, !a.isFainted else { return }
        spawn(near: a)
        if let pos { wildMon?.place(at: pos) }
    }

    /// Debug: drop a chosen wild (nil = random) right next to the follower at
    /// the active mon's level — the battle starts on the next contact check.
    func forceEncounter(dex: Int? = nil) {
        guard AppSettings.shared.raisingMode,
              let a = RaisingState.shared.active, !a.isFainted else { return }
        if phase != .idle { despawn() }
        let level = max(2, a.level)
        guard let d = dex ?? GameData.wildPool(atLevel: level).randomElement(),
              let w = Battler(wildDex: d, level: level),
              let wm = WildMon(dex: d) else { return }
        wild = w
        wildMon = wm
        let scale = AppSettings.shared.scale
        wm.place(at: CGPoint(x: playerPos.x + 50 * scale, y: playerPos.y))
        despawnTicks = 5 * 60 * 60
        phase = .present
    }

    func update(playerGlobalPos: CGPoint) -> BattleScene? {
        playerPos = playerGlobalPos
        // Abort any encounter if raising mode was turned off or the party was
        // reset/emptied. A recall mid-battle is deferred to the turn boundary
        // (requestRecall) and only cancels the battle — the wild stays and
        // goes back to wandering; the active==nil check below is the safety
        // net for other ways the follower can vanish (e.g. released).
        if phase != .idle {
            if !AppSettings.shared.raisingMode || RaisingState.shared.party.isEmpty {
                despawn()
            } else if isBattling && RaisingState.shared.active == nil {
                cancelBattle()
            }
        }
        switch phase {
        case .idle: tickIdle()
        case .present: tickPresent()
        case .battling: tickBattling()
        case .ending: tickEnding()
        }
        return scene()
    }

    // MARK: phases

    private func tickIdle() {
        guard AppSettings.shared.raisingMode, AppSettings.shared.wildSpawnsEnabled,
              let a = RaisingState.shared.active, !a.isFainted else { return }
        spawnCooldown -= 1
        if spawnCooldown <= 0 { spawn(near: a) }
    }

    private func spawn(near active: OwnedPokemon) {
        // Level scales to the ACTIVE mon, capped just above it so wilds stay
        // beatable (#2); species must fit the level — no under-leveled evolved
        // forms like a Lv5 Butterfree (#12, GameData.minWildLevel).
        let level = min(100, max(2, active.level + Int.random(in: -4...2)))
        guard let dex = GameData.wildPool(atLevel: level).randomElement(),
              let w = Battler(wildDex: dex, level: level),
              let wm = WildMon(dex: dex) else { spawnCooldown = 120; return }
        let b = screenBounds()
        wm.place(at: CGPoint(x: .random(in: b.minX + 80 ... b.maxX - 80),
                             y: .random(in: b.minY + 80 ... b.maxY - 80)))
        wild = w
        wildMon = wm
        despawnTicks = (fast ? 30 : 5 * 60) * 60
        phase = .present
    }

    private func tickPresent() {
        if !AppSettings.shared.wildSpawnsEnabled { despawn(); return }
        despawnTicks -= 1
        if despawnTicks <= 0 { despawn(); return }
        guard let wm = wildMon else { despawn(); return }
        let scale = AppSettings.shared.scale
        let d = hypot(playerPos.x - wm.pos.x, playerPos.y - wm.pos.y)
        let active = RaisingState.shared.active
        let conscious = !(active?.isFainted ?? true)
        // A fainted mon is ignored — the wild just wanders. Near a conscious
        // one it stops and watches; the battle starts on actual contact and is
        // fought right where they meet (no teleporting stance snap).
        if conscious, d < 56 * scale { startBattle(); return }
        if conscious && d < 90 * scale { wm.faceStanding(toward: playerPos) }
        else { wm.wander(bounds: screenBounds()) }
    }

    private func startBattle() {
        guard let w = wild, let wm = wildMon, let mon = RaisingState.shared.active, let p = Battler(mon: mon) else { despawn(); return }
        // Fight where they met. Only un-overlap: if the two are practically on
        // top of each other, nudge the wild out to a minimal gap.
        let scale = AppSettings.shared.scale
        var dx = wm.pos.x - playerPos.x, dy = wm.pos.y - playerPos.y
        let dist = max(0.001, hypot(dx, dy)); dx /= dist; dy /= dist
        let minGap = 36 * scale
        if dist < minGap {
            wm.setPos(CGPoint(x: playerPos.x + dx * minGap, y: playerPos.y + dy * minGap))
        }
        wm.faceStanding(toward: playerPos)
        // Balls to throw (D11) — only when the bag's capture toggle is on; a
        // full party still catches (the release-or-abandon prompt resolves it
        // afterwards). Cheap balls go first.
        let st = RaisingState.shared
        var balls: [GameItem] = []
        if st.captureEnabled {
            balls = Array(repeating: GameItem.pokeBall, count: min(3, st.itemCount(.pokeBall)))
            balls += Array(repeating: .greatBall, count: min(3 - balls.count, st.itemCount(.greatBall)))
        }
        // Gauges start at the REAL current/max ratio (a hurt mon enters hurt;
        // a rematched wild keeps its damage) — captured before run() mutates
        // both battlers to their end state.
        let startPHP = frac(p.currentHP, p.maxHP)
        let startWHP = frac(w.currentHP, w.maxHP)
        result = BattleEngine.run(player: p, wild: w, balls: balls)
        events = result?.events ?? []
        curPStatus = mon.status
        evIdx = 0; evTick = 0; curPHP = startPHP; curWHP = startWHP
        wildAlpha = 1.0; playerAlpha = 1.0
        flashP = false; flashW = false
        phase = .battling
    }

    private func tickBattling() {
        guard evIdx < events.count else {
            wildMon?.faceStanding(toward: playerPos)
            finishBattle()
            return
        }
        let e = events[evIdx]
        if evTick == 0 {
            // Pending recall + the next event opens a LATER turn: the turn the
            // player was committed to has fully played — flee now, before the
            // new turn starts. The engine reorders combatants every turn by
            // effectiveSpeed, so the stamped turn number is the only safe
            // boundary marker.
            if let rt = recallTurn, e.turn > rt {
                recallTurn = nil
                cancelBattle()
                RaisingState.shared.recall()
                return
            }
            beginEvent(e)
        }
        // Battle poses (D2-1): attacker lunges/shoots, the hit side flinches.
        let (pPose, wPose) = poses(for: e)
        playerPose = pPose
        if ProcessInfo.processInfo.environment["PMF_TRACE_BATTLE"] != nil, wPose.0 != lastTracedWildPose {
            lastTracedWildPose = wPose.0
            print("  wildPose -> \(wPose.0) (event \(e.kind), actorIsPlayer=\(e.actorIsPlayer), evTick=\(evTick))")
        }
        wildMon?.faceStanding(toward: playerPos, pose: wPose.0, poseTick: wPose.1)
        // #9: the HP bar drains only AFTER the attack finished landing —
        // attack plays (0..hitAt), damage drains (hitAt..drainEnd), pause.
        if drainEnd > hitAt {
            let t = min(1.0, max(0.0, Double(evTick - hitAt) / Double(drainEnd - hitAt)))
            if e.targetIsPlayer { curPHP = lerp(pFrom, pTo, t) } else { curWHP = lerp(wFrom, wTo, t) }
        }
        let flashing = e.damage > 0 && evTick >= impactAt && evTick < impactAt + 10
        flashP = flashing && e.targetIsPlayer
        flashW = flashing && !e.targetIsPlayer
        tickDodge(e)
        tickLunge(e)
        tickFloatText(e)
        tickScreenFX(e)
        if e.kind == .ball { tickBall(e) }
        if !effects.isEmpty {
            effects[0].advance()
            if effects[0].isDone { effects.removeFirst() }
        }
        evTick += 1
        if evTick >= curTicks { evTick = 0; evIdx += 1 }
    }

    /// Miss handling (#10): the defender sidesteps out and back, perpendicular
    /// to the attack line.
    private func tickDodge(_ e: BattleEvent) {
        playerDodge = .zero; wildDodge = .zero
        // Sidestep only attacks that could have hurt — a whiffed status move
        // has nothing to dodge.
        guard e.kind == .miss, e.moveId > 0, BattleEngine.isDamaging(e.moveId) else { return }
        let scale = AppSettings.shared.scale
        let defenderPos = e.targetIsPlayer ? playerPos : (wildMon?.pos ?? playerPos)
        let attackerPos = e.targetIsPlayer ? (wildMon?.pos ?? playerPos) : playerPos
        let dodgeSpan = 22
        if evTick >= impactAt, evTick < impactAt + dodgeSpan {
            let t = CGFloat(evTick - impactAt) / CGFloat(dodgeSpan)
            var dx = defenderPos.x - attackerPos.x, dy = defenderPos.y - attackerPos.y
            let d = max(0.001, hypot(dx, dy)); dx /= d; dy /= d
            let amp = sin(t * .pi) * 20 * scale
            let off = CGPoint(x: -dy * amp, y: dx * amp)
            if e.targetIsPlayer { playerDodge = off } else { wildDodge = off }
        }
    }

    /// The moment an ailment is inflicted: (float label, color, status-clip
    /// key). Keyed by the engine's ailment names carried in statusApplied.
    private static let ailmentLanding: [String: (String, NSColor, String)] = [
        "paralysis": ("Paralyzed!", NSColor(srgbRed: 0.98, green: 0.85, blue: 0.25, alpha: 1), "paralyzed"),
        "burn": ("Burned!", NSColor(srgbRed: 1.0, green: 0.55, blue: 0.25, alpha: 1), "burn"),
        "poison": ("Poisoned!", NSColor(srgbRed: 0.75, green: 0.45, blue: 0.95, alpha: 1), "poison"),
        "sleep": ("Fell asleep!", NSColor(srgbRed: 0.65, green: 0.72, blue: 0.95, alpha: 1), "asleep"),
        "freeze": ("Frozen!", NSColor(srgbRed: 0.55, green: 0.85, blue: 0.95, alpha: 1), "frozen"),
        "confusion": ("Confused!", NSColor(srgbRed: 0.9, green: 0.6, blue: 0.95, alpha: 1), "confused"),
        "infatuation": ("In love!", NSColor(srgbRed: 0.98, green: 0.55, blue: 0.72, alpha: 1), "infatuated"),
    ]

    /// Floating combat tag over the defender at impact: "Miss"/"No Effect" on
    /// a whiff, "Super Effective!"/"Not Very Effective.." by type matchup.
    private func tickFloatText(_ e: BattleEvent) {
        floatText = nil; floatAlpha = 0
        // An ailment landing gets its own late window (after the HP drain and
        // the effectiveness tag's beat) so "Super Effective!" and "Burned!"
        // both get read on a burning Flamethrower hit.
        if e.kind == .attack, let s = e.statusApplied,
           let (label, color, _) = Self.ailmentLanding[s] {
            let span = 44
            if evTick >= drainEnd, evTick < drainEnd + span {
                let scale = AppSettings.shared.scale
                let anchor = e.targetIsPlayer ? playerPos : (wildMon?.pos ?? playerPos)
                let t = Double(evTick - drainEnd) / Double(span)
                floatText = label
                floatPos = CGPoint(x: anchor.x,
                                   y: anchor.y + (26 + CGFloat(t) * 14) * scale)
                floatAlpha = 1.0 - t * 0.8
                floatColor = color.cgColor
                return
            }
            if evTick >= drainEnd { return }   // window over — stay clear
        }
        var text: String?
        var color = NSColor(srgbRed: 1.0, green: 0.85, blue: 0.3, alpha: 1)   // miss yellow
        var overActor = false
        switch e.kind {
        case .miss where e.moveId > 0:
            text = e.effectiveness == 0 ? "No Effect" : "Miss"
        case .attack where e.crit && e.damage > 0:
            text = "Critical Hit!"
            color = NSColor(srgbRed: 1.0, green: 0.5, blue: 0.15, alpha: 1)
        case .attack where e.damage > 0 && e.effectiveness > 1:
            text = "Super Effective!"
            color = NSColor(srgbRed: 1.0, green: 0.45, blue: 0.25, alpha: 1)
        case .attack where e.damage > 0 && e.effectiveness > 0 && e.effectiveness < 1:
            text = "Not Very Effective.."
            color = NSColor(srgbRed: 0.75, green: 0.78, blue: 0.85, alpha: 1)
        case .skip:
            // Lost turn — say why, over the one who lost it.
            overActor = true
            switch e.moveName {
            case "asleep": text = "Zzz.."; color = NSColor(srgbRed: 0.65, green: 0.72, blue: 0.95, alpha: 1)
            case "frozen": text = "Frozen!"; color = NSColor(srgbRed: 0.55, green: 0.85, blue: 0.95, alpha: 1)
            case "paralyzed": text = "Paralyzed!"; color = NSColor(srgbRed: 0.98, green: 0.85, blue: 0.25, alpha: 1)
            case "infatuated": text = "In love!"; color = NSColor(srgbRed: 0.98, green: 0.55, blue: 0.72, alpha: 1)
            case "charging": text = "Charging.."; color = NSColor(srgbRed: 0.98, green: 0.80, blue: 0.35, alpha: 1)
            case "recharging": text = "Recharging.."; color = NSColor(srgbRed: 0.75, green: 0.78, blue: 0.85, alpha: 1)
            case "storing": text = "Storing energy.."; color = NSColor(srgbRed: 0.75, green: 0.78, blue: 0.85, alpha: 1)
            case "fled": text = "Fled!"; color = NSColor(srgbRed: 0.75, green: 0.78, blue: 0.85, alpha: 1)
            default: break
            }
        case .attack where e.damage == 0:
            // Mechanic tags: stat stages ("DEF -1"), "transformed!", walls,
            // "nothing happened" — anything that isn't a persisted ailment.
            if let tag = e.statusApplied, Ailment(rawValue: tag) == nil,
               !["confusion", "infatuation"].contains(tag) {
                overActor = e.targetIsPlayer == e.actorIsPlayer
                text = tag
                color = tag.contains("-") ? NSColor(srgbRed: 0.55, green: 0.65, blue: 0.95, alpha: 1)
                                          : NSColor(srgbRed: 0.98, green: 0.72, blue: 0.30, alpha: 1)
            }
        default:
            return
        }
        let span = 44
        guard let text, evTick >= impactAt, evTick < impactAt + span else { return }
        let scale = AppSettings.shared.scale
        let anchorIsPlayer = overActor ? e.actorIsPlayer : e.targetIsPlayer
        let anchor = anchorIsPlayer ? playerPos : (wildMon?.pos ?? playerPos)
        let t = Double(evTick - impactAt) / Double(span)
        floatText = text
        floatPos = CGPoint(x: anchor.x,
                           y: anchor.y + (26 + CGFloat(t) * 14) * scale)
        floatAlpha = 1.0 - t * 0.8
        floatColor = color.cgColor
    }

    /// Full-screen move (Psychic & co): a brief type-colored veil over the
    /// whole screen plus a quake on both combatants around the impact.
    private func tickScreenFX(_ e: BattleEvent) {
        screenFlash = 0
        guard e.kind == .attack || e.kind == .miss, EffectPlayer.isScreen(e.moveId),
              evTick >= impactAt, evTick < impactAt + 20 else { return }
        let t = Double(evTick - impactAt) / 20.0
        screenFlash = sin(t * .pi)
        screenColor = TypeStyle.color(GameData.moves[e.moveId]?.type).cgColor
        let scale = AppSettings.shared.scale
        let jitter = CGFloat(sin(Double(evTick) * 1.9)) * 3 * scale * CGFloat(1 - t)
        playerDodge.x += jitter
        wildDodge.x -= jitter
    }

    /// Contact-move lunge: the attacker physically darts at the defender,
    /// peaking exactly at the impact tick, then springs back. Makes a Tackle
    /// read as a body blow on BOTH sides regardless of how animated the
    /// species' Attack sheet is. Projectile moves stay put (they shoot);
    /// full-screen moves neither lunge nor shoot.
    private func tickLunge(_ e: BattleEvent) {
        // Only a landed hit (or a whiffed DAMAGING move) is a body blow —
        // status moves (Leer, Defense Curl, ...) play their effect clip and
        // pose in place instead of ramming the foe.
        guard e.kind == .attack || e.kind == .miss, e.moveId > 0,
              e.damage > 0 || (e.kind == .miss && BattleEngine.isDamaging(e.moveId)),
              !EffectPlayer.isScreen(e.moveId),
              !EffectPlayer.hasProjectile(e.moveId) else { return }
        let scale = AppSettings.shared.scale
        let attackerPos = e.actorIsPlayer ? playerPos : (wildMon?.pos ?? playerPos)
        let defenderPos = e.actorIsPlayer ? (wildMon?.pos ?? playerPos) : playerPos
        var dx = defenderPos.x - attackerPos.x, dy = defenderPos.y - attackerPos.y
        let d = max(0.001, hypot(dx, dy)); dx /= d; dy /= d
        let springBack = 12
        var f: CGFloat = 0
        if evTick < impactAt {
            let t = CGFloat(evTick) / CGFloat(max(1, impactAt))
            f = t * t                                  // accelerate in
        } else if evTick < impactAt + springBack {
            f = 1 - CGFloat(evTick - impactAt) / CGFloat(springBack)
        }
        let amp = f * min(d * 0.55, 26 * scale)        // close the gap, don't overlap
        let off = CGPoint(x: dx * amp, y: dy * amp)
        if e.actorIsPlayer { playerDodge = off } else { wildDodge = off }
    }

    /// Per-tick battle poses for the current event (D2-1): the attacker plays
    /// Attack (Shoot for projectile moves) at the start of its beat; the side
    /// taking damage plays Hurt as the hit lands (a missed target dodges
    /// instead — tickDodge).
    private func poses(for e: BattleEvent) -> (player: (BattlePose, Int), wild: (BattlePose, Int)) {
        // A sleeping side stays in its sleep pose through EVERYONE's beats —
        // it only breaks pose to flinch when actually hit (overrides below).
        var p: (BattlePose, Int) = e.playerAsleep ? (.sleep, evTick) : (.stand, 0)
        var w: (BattlePose, Int) = e.wildAsleep ? (.sleep, evTick) : (.stand, 0)
        switch e.kind {
        case .attack, .miss:
            let hasProj = EffectPlayer.hasProjectile(e.moveId)
            // Attack anim runs through the impact (holding its last frame just
            // past it), so a lunge isn't cut off mid-swing.
            if evTick < min(36, impactAt + 12) {
                let atk = (hasProj ? BattlePose.shoot : .attack, evTick)
                if e.actorIsPlayer { p = atk } else { w = atk }
            }
            if e.kind == .attack, e.damage > 0, evTick >= impactAt, evTick < impactAt + 18 {
                let hurtPose = (BattlePose.hurt, evTick - impactAt)
                if e.targetIsPlayer { p = hurtPose } else { w = hurtPose }
            }
        case .selfHit:
            if evTick >= impactAt, evTick < impactAt + 18 {
                let hurtPose = (BattlePose.hurt, evTick - impactAt)
                if e.actorIsPlayer { p = hurtPose } else { w = hurtPose }
            }
        case .residual:
            // Hurt pose held while the burn/poison effect plays (user req).
            if evTick >= impactAt, evTick < hitAt + 6 {
                let hurtPose = (BattlePose.hurt, evTick - impactAt)
                if e.targetIsPlayer { p = hurtPose } else { w = hurtPose }
            }
        case .skip where e.moveName == "asleep":
            // Asleep: the actor visibly sleeps through its turn.
            let sleepPose = (BattlePose.sleep, evTick)
            if e.actorIsPlayer { p = sleepPose } else { w = sleepPose }
        default:
            break
        }
        return (p, w)
    }

    /// Ball-throw beat (D11): the ball arcs player -> wild, the wild is pulled
    /// in, the ball wobbles once per passed shake check, then either clicks
    /// shut (caught — the wild stays in) or bursts open (the wild pops back).
    private func tickBall(_ e: BattleEvent) {
        let icon = GameItem(rawValue: e.ballId)?.icon
        let scale = AppSettings.shared.scale
        let wpos = wildMon?.pos ?? playerPos
        let flight = 16
        if evTick < flight {
            let f = CGFloat(evTick) / CGFloat(flight)
            ballFrame = icon
            ballPos = CGPoint(x: playerPos.x + (wpos.x - playerPos.x) * f,
                              y: playerPos.y + (wpos.y - playerPos.y) * f
                                 + sin(f * .pi) * 34 * scale)
            wildAlpha = 1
            return
        }
        wildAlpha = 0                              // pulled inside the ball
        let st = evTick - flight
        let shakeLen = 14
        if st < e.shakes * shakeLen {
            let phase = CGFloat(st % shakeLen) / CGFloat(shakeLen)
            ballFrame = icon
            ballPos = CGPoint(x: wpos.x + sin(phase * 2 * .pi) * 4 * scale, y: wpos.y)
        } else if e.caught {
            ballFrame = icon                       // sits still, wild stays in
            ballPos = wpos
        } else {
            ballFrame = nil                        // burst open — the wild is back
            wildAlpha = 1
        }
    }

    /// Set up one event beat (#8/#9 pacing): the attack (poses + projectile +
    /// hit effect) plays out first, THEN the HP bar drains, then a clear pause
    /// before the next combatant acts. Misses run the same attack but resolve
    /// into a dodge instead of a drain (#10).
    private func beginEvent(_ e: BattleEvent) {
        let to = frac(e.targetHP, e.targetMaxHP)
        if e.targetIsPlayer { pFrom = curPHP; pTo = to }
        else { wFrom = curWHP; wTo = to }

        // Track the major ailment the playback has shown on the follower so
        // far — a flee (cancelBattle) takes it home along with the gauge HP.
        // Volatiles (confusion/infatuation) don't persist, so they're skipped.
        // Only genuine cures clear it: HP-restoring recovers (drains, Recover,
        // Wish) and confusion's "snapped out" leave the ailment alone.
        if e.targetIsPlayer, let s = e.statusApplied, Ailment(rawValue: s) != nil { curPStatus = s }
        if e.kind == .recover, e.targetIsPlayer,
           ["woke up", "thawed", "Refresh", "Heal Bell", "Aromatherapy"].contains(e.moveName) {
            curPStatus = nil
        }

        effects = []
        ballFrame = nil
        switch e.kind {
        case .ball:
            hitAt = 0; drainEnd = 0
            // flight + one wobble per shake + a settle/burst tail
            curTicks = 16 + e.shakes * 14 + 26
        case .attack, .miss:
            // Same effect timeline for hits and misses (#10). Projectiles
            // connect when the shot arrives (travel end); contact moves after
            // a windup, so the hit effect bursts as the lunge lands — not at
            // the start of the attack animation.
            let wildPos = wildMon?.pos ?? playerPos
            let target = e.targetIsPlayer ? playerPos : wildPos
            let attacker = e.actorIsPlayer ? playerPos : wildPos
            let travel = 18, windup = 20
            var total = 0
            // Travel direction picks the projectile's facing (8-dir ROM sets).
            var octant = 6
            let ddx = target.x - attacker.x, ddy = target.y - attacker.y
            if abs(ddx) > 0.01 || abs(ddy) > 0.01 {
                var deg = atan2(ddy, ddx) * 180 / .pi
                if deg < 0 { deg += 360 }
                octant = Int((deg / 45).rounded()) % 8
            }
            let proj = e.moveId > 0 ? EffectPlayer.projectile(forMove: e.moveId, octant: octant) : nil
            if let proj {
                effects.append(RunningEffect(clip: proj, from: attacker, to: target, maxTicks: travel))
                total = travel
            } else {
                total = windup
            }
            impactAt = total
            if e.moveId > 0, let clip = EffectPlayer.clip(forMove: e.moveId) {
                let hitTicks = min(clip.loop ? 40 : clip.totalTicks, 54)
                let delay = proj == nil ? windup : 0
                effects.append(RunningEffect(clip: clip, anchor: target,
                                             maxTicks: delay + hitTicks, delay: delay))
                total += hitTicks
            }
            hitAt = max(impactAt, min(total, 72))
            if EffectPlayer.isScreen(e.moveId) { hitAt = impactAt + 20 }   // flash duration
            let resolve = e.damage > 0 ? 26 : (e.kind == .miss ? 24 : 10)
            drainEnd = hitAt + resolve
            curTicks = drainEnd + (fast ? 8 : 16)   // beat gap before the reply
            // An inflicted ailment announces itself: its status clip queues up
            // after the move's own effect, and the beat stretches so the
            // "Burned!"-style tag (tickFloatText) has room to play out.
            if e.kind == .attack, let s = e.statusApplied,
               let (_, _, clipKey) = Self.ailmentLanding[s] {
                if let clip = EffectPlayer.statusClip(clipKey) {
                    let ticks = min(clip.loop ? 30 : clip.totalTicks, 44)
                    effects.append(RunningEffect(clip: clip, anchor: target, maxTicks: ticks))
                }
                curTicks = max(curTicks, drainEnd + 52)
            }
        case .residual:
            // Mainline end-of-turn chip damage: play the condition's effect
            // (burn flames / poison gas) over the victim WITH the hurt pose,
            // then drain — same beat order as an attack (#9).
            let victim = e.targetIsPlayer ? playerPos : (wildMon?.pos ?? playerPos)
            impactAt = 8
            hitAt = 22
            if let clip = EffectPlayer.statusClip(e.moveName) {
                let ticks = min(clip.loop ? 30 : clip.totalTicks, 44)
                effects.append(RunningEffect(clip: clip, anchor: victim, maxTicks: ticks))
                hitAt = max(hitAt, ticks)
            }
            drainEnd = hitAt + 24
            curTicks = drainEnd + 12
        case .selfHit:
            impactAt = 6
            hitAt = 6
            drainEnd = hitAt + 24
            curTicks = drainEnd + 12
        case .skip:
            // A lost turn must be readable (paralyzed / frozen / asleep / in
            // love): the condition's effect plays over the ACTOR + a float tag.
            let actor = e.actorIsPlayer ? playerPos : (wildMon?.pos ?? playerPos)
            impactAt = 4; hitAt = 0; drainEnd = 0
            curTicks = 34
            if let clip = EffectPlayer.statusClip(e.moveName) {
                let ticks = min(clip.loop ? 30 : clip.totalTicks, 44)
                effects.append(RunningEffect(clip: clip, anchor: actor, maxTicks: ticks, delay: 4))
                curTicks = max(curTicks, ticks + 16)
            }
            if e.moveName == "asleep" { curTicks = 46 }   // let the sleep pose breathe
        case .recover:
            // HP restores (drain heals, Recover, Wish, ...) animate the gauge
            // back up — the lerp is direction-agnostic. Pure cures ("woke up")
            // carry an unchanged snapshot and stay flat.
            impactAt = 6; hitAt = 8
            drainEnd = hitAt + 22
            curTicks = drainEnd + 12
        }
    }

    private func finishBattle() {
        let won = result?.playerWon ?? false
        var captured = false
        if let r = result {
            let st = RaisingState.shared
            for b in r.ballsUsed { st.consumeItem(b) }
            let expIdx = st.save.activeIndex        // who fought (before faint swap)
            let growth = st.applyBattleOutcome(playerHP: r.playerEndHP, status: r.playerEndStatus,
                                               won: r.playerWon, expGained: r.expGained)
            // A 5th move needs a replace decision — on-overlay prompt (C1/#5).
            for moveId in growth.pendingMoves {
                PromptCenter.shared.enqueue(.learnMove(monIndex: expIdx, moveId: moveId))
            }
            levelUpTo = growth.leveledTo
            if r.captured, let w = wild {
                captured = true
                if st.partyHasRoom {
                    _ = st.addCaptured(from: w)
                } else if let mon = st.capturedMon(from: w) {
                    // Full party: release someone or let the catch go (D14/#14).
                    PromptCenter.shared.enqueue(.fullParty(captured: mon))
                }
            }
        }
        if captured {
            // The wild is inside the ball (already hidden); linger briefly.
            endTicks = fast ? 30 : 60
            endTotal = endTicks
            phase = .ending
        } else if won {
            ballFrame = nil
            // A level-up tag needs a beat longer to read (mainline jingle).
            endTicks = levelUpTo != nil ? (fast ? 60 : 130) : (fast ? 40 : 90)
            endTotal = endTicks
            phase = .ending                 // the beaten wild fades away
        } else if result?.wildFled == true {
            // The wild teleported / was roared away: it slips off with no
            // spoils — fade it out like a win, minus the EXP.
            ballFrame = nil
            endTicks = fast ? 30 : 60
            endTotal = endTicks
            phase = .ending
        } else {
            ballFrame = nil
            // My mon fainted (it now stays down where it fell). The wild is NOT
            // defeated — it lingers/wanders so I can send out another mon and keep
            // challenging it; it leaves on its own despawn timer.
            phase = .present
        }
        // The battle ended during the turn the flee was waiting on — the
        // outcome stands (applied above), THEN the recall goes through.
        if recallTurn != nil {
            recallTurn = nil
            RaisingState.shared.recall()
        }
    }

    private func tickEnding() {
        wildMon?.faceStanding(toward: playerPos)
        endTicks -= 1
        if ballFrame == nil {
            wildAlpha = max(0, Double(endTicks) / 40.0)   // defeated wild fades out
        }                                                  // caught: stays in the ball
        // Level-up tag over the winner's head (mainline post-battle beat):
        // same floating-tag pipeline as "Miss"/"Super Effective!", gold, and
        // drifting upward across the whole ending.
        floatText = nil; floatAlpha = 0
        if let lv = levelUpTo {
            let t = min(1.0, max(0.0, Double(endTotal - endTicks) / Double(endTotal)))
            let scale = AppSettings.shared.scale
            floatText = "Level Up! Lv.\(lv)"
            floatPos = CGPoint(x: playerPos.x,
                               y: playerPos.y + (28 + CGFloat(t) * 16) * scale)
            floatAlpha = 1.0 - t * 0.8
            floatColor = NSColor(srgbRed: 1.0, green: 0.84, blue: 0.25, alpha: 1).cgColor
        }
        if endTicks <= 0 { despawn() }
    }

    /// Break off the current battle without applying its pre-simulated
    /// outcome: BOTH sides keep what their gauges were showing — the wild its
    /// HP (resumes wandering), the follower its HP and shown ailment. No EXP,
    /// nothing consumed; fleeing is never a free heal and never faints.
    private func cancelBattle() {
        if let w = wild { w.currentHP = max(1, Int(curWHP * Double(w.maxHP))) }
        if let mon = RaisingState.shared.active {
            RaisingState.shared.applyFleeState(
                hp: Int((curPHP * Double(mon.maxHP)).rounded()), status: curPStatus)
        }
        recallTurn = nil
        events = []; result = nil; effects = []; ballFrame = nil
        playerPose = (.stand, 0)
        playerDodge = .zero; wildDodge = .zero
        floatText = nil; floatAlpha = 0; screenFlash = 0
        flashP = false; flashW = false
        wildAlpha = 1; playerAlpha = 1
        evIdx = 0; evTick = 0
        phase = .present
    }

    private func despawn() {
        recallTurn = nil
        levelUpTo = nil
        floatText = nil; floatAlpha = 0
        wild = nil; wildMon = nil; events = []; result = nil; effects = []; ballFrame = nil
        playerAlpha = 1.0; wildAlpha = 1.0
        phase = .idle
        spawnCooldown = nextSpawnDelay()
    }

    // MARK: scene

    private func scene() -> BattleScene? {
        guard phase != .idle, let wm = wildMon, let frame = wm.currentFrame else { return nil }
        let fx = ballFrame.map { ($0, ballPos) }
            ?? effects.first?.current(scale: AppSettings.shared.scale)
        return BattleScene(
            wildFrame: frame,
            wildPos: CGPoint(x: wm.pos.x + wildDodge.x, y: wm.pos.y + wildDodge.y),
            playerPos: playerPos,
            playerHP: curPHP, wildHP: curWHP, flashPlayer: flashP, flashWild: flashW,
            playerAlpha: playerAlpha, wildAlpha: wildAlpha, showBars: isBattling,
            effectFrame: fx?.0, effectPos: fx?.1 ?? .zero,
            playerPose: phase == .battling ? playerPose.0 : .stand,
            playerPoseTick: playerPose.1,
            wildLevel: wild?.level,
            playerDodge: playerDodge,
            floatText: floatText, floatPos: floatPos,
            floatAlpha: floatAlpha, floatColor: floatColor,
            screenFlash: screenFlash, screenColor: screenColor)
    }

    // MARK: helpers

    private func frac(_ hp: Int, _ maxHP: Int) -> Double { Double(hp) / Double(max(1, maxHP)) }
    private func lerp(_ a: Double, _ b: Double, _ t: Double) -> Double { a + (b - a) * t }

    private func screenBounds() -> CGRect {
        var r = CGRect.null
        for s in NSScreen.screens { r = r.union(s.frame) }
        return r.isNull ? CGRect(x: 0, y: 0, width: 1440, height: 900) : r
    }

    /// Random delay around the user's average encounter interval (D9): the
    /// setting is the mean in minutes; actual spawns land in ±25% of it.
    private func nextSpawnDelay() -> Int {
        if fast { return 60 * 4 }   // 4s for testing
        let avg = Double(AppSettings.shared.encounterMinutes) * 60   // seconds
        return Int(Double.random(in: (avg * 0.75)...(avg * 1.25))) * 60
    }
}
