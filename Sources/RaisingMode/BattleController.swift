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
    private var curPHP = 1.0, curWHP = 1.0
    private var pFrom = 1.0, pTo = 1.0, wFrom = 1.0, wTo = 1.0
    private var flashP = false, flashW = false
    private var playerAlpha = 1.0
    private var wildAlpha = 1.0
    private var result: BattleResult?
    private var endTicks = 0

    init() { spawnCooldown = nextSpawnDelay() }

    var isBattling: Bool { phase == .battling || phase == .ending }

    /// Debug: spawn a wild encounter immediately.
    func forceSpawn() {
        guard phase == .idle, let a = RaisingState.shared.active, !a.isFainted else { return }
        spawn(near: a)
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
        // The follower just roams (cursor); if it happens to pass close, the wild
        // notices (stops & looks) and, if they meet, a battle begins.
        if d < 150 * scale { wm.faceStanding(toward: playerPos) }
        else { wm.wander(bounds: screenBounds()) }
        if d < 85 * scale { startBattle() }
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
        result = BattleEngine.run(player: p, wild: w)
        events = result?.events ?? []
        evIdx = 0; evTick = 0; curPHP = 1.0; curWHP = 1.0; wildAlpha = 1.0; playerAlpha = 1.0
        flashP = false; flashW = false
        phase = .battling
    }

    private func tickBattling() {
        wildMon?.faceStanding(toward: playerPos)
        guard evIdx < events.count else { finishBattle(); return }
        let e = events[evIdx]
        if evTick == 0 {
            if e.playerActed { wFrom = curWHP; wTo = frac(e.defenderHP, e.defenderMaxHP); flashW = true }
            else { pFrom = curPHP; pTo = frac(e.defenderHP, e.defenderMaxHP); flashP = true }
        }
        let t = min(1.0, Double(evTick) / Double(eventTicks) * 1.4)
        if e.playerActed { curWHP = lerp(wFrom, wTo, t) } else { curPHP = lerp(pFrom, pTo, t) }
        if evTick > 8 { flashP = false; flashW = false }
        evTick += 1
        if evTick >= eventTicks { evTick = 0; evIdx += 1 }
    }

    private func finishBattle() {
        if let r = result {
            RaisingState.shared.applyBattleOutcome(playerHPFraction: curPHP, won: r.playerWon, expGained: r.expGained)
        }
        endTicks = fast ? 40 : 90
        phase = .ending
    }

    private func tickEnding() {
        wildMon?.faceStanding(toward: playerPos)
        endTicks -= 1
        let fade = max(0, Double(endTicks) / 40.0)
        // The loser faints (fades out); the winner stays.
        if result?.playerWon == true { wildAlpha = fade; playerAlpha = 1 }
        else { playerAlpha = fade; wildAlpha = 1 }
        if endTicks <= 0 { despawn() }
    }

    private func despawn() {
        wild = nil; wildMon = nil; events = []; result = nil
        playerAlpha = 1.0; wildAlpha = 1.0
        phase = .idle
        spawnCooldown = nextSpawnDelay()
    }

    // MARK: scene

    private func scene() -> BattleScene? {
        guard phase != .idle, let wm = wildMon, let frame = wm.currentFrame else { return nil }
        return BattleScene(
            wildFrame: frame, wildPos: wm.pos, playerPos: playerPos,
            playerHP: curPHP, wildHP: curWHP, flashPlayer: flashP, flashWild: flashW,
            playerAlpha: playerAlpha, wildAlpha: wildAlpha, showBars: isBattling)
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
