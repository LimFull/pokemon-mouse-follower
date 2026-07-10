// Debug hooks & selftests (--dump-effect/-icons/-evolution,
// --selftest-uiscale/-raising), dispatched from main.swift.

import Cocoa
import ImageIO
import UniformTypeIdentifiers

/// Write a CGImage as PNG (the dump hooks' shared output path).
@discardableResult
private func writePNG(_ image: CGImage, to url: URL) -> Bool {
    guard let d = CGImageDestinationCreateWithURL(url as CFURL,
                                                  UTType.png.identifier as CFString, 1, nil)
    else { return false }
    CGImageDestinationAddImage(d, image, nil)
    return CGImageDestinationFinalize(d)
}

/// Handle the --dump-* / --selftest-* debug flags. Each hook exits the
/// process after it runs; with no flag present this returns immediately and
/// the normal app bootstrap continues.
func runCommandLineHooks() {
    dumpEffectIfRequested()
    dumpIconsIfRequested()
    dumpEvolutionIfRequested()
    dumpBattleLogIfRequested()
    selftestUIScaleIfRequested()
    selftestRaisingIfRequested()
}

private func dumpBattleLogIfRequested() {
    // Debug hook: `--dump-battlelog <out.png>` renders a synthetic battle
    // scene (sprites + HP bars + a 4-line log box) through the real
    // SpriteView layer pipeline — visual check for the log layout.
    if let i = CommandLine.arguments.firstIndex(of: "--dump-battlelog"),
       CommandLine.arguments.count > i + 1 {
        let out = URL(fileURLWithPath: CommandLine.arguments[i + 1])
        guard let wildFrame = CharacterPreviewView.idleDownFrames("016").first,
              let playerFrame = CharacterPreviewView.idleDownFrames("025").first else {
            print("dump-battlelog: no sprite frames in bundle"); exit(2)
        }
        let size = NSSize(width: 640, height: 400)
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                              styleMask: .borderless, backing: .buffered, defer: false)
        let view = SpriteView(frame: NSRect(origin: .zero, size: size))
        view.screenOrigin = .zero
        window.contentView = view
        let scene = BattleScene(
            wildFrame: wildFrame,
            wildPos: CGPoint(x: 240, y: 260), playerPos: CGPoint(x: 400, y: 260),
            playerHP: 0.8, wildHP: 0.45, flashPlayer: false, flashWild: false,
            playerAlpha: 1, wildAlpha: 1, showBars: true,
            effectFrame: nil, effectPos: .zero,
            wildLevel: 7,
            logLines: [("앗! 야생의 구구가 튀어나왔다!", 0.4),
                       ("피카츄의 전기쇼크!", 1.0),
                       ("효과가 굉장했다!", 1.0),
                       ("구구는 12의 데미지를 입었다!", 1.0)],
            logAnchor: CGPoint(x: 320, y: 200))
        view.render(playerFrame, globalPos: scene.playerPos,
                    shadow: ShadowAnchor(offset: .zero, size: CGSize(width: 14, height: 6)))
        view.renderBattle(scene)
        view.layoutSubtreeIfNeeded()
        window.display()
        guard let ctx = CGContext(data: nil, width: Int(size.width * 2), height: Int(size.height * 2),
                                  bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue) else { exit(2) }
        ctx.scaleBy(x: 2, y: 2)
        view.layer?.render(in: ctx)
        if let img = ctx.makeImage() { writePNG(img, to: out) }
        print("dumped battle-log scene → \(out.path)")
        exit(0)
    }
}

private func dumpEffectIfRequested() {
    // Debug hook: `--dump-effect <moveId> <outDir>` writes the corrected effect
    // clip's frames as PNGs (visual check of crop/tint/particle composition).
    if let i = CommandLine.arguments.firstIndex(of: "--dump-effect"),
       CommandLine.arguments.count > i + 2, let moveId = Int(CommandLine.arguments[i + 1]) {
        let dir = URL(fileURLWithPath: CommandLine.arguments[i + 2])
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        func dump(_ clip: EffectClip?, _ prefix: String) {
            guard let clip else { return }
            for (n, s) in clip.steps.enumerated() {
                writePNG(s.image, to: dir.appendingPathComponent(String(format: "%@-%02d.png", prefix, n)))
            }
            print("dumped \(prefix): \(clip.steps.count) steps (\(clip.totalTicks) ticks) for move \(moveId) → \(dir.path)")
        }
        dump(EffectPlayer.clip(forMove: moveId), "step")
        dump(EffectPlayer.projectile(forMove: moveId), "proj")
        dump(EffectPlayer.projectile(forMove: moveId, octant: 0), "projE")   // flying east
        exit(0)
    }
}

