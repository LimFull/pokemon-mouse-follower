// Raising mode — wild encounters + on-overlay battle playback (Phase 2c/2d).
//
// Wild encounters spawn at a random screen spot on a long timer (D9) and wander
// (stop-and-go). When the active mon walks near, both stop and face each other
// and BattleEngine runs, the turns playing back on the overlay; the outcome
// (EXP/HP/evolution) is applied and the wild despawns. Distances scale with the
// sprite scale. Set PMF_FAST_BATTLE=1 for quick testing.
//
// Platform-neutral (Phase 5a): frames are PMFImage handles, colors are RGBA,
// screens/prompts/item icons go through the platform seams
// (platformScreensWorld / PromptRelay / platformItemIcon).

import Foundation


/// What the overlay should draw for the current battle frame (nil = nothing).
struct BattleScene {
    let wildFrame: PMFImage
    let wildPos: CGPoint
    let playerPos: CGPoint
    let playerHP: Double
    let wildHP: Double
    let flashPlayer: Bool
    let flashWild: Bool
    let playerAlpha: Double
    let wildAlpha: Double
    let showBars: Bool
    let effectFrame: PMFImage?   // move-effect sprite over the hit target (D22)
    let effectPos: CGPoint
    var playerPose: BattlePose = .stand   // battle pose for the follower (D2-1)
    var playerPoseTick: Int = 0
    var wildLevel: Int?                   // shown above the wild's head
    var playerDodge: CGPoint = .zero      // sidestep offset while evading a miss
    var floatText: String?                // floating combat tag ("Miss", "Super Effective!", ...)
    var floatPos: CGPoint = .zero
    var floatAlpha: Double = 0
    var floatColor: RGBA = RGBA(white: 1)
    // Floating damage number over the hit side ("-23"; settings-gated).
    var damageText: String?
    var damagePos: CGPoint = .zero
    var damageAlpha: Double = 0
    var damageColor: RGBA = RGBA(white: 1)
    var screenFlash: Double = 0           // full-screen effect veil 0...1 (Psychic & co)
    var screenColor: RGBA = RGBA(white: 1)
    var logLines: [(String, Double)] = [] // PMD-style log: (text, alpha), oldest first
    var logAnchor: CGPoint = .zero        // global top-center of the log box
    var playerSpriteDex: Int? = nil       // player Transformed: draw the follower as this species
    var wildSpriteDex: Int? = nil         // wild Transformed: the species it currently shows
    // Minimize/Growth body scale — the ROM keeps this visual in engine code
    // (the anim data ships only a tiny spark), so the playback scales the
    // sprite itself; sticks for the battle like the stat stage it mirrors.
    var playerSpriteScale: CGFloat = 1
    var wildSpriteScale: CGFloat = 1
    // Semi-invulnerable charge turns (Dig & co): the hider's sprite is off
    // screen entirely until it pops back up to strike.
    var playerVanished: Bool = false
    var wildVanished: Bool = false
    // Substitute up: the platform draws the doll instead of the follower
    // (the wild's frame is swapped inside scene() directly).
    var playerSubstitute: Bool = false
}

final class BattleController: LiveBattleBridge {
    /// The live controller (owned by the app delegate) so PartyState can route
    /// a mid-battle recall through the turn machinery (via the platform-neutral
    /// LiveBattle.current seam registered in init).
    private(set) static weak var current: BattleController?

    private enum Phase { case idle, present, battling, ending }
    private var phase: Phase = .idle

    private let fast = ProcessInfo.processInfo.environment["PMF_FAST_BATTLE"] != nil
    private let eventTicks = 20
    private var spawnCooldown = 0
    private var cooldownBasisMinutes: CGFloat = 0   // setting the cooldown was rolled from
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
    private var ballFrame: PMFImage?     // thrown ball being drawn (D11)
    private var ballPos = CGPoint.zero
    private var playerPose: (BattlePose, Int) = (.stand, 0)   // pose + its tick
    private var playerDodge = CGPoint.zero
    private var wildDodge = CGPoint.zero
    private var floatText: String?
    private var floatPos = CGPoint.zero
    private var floatAlpha = 0.0
    private var floatColor = RGBA(white: 1)
    private var dmgText: String?
    private var dmgPos = CGPoint.zero
    private var dmgAlpha = 0.0
    private var dmgColor = RGBA(white: 1)
    private var screenFlash = 0.0
    private var screenColor = RGBA(white: 1)
    private var lastTracedWildPose = BattlePose.stand   // PMF_TRACE_BATTLE only
    private var curPHP = 1.0, curWHP = 1.0
    private var pFrom = 1.0, pTo = 1.0, wFrom = 1.0, wTo = 1.0
    private var flashP = false, flashW = false
    // Minimize/Growth body scale (current eased value + target). The wild's
    // persists while it lingers between battles — consistent with its stat
    // stages surviving; the player's resets on every battle entry.
    private var pBodyScale: CGFloat = 1, wBodyScale: CGFloat = 1
    private var pBodyTarget: CGFloat = 1, wBodyTarget: CGFloat = 1
    // Dig/Fly/Dive/Shadow Force: who is currently hidden from view.
    private var pVanish = false, wVanish = false
    private static let hiddenReasons: Set<String> = ["dug in", "flew up", "dove under", "vanished"]
    // Substitute: who currently fights behind the doll.
    private var pSub = false, wSub = false
    /// The mainline doll sprite (PokeAPI art; the ROM never draws one —
    /// its Substitute effect is just the shared particle).
    static let substituteDoll: PMFImage? =
        Sprite.loadBuffer("substitute", subdir: "gamedata").flatMap { PlatformImageIO.makeImage($0) }
    private var playerAlpha = 1.0
    private var wildAlpha = 1.0
    private var result: BattleResult?
    private var session: BattleSession?  // stepwise sim: one round per batch
    private var pendingItem: GameItem?   // healing item queued for the next round
    private var pendingBall: GameItem?   // manual ball throw queued from the bag
    private var endTicks = 0
    private var endTotal = 1             // endTicks' starting value (tag timing)
    private var recallTurn: Int?         // flee after this simulated turn ends
    private var switchTurn: Int?         // swap the active mon after this turn ends
    private var switchIndex: Int?        // ...for this party member
    // The switch beat in progress (mainline send-out): the outgoing mon backs
    // away from the wild and fades, the newcomer pops out of a smoke burst
    // and scales in; the swap itself lands between the two halves.
    private var switchAnim: (index: Int, tick: Int)?
    private var switchOutTicks: Int { fast ? 18 : 36 }
    private var switchInTicks: Int { fast ? 16 : 32 }
    // Everyone who battled THIS wild (party indices): seeded at battle start,
    // extended by switches and drag-outs, and kept across a recall +
    // re-engage while the same wild lingers — the mainline EXP-share pool.
    // Reset when the wild itself goes (spawn/forceEncounter/despawn).
    private var participants: Set<Int> = []
    private var levelUpTo: Int?          // show a level-up tag while ending
    private var curPStatus: String?      // ailment the playback has shown on the follower
    // PMD-style battle log: visible lines (oldest first) and lines scheduled
    // for later ticks of the current event's beat, so text tracks the action.
    private var logLines: [(text: String, age: Int)] = []
    private var pendingLog: [(tick: Int, text: String)] = []
    // Transform (D2): the engine copies stats/moves/types on the Battler; the
    // LOOK is playback state, applied at the transform event's impact tick.
    // The follower reverts when the battle ends (its Battler is rebuilt from
    // the save each fight); the WILD keeps it while it stays out — consistent
    // with its persisting HP/stat stages — and only a capture resets it.
    private var playerTransformedDex: Int?   // follower shown as this species
    private var wildTransformedDex: Int?     // wild shown as this species
    private let logHoldTicks = 300       // fully readable span (~5s at 60fps)
    private let logFadeTicks = 30

