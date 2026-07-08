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
}

final class BattleController {
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
    private var effects: [RunningEffect] = []   // phases: projectile, then hit
    private var ballFrame: CGImage?      // thrown ball being drawn (D11)
    private var ballPos = CGPoint.zero
    private var curPHP = 1.0, curWHP = 1.0
    private var pFrom = 1.0, pTo = 1.0, wFrom = 1.0, wTo = 1.0
    private var flashP = false, flashW = false
    private var playerAlpha = 1.0
    private var wildAlpha = 1.0
    private var result: BattleResult?
    private var endTicks = 0

    init() { spawnCooldown = nextSpawnDelay() }

    var isBattling: Bool { phase == .battling || phase == .ending }

    /// Debug: spawn a wild encounter immediately; `at` pins its position
    /// (used by the selftest to force a contact battle deterministically).
    func forceSpawn(at pos: CGPoint? = nil) {
        guard phase == .idle, let a = RaisingState.shared.active, !a.isFainted else { return }
        spawn(near: a)
        if let pos { wildMon?.place(at: pos) }
    }

    func update(playerGlobalPos: CGPoint) -> BattleScene? {
        playerPos = playerGlobalPos
        // Abort any encounter if raising mode was turned off or the party was
        // reset/emptied, so a later spawn (or reset) isn't blocked by stale state.
        if phase != .idle && (!AppSettings.shared.raisingMode || RaisingState.shared.active == nil) {
            despawn()
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
        guard AppSettings.shared.raisingMode, let a = RaisingState.shared.active, !a.isFainted else { return }
        spawnCooldown -= 1
        if spawnCooldown <= 0 { spawn(near: a) }
    }

    private func spawn(near active: OwnedPokemon) {
        let level = max(2, active.level + Int.random(in: -3...3))
        let dex = Int.random(in: 1...251)
        guard let w = Battler(wildDex: dex, level: level), let wm = WildMon(dex: dex) else { spawnCooldown = 120; return }
        let b = screenBounds()
        wm.place(at: CGPoint(x: .random(in: b.minX + 80 ... b.maxX - 80),
                             y: .random(in: b.minY + 80 ... b.maxY - 80)))
        wild = w
        wildMon = wm
        despawnTicks = (fast ? 30 : 5 * 60) * 60
        phase = .present
    }

    private func tickPresent() {
        despawnTicks -= 1
        if despawnTicks <= 0 { despawn(); return }
        guard let wm = wildMon else { despawn(); return }
        let scale = AppSettings.shared.scale
        let d = hypot(playerPos.x - wm.pos.x, playerPos.y - wm.pos.y)
        let active = RaisingState.shared.active
        let conscious = !(active?.isFainted ?? true)
        // A fainted mon is ignored — the wild just wanders. A conscious one that
        // wanders close is noticed (stop & look) and, on contact, battled.
        if conscious && d < 150 * scale { wm.faceStanding(toward: playerPos) }
        else { wm.wander(bounds: screenBounds()) }
        if conscious, d < 85 * scale { startBattle() }
    }

    private func startBattle() {
        guard let w = wild, let wm = wildMon, let mon = RaisingState.shared.active, let p = Battler(mon: mon) else { despawn(); return }
        // Snap the wild to a battle stance: a scale-relative gap from the player,
        // along the direction they met, facing each other.
        let scale = AppSettings.shared.scale
        var dx = wm.pos.x - playerPos.x, dy = wm.pos.y - playerPos.y
        let dist = max(0.001, hypot(dx, dy)); dx /= dist; dy /= dist
        wm.setPos(CGPoint(x: playerPos.x + dx * 75 * scale, y: playerPos.y + dy * 75 * scale))
        wm.faceStanding(toward: playerPos)
        // Balls to throw (D11): only with party room; cheap balls go first.
        var balls: [GameItem] = []
        if RaisingState.shared.partyHasRoom {
            let st = RaisingState.shared
            balls += Array(repeating: .pokeBall, count: min(3, st.itemCount(.pokeBall)))
            balls += Array(repeating: .greatBall, count: min(3 - balls.count, st.itemCount(.greatBall)))
        }
        result = BattleEngine.run(player: p, wild: w, balls: balls)
        events = result?.events ?? []
        evIdx = 0; evTick = 0; curPHP = 1.0; curWHP = 1.0; wildAlpha = 1.0; playerAlpha = 1.0
        flashP = false; flashW = false
        phase = .battling
    }

    private func tickBattling() {
        wildMon?.faceStanding(toward: playerPos)
        guard evIdx < events.count else { finishBattle(); return }
        let e = events[evIdx]
        if evTick == 0 { beginEvent(e) }
        let t = min(1.0, Double(evTick) / Double(curTicks) * 1.4)
        if e.targetIsPlayer { curPHP = lerp(pFrom, pTo, t) } else { curWHP = lerp(wFrom, wTo, t) }
        if evTick > 8 { flashP = false; flashW = false }
        if e.kind == .ball { tickBall(e) }
        if !effects.isEmpty {
            effects[0].advance()
            if effects[0].isDone { effects.removeFirst() }
        }
        evTick += 1
        if evTick >= curTicks { evTick = 0; evIdx += 1 }
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

    /// Set up one event beat: HP-bar animation targets, hit flash, and the
    /// move-effect phases — a projectile flown attacker -> target when the
    /// move has one, then the hit clip over whoever got hit. The beat lasts
    /// long enough for the phases to play out (capped so slow effects don't
    /// stall the battle); misses/skips/status-only beats run shorter.
    private func beginEvent(_ e: BattleEvent) {
        let to = frac(e.targetHP, e.targetMaxHP)
        if e.targetIsPlayer { pFrom = curPHP; pTo = to; flashP = e.damage > 0 }
        else { wFrom = curWHP; wTo = to; flashW = e.damage > 0 }

        effects = []
        ballFrame = nil
        if e.kind == .ball {
            // flight + one wobble per shake + a settle/burst tail
            curTicks = 16 + e.shakes * 14 + 26
            return
        }
        curTicks = (e.damage > 0 || e.kind == .attack) ? eventTicks : eventTicks * 3 / 5
        guard e.kind == .attack else { return }
        let wildPos = wildMon?.pos ?? playerPos
        let target = e.targetIsPlayer ? playerPos : wildPos
        let attacker = e.actorIsPlayer ? playerPos : wildPos
        var total = 0
        if let proj = EffectPlayer.projectile(forMove: e.moveId) {
            let travel = 18
            effects.append(RunningEffect(clip: proj, from: attacker, to: target, maxTicks: travel))
            total += travel
        }
        if let clip = EffectPlayer.clip(forMove: e.moveId) {
            let hitTicks = min(clip.loop ? eventTicks * 2 : clip.totalTicks, 54)
            effects.append(RunningEffect(clip: clip, anchor: target, maxTicks: hitTicks))
            total += hitTicks
        }
        curTicks = max(curTicks, min(total, 70))
    }

    private func finishBattle() {
        let won = result?.playerWon ?? false
        var captured = false
        if let r = result {
            for b in r.ballsUsed { RaisingState.shared.consumeItem(b) }
            RaisingState.shared.applyBattleOutcome(playerHP: r.playerEndHP, status: r.playerEndStatus,
                                                   won: r.playerWon, expGained: r.expGained)
            if r.captured, let w = wild {
                captured = RaisingState.shared.addCaptured(from: w)
            }
        }
        if captured {
            // The wild is inside the ball (already hidden); linger briefly.
            endTicks = fast ? 30 : 60
            phase = .ending
        } else if won {
            ballFrame = nil
            endTicks = fast ? 40 : 90
            phase = .ending                 // the beaten wild fades away
        } else {
            ballFrame = nil
            // My mon fainted (it now stays down where it fell). The wild is NOT
            // defeated — it lingers/wanders so I can send out another mon and keep
            // challenging it; it leaves on its own despawn timer.
            phase = .present
        }
    }

    private func tickEnding() {
        wildMon?.faceStanding(toward: playerPos)
        endTicks -= 1
        if ballFrame == nil {
            wildAlpha = max(0, Double(endTicks) / 40.0)   // defeated wild fades out
        }                                                  // caught: stays in the ball
        if endTicks <= 0 { despawn() }
    }

    private func despawn() {
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
            wildFrame: frame, wildPos: wm.pos, playerPos: playerPos,
            playerHP: curPHP, wildHP: curWHP, flashPlayer: flashP, flashWild: flashW,
            playerAlpha: playerAlpha, wildAlpha: wildAlpha, showBars: isBattling,
            effectFrame: fx?.0, effectPos: fx?.1 ?? .zero)
    }

    // MARK: helpers

    private func frac(_ hp: Int, _ maxHP: Int) -> Double { Double(hp) / Double(max(1, maxHP)) }
    private func lerp(_ a: Double, _ b: Double, _ t: Double) -> Double { a + (b - a) * t }

    private func screenBounds() -> CGRect {
        var r = CGRect.null
        for s in NSScreen.screens { r = r.union(s.frame) }
        return r.isNull ? CGRect(x: 0, y: 0, width: 1440, height: 900) : r
    }

    private func nextSpawnDelay() -> Int {
        fast ? 60 * 4 : Int.random(in: (30 * 60)...(60 * 60)) * 60   // 4s (fast) or 30–60 min
    }
}