private func dumpIconsIfRequested() {
    // Debug hook: `--dump-icons <outDir>` writes every drawn item icon as PNG.
    if let i = CommandLine.arguments.firstIndex(of: "--dump-icons"), CommandLine.arguments.count > i + 1 {
        let dir = URL(fileURLWithPath: CommandLine.arguments[i + 1])
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for item in GameItem.allCases {
            guard let cg = item.icon else { continue }
            writePNG(cg, to: dir.appendingPathComponent("\(item.rawValue)-\(item.nameKey).png"))
        }
        print("dumped \(GameItem.allCases.count) icons → \(dir.path)")
        exit(0)
    }
}

private func dumpEvolutionIfRequested() {
    // Debug hook: `--dump-evolution <fromDex> <toDex> <outDir>` writes the
    // evolution scene's frames (every 10 ticks) for a visual check.
    if let i = CommandLine.arguments.firstIndex(of: "--dump-evolution"),
       CommandLine.arguments.count > i + 3,
       let fromDex = Int(CommandLine.arguments[i + 1]), let toDex = Int(CommandLine.arguments[i + 2]) {
        let dir = URL(fileURLWithPath: CommandLine.arguments[i + 3])
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let anim = EvolutionAnimator()
        anim.start(fromDex: fromDex, toDex: toDex, at: .zero)
        var n = 0, tick = 0
        while let (frame, glow) = anim.update() {
            if tick % 10 == 0 {
                let u = dir.appendingPathComponent(String(format: "e%03d-g%02.0f.png", tick, glow * 10))
                if writePNG(frame, to: u) { n += 1 }
            }
            tick += 1
        }
        print("dumped \(n) evolution frames over \(tick) ticks → \(dir.path)")
        exit(0)
    }
}

private func selftestUIScaleIfRequested() {
    // Headless check for the UI-scale zoom: the settings window / update HUD
    // must grow by the factor while their content keeps its 1x layout.
    if CommandLine.arguments.contains("--selftest-uiscale") {
        // Visual dump for eyeballing the zoom. Render the LAYER tree — the
        // same thing the window server composites; cacheDisplay draws through
        // the view path, which mishandles the bounds transform.
        func dump(_ sc: SettingsWindowController, _ name: String) {
            guard let cv = sc.window.contentView else { return }
            cv.layoutSubtreeIfNeeded()
            sc.window.display()
            let sz = cv.bounds.size
            guard let ctx = CGContext(data: nil, width: Int(sz.width * 2), height: Int(sz.height * 2),
                                      bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue) else { return }
            ctx.scaleBy(x: 2, y: 2)
            NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
            cv.layer?.render(in: ctx)
            NSGraphicsContext.current = nil
            if let img = ctx.makeImage() {
                writePNG(img, to: URL(fileURLWithPath: "/tmp/pmf-uiscale-\(name).png"))
            }
        }
        let saved = AppSettings.shared.uiScale
        for k in [1.0, 1.5, 2.0] {
            AppSettings.shared.uiScale = k
            let sc = SettingsWindowController(controller: CharacterController())
            let f = sc.window.frame
            let hud = UpdateProgressWindow()
            print(String(format: "uiscale %.2f: settings=%.0fx%.0f hud=%@",
                         k, f.width, f.height, hud.debugFrameString))
            dump(sc, String(Int(k * 100)))
        }
        // Live change: the popup path must re-render at the new factor without
        // recreating the window (no relaunch needed).
        AppSettings.shared.uiScale = 1
        let sc = SettingsWindowController(controller: CharacterController())
        sc.setUIScale(2.0)
        let f = sc.window.frame
        print(String(format: "uiscale live 1->2: settings=%.0fx%.0f", f.width, f.height))
        dump(sc, "live")
        AppSettings.shared.uiScale = saved
        exit(0)
    }
}