    init() {
        spawnCooldown = nextSpawnDelay()
        BattleController.current = self
        LiveBattle.current = self
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
        // Mid-Rollout the mon can't be pulled back (mainline lock-in).
        guard session?.playerLockedIn != true else { return false }
        switchTurn = nil; switchIndex = nil   // a recall supersedes a queued switch
        if recallTurn == nil {
            recallTurn = evIdx < events.count ? events[evIdx].turn
                                              : (events.last?.turn ?? 0)
        }
        return true
    }

    /// Drop a pending flee (e.g. the player sent out someone else instead).
    func cancelRecallRequest() { recallTurn = nil }

    /// Mainline switch timing: sending out another member during battle
    /// playback only takes effect once the turn in progress fully plays out —
    /// the controller writes the outgoing mon's state back, swaps the
    /// session's battler and logs the recall/send-out pair at the boundary.
    /// Returns true when the switch was queued; false means no turn machinery
    /// applies (the caller activates the member immediately). Unlike a
    /// recall, a queued switch survives a Rollout lock-in — it just waits for
    /// the first free boundary, like a queued potion. Clicking a different
    /// member re-targets the pending switch.
    func requestSwitch(to index: Int) -> Bool {
        guard phase == .battling else { return false }
        let st = RaisingState.shared
        guard st.save.party.indices.contains(index), !st.party[index].isFainted,
              index != st.save.activeIndex else { return false }
        recallTurn = nil            // the switch supersedes a queued flee
        switchIndex = index
        if switchTurn == nil {
            switchTurn = evIdx < events.count ? events[evIdx].turn
                                              : (events.last?.turn ?? 0)
        }
        return true
    }

    /// The member a mid-battle switch is queued for (panels show the state).
    var switchPendingIndex: Int? { switchTurn != nil ? switchIndex : nil }

    /// Queue a healing/curing item as the follower's NEXT action — mainline
    /// rules: using an item costs the turn, so it replaces the move when the
    /// next round is simulated. Returns false when there's no battle to act in
    /// (the caller should apply the item directly).
    func requestItem(_ item: GameItem) -> Bool {
        guard phase == .battling, item.healAmount > 0 || item.curesStatus, pendingItem == nil,
              session?.isOver == false else { return false }
        pendingItem = item
        return true
    }

    /// A healing item is queued and not yet spent (panels disable buttons).
    var itemPending: Bool { pendingItem != nil }

    /// Manual ball throw from the bag: queued as the follower's next action
    /// (turn-spending, like an item). The battle-end settlement consumes it
    /// via the session's used-ball list, same as auto-throws.
    func requestBall(_ item: GameItem) -> Bool {
        guard phase == .battling, item.isBall, pendingBall == nil,
              session?.isOver == false else { return false }
        let alreadyUsed = session?.used.filter { $0 == item }.count ?? 0
        guard RaisingState.shared.itemCount(item) > alreadyUsed else { return false }
        pendingBall = item
        return true
    }

    var ballPending: Bool { pendingBall != nil }

    /// The follower's live gauge fraction while a battle plays (panel gating).
    var playerGaugeFraction: Double? { phase == .battling ? curPHP : nil }

    /// The ailment the playback has shown on the follower so far (panel gating
    /// for status-curing items — the saved status is stale mid-battle).
    var playerLiveStatus: String? { phase == .battling ? curPStatus : nil }

    /// Debug: spawn a wild encounter immediately; `at` pins its position
    /// (used by the selftest to force a contact battle deterministically).
    func forceSpawn(at pos: CGPoint? = nil) {
        guard phase == .idle, let a = RaisingState.shared.active, !a.isFainted else { return }
        spawn(near: a)
        if let pos { wildMon?.place(at: pos) }
    }

    /// Debug: drop a chosen wild (nil = random) right next to the follower at
    /// the active mon's level — the battle starts on the next contact check.
    /// Debug showcase spawns (both platforms' 디버그 menus): guarantee the
    /// mechanic the menu entry advertises. Wild movesets are the last 4
    /// level-up moves at the spawn level, so mid-level spawns can silently
    /// lose the showcase move (e.g. Pineco drops Selfdestruct at L20–33).
    private static let showcaseMoves: [Int: Int] = [
        204: 123,   // 피콘 → 자폭 (Selfdestruct)
        43: 135,    // 뚜벅쵸 → 흡수 (Absorb; L21+ would drop it for Mega Drain)
        35: 169,    // 삐삐 → 작아지기 (Minimize; learned at L19, later window drops it)
        249: 268,   // 루기아 → 날려버리기 (Whirlwind; L1 move, L29+ window drops it)
        111: 176,   // 뿔카노 → 뿔찌르기 (Horn Attack; L1 move, later window drops it)
    ]

    func forceEncounter(dex: Int? = nil, moves: [Int]? = nil) {
        guard AppSettings.shared.raisingMode,
              let a = RaisingState.shared.active, !a.isFainted else { return }
        if phase != .idle { despawn() }
        let level = max(2, a.level)
        guard let d = dex ?? GameData.wildPool(atLevel: level).randomElement(),
              let w = Battler(wildDex: d, level: level),
              let wm = WildMon(dex: d) else { return }
        if let custom = moves?.filter({ GameData.moves[$0] != nil }), !custom.isEmpty {
            // Debug custom battle: the wild fights with exactly this moveset.
            w.moves = Array(custom.prefix(4))
        } else if dex != nil, let mid = Self.showcaseMoves[d], !w.moves.contains(mid) {
            // Only explicitly requested spawns get the pinned showcase move —
            // random encounters keep the natural last-4 moveset.
            if w.moves.count < 4 { w.moves.append(mid) } else { w.moves[0] = mid }
        }
        wild = w
        wildMon = wm
        participants = []   // a fresh wild starts a fresh EXP-share pool
        let scale = AppSettings.shared.scale
        wm.place(at: CGPoint(x: playerPos.x + 50 * scale, y: playerPos.y))
        despawnTicks = 5 * 60 * 60
        phase = .present
    }

