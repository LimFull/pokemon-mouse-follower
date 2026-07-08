// Raising mode — wild encounters + on-overlay battle playback (Phase 2c/2d).
//
// Owns the wild-encounter lifecycle: spawn on a long random timer (D9), let the
// active mon walk over and, on contact, run BattleEngine and play the turns back
// on the overlay (HP bars deplete, sprites flash), then apply the outcome (EXP,
// HP, evolution) and despawn. Set PMF_FAST_BATTLE=1 for quick testing.

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
    private var frameTick = 0

    private var wild: Battler?
    private var wildFrames: [CGImage] = []
    private var wildPos = CGPoint.zero
    private var playerPos = CGPoint.zero

    private var events: [BattleEvent] = []
    private var evIdx = 0
    private var evTick = 0
    private var curPHP = 1.0, curWHP = 1.0
    private var pFrom = 1.0, pTo = 1.0, wFrom = 1.0, wTo = 1.0
    private var flashP = false, flashW = false
    private var wildAlpha = 1.0
    private var result: BattleResult?
    private var endTicks = 0

    init() { spawnCooldown = nextSpawnDelay() }


    var isBattling: Bool { phase == .battling || phase == .ending }

    /// The follower heads toward a present wild (so it walks over), else the cursor.
    func followTarget(cursor: CGPoint) -> CGPoint { phase == .present ? wildPos : cursor }

    /// Debug: spawn a wild encounter immediately.
    func forceSpawn() {
        guard phase == .idle, let a = RaisingState.shared.active, !a.isFainted else { return }
        spawn(near: a)
    }

    func update(playerGlobalPos: CGPoint) -> BattleScene? {
        playerPos = playerGlobalPos
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
        guard let w = Battler(wildDex: dex, level: level) else { spawnCooldown = 60; return }
        let frames = CharacterPreviewView.idleDownFrames(String(format: "%03d", dex))
        guard !frames.isEmpty else { spawnCooldown = 60; return }
        wild = w
        wildFrames = frames
        let ang = Double.random(in: 0 ..< (2 * .pi))
        wildPos = CGPoint(x: playerPos.x + CGFloat(cos(ang)) * 320,
                          y: playerPos.y + CGFloat(sin(ang)) * 220)
        despawnTicks = (fast ? 30 : 5 * 60) * 60
        phase = .present
    }

    private func tickPresent() {
        despawnTicks -= 1
        if despawnTicks <= 0 { despawn(); return }
        let trigger = AppSettings.shared.followGap + 50
        if hypot(playerPos.x - wildPos.x, playerPos.y - wildPos.y) < trigger { startBattle() }
    }

    private func startBattle() {
        guard let w = wild, let mon = RaisingState.shared.active, let p = Battler(mon: mon) else { despawn(); return }
        result = BattleEngine.run(player: p, wild: w)
        events = result?.events ?? []
        evIdx = 0; evTick = 0
        curPHP = 1.0; curWHP = 1.0; wildAlpha = 1.0
        flashP = false; flashW = false
        phase = .battling
    }

    private func tickBattling() {
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
        endTicks -= 1
        wildAlpha = max(0, Double(endTicks) / 40.0)
        if endTicks <= 0 { despawn() }
    }

    private func despawn() {
        wild = nil; wildFrames = []; events = []; result = nil
        phase = .idle
        spawnCooldown = nextSpawnDelay()
    }

    // MARK: scene

    private func scene() -> BattleScene? {
        guard phase != .idle, wild != nil, !wildFrames.isEmpty else { return nil }
        frameTick += 1
        let frame = wildFrames[(frameTick / 10) % wildFrames.count]
        return BattleScene(
            wildFrame: frame, wildPos: wildPos, playerPos: playerPos,
            playerHP: curPHP, wildHP: curWHP, flashPlayer: flashP, flashWild: flashW,
            wildAlpha: wildAlpha, showBars: isBattling)
    }

    // MARK: helpers

    private func frac(_ hp: Int, _ maxHP: Int) -> Double { Double(hp) / Double(max(1, maxHP)) }
    private func lerp(_ a: Double, _ b: Double, _ t: Double) -> Double { a + (b - a) * t }

    private func nextSpawnDelay() -> Int {
        fast ? 60 * 4 : Int.random(in: (30 * 60)...(60 * 60)) * 60   // 4s (fast) or 30–60 min
    }
}