// Debug hook: `--selftest-raising` exercises the raising-mode data/state layer
// against the bundled game data, prints a report, and exits. Harmless otherwise.
private func selftestRaisingIfRequested() {
    if CommandLine.arguments.contains("--selftest-raising") {
        // The selftest RESETS the party. Refuse to touch the real save: it only
        // runs against a scratch directory (PMF_SAVE_DIR redirects persistence).
        guard ProcessInfo.processInfo.environment["PMF_SAVE_DIR"] != nil else {
            print("refusing --selftest-raising: it resets the save. Set PMF_SAVE_DIR to a scratch directory first.")
            exit(2)
        }
        print("GameData: species=\(GameData.species.count) moves=\(GameData.moves.count) starters=\(GameData.starters.count)")
        let st = RaisingState.shared
        st.reset()
        st.startNewGame(dex: 1)
        if let m = st.active, let s = m.species {
            let sv = GameData.stats(s, level: m.level)
            print("start: \(Characters.displayName(s.id)) Lv\(m.level) \(m.gender.rawValue) HP=\(m.currentHP)/\(m.maxHP) ATK\(sv.atk) DEF\(sv.def) moves=\(m.moves)")
        } else { print("start FAILED — GameData not loaded from bundle?") }
        // Growth: give enough EXP to level up through the L16 evolution.
        st.setActive(0)
        let g = st.gainExp(50000)
        if let m = st.active {
            let evo = (g.evolvedFrom != nil) ? "\(g.evolvedFrom!)->\(g.evolvedTo!)" : "none"
            print("train: Lv\(m.level) dex=\(m.dex) \(Characters.displayName(dex: m.dex)) moves=\(m.moves) evolved=\(evo) auto=\(g.learnedMoves) pending=\(g.pendingMoves)")
            let (left, frac) = m.expToNext
            print("exp gauge: toNext=\(left) frac=\(String(format: "%.2f", frac)) (expect 0<frac<1, left>0)")
        }
        print("followerFolder(raising off)=\(st.followerFolder)")
        // Battle: active mon vs a wild Pidgey (dex 16).
        print("typechart types=\(TypeChart.chart.count)")
        if let p = Battler(mon: st.active!), let w = Battler(wildDex: 16, level: 12) {
            let r = BattleEngine.run(player: p, wild: w)
            print("battle: \(p.name) L\(p.level) \(p.gender.rawValue) vs wild \(w.name) L\(w.level) \(w.gender.rawValue) → \(r.playerWon ? "WIN" : "LOSE") in \(r.events.count) events, exp=\(r.expGained) (base \(w.baseExp)), endStatus=\(r.playerEndStatus ?? "none")")
            for e in r.events.prefix(4) {
                print("  \(e.actorIsPlayer ? "▶" : "◀") [\(e.kind)] T\(e.turn) \(e.moveName): \(e.damage) dmg x\(e.effectiveness) (tgt \(e.targetIsPlayer ? "P" : "W") HP \(e.targetHP)/\(e.targetMaxHP))\(e.statusApplied.map { " +\($0)" } ?? "")\(e.fainted ? " FAINT" : "")")
            }
            // Turn stamps (the mid-battle recall flees at these boundaries):
            // must start at 1 and never decrease across the event log.
            let turns = r.events.map(\.turn)
            let monotonic = zip(turns, turns.dropFirst()).allSatisfy { $0 <= $1 }
            print("turn stamps: first=\(turns.first ?? 0) last=\(turns.last ?? 0) monotonic=\(monotonic) (expect first=1, monotonic=true)")
        }
        // Status conditions (D19): Thunder Wave-style paralysis + burn chip damage.
        if let p = Battler(wildDex: 25, level: 20), let w = Battler(wildDex: 16, level: 18) {
            let r = BattleEngine.run(player: p, wild: w)
            let statuses = r.events.compactMap { $0.statusApplied }
            let kinds = Set(r.events.map { "\($0.kind)" })
            print("status battle: Pikachu vs Pidgey → statuses=\(statuses) kinds=\(kinds.sorted())")
            // Battle log composer (pure): every event yields at least one line,
            // and no raw localization key may leak into the text.
            var logs = [BattleLog.battleStart(wildName: w.name)]
            logs += r.events.flatMap { BattleLog.lines(for: $0, playerName: p.name, wildName: w.name) }
                            .map { $0.text }
            logs += BattleLog.outcome(won: r.playerWon, expGained: r.expGained, levelUpTo: 21,
                                      captured: false, wildFled: r.wildFled,
                                      playerName: p.name, wildName: w.name)
            logs.append(BattleLog.recallLine(playerName: p.name))
            let unresolved = logs.filter { $0.contains("log.") }
            print("battle log: \(logs.count) lines from \(r.events.count) events, unresolved keys=\(unresolved.count) (expect 0)")
            for bad in unresolved.prefix(3) { print("  UNRESOLVED: \(bad)") }
            for l in logs.prefix(5) { print("  log: \(l)") }
        }
        // Special move mechanics (MoveMechanics): the table resolves, Transform
        // fires and copies the foe, empty movesets Struggle, stat stages bend the
        // damage math, and random matchups never hang the 200-round cap logic.
        do {
            let mapped = GameData.moves.keys.filter { MoveMechanics.mechanic(for: $0) != nil }.count
            print("mechanics: \(mapped) moves mapped, struggle=\(GameData.moves[MoveMechanics.struggleId]?.displayName ?? "?")")
            if let ditto = Battler(wildDex: 132, level: 20), let bird = Battler(wildDex: 16, level: 18) {
                let r = BattleEngine.run(player: ditto, wild: bird)
                let ev = r.events.first { $0.statusApplied == "transformed!" }
                // Self-directed: effect/tag/log must anchor on the TRANSFORMER.
                let selfTargeted = ev.map { $0.targetIsPlayer == $0.actorIsPlayer }
                print("ditto: transformed=\(ev != nil) selfTargeted=\(selfTargeted.map(String.init) ?? "n/a") in \(r.events.count) events (expect true true)")
                // End-of-battle reset: Transform ends with the battle — the
                // reset copy is a plain Ditto again (moves/types recomputed),
                // keeping only identity, HP and major status.
                if ev != nil, let reset = Battler(resetting: ditto),
                   let orig = Battler(wildDex: 132, level: 20) {
                    print("ditto reset: movesReverted=\(reset.moves == orig.moves) typeReverted=\(reset.type1 == "Normal") wasTransformed=\(ditto.moves != orig.moves) (expect true true true)")
                }
            }
            if let sm = Battler(wildDex: 235, level: 10), let d = Battler(wildDex: 16, level: 10) {
                let pick = BattleEngine.chooseMove(attacker: sm, defender: d)
                print("smeargle first pick: \(GameData.moves[pick]?.displayName ?? "?") (expect Struggle)")
            }
            // Mid-battle potion: the item event fires as the follower's action and
            // the heal lands before the wild replies (priority +6).
            if let p = Battler(wildDex: 7, level: 12), let w = Battler(wildDex: 16, level: 10) {
                p.currentHP = 5
                let s = BattleSession(player: p, wild: w)
                let evs = s.nextRound(playerItem: .potion)
                let itemEv = evs.first { $0.kind == .item }
                print("mid-battle potion: event=\(itemEv != nil) healedTo=\(itemEv?.targetHP ?? -1) icon=\(GameItem.potion.icon != nil) (expect true, 25, true)")
            }
            // Mid-battle Full Heal: the item cures the follower's ailment and the
            // turn is spent in its place.
            if let p = Battler(wildDex: 7, level: 12), let w = Battler(wildDex: 16, level: 10) {
                p.status = .poison
                let s = BattleSession(player: p, wild: w)
                let evs = s.nextRound(playerItem: .fullHeal)
                let itemEv = evs.first { $0.kind == .item }
                print("mid-battle full heal: event=\(itemEv != nil) cured=\(p.status == nil) icon=\(GameItem.fullHeal.icon != nil) (expect true, true, true)")
            }
            if let a = Battler(wildDex: 19, level: 20), let b = Battler(wildDex: 19, level: 20),
               let tackle = GameData.moves.values.first(where: { $0.displayName == "Tackle" }) {
                let base = (0..<300).map { _ in BattleEngine.computeDamage(attacker: a, defender: b, move: tackle, eff: 1) }.reduce(0, +)
                b.stages[.def] = -6
                let lowered = (0..<300).map { _ in BattleEngine.computeDamage(attacker: a, defender: b, move: tackle, eff: 1) }.reduce(0, +)
                print("stages: -6 DEF -> x\(String(format: "%.1f", Double(lowered) / Double(max(1, base)))) damage (expect ~4.0)")
                // Crits double and punch through the defender's buffs.
                b.stages = [.def: 6]
                let buffed = (0..<300).map { _ in BattleEngine.computeDamage(attacker: a, defender: b, move: tackle, eff: 1) }.reduce(0, +)
                let critted = (0..<300).map { _ in BattleEngine.computeDamage(attacker: a, defender: b, move: tackle, eff: 1, crit: true) }.reduce(0, +)
                print("crit: vs +6 DEF -> x\(String(format: "%.1f", Double(critted) / Double(max(1, buffed)))) damage (expect ~6-8)")
            }
            // Zero-usable movesets after the table: only "copy the foe's move
            // first" sets and pure field-sport sets should remain — they Struggle,
            // mainline-style, instead of whiffing forever.
            var dead = Set<Int>()
            if let dummy = Battler(wildDex: 16, level: 20) {
                for (dex, s) in GameData.species {
                    for L in stride(from: 2, through: 100, by: 3) {
                        let ms = Array(s.levelUpMoves.filter { $0.level <= L }.map { $0.moveId }.suffix(4))
                        guard !ms.isEmpty, let me = Battler(wildDex: dex, level: L) else { continue }
                        if !ms.contains(where: { BattleEngine.usable($0, attacker: me, defender: dummy) }) {
                            dead.insert(dex)
                        }
                    }
                }
            }
            print("zero-usable windows remain: \(dead.sorted()) (Struggle covers them)")
            var fuzzEvents = 0, fuzzBattles = 0
            for _ in 0..<40 {
                let l = Int.random(in: 3...60)
                guard let x = Battler(wildDex: GameData.species.keys.randomElement()!, level: l),
                      let y = Battler(wildDex: GameData.species.keys.randomElement()!, level: max(2, l + Int.random(in: -5...5)))
                else { continue }
                let r = BattleEngine.run(player: x, wild: y)
                fuzzBattles += 1
                fuzzEvents += r.events.count
                let turns = r.events.map(\.turn)
                if zip(turns, turns.dropFirst()).contains(where: { $0 > $1 }) {
                    print("FUZZ FAILURE: non-monotonic turn stamps")
                }
            }
            print("fuzz: \(fuzzBattles) random battles, \(fuzzEvents) events, all terminated")
        }
        // Move-effect sprites (D22): mapping + frames load from the bundle.
        print("move effects mapped=\(MoveEffects.map.count)")
        for (label, id) in [("Tackle", 154), ("Ember", 262), ("Thunderbolt", 129)] {
            if let c = EffectPlayer.clip(forMove: id) {
                print("  effect \(label): steps=\(c.steps.count) ticks=\(c.totalTicks) loop=\(c.loop) head=\(c.headAnchored)")
            } else { print("  effect \(label): MISSING") }
        }
        // Status visuals: every condition resolves to a playable proxy clip.
        let statusKeys = ["burn", "poison", "paralyzed", "frozen", "infatuated", "asleep", "confused"]
        print("status clips:", statusKeys.map { "\($0)=\(EffectPlayer.statusClip($0) != nil ? "ok" : "MISSING")" }.joined(separator: " "))
        // Gender ratios (G): Magnemite genderless, Nidoran♀ always female, Chansey female.
        for d in [81, 29, 113] {
            if let s = GameData.species[d] {
                let g = (0..<6).map { _ in Gender.random(genderRate: s.genderRate).rawValue.prefix(1) }.joined()
                print("gender \(s.displayName) rate=\(s.genderRate ?? 99): \(g)")
            }
        }
        // Capture (D11): a hurt, statused, high-catch-rate wild should catch fast.
        if let w = Battler(wildDex: 16, level: 5) {   // Pidgey, capture_rate 255
            w.currentHP = 1
            w.status = .sleep
            var caught = 0
            for _ in 0..<20 where BattleEngine.attemptCapture(wild: w, ball: .pokeBall).0 { caught += 1 }
            print("capture: Pidgey 1HP asleep — \(caught)/20 throws caught (expect most)")
        }
        // Items: inventory round-trip + a full engine run with balls.
        st.addItem(.pokeBall, 3)
        st.addItem(.potion)
        // A slight level edge: the wild survives into the 50% throw window but
        // the player reliably lives long enough to throw.
        if let p2 = Battler(wildDex: 7, level: 7), let w2 = Battler(wildDex: 16, level: 5) {
            let r = BattleEngine.run(player: p2, wild: w2, balls: [.pokeBall, .pokeBall, .pokeBall])
            let ballEvents = r.events.filter { $0.kind == .ball }
                .map { "\($0.shakes)s" + ($0.caught ? "O" : "X") }
            print("ball battle: thrown=\(r.ballsUsed.count) events=\(ballEvents) captured=\(r.captured)")
            if r.captured { _ = st.addCaptured(from: w2); print("party after capture=\(st.party.count)") }
        }
        print("bag: pokeball=\(st.itemCount(.pokeBall)) potion=\(st.itemCount(.potion)) canUsePotionOnHurt=\(st.canUseItem(.potion, at: 0))")
        // Wild battle-pose sheets actually load (attack frame differs from idle).
        if let wm = WildMon(dex: 7) {
            wm.place(at: .zero)
            wm.faceStanding(toward: CGPoint(x: 10, y: 0))
            let idleFrame = wm.currentFrame
            wm.faceStanding(toward: CGPoint(x: 10, y: 0), pose: .attack, poseTick: 12)
            let atkDistinct = wm.currentFrame !== idleFrame
            wm.faceStanding(toward: CGPoint(x: 10, y: 0), pose: .hurt, poseTick: 6)
            let hurtDistinct = wm.currentFrame !== idleFrame
            print("wild pose sheets: attack distinct=\(atkDistinct) hurt distinct=\(hurtDistinct) (expect true true)")
        }
        // Ranged-visual classification (mainline contact flag): only contact
        // moves lunge — Thunder Shock (special, no ROM projectile) and even
        // Earthquake (physical but non-contact) cast from range; Tackle and
        // the synthetic basic attack still ram the foe.
        do {
            func flag(_ name: String) -> String {
                guard let id = GameData.moves.first(where: { $0.value.englishName == name })?.key
                else { return "\(name)=?" }
                return "\(name)=\(BattleController.rangedVisual(id))"
            }
            print("ranged visual: \(flag("ThunderShock")) \(flag("Earthquake")) \(flag("Bubble")) \(flag("Tackle")) basicAttack=\(BattleController.rangedVisual(MoveMechanics.basicAttackId)) (expect true true true false false)")
        }
        // Wilds honor the alt-color setting (species 001 ships a variant):
        // the same first frame must have different pixels with the toggle on.
        do {
            let had = AppSettings.shared.altColor
            func firstFrameBytes(altColor: Bool) -> Data? {
                AppSettings.shared.altColor = altColor
                return WildMon(dex: 1)?.currentFrame?.dataProvider?.data as Data?
            }
            let normal = firstFrameBytes(altColor: false)
            let alt = firstFrameBytes(altColor: true)
            AppSettings.shared.altColor = had
            print("wild altcolor: frames loaded=\(normal != nil && alt != nil) differ=\(normal != alt) (expect true true)")
        }
        // Over-leveled capture evolves on the next level (#11): Lv20 Caterpie -> Metapod at 21.
        let caterpie = st.makeMon(species: GameData.species[10]!, level: 20)
        _ = st.addToParty(caterpie)
        st.setActive(st.party.count - 1)
        let need = (GameData.species[10]!.expCurve[20]) - caterpie.exp
        let g11 = st.gainExp(need)
        print("overlevel evo: Lv\(st.active!.level) dex=\(st.active!.dex) evolved=\(g11.evolvedFrom ?? 0)->\(g11.evolvedTo ?? 0) (expect 10->11)")
        st.setActive(0)
        // Wild pool (#12): evolved forms gated by their LEVEL thresholds.
        print("minWildLevel: Metapod=\(GameData.minWildLevel[11] ?? -1) Butterfree=\(GameData.minWildLevel[12] ?? -1) Charizard=\(GameData.minWildLevel[6] ?? -1) Pikachu=\(GameData.minWildLevel[25] ?? -1)")
        print("wildPool(5) has Butterfree: \(GameData.wildPool(atLevel: 5).contains(12)) (expect false), size=\(GameData.wildPool(atLevel: 5).count)")
        // Overlay-prompt state ops (C1): full-party capture resolve + indexed learnMove.
        if let w3 = Battler(wildDex: 25, level: 9), let cap = st.capturedMon(from: w3), let s16 = GameData.species[16] {
            while st.partyHasRoom { _ = st.addToParty(st.makeMon(species: s16, level: 4)) }
            st.resolveCapture(cap, releasing: 0)
            print("fullparty resolve: party=\(st.party.count)/6 last=\(st.party.last!.dex) (expect 25)")
            st.learnMove(999, replacing: 0, at: 1)
            print("indexed learnMove: party[1].moves[0]=\(st.party[1].moves.first ?? -1) (expect 999)")
        }
        // Move ON/OFF toggles (PMD-style): all OFF -> the weak typeless regular
        // attack; partial OFF narrows the AI pool to the enabled moves.
        do {
            let ba = GameData.moves[MoveMechanics.basicAttackId]!
            print("basic attack: id=\(ba.moveId) power=\(ba.effectivePower) type=\(ba.type ?? "typeless") acc=\(ba.accuracy) (expect power 20 < Tackle 40, typeless)")
            func playerMoveIds(_ mon: OwnedPokemon) -> Set<Int> {
                let p = Battler(mon: mon)!, w = Battler(wildDex: 16, level: 5)!
                let r = BattleEngine.run(player: p, wild: w)
                return Set(r.events.filter { $0.actorIsPlayer && $0.moveId > 0 }.map { $0.moveId })
            }
            var allOff = st.makeMon(species: GameData.species[25]!, level: 20)
            allOff.disabledMoves = allOff.moves
            let usedOff = playerMoveIds(allOff)
            print("toggles all-OFF: used=\(usedOff.sorted()) (expect [\(MoveMechanics.basicAttackId)] only)")
            var oneOn = st.makeMon(species: GameData.species[25]!, level: 20)
            let keep = oneOn.moves.first(where: { BattleEngine.isDamaging($0) }) ?? oneOn.moves[0]
            oneOn.disabledMoves = oneOn.moves.filter { $0 != keep }
            let usedOn = playerMoveIds(oneOn)
            print("toggles one-ON: kept=\(keep) used=\(usedOn.sorted()) onlyKept=\(usedOn.isSubset(of: [keep]))")
            let m0 = st.party[0].moves[0]
            st.setMoveEnabled(m0, false, at: 0)
            print("toggles persist: disabled=\(st.party[0].disabledMoves ?? []) enabled(\(m0))=\(st.party[0].isMoveEnabled(m0)) (expect false)")
            st.setMoveEnabled(m0, true, at: 0)
            print("toggles persist: back on -> disabledMoves=\(st.party[0].disabledMoves?.description ?? "nil") (expect nil)")
        }
        // Headless battle playback: force a contact encounter and tick the
        // controller through the whole fight, counting effect frames drawn.
        do {
            let hadRaising = AppSettings.shared.raisingMode
            AppSettings.shared.raisingMode = true
            let bc = BattleController()
            let p = CGPoint(x: 500, y: 500)
            bc.forceSpawn(at: CGPoint(x: 520, y: 500))    // inside battle range
            var effectFrames = 0, battleTicks = 0
            var logTicks = 0, maxLogLines = 0
            let trace = ProcessInfo.processInfo.environment["PMF_TRACE_BATTLE"] != nil
            var hadFX = false, hadFlashP = false, hadFlashW = false
            var levelTagTicks = 0
            var lastPose = BattlePose.stand
            for tick in 0..<20_000 {
                let scene = bc.update(playerGlobalPos: p)
                if bc.isBattling { battleTicks += 1 }
                if scene?.effectFrame != nil { effectFrames += 1 }
                if let lines = scene?.logLines, !lines.isEmpty {
                    logTicks += 1
                    maxLogLines = max(maxLogLines, lines.count)
                }
                if scene?.floatText?.hasPrefix("Level Up") == true { levelTagTicks += 1 }
                if trace, let sc = scene, bc.isBattling {
                    let fx = sc.effectFrame != nil
                    if fx != hadFX { print("  t\(tick) effect \(fx ? "ON" : "off")"); hadFX = fx }
                    if sc.flashPlayer != hadFlashP { if sc.flashPlayer { print("  t\(tick) FLASH player (impact)") }; hadFlashP = sc.flashPlayer }
                    if sc.flashWild != hadFlashW { if sc.flashWild { print("  t\(tick) FLASH wild (impact)") }; hadFlashW = sc.flashWild }
                    if sc.playerPose != lastPose { print("  t\(tick) playerPose -> \(sc.playerPose)"); lastPose = sc.playerPose }
                }
                if scene == nil && battleTicks > 0 { break }   // battle done + despawned
            }
            let m = RaisingState.shared.active!
            print("playback: battleTicks=\(battleTicks) effectFrames=\(effectFrames) levelTagTicks=\(levelTagTicks) → \(Characters.displayName(dex: m.dex)) Lv\(m.level) HP \(m.currentHP)/\(m.maxHP) status=\(m.status ?? "none")")
            print("playback log: shown \(logTicks) ticks, up to \(maxLogLines) lines (expect ticks>0, lines 1...4)")
            AppSettings.shared.raisingMode = hadRaising
        }
        // Wander legs are capped: a wild must never trek edge-to-edge (it kept
        // steamrolling over the follower and starting accidental battles). A leg
        // ends at a stationary tick (pause or target repick), so the max distance
        // between stationary points is the max single move.
        if let wm = WildMon(dex: 7) {
            wm.place(at: CGPoint(x: 1500, y: 1000))
            var anchor = wm.pos, last = wm.pos
            var maxLeg: CGFloat = 0
            for _ in 0..<120_000 {
                wm.wander(bounds: CGRect(x: 0, y: 0, width: 3000, height: 2000))
                if wm.pos == last {
                    maxLeg = max(maxLeg, hypot(wm.pos.x - anchor.x, wm.pos.y - anchor.y))
                    anchor = wm.pos
                }
                last = wm.pos
            }
            print("wander max leg: \(Int(maxLeg))px over 120k ticks (expect <= 280)")
        }
        // Sleep continuity: re-applying the SAME character (raisingChanged fires
        // on any party/bag change — the sleep-regen tick included) must not
        // reload the sheets and reset the idle clock, waking the sleeper.
        do {
            let cc = CharacterController()
            cc.setCharacter("025")
            let cursor = CGPoint(x: 100, y: 100)
            for _ in 0..<(Int(AppSettings.shared.sleepDelay) * 60 + 1200) {
                cc.update(mouseGlobal: cursor)
            }
            let asleepBefore = cc.isSleeping
            cc.setCharacter("025")            // what the regen notification does
            cc.update(mouseGlobal: cursor)
            print("sleep continuity: asleep=\(asleepBefore) stillAsleep=\(cc.isSleeping) (expect true true)")
        }
        // Level-up tag: prime the active mon 1 EXP short of its next level, then
        // battle until a win — the ending beat must float "Level Up!" overhead.
        do {
            let hadRaising = AppSettings.shared.raisingMode
            AppSettings.shared.raisingMode = true
            st.setActive(0)
            var tagTicks = 0, wins = 0, tries = 0
            for _ in 0..<8 where tagTicks == 0 {
                tries += 1
                st.healMon(at: 0)
                guard let mon = st.active, let sp = mon.species,
                      sp.expCurve.indices.contains(mon.level) else { break }
                let short = sp.expCurve[mon.level] - mon.exp - 1
                if short > 0 { _ = st.gainExp(short) }
                let before = st.active!.level
                let bc = BattleController()
                let p = CGPoint(x: 500, y: 500)
                bc.forceSpawn(at: CGPoint(x: 520, y: 500))
                var sawBattle = false
                for _ in 0..<20_000 {
                    let scene = bc.update(playerGlobalPos: p)
                    if bc.isBattling { sawBattle = true }
                    if scene?.floatText?.hasPrefix("Level Up") == true { tagTicks += 1 }
                    if sawBattle, !bc.isBattling {
                        if st.active!.isFainted { break }          // lost — retry
                        if scene == nil { break }                  // won + despawned
                    }
                }
                if st.active!.level > before { wins += 1 }
            }
            print("levelup tag: shown \(tagTicks) ticks over \(wins) level-up win(s) in \(tries) battles (expect ticks>0)")
            AppSettings.shared.raisingMode = hadRaising
        }
        // Deferred recall (mainline flee timing): recalling mid-battle must NOT
        // break off immediately — the turn in progress plays out first, then the
        // battle cancels and the follower is recalled (activeIndex -1).
        do {
            let hadRaising = AppSettings.shared.raisingMode
            AppSettings.shared.raisingMode = true
            st.healMon(at: 0)
            st.setActive(0)
            let bc = BattleController()
            let p = CGPoint(x: 500, y: 500)
            bc.forceSpawn(at: CGPoint(x: 520, y: 500))
            var playedOn = -1
            var pendingSeen = false
            for _ in 0..<20_000 {
                _ = bc.update(playerGlobalPos: p)
                if bc.isBattling, playedOn < 0 {
                    RaisingState.shared.recall()
                    pendingSeen = bc.recallPending
                    playedOn = 0
                    continue
                }
                if playedOn >= 0 {
                    if !bc.isBattling { break }
                    playedOn += 1
                }
            }
            print("deferred recall: pending=\(pendingSeen) playedOn=\(playedOn) activeAfter=\(RaisingState.shared.save.activeIndex) (expect true, >0, -1)")
            AppSettings.shared.raisingMode = hadRaising
        }
        // Flee keeps the damage: recall AFTER the gauge visibly dropped — the mon
        // must come back with the gauge HP, not its pre-battle full HP (the old
        // free-heal bug: cancelBattle restored only the wild's gauge state).
        do {
            let hadRaising = AppSettings.shared.raisingMode
            AppSettings.shared.raisingMode = true
            var checked = false
            for _ in 0..<8 where !checked {
                st.setActive(0)
                st.healMon(at: 0)
                let full = st.party[0].maxHP
                let bc = BattleController()
                bc.forceSpawn(at: CGPoint(x: 520, y: 500))
                var recalledNow = false, gauge = 1.0, seen = false
                for _ in 0..<20_000 {
                    let sc = bc.update(playerGlobalPos: CGPoint(x: 500, y: 500))
                    if bc.isBattling, let sc {
                        seen = true
                        gauge = sc.playerHP
                        if !recalledNow, sc.playerHP < 0.999 {
                            RaisingState.shared.recall()
                            recalledNow = true
                        }
                    }
                    if seen, !bc.isBattling { break }
                }
                if recalledNow, st.save.activeIndex == -1, gauge < 0.999 {
                    checked = true
                    print("flee damage: gauge=\(String(format: "%.2f", gauge)) kept=\(st.party[0].currentHP)/\(full) (expect kept<\(full))")
                }
            }
            if !checked { print("flee damage: no damaged-flee scenario arose in 8 battles") }
            AppSettings.shared.raisingMode = hadRaising
        }
        // Transform playback: a wild Ditto's shown sprite must swap to the
        // player's species at the transform beat (scene.wildSpriteDex) and
        // PERSIST after the battle while the wild stays out (it despawns on a
        // player win; only a capture resets it).
        do {
            let hadRaising = AppSettings.shared.raisingMode
            AppSettings.shared.raisingMode = true
            if st.active?.isFainted != false, let alive = st.party.firstIndex(where: { !$0.isFainted }) {
                st.setActive(alive)
            }
            if let playerDex = st.active?.dex {
                let bc = BattleController()
                bc.forceEncounter(dex: 132)   // Ditto: Transform is its only move
                var swappedTicks = 0, battleTicks = 0
                var recalled = false
                var after = "gone"
                for _ in 0..<20_000 {
                    let scene = bc.update(playerGlobalPos: .zero)
                    if bc.isBattling {
                        battleTicks += 1
                        if scene?.wildSpriteDex == playerDex { swappedTicks += 1 }
                        // Once the swap showed, flee — the surviving wild must
                        // KEEP the transformed look while it wanders.
                        if swappedTicks == 1, !recalled { recalled = true; RaisingState.shared.recall() }
                    } else if battleTicks > 0 {
                        if let sc = scene {
                            after = sc.wildSpriteDex == playerDex ? "persisted" : "reverted"
                        }
                        break
                    }
                }
                print("transform sprite: wild shown as player dex=\(playerDex) for \(swappedTicks) ticks, after flee=\(after) (expect >0, persisted)")
                if st.save.activeIndex == -1, let alive = st.party.firstIndex(where: { !$0.isFainted }) {
                    st.setActive(alive)   // undo the test recall
                }
            }
            AppSettings.shared.raisingMode = hadRaising
        }
        if let s7 = GameData.species[7] { _ = st.addToParty(st.makeMon(species: s7, level: 5)) }
        print("party=\(st.party.count) dailyHealNeededSameDay=\(st.dailyHealIfNeeded())")
        let savePath = (FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!)
            .appendingPathComponent("PokemonMouseFollower/raising.json")
        print("save exists=\(FileManager.default.fileExists(atPath: savePath.path)) at \(savePath.path)")
        st.reset()   // leave no test state behind
        exit(0)
    }
}