    func update(playerGlobalPos: CGPoint) -> BattleScene? {
        playerPos = playerGlobalPos
        // Age the battle log everywhere (fades keep running after a flee).
        if !logLines.isEmpty {
            for i in logLines.indices { logLines[i].age += 1 }
            logLines.removeAll { $0.age > logHoldTicks + logFadeTicks }
        }
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
        // The pending delay was rolled from the interval setting at the time —
        // re-roll when the slider moves, or a 45m→5m change would still sit
        // out the rest of the old (up to ~56m) countdown.
        if AppSettings.shared.encounterMinutes != cooldownBasisMinutes {
            spawnCooldown = nextSpawnDelay()
        }
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
        // On an actual screen, AND far enough from the follower that the
        // spawn can't collide into an instant unwanted battle (contact
        // starts at ~56*scale; keep several times that). Best-of-N sampling:
        // take the first far-enough point, else the farthest seen.
        let scale = AppSettings.shared.scale
        let minDist = 320 * scale
        var best = randomOnScreenPoint(margin: 80)
        var bestDist = hypot(best.x - playerPos.x, best.y - playerPos.y)
        for _ in 0..<11 where bestDist < minDist {
            let c = randomOnScreenPoint(margin: 80)
            let d = hypot(c.x - playerPos.x, c.y - playerPos.y)
            if d > bestDist { best = c; bestDist = d }
        }
        wm.place(at: best)
        wild = w
        wildMon = wm
        participants = []   // a fresh wild starts a fresh EXP-share pool
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

    /// Balls available to throw right now: nothing when the capture toggle is
    /// off, else bag counts minus what this battle already threw (the bag is
    /// only debited at finishBattle), capped at 3 throws per battle including
    /// those already made. The stronger ball goes first (2026-07-10, was
    /// cheapest first).
    private func ballStock(used: [GameItem]) -> [GameItem] {
        let st = RaisingState.shared
        guard st.captureEnabled else { return [] }
        let throwsLeft = 3 - used.count
        guard throwsLeft > 0 else { return [] }
        func remaining(_ item: GameItem) -> Int {
            max(0, st.itemCount(item) - used.filter { $0 == item }.count)
        }
        var balls = Array(repeating: GameItem.greatBall, count: min(throwsLeft, remaining(.greatBall)))
        balls += Array(repeating: .pokeBall, count: min(throwsLeft - balls.count, remaining(.pokeBall)))
        return balls
    }

    /// Wild Roar/Whirlwind landed: write the outgoing mon's battle state
    /// back, activate a random other conscious member, and hand its fresh
    /// Battler to the session. False when nobody else can battle.
    private func dragOutReplacement(into s: BattleSession) -> Bool {
        let st = RaisingState.shared
        if let mon = st.active {
            st.applyFleeState(hp: Int((curPHP * Double(mon.maxHP)).rounded()),
                              status: curPStatus)
        }
        let choices = st.party.indices.filter { $0 != st.save.activeIndex && !st.party[$0].isFainted }
        guard let pick = choices.randomElement() else { return false }
        st.applyActive(pick)   // direct: setActive would re-enter the switch queue
        guard let mon = st.active, let b = Battler(mon: mon) else { return false }
        s.dragOutPlayer(replacement: b)
        participants.insert(pick)
        curPHP = frac(b.currentHP, b.maxHP)
        curPStatus = mon.status
        playerTransformedDex = nil
        pBodyScale = 1; pBodyTarget = 1   // the newcomer is full size
        pushLog(BattleLog.draggedOutLine(playerName: b.name))
        return true
    }

    /// Turn-boundary switch (mainline timing), first half: validate the
    /// target and start the switch beat — tickSwitchAnim drives recall fade →
    /// swap → send-out pop, and the turn cost lands when the beat ends.
    /// False when the target can't come in (the boundary just moves on).
    private func beginSwitchAnim(to index: Int, in s: BattleSession) -> Bool {
        let st = RaisingState.shared
        guard st.save.party.indices.contains(index), !st.party[index].isFainted,
              index != st.save.activeIndex,
              Battler(mon: st.party[index]) != nil else { return false }
        switchAnim = (index, 0)
        playerPose = (.stand, 0)
        // Leftover combat text would freeze mid-air for the beat's ~1s.
        floatText = nil; floatAlpha = 0
        dmgText = nil; dmgAlpha = 0
        pushLog(BattleLog.switchOutLine(playerName: s.player.name, foeHPFraction: curWHP))
        return true
    }

    /// The swap itself (between the beat's halves): write the outgoing mon's
    /// live battle state back (like a flee — the damage sticks, no free
    /// heal), activate the chosen member, hand its fresh Battler to the
    /// session so moves/log/EXP identity all follow the newcomer, and pop
    /// the send-out smoke the newcomer scales in from.
    private func completeSwitch(to index: Int, in s: BattleSession) -> Bool {
        let st = RaisingState.shared
        guard st.save.party.indices.contains(index), !st.party[index].isFainted,
              index != st.save.activeIndex,
              let b = Battler(mon: st.party[index]) else { return false }
        if let mon = st.active {
            st.applyFleeState(hp: Int((curPHP * Double(mon.maxHP)).rounded()),
                              status: curPStatus)
        }
        st.applyActive(index)   // direct: setActive would re-enter the switch queue
        s.switchPlayer(replacement: b)
        participants.insert(index)
        curPHP = frac(b.currentHP, b.maxHP)
        curPStatus = st.party[index].status
        playerTransformedDex = nil
        pVanish = false                   // the newcomer is not mid-Dig
        pSub = false                      // ...and not behind the old doll
        pushLog(BattleLog.sendOutLine(playerName: b.name, foeHPFraction: curWHP))
        if let clip = EffectPlayer.clip(forMove: 37) {   // SmokeScreen's puff
            effects.append(RunningEffect(clip: clip, anchor: playerPos,
                                         maxTicks: min(clip.loop ? 30 : clip.totalTicks, 40)))
        }
        return true
    }

    /// The switch beat, at the turn boundary the queued switch landed on.
    /// First half: the outgoing mon backs straight away from the wild,
    /// fading out on the way. Swap. Second half: a smoke burst pops and the
    /// newcomer scales in with an overshoot. Then the turn cost lands —
    /// the round is pulled with playerSwitched set (mainline: switching
    /// spends the turn, so the incoming mon just takes the wild's move).
    private func tickSwitchAnim() {
        guard let s = session, let anim = switchAnim else { switchAnim = nil; return }
        let t = anim.tick
        wildMon?.faceStanding(toward: playerPos)
        playerPose = (.stand, 0)
        // Event beats normally advance effects — keep the poof playing here.
        if !effects.isEmpty {
            effects[0].advance()
            if effects[0].isDone { effects.removeFirst() }
        }
        if t < switchOutTicks {
            // Recall: back away from the wild, fading out on the way.
            let p = Double(t + 1) / Double(switchOutTicks)
            let wpos = wildMon?.pos ?? playerPos
            var dx = playerPos.x - wpos.x, dy = playerPos.y - wpos.y
            let d = max(0.001, hypot(dx, dy)); dx /= d; dy /= d
            let slide = CGFloat(p * p) * 46 * AppSettings.shared.scale
            playerDodge = CGPoint(x: dx * slide, y: dy * slide)
            playerAlpha = 1 - p
            if t == switchOutTicks - 1 {
                playerDodge = .zero
                guard completeSwitch(to: anim.index, in: s) else {
                    // The target vanished mid-beat (released or fainted from
                    // a panel): abort — no swap, no turn spent.
                    switchAnim = nil
                    playerAlpha = 1
                    return
                }
                pBodyScale = 0.2; pBodyTarget = 1
            }
        } else {
            // Send-out: pop out of the smoke, overshoot, settle to full size.
            let p = Double(t - switchOutTicks + 1) / Double(switchInTicks)
            playerAlpha = min(1, p * 4)
            pBodyScale = 0.2 + 0.8 * easeOutBack(p)
        }
        switchAnim = (anim.index, t + 1)
        if t + 1 >= switchOutTicks + switchInTicks {
            switchAnim = nil
            playerAlpha = 1; pBodyScale = 1; pBodyTarget = 1
            // The switch spent the turn: the wild's free round starts now —
            // queued potions/balls wait for the next boundary (each action
            // costs its own turn, mainline rules).
            s.setBallStock(ballStock(used: s.used))
            events = s.nextRound(playerSwitched: true)
            evIdx = 0; evTick = 0
        }
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
        // afterwards). Re-synced at every round boundary so the toggle is live.
        let balls = ballStock(used: [])
        // Gauges start at the REAL current/max ratio (a hurt mon enters hurt;
        // a rematched wild keeps its damage) — captured before the first
        // round mutates the battlers.
        let startPHP = frac(p.currentHP, p.maxHP)
        let startWHP = frac(w.currentHP, w.maxHP)
        // Stepwise simulation: one round at a time, so mid-battle decisions
        // (potions, flee) can be woven in between rounds as they play out.
        let s = BattleSession(player: p, wild: w, balls: balls)
        session = s
        result = nil
        pendingItem = nil
        pendingBall = nil
        participants.insert(RaisingState.shared.save.activeIndex)
        events = s.nextRound()
        curPStatus = mon.status
        evIdx = 0; evTick = 0; curPHP = startPHP; curWHP = startWHP
        wildAlpha = 1.0; playerAlpha = 1.0
        flashP = false; flashW = false
        pendingLog = []
        playerTransformedDex = nil   // the follower always re-enters as itself
        pBodyScale = 1; pBodyTarget = 1   // fresh mon, full size (wild's persists)
        pVanish = false; wVanish = false  // nobody enters a battle mid-Dig
        pSub = false; wSub = false        // ...or behind last battle's doll
        pushLog(BattleLog.battleStart(wildName: w.name))
        phase = .battling
    }

    private func tickBattling() {
        if switchAnim != nil { tickSwitchAnim(); return }
        guard evIdx < events.count else {
            // The played round is over. Weave in queued decisions, then pull
            // the next round from the session — or wrap up when it's done.
            if let s = session, !s.isOver {
                if recallTurn != nil {   // mainline flee: leaves at the boundary
                    recallTurn = nil
                    cancelBattle()
                    RaisingState.shared.recall()
                    return
                }
                // The wild's Roar/Whirlwind: drag in a random other party
                // member (trainer rules). Nobody left -> the blow-out ends
                // the encounter after all (falls to finishBattle below).
                if s.playerDraggedOut, !dragOutReplacement(into: s) {
                    s.markPlayerFled()
                    result = s.makeResult()
                    wildMon?.faceStanding(toward: playerPos)
                    finishBattle()
                    return
                }
                // A queued switch lands at the turn boundary (mainline switch
                // timing). Locked mid-Rollout it stays queued — like a queued
                // potion — and lands at the first free boundary instead.
                if let idx = switchIndex, switchTurn != nil, !s.playerLockedIn {
                    switchTurn = nil; switchIndex = nil
                    // The beat plays out first; its last tick performs the
                    // swap and pulls the wild's free round (turn cost) —
                    // queued items wait for the next boundary.
                    if beginSwitchAnim(to: idx, in: s) { return }
                }
                var item: GameItem? = nil
                // Items wait while the mon is locked mid-Rollout — the queued
                // potion applies at the first free round boundary instead.
                if let queued = pendingItem, !s.playerLockedIn {
                    pendingItem = nil
                    if RaisingState.shared.itemCount(queued) > 0 {
                        RaisingState.shared.consumeItem(queued)
                        item = queued
                    }
                }
                // Manual ball throw: same gate; finishBattle settles the bag
                // through the session's used list, so no consume here.
                var ball: GameItem? = nil
                if let queued = pendingBall, !s.playerLockedIn, item == nil {
                    pendingBall = nil
                    let alreadyUsed = s.used.filter { $0 == queued }.count
                    if RaisingState.shared.itemCount(queued) > alreadyUsed { ball = queued }
                }
                s.setBallStock(ballStock(used: s.used))   // capture toggle is live
                events = s.nextRound(playerItem: item, playerBall: ball)
                evIdx = 0; evTick = 0
                return
            }
            result = session?.makeResult()
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
        while let next = pendingLog.first, next.tick <= evTick {
            pushLog(next.text)
            pendingLog.removeFirst()
        }
        // Substitute: the doll goes up at its tag and comes down at the
        // break notice.
        if evTick == impactAt {
            if e.statusApplied == "substitute!" {
                if e.actorIsPlayer { pSub = true } else { wSub = true }
            }
            if e.kind == .skip, e.moveName == "sub broke" {
                if e.actorIsPlayer { pSub = false } else { wSub = false }
            }
        }
        // Semi-invulnerable charges: the hider disappears at its dig-in beat
        // and pops back up the next time it acts — or the moment a piercing
        // hit lands on it (residual chips tick without surfacing it).
        if evTick == impactAt {
            let hides = e.kind == .skip && Self.hiddenReasons.contains(e.moveName)
            let acts = e.kind == .attack || e.kind == .miss
                || e.kind == .skip || e.kind == .selfHit
            if e.actorIsPlayer {
                if hides { pVanish = true } else if acts { pVanish = false }
            } else {
                if hides { wVanish = true } else if acts { wVanish = false }
            }
            if e.damage > 0, e.kind != .residual {
                if e.targetIsPlayer { pVanish = false } else { wVanish = false }
            }
        }
        // Minimize/Growth: the body itself shrinks/swells at the impact tick
        // (compounding on repeat use, clamped) and eases toward the target.
        if e.kind == .attack, evTick == impactAt {
            switch GameData.moves[e.moveId]?.englishName {
            case "Minimize":
                if e.actorIsPlayer { pBodyTarget = max(0.4, pBodyTarget * 0.6) }
                else { wBodyTarget = max(0.4, wBodyTarget * 0.6) }
            case "Growth":
                if e.actorIsPlayer { pBodyTarget = min(1.4, pBodyTarget * 1.2) }
                else { wBodyTarget = min(1.4, wBodyTarget * 1.2) }
            default: break
            }
        }
        pBodyScale += (pBodyTarget - pBodyScale) * 0.12
        wBodyScale += (wBodyTarget - wBodyScale) * 0.12
        // Transform: swap the shown sprite the moment the copy lands.
        if e.statusApplied == "transformed!", evTick == impactAt {
            if e.actorIsPlayer, let w = wild {
                playerTransformedDex = w.dex
            } else if let p = session?.player {
                wildTransformedDex = p.dex
                wildMon?.setSpecies(dex: p.dex)
            }
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
        tickDamageNumber(e)
        tickScreenFX(e)
        if e.kind == .ball { tickBall(e) }
        if e.kind == .item { tickItemUse(e) }
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
    private static let ailmentLanding: [String: (String, RGBA, String)] = [
        "paralysis": ("Paralyzed!", RGBA(r: 0.98, g: 0.85, b: 0.25), "paralyzed"),
        "burn": ("Burned!", RGBA(r: 1.0, g: 0.55, b: 0.25), "burn"),
        "poison": ("Poisoned!", RGBA(r: 0.75, g: 0.45, b: 0.95), "poison"),
        "sleep": ("Fell asleep!", RGBA(r: 0.65, g: 0.72, b: 0.95), "asleep"),
        "freeze": ("Frozen!", RGBA(r: 0.55, g: 0.85, b: 0.95), "frozen"),
        "confusion": ("Confused!", RGBA(r: 0.9, g: 0.6, b: 0.95), "confused"),
        "infatuation": ("In love!", RGBA(r: 0.98, g: 0.55, b: 0.72), "infatuated"),
    ]

    /// Floating combat tag over the defender at impact: "Miss"/"No Effect" on
    /// a whiff, "Super Effective!"/"Not Very Effective.." by type matchup.
    /// Floating damage number ("-23") rising off the hit side while its
    /// gauge drains — settings-gated (label.damagenumbers).
    /// "self ATK -1 DEF -1" / "SP.ATK +2" -> the stat deltas inside a tag.
    /// Tokens pair a BattleStat label with a signed count; anything else
    /// (ailment names, "3 hits!", "substitute!") yields nothing.
    static func statChanges(in tag: String) -> [(BattleStat, Int)] {
        let labelToStat = Dictionary(uniqueKeysWithValues:
            BattleStat.allCases.map { ($0.label, $0) })
        let tokens = tag.split(separator: " ").map(String.init)
        var out: [(BattleStat, Int)] = []
        var i = 0
        while i + 1 < tokens.count {
            if let stat = labelToStat[tokens[i]], let delta = Int(tokens[i + 1]), delta != 0 {
                out.append((stat, delta))
                i += 2
            } else {
                i += 1
            }
        }
        return out
    }

    private func tickDamageNumber(_ e: BattleEvent) {
        dmgText = nil; dmgAlpha = 0
        guard AppSettings.shared.damageNumbersEnabled, e.damage > 0,
              e.kind == .attack || e.kind == .selfHit || e.kind == .residual else { return }
        let span = max(1, drainEnd - hitAt) + 18
        guard evTick >= hitAt, evTick < hitAt + span else { return }
        let scale = AppSettings.shared.scale
        let anchor = e.targetIsPlayer ? playerPos : (wildMon?.pos ?? playerPos)
        let t = Double(evTick - hitAt) / Double(span)
        dmgText = "-\(e.damage)"
        // Rises on the opposite lane from the tag text (which floats higher).
        dmgPos = CGPoint(x: anchor.x + 18 * scale,
                         y: anchor.y + (8 + CGFloat(t) * 20) * scale)
        dmgAlpha = 1.0 - t * 0.75
        // My side bleeds red, the wild's damage reads white.
        dmgColor = e.targetIsPlayer ? RGBA(r: 1.0, g: 0.42, b: 0.38) : RGBA(white: 0.97)
    }

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
                floatColor = color
                return
            }
            if evTick >= drainEnd { return }   // window over — stay clear
        }
        var text: String?
        var color = RGBA(r: 1.0, g: 0.85, b: 0.3)   // miss yellow
        var overActor = false
        switch e.kind {
        case .miss where e.moveId > 0:
            text = e.effectiveness == 0 ? "No Effect" : "Miss"
        case .attack where e.crit && e.damage > 0:
            text = "Critical Hit!"
            color = RGBA(r: 1.0, g: 0.5, b: 0.15)
        case .attack where e.damage > 0 && e.effectiveness > 1:
            text = "Super Effective!"
            color = RGBA(r: 1.0, g: 0.45, b: 0.25)
        case .attack where e.damage > 0 && e.effectiveness > 0 && e.effectiveness < 1:
            text = "Not Very Effective.."
            color = RGBA(r: 0.75, g: 0.78, b: 0.85)
        case .skip:
            // Lost turn — say why, over the one who lost it.
            overActor = true
            switch e.moveName {
            case "asleep": text = "Zzz.."; color = RGBA(r: 0.65, g: 0.72, b: 0.95)
            case "frozen": text = "Frozen!"; color = RGBA(r: 0.55, g: 0.85, b: 0.95)
            case "paralyzed": text = "Paralyzed!"; color = RGBA(r: 0.98, g: 0.85, b: 0.25)
            case "infatuated": text = "In love!"; color = RGBA(r: 0.98, g: 0.55, b: 0.72)
            case "charging": text = "Charging.."; color = RGBA(r: 0.98, g: 0.80, b: 0.35)
            case "recharging": text = "Recharging.."; color = RGBA(r: 0.75, g: 0.78, b: 0.85)
            case "storing": text = "Storing energy.."; color = RGBA(r: 0.75, g: 0.78, b: 0.85)
            case "fled": text = "Fled!"; color = RGBA(r: 0.75, g: 0.78, b: 0.85)
            default: break
            }
        case .item:
            // Name tag under the rising icon: "Potion" in heal green.
            overActor = true
            text = e.moveName
            color = RGBA(r: 0.35, g: 0.85, b: 0.45)
        case .attack where e.damage == 0:
            // Mechanic tags: stat stages ("DEF -1"), "transformed!", walls,
            // "nothing happened" — anything that isn't a persisted ailment.
            if let tag = e.statusApplied, Ailment(rawValue: tag) == nil,
               !["confusion", "infatuation"].contains(tag) {
                overActor = e.targetIsPlayer == e.actorIsPlayer
                text = tag
                color = tag.contains("-") ? RGBA(r: 0.55, g: 0.65, b: 0.95)
                                          : RGBA(r: 0.98, g: 0.72, b: 0.30)
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
        floatColor = color
    }

    /// Full-screen move (Psychic & co): a brief type-colored veil over the
    /// whole screen plus a quake on both combatants around the impact.
    private func tickScreenFX(_ e: BattleEvent) {
        screenFlash = 0
        // Selfdestruct/Explosion borrow the full-screen treatment: the blast
        // is the drama the ROM keeps in engine code — flash + quake on the
        // DETONATION beat (the selfHit), not on the follow-up damage beat.
        let explosion = e.kind == .selfHit && EffectPlayer.isExplosionMove(e.moveId)
        let screenMove = (e.kind == .attack || e.kind == .miss) && EffectPlayer.isScreen(e.moveId)
        guard explosion || screenMove,
              evTick >= impactAt, evTick < impactAt + 20 else { return }
        let t = Double(evTick - impactAt) / 20.0
        screenFlash = sin(t * .pi)
        screenColor = explosion ? RGBA(r: 1.0, g: 0.66, b: 0.3)   // blast orange
                                : TypeStyle.rgba(GameData.moves[e.moveId]?.type)
        let scale = AppSettings.shared.scale
        let jitter = CGFloat(sin(Double(evTick) * 1.9)) * (explosion ? 6 : 3)
            * scale * CGFloat(1 - t)
        playerDodge.x += jitter
        wildDodge.x -= jitter
    }

    /// A move that should be delivered from range (Shoot pose, no lunge).
    /// Only genuine contact moves ram the foe: the mainline "makes contact"
    /// flag decides (merged via rom-extract/fetch_contact.py), so Thunder
    /// Shock casts from range and non-contact physical moves (Earthquake)
    /// don't body-slam either. A ROM projectile clip always means ranged;
    /// EoS-only moves without a flag fall back to category (Special = ranged).
    static func rangedVisual(_ moveId: Int) -> Bool {
        if EffectPlayer.hasProjectile(moveId) { return true }
        guard let m = GameData.moves[moveId] else { return false }
        // ROM caster-anim classes that extend a weapon or cast in place —
        // 2 Strike-class swipe (Vine Whip), 3 Shoot-class emit, 8 Swing
        // (Power Whip, Iron Tail), 11 Charge: the body stays put even when
        // the move officially "makes contact". Body anims (1 Attack,
        // 9 Double, 10 Hop, 12 Rotate) keep the contact-flag lunge.
        if let a = m.casterAnim, [2, 3, 8, 11].contains(a) { return true }
        if let contact = m.contact { return !contact }
        return m.category == "Special"
    }

    /// Contact-move lunge: the attacker physically darts at the defender,
    /// peaking exactly at the impact tick, then springs back. Makes a Tackle
    /// read as a body blow on BOTH sides regardless of how animated the
    /// species' Attack sheet is. Ranged moves (projectile or special) stay
    /// put; full-screen moves neither lunge nor shoot.
    private func tickLunge(_ e: BattleEvent) {
        // Only a landed hit (or a whiffed DAMAGING move) is a body blow —
        // status moves (Leer, Defense Curl, ...) play their effect clip and
        // pose in place instead of ramming the foe.
        guard e.kind == .attack || e.kind == .miss, e.moveId > 0,
              e.damage > 0 || (e.kind == .miss && BattleEngine.isDamaging(e.moveId)),
              !EffectPlayer.isScreen(e.moveId),
              !EffectPlayer.isExplosionMove(e.moveId),   // detonates in place
              !Self.rangedVisual(e.moveId) else { return }
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
            let ranged = Self.rangedVisual(e.moveId)
            // Attack anim runs through the impact (holding its last frame just
            // past it), so a lunge isn't cut off mid-swing. An explosion's
            // damage beat gets NO attacker pose: the user already detonated
            // (and fainted) on the preceding selfHit beat.
            if evTick < min(36, impactAt + 12), !EffectPlayer.isExplosionMove(e.moveId) {
                // The move's ROM caster anim when it has one (each renderer
                // resolves it per species, falling back to attack/shoot);
                // index 0 (Walk) reads wrong as a battle pose — heuristic.
                let atk: (BattlePose, Int)
                if let idx = GameData.moves[e.moveId]?.casterAnim, idx >= 1 {
                    atk = (.rom(index: idx, ranged: ranged), evTick)
                } else {
                    atk = (ranged ? BattlePose.shoot : .attack, evTick)
                }
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

    /// Item-use beat: the used item's icon rises over the follower's head so
    /// there's no doubt WHAT the turn was spent on.
    private func tickItemUse(_ e: BattleEvent) {
        guard let icon = GameItem(rawValue: e.ballId).flatMap(platformItemIcon) else { return }
        let scale = AppSettings.shared.scale
        let anchor = e.targetIsPlayer ? playerPos : (wildMon?.pos ?? playerPos)
        let t = min(1.0, Double(evTick) / Double(max(1, drainEnd)))
        ballFrame = icon
        ballPos = CGPoint(x: anchor.x,
                          y: anchor.y + (34 + CGFloat(t) * 18) * scale)
    }

    /// Ball-throw beat (D11): the ball arcs player -> wild, the wild is pulled
    /// in, the ball wobbles once per passed shake check, then either clicks
    /// shut (caught — the wild stays in) or bursts open (the wild pops back).
    private func tickBall(_ e: BattleEvent) {
        let icon = GameItem(rawValue: e.ballId).flatMap(platformItemIcon)
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

    /// Append a battle-log line (newest last, capped at 4 visible lines).
    private func pushLog(_ text: String) {
        guard AppSettings.shared.battleLogEnabled else { return }
        logLines.append((text, 0))
        if logLines.count > 4 { logLines.removeFirst(logLines.count - 4) }
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
           ["woke up", "thawed"].contains(e.moveName)
            || ["Refresh", "Heal Bell", "Aromatherapy"]
                .contains(GameData.moves[e.moveId]?.englishName ?? "") {
            curPStatus = nil
        }
        if e.kind == .item, e.targetIsPlayer,
           GameItem(rawValue: e.ballId)?.curesStatus == true {
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
            // A follow-up strike continues an announced move: barely any
            // windup, so the string raps out hit-hit-hit.
            let travel = 18, windup = e.followUp ? 6 : 20
            var total = 0
            // Travel direction picks the projectile's facing (8-dir ROM sets).
            let ddx = target.x - attacker.x, ddy = target.y - attacker.y
            let octant = (abs(ddx) > 0.01 || abs(ddy) > 0.01)
                ? Sprite.octant(dx: ddx, dy: ddy) : 6
            let proj = e.moveId > 0 ? EffectPlayer.projectile(forMove: e.moveId, octant: octant) : nil
            if let proj {
                effects.append(RunningEffect(clip: proj, from: attacker, to: target, maxTicks: travel))
                total = travel
            } else {
                total = windup
            }
            // Companion clip (ROM anim2 — e.g. Vine Whip's vine lash): plays
            // at the target BEFORE the hit flash, so the impact lands exactly
            // when the whip does. Directional sets face the CASTER — a
            // drain's gather must flow toward whoever is absorbing, not
            // whichever way the sheet's first rotation happens to point.
            // Cry-type moves (mainline "sound" flag): a STATUS cry with no
            // projectile emanates from just in front of the USER — Growl's
            // rings on the target read as the target doing the growling
            // (user report). Damaging sound moves keep their on-target
            // impact, and projectile cries (Sing & co) already fly.
            let moveData = GameData.moves[e.moveId]
            let cry = proj == nil && moveData?.sound == true && moveData?.category == "Status"
            let front = CGPoint(x: attacker.x + (target.x - attacker.x) * 0.3,
                                y: attacker.y + (target.y - attacker.y) * 0.3)
            // One multi-hit STRIKE per event (engine emits them separately):
            // the strike visual raps 3 quick times per hit — the ROM clip is
            // a single 5-tick poke, and EoS multiplies it engine-side.
            let strikeReps = e.multiStrike ? 3 : 1
            var coTicks = 0
            if e.moveId > 0, !EffectPlayer.isExplosionMove(e.moveId),
               let co = EffectPlayer.coClip(forMove: e.moveId, octant: octant) {
                let ticks = min(co.loop ? 24 : co.totalTicks, e.multiStrike ? 8 : 36)
                let delay = proj == nil ? windup : 0
                // Companion anchor: drain gathers collect ON the caster and
                // cries ring just ahead of it (both user-tuned); everything
                // else — Vine Whip's vine, Fury Attack's horn thrusts — lands
                // on the TARGET, where directional sets' baked offsets
                // animate the approach from the attacker's side.
                let coAnchor: CGPoint
                if case .drain = MoveMechanics.mechanic(for: e.moveId) { coAnchor = attacker }
                else if cry { coAnchor = front }
                else { coAnchor = target }
                for i in 0..<strikeReps {
                    effects.append(RunningEffect(clip: co, anchor: coAnchor,
                                                 maxTicks: (i == 0 ? delay : 0) + ticks,
                                                 delay: i == 0 ? delay : 0))
                }
                coTicks = ticks * strikeReps
                total += coTicks
            }
            impactAt = total
            // Explosion moves played their boom on the detonation beat (the
            // selfHit before this event) — this beat only lands the damage.
            if e.moveId > 0, !EffectPlayer.isExplosionMove(e.moveId),
               let clip = EffectPlayer.clip(forMove: e.moveId, octant: octant) {
                // The companion already carried the raps; without one, the
                // hit clip itself raps.
                let reps = coTicks > 0 ? 1 : strikeReps
                let hitTicks = min(clip.loop ? 40 : clip.totalTicks, reps > 1 ? 8 : 54)
                let delay = (proj == nil && coTicks == 0) ? windup : 0
                for i in 0..<reps {
                    effects.append(RunningEffect(clip: clip, anchor: cry ? front : target,
                                                 maxTicks: (i == 0 ? delay : 0) + hitTicks,
                                                 delay: i == 0 ? delay : 0))
                }
                total += hitTicks * reps
            }
            // Stat-change auras: any "ATK +1"-style token in the tag queues
            // the stat's colored aura on WHOSE stats moved — rising for a
            // raise, sinking for a drop. Covers status moves, secondaries,
            // and self-drops alike (they all ride statTag).
            if let tag = e.statusApplied {
                let changes = Self.statChanges(in: tag)
                if !changes.isEmpty {
                    let anchor = tag.hasPrefix("self ") ? attacker
                        : (e.targetIsPlayer ? playerPos : wildPos)
                    for (stat, delta) in changes.prefix(3) {
                        if let aura = EffectPlayer.statAura(stat, rising: delta > 0) {
                            let ticks = min(aura.totalTicks, 30)
                            effects.append(RunningEffect(clip: aura, anchor: anchor,
                                                         maxTicks: ticks))
                            total += ticks
                        }
                    }
                }
            }
            hitAt = max(impactAt, min(total, 72))
            if EffectPlayer.isScreen(e.moveId) { hitAt = impactAt + 20 }   // flash duration
            // Mid-string strikes drain briskly; the last one (carrying the
            // "N hits!" tag) keeps the full pause so the tally can land.
            let resolve = e.damage > 0 ? (e.multiStrike && e.statusApplied == nil ? 14 : 26)
                                       : (e.kind == .miss ? 24 : 10)
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
            if e.moveName == "leech seed", let clip = EffectPlayer.drainClip {
                // The stolen HP flows INTO the seeder: loose round sparks
                // gather together while they travel victim -> seeder (the
                // ROM keeps this tick's visual in engine code — a suck-in
                // reads as draining, a burst reads as a hit).
                let seeder = e.targetIsPlayer ? (wildMon?.pos ?? playerPos) : playerPos
                let travel = 26
                effects.append(RunningEffect(clip: clip, from: victim, to: seeder,
                                             maxTicks: travel))
                hitAt = max(hitAt, travel)
            } else if let clip = EffectPlayer.statusClip(e.moveName) {
                let ticks = min(clip.loop ? 30 : clip.totalTicks, 44)
                effects.append(RunningEffect(clip: clip, anchor: victim, maxTicks: ticks))
                hitAt = max(hitAt, ticks)
            }
            drainEnd = hitAt + 24
            curTicks = drainEnd + 12
        case .selfHit:
            if EffectPlayer.isExplosionMove(e.moveId),
               let clip = EffectPlayer.clip(forMove: e.moveId) {
                // Detonation beat (Selfdestruct & co): announce + blast over
                // the USER first, then its whole gauge drains. The follow-up
                // attack event lands the foe's damage without a second boom.
                let actor = e.actorIsPlayer ? playerPos : (wildMon?.pos ?? playerPos)
                let ticks = min(clip.loop ? 40 : clip.totalTicks, 54)
                effects.append(RunningEffect(clip: clip, anchor: actor,
                                             maxTicks: 6 + ticks, delay: 6))
                impactAt = 6                    // flash + quake open with the burst
                hitAt = 6 + ticks               // gauge drains once the blast peaks
                drainEnd = hitAt + 26
                curTicks = drainEnd + 12
            } else {
                impactAt = 6
                hitAt = 6
                drainEnd = hitAt + 24
                curTicks = drainEnd + 12
            }
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
            // A heal MOVE (Recover, Milk Drink, Moonlight...) plays its own
            // clip(s) over the healer before the gauge fills — this beat
            // never appended one, so every self-heal was gauge-only (user
            // report). Passive recoveries (woke up, drained) stay clip-less.
            if e.moveId > 0 {
                let healer = e.targetIsPlayer ? playerPos : (wildMon?.pos ?? playerPos)
                var t = 0
                if let co = EffectPlayer.coClip(forMove: e.moveId) {
                    let ticks = min(co.loop ? 24 : co.totalTicks, 36)
                    effects.append(RunningEffect(clip: co, anchor: healer, maxTicks: ticks))
                    t += ticks
                }
                if let clip = EffectPlayer.clip(forMove: e.moveId) {
                    let ticks = min(clip.loop ? 30 : clip.totalTicks, 44)
                    effects.append(RunningEffect(clip: clip, anchor: healer, maxTicks: ticks))
                    t += ticks
                }
                hitAt = max(hitAt, t)
            }
            drainEnd = hitAt + 22
            curTicks = drainEnd + 12
        case .item:
            // The trainer's potion: the item icon floats over the follower's
            // head (tickItemUse) while the gauge fills.
            impactAt = 8; hitAt = 14
            drainEnd = hitAt + 24
            curTicks = drainEnd + 18
        }

        // Battle log: schedule this event's lines inside its beat (start now,
        // impact/resolve when the hit lands / the drain finishes).
        pendingLog = []
        if AppSettings.shared.battleLogEnabled, let w = wild {
            let impactTick = e.kind == .ball ? 16 + e.shakes * 14 : hitAt
            for entry in BattleLog.lines(for: e, playerName: session?.player.name ?? "",
                                         wildName: w.name) {
                switch entry.phase {
                case .start: pushLog(entry.text)
                case .impact: pendingLog.append((impactTick, entry.text))
                case .resolve: pendingLog.append((e.kind == .ball ? impactTick : drainEnd,
                                                  entry.text))
                }
            }
            pendingLog.sort { $0.tick < $1.tick }
        }
    }

    private func finishBattle() {
        let won = result?.playerWon ?? false
        var captured = false
        levelUpTo = nil
        if let r = result {
            let st = RaisingState.shared
            for b in r.ballsUsed { st.consumeItem(b) }
            let activeIdx = st.save.activeIndex     // who fought last (before faint swap)
            // End state first (HP/status write-back), then the spoils.
            st.applyBattleState(hp: r.playerEndHP, status: r.playerEndStatus, at: activeIdx)
            BattleLog.outcome(wildFled: r.wildFled, playerFled: r.playerFled,
                              wildName: wild?.name ?? "").forEach { pushLog($0) }
            if r.playerWon, r.expGained > 0 {
                participants.insert(activeIdx)
                awardExp(total: r.expGained, activeIdx: activeIdx)
            }
            if r.captured, let w = wild {
                captured = true
                // Battle-local state (Transform, Mimic, stages) ends with the
                // battle — a transformed Ditto is caught as a plain Ditto.
                let caught = Battler(resetting: w) ?? w
                if st.partyHasRoom {
                    _ = st.addCaptured(from: caught)
                } else if let mon = st.capturedMon(from: caught) {
                    // Full party: release someone or let the catch go (D14/#14).
                    PromptRelay.enqueue(.fullParty(captured: mon))
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
            // A level-up tag needs a beat longer to read (mainline jingle);
            // so do the EXP/level-up log lines.
            endTicks = levelUpTo != nil ? (fast ? 60 : 130) : (fast ? 40 : 90)
            if AppSettings.shared.battleLogEnabled { endTicks += 40 }
            endTotal = endTicks
            phase = .ending                 // the beaten wild fades away
        } else if result?.wildFled == true || result?.playerFled == true {
            // The wild teleported / was roared away — OR it blew/teleported
            // US out. Either way the ENCOUNTER is over, and only the wild
            // can leave the screen (the follower is the mouse), so it
            // departs with a fade and no spoils. (playerFled used to fall
            // into the lingering branch below: a wild Lugia would Whirlwind,
            // log "fled", stay put, and immediately re-engage — forever.)
            ballFrame = nil
            endTicks = fast ? 30 : 60
            endTotal = endTicks
            phase = .ending
        } else if result?.wildFainted == true {
            // Double KO (e.g. the wild's Explosion): no winner, so no EXP,
            // but the wild went down too — fade it out like a win instead of
            // letting a 0-HP wild linger and wander (the loss branch below
            // assumes the wild is still standing).
            ballFrame = nil
            endTicks = fast ? 30 : 60
            endTotal = endTicks
            phase = .ending
        } else {
            ballFrame = nil
            // My mon fainted (it now stays down where it fell). The wild is NOT
            // defeated — it lingers/wanders so I can send out another mon and keep
            // challenging it; it leaves on its own despawn timer. Its battle
            // state — stat stages AND Transform (look included) — persists
            // while it stays out, consistent with the wild keeping its HP;
            // only a capture resets it (see the captured branch above).
            phase = .present
        }
        playerTransformedDex = nil
        // The fatal hit's damage number outlives its event (its fade window
        // runs past curTicks) and nothing ticks it outside .battling — clear
        // it, or a faint leaves the last "-NN" frozen while the wild lingers.
        dmgText = nil; dmgAlpha = 0
        // The battle ended during the turn the flee was waiting on — the
        // outcome stands (applied above), THEN the recall goes through.
        if recallTurn != nil {
            recallTurn = nil
            RaisingState.shared.recall()
        }
        // Same for a queued switch: the outcome (EXP share included) lands
        // first, then the chosen member simply comes out post-battle.
        if let idx = switchIndex {
            switchTurn = nil; switchIndex = nil
            if RaisingState.shared.save.party.indices.contains(idx),
               !RaisingState.shared.party[idx].isFainted {
                RaisingState.shared.applyActive(idx)
            }
        }
    }

    /// Mainline EXP share: every participant still standing gets an equal
    /// split (fainted ones sit the payout out — strict mainline rules),
    /// announced one by one — the mon that finished the fight first, then the
    /// bench in party order — with level-ups, move-learn prompts and
    /// evolutions riding each share (evolutions queue on the overlay in this
    /// same order, so the active mon's scene plays first).
    private func awardExp(total: Int, activeIdx: Int) {
        let st = RaisingState.shared
        let eligible = participants.filter {
            st.save.party.indices.contains($0) && !st.party[$0].isFainted
        }
        guard !eligible.isEmpty else { return }
        let share = max(1, total / eligible.count)
        let ordered = (eligible.contains(activeIdx) ? [activeIdx] : [])
            + eligible.sorted().filter { $0 != activeIdx }
        for idx in ordered {
            let name = Characters.displayName(dex: st.party[idx].dex)   // pre-evolution name
            pushLog(BattleLog.expLine(name: name, amount: share))
            let growth = st.gainExp(share, at: idx)
            if let lv = growth.leveledTo {
                pushLog(BattleLog.levelUpLine(name: name, level: lv))
                if idx == activeIdx { levelUpTo = lv }   // overhead tag = active only
            }
            // A 5th move needs a replace decision — on-overlay prompt (C1/#5),
            // benched participants included, in the same announce order.
            for moveId in growth.pendingMoves {
                PromptRelay.enqueue(.learnMove(monIndex: idx, moveId: moveId))
            }
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
            floatColor = RGBA(r: 1.0, g: 0.84, b: 0.25)
        }
        if endTicks <= 0 { despawn() }
    }

    /// Break off the current battle without applying its pre-simulated
    /// outcome: BOTH sides keep what their gauges were showing — the wild its
    /// HP (resumes wandering), the follower its HP and shown ailment. No EXP,
    /// nothing consumed; fleeing is never a free heal and never faints.
    private func cancelBattle() {
        pushLog(BattleLog.recallLine(playerName: session?.player.name ?? ""))
        pendingLog = []
        playerTransformedDex = nil
        if let w = wild { w.currentHP = max(1, Int(curWHP * Double(w.maxHP))) }
        if let mon = RaisingState.shared.active {
            RaisingState.shared.applyFleeState(
                hp: Int((curPHP * Double(mon.maxHP)).rounded()), status: curPStatus)
        }
        recallTurn = nil
        switchTurn = nil; switchIndex = nil
        if switchAnim != nil {   // broken off mid-beat: undo its visuals
            switchAnim = nil
            pBodyScale = 1; pBodyTarget = 1
        }
        // participants stay: the wild lingers, and whoever re-engages it
        // joins the same EXP-share pool (mainline share across the fight).
        session = nil
        pendingItem = nil
        pendingBall = nil
        events = []; result = nil; effects = []; ballFrame = nil
        playerPose = (.stand, 0)
        playerDodge = .zero; wildDodge = .zero
        floatText = nil; floatAlpha = 0; screenFlash = 0
        dmgText = nil; dmgAlpha = 0
        flashP = false; flashW = false
        wildAlpha = 1; playerAlpha = 1
        pVanish = false; wVanish = false
        pSub = false; wSub = false
        evIdx = 0; evTick = 0
        phase = .present
    }

    private func despawn() {
        logLines = []
        pendingLog = []
        playerTransformedDex = nil
        wildTransformedDex = nil
        pBodyScale = 1; wBodyScale = 1
        pBodyTarget = 1; wBodyTarget = 1
        pVanish = false; wVanish = false
        pSub = false; wSub = false
        recallTurn = nil
        switchTurn = nil; switchIndex = nil
        switchAnim = nil
        participants = []
        session = nil
        pendingItem = nil
        pendingBall = nil
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
            wildFrame: (wSub ? Self.substituteDoll : nil) ?? frame,
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
            damageText: dmgText, damagePos: dmgPos,
            damageAlpha: dmgAlpha, damageColor: dmgColor,
            screenFlash: screenFlash, screenColor: screenColor,
            logLines: logLines.map { ($0.text, logAlpha($0.age)) },
            logAnchor: logAnchor(wildPos: wm.pos),
            playerSpriteDex: playerTransformedDex,
            wildSpriteDex: wildTransformedDex,
            playerSpriteScale: pBodyScale,
            wildSpriteScale: wBodyScale,
            playerVanished: pVanish,
            wildVanished: wVanish,
            playerSubstitute: pSub)
    }

    private func logAlpha(_ age: Int) -> Double {
        min(1, max(0, Double(logHoldTicks + logFadeTicks - age) / Double(logFadeTicks)))
    }

    /// Top-center of the log box: under the pair, clamped to the screen that
    /// hosts the midpoint. Clamped HERE (not per view) so every monitor's
    /// SpriteView draws the box at the same global spot.
    private func logAnchor(wildPos: CGPoint) -> CGPoint {
        let s = AppSettings.shared.scale
        var p = CGPoint(x: (playerPos.x + wildPos.x) / 2,
                        y: min(playerPos.y, wildPos.y) - 34 * s)
        let estW: CGFloat = 340, estH: CGFloat = 88   // conservative box estimate
        let screens = platformScreensWorld()
        let screen = screens.first { $0.contains(p) } ?? screens.first
            ?? CGRect(x: 0, y: 0, width: 1440, height: 900)
        p.x = min(max(p.x, screen.minX + estW / 2 + 8), screen.maxX - estW / 2 - 8)
        p.y = min(max(p.y, screen.minY + estH + 8), screen.maxY - 8)
        return p
    }

    // MARK: helpers

    private func frac(_ hp: Int, _ maxHP: Int) -> Double { Double(hp) / Double(max(1, maxHP)) }
    private func lerp(_ a: Double, _ b: Double, _ t: Double) -> Double { a + (b - a) * t }

    /// 0...1 ease that overshoots past 1 near the end and settles back —
    /// the send-out pop of the switch beat.
    private func easeOutBack(_ p: Double) -> Double {
        let c1 = 1.70158, c3 = c1 + 1
        let q = p - 1
        return 1 + c3 * q * q * q + c1 * q * q
    }

    private func screenBounds() -> CGRect {
        var r = CGRect.null
        for s in platformScreensWorld() { r = r.union(s) }
        return r.isNull ? CGRect(x: 0, y: 0, width: 1440, height: 900) : r
    }

    /// Random delay around the user's average encounter interval (D9): the
    /// setting is the mean in minutes; actual spawns land in ±25% of it.
    private func nextSpawnDelay() -> Int {
        cooldownBasisMinutes = AppSettings.shared.encounterMinutes
        if fast { return 60 * 4 }   // 4s for testing
        let avg = Double(AppSettings.shared.encounterMinutes) * 60   // seconds
        return Int(Double.random(in: (avg * 0.75)...(avg * 1.25))) * 60
    }
}
