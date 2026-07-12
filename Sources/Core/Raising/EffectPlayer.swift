// Raising mode — move-effect sprite playback (Phase 2d, design D22).
//
// gamedata/move_effects.json maps a move id to an effect file + animation
// (built by rom-extract/build_effects.py); gamedata/effects/effect_NNNN/ holds
// the frame PNGs and per-frame timing. EffectPlayer turns that into a tick-
// driven frame sequence the BattleController overlays on the hit target.
//
// Three source quirks are corrected here (they made effects look wrong raw):
//  - frames sit off-center in large cells -> crop to the animation's union
//    bbox and center that on the target;
//  - shared-file effects are single tiny PARTICLES the game multiplies at
//    runtime -> "particle" clips get composed into a small burst of copies;
//  - "approx_common" palettes ship the wrong hue (pink bubbles) -> "tint"
//    clips are re-hued with the move's type color, keeping luminosity.
//
// Platform-neutral (Phase 5a): all pixel work happens on RGBABuffer; the
// finished clip steps carry renderable PMFImages.

import Foundation

struct MoveEffectRef: Codable {
    struct Proj: Codable {
        let file: Int
        let anim: Int
        let loop: Bool
        let particle: Bool?
        let tint: Bool?
        let dirs: Bool?      // anim..anim+7 are the 8 facings of this projectile
    }
    let file: Int?          // nil for screen-type entries
    let anim: Int?
    let loop: Bool?
    let point: String?      // HEAD / CENTER / ... — anchor on the target
    let particle: Bool?     // single-particle art: compose a burst of copies
    let tint: Bool?         // approximate palette: re-hue with the type color
    let screen: Bool?       // full-screen effect: type-colored flash + quake
    let dirs: Bool?         // hit clip is an 8-facing set (Horn Attack & co)
    let proj: Proj?         // travel effect flown attacker -> target first
    let co: Proj?           // companion clip (ROM anim2 — e.g. Vine Whip's
                            // vine lash) played at the target before the hit
}

enum MoveEffects {
    static let map: [Int: MoveEffectRef] = load()

    private static func load() -> [Int: MoveEffectRef] {
        guard let u = Resources.url("move_effects", ext: "json", subdir: "gamedata"),
              let d = try? Data(contentsOf: u),
              let j = try? JSONDecoder().decode([String: MoveEffectRef].self, from: d)
        else { NSLog("[MoveEffects] load failed"); return [:] }
        var out: [Int: MoveEffectRef] = [:]
        for (k, v) in j { if let id = Int(k) { out[id] = v } }
        return out
    }
}

/// One playable, already-resolved effect: frames with per-frame ticks/offsets.
struct EffectClip {
    struct Step {
        let image: PMFImage
        let ticks: Int          // duration in 1/60s ticks (EoS native rate)
        let dx: Int, dy: Int    // pixel offset (source coords, y-down)
    }
    let steps: [Step]
    let loop: Bool
    let headAnchored: Bool
    var riseOffset: CGFloat = 0   // game-px lift so strike columns land ON the target
    var totalTicks: Int { steps.reduce(0) { $0 + $1.ticks } }
}

enum EffectPlayer {
    // Buffer-typed step used through the correction pipeline; converted to
    // the renderable EffectClip.Step at the end of build().
    private struct RawStep {
        let image: RGBABuffer
        let ticks: Int
        let dx: Int, dy: Int
    }

    // MARK: JSON models (effects/effect_NNNN/animations.json)
    private struct AnimFrame: Codable {
        let frame: Int
        let duration: Int
        let offset: [Int]
    }
    private struct Anim: Codable {
        let animId: Int
        let frames: [AnimFrame]
        enum CodingKeys: String, CodingKey { case animId = "anim_id", frames }
    }
    private struct FileMeta: Codable {
        let animations: [Anim]
    }

    private static var metaCache: [Int: FileMeta] = [:]
    private static var clipCache: [Int: EffectClip?] = [:]   // key: moveId*8 + facing
    private static var projCache: [Int: EffectClip?] = [:]   // key: moveId*8 + facing
    private static var coCache: [Int: EffectClip?] = [:]     // key: moveId*8 + facing

    /// Whether `moveId` is a full-screen effect (Psychic & co) — the overlay
    /// renders a type-colored screen flash + quake instead of a sprite.
    static func isScreen(_ moveId: Int) -> Bool {
        MoveEffects.map[moveId]?.screen == true
    }

    /// Status-condition visuals (D19): the ROM's status-effect table is
    /// undecoded, so each condition borrows the hit clip of its signature
    /// move. Keys match the engine's residual names ("burn"/"poison") and
    /// skip reasons ("paralyzed"/"frozen"/"infatuated").
    private static let statusMoveIds: [String: Int] = {
        func id(_ name: String) -> Int? {
            GameData.moves.first { $0.value.names["e"] == name }?.key
        }
        var m: [String: Int] = [:]
        m["burn"] = id("Will-O-Wisp") ?? id("Ember")
        m["poison"] = id("Poison Gas") ?? id("Toxic")
        // Spark's crackle sits ON the mon (no falling bolt — a paralyzed mon
        // shouldn't look like it's being struck by Thunderbolt).
        m["paralyzed"] = id("Spark") ?? id("Thunder Wave")
        m["frozen"] = id("Powder Snow") ?? id("Ice Beam")
        m["infatuated"] = id("Attract")
        m["asleep"] = id("Sing") ?? id("Hypnosis")
        m["confused"] = id("Supersonic") ?? id("Confuse Ray")
        // Per-round drain beats (residual reasons) each borrow a fitting
        // move clip — without one the victim's HP just melts with nothing
        // on screen. The planting/casting clip belongs to the move itself.
        // ("leech seed" uses the synthetic drainClip instead — see below.)
        m["curse"] = id("Curse")                             // ghost-nail flicker
        m["nightmare"] = id("Nightmare")
        m["perish song"] = id("Perish Song") ?? id("Sing")
        m["trap"] = id("Wrap") ?? id("Bind")                 // squeeze coils
        return m
    }()

    static func statusClip(_ key: String) -> EffectClip? {
        if key == "confused" { return confusionClip }   // dedicated orbit, below
        return statusMoveIds[key].flatMap { clip(forMove: $0) }
    }

    /// Synthetic confusion orbit: two dizzy sparks circling over the head in
    /// counter-phase — the mainline "birds circling" read. The ROM keeps this
    /// visual engine-side; its only extractable trace is the lone orbiting
    /// particle (effect_0000 anim 35), so we rebuild the full orbit here.
    static let confusionClip: EffectClip? = makeConfusionClip()

    private static func makeConfusionClip() -> EffectClip? {
        let dot = 6, radius = 14, frames = 16
        let canvas = 2 * radius + dot + 4
        let spark = glowDot(width: dot, height: dot, color: RGBA(r: 1.0, g: 0.9, b: 0.35))
        var raw: [RawStep] = []
        for i in 0..<frames {
            let t = Double(i) / Double(frames) * 2 * .pi
            var out = RGBABuffer(width: canvas, height: canvas,
                                 pixels: [UInt8](repeating: 0, count: canvas * canvas * 4))
            let c = Double(canvas) / 2
            for phase in [0.0, Double.pi] {          // two sparks, opposite sides
                let x = c + cos(t + phase) * Double(radius) - Double(dot) / 2
                // Flatten the orbit so it reads as a halo seen at an angle.
                let y = c + sin(t + phase) * Double(radius) * 0.45 - Double(dot) / 2
                blit(spark, onto: &out, x: Int(x), y: Int(y))
            }
            raw.append(RawStep(image: out, ticks: 2, dx: 0, dy: 0))
        }
        let rendered = raw.compactMap { s -> EffectClip.Step? in
            guard let img = PlatformImageIO.makeImage(s.image) else { return nil }
            return EffectClip.Step(image: img, ticks: s.ticks, dx: s.dx, dy: s.dy)
        }
        guard !rendered.isEmpty else { return nil }
        return EffectClip(steps: rendered, loop: true, headAnchored: true)
    }

    /// The on-target hit clip for `moveId` (fully corrected: cropped/centered,
    /// tinted, particle-composed), or nil when the move has no sprite effect.
    /// Directional sets (Horn Attack's thrust & co) pick the rotation for
    /// `octant` — their baked offsets start the art on the ATTACKER's side of
    /// the anchor and drive it into the target, so the right facing also puts
    /// the strike between the two mons.
    static func clip(forMove moveId: Int, octant: Int = 6) -> EffectClip? {
        guard let ref = MoveEffects.map[moveId], let file = ref.file, let anim = ref.anim else {
            clipCache[moveId * 8] = nil
            return nil
        }
        let idx = ref.dirs == true ? (2 + (octant & 7)) % 8 : 0
        let key = moveId * 8 + idx
        if let cached = clipCache[key] { return cached }
        let built = build(moveId: moveId, file: file, anim: anim + idx, loop: ref.loop ?? false,
                          particle: ref.particle == true, tint: ref.tint == true,
                          headAnchored: ref.point == "HEAD")
        clipCache[key] = built
        return built
    }

    /// Whether the move has a projectile phase at all.
    static func hasProjectile(_ moveId: Int) -> Bool {
        MoveEffects.map[moveId]?.proj != nil
    }

    /// Selfdestruct/Explosion: the user detonates. The ROM's sprite for these
    /// is just the tiny shared particle (the real game's drama is engine-side
    /// screen work), so the playback compensates: a bigger blast-colored
    /// burst, anchored on the USER, plus a screen flash + quake — and no
    /// lunge/shoot delivery.
    static func isExplosionMove(_ moveId: Int) -> Bool {
        if case .explosion = MoveMechanics.mechanic(for: moveId) { return true }
        return false
    }

    /// Synthetic drain-tick clip (leech seed's per-round HP steal): small
    /// ROUND green sparks, loosely scattered at the start and CONVERGING as
    /// the clip plays. The playback flies it victim -> seeder, so the gather
    /// reads as HP being pulled in — the opposite arc of composeBurst, whose
    /// borrowed Absorb ellipses read as an outward hit (user feedback).
    static let drainClip: EffectClip? = makeDrainClip()

    private static func makeDrainClip() -> EffectClip? {
        let color = TypeStyle.rgba("Grass")
        let dot = 5, spread = 18, copies = 7, frames = 8
        let canvas = 2 * spread + dot + 4
        let spark = glowDot(width: dot, height: dot, color: color)
        var raw: [RawStep] = []
        for i in 0..<frames {
            let progress = Double(i) / Double(frames - 1)
            var out = RGBABuffer(width: canvas, height: canvas,
                                 pixels: [UInt8](repeating: 0, count: canvas * canvas * 4))
            let c = Double(canvas) / 2
            for j in 0..<copies {
                let jitter = 0.65 + 0.35 * Double((j * 37) % 10) / 9.0
                let r = (2 + Double(spread - 2) * (1 - progress)) * jitter
                let angle = Double(j) * 2.399963        // golden angle
                let x = c + cos(angle) * r - Double(dot) / 2
                let y = c + sin(angle) * r - Double(dot) / 2
                blit(spark, onto: &out, x: Int(x), y: Int(y))
            }
            raw.append(RawStep(image: out, ticks: 3, dx: 0, dy: 0))
        }
        let rendered = raw.compactMap { s -> EffectClip.Step? in
            guard let img = PlatformImageIO.makeImage(s.image) else { return nil }
            return EffectClip.Step(image: img, ticks: s.ticks, dx: s.dx, dy: s.dy)
        }
        guard !rendered.isEmpty else { return nil }
        return EffectClip(steps: rendered, loop: false, headAnchored: false)
    }

    /// Stat-change aura (mainline-style): particles in the STAT's color
    /// sweep upward for a raise, sink downward for a drop — the ROM keeps
    /// this visual engine-side (nothing extractable), same as the screen
    /// flash and the confusion orbit.
    private static var statAuraCache: [String: EffectClip?] = [:]

    static func statAura(_ stat: BattleStat, rising: Bool) -> EffectClip? {
        let key = "\(stat.rawValue)+\(rising)"
        if let cached = statAuraCache[key] { return cached }
        let color: RGBA
        switch stat {
        case .atk: color = RGBA(r: 1.00, g: 0.36, b: 0.30)   // red
        case .def: color = RGBA(r: 0.38, g: 0.58, b: 1.00)   // blue
        case .spa: color = RGBA(r: 0.85, g: 0.45, b: 1.00)   // purple
        case .spd: color = RGBA(r: 0.35, g: 0.90, b: 0.70)   // teal
        case .spe: color = RGBA(r: 1.00, g: 0.85, b: 0.30)   // yellow
        case .acc: color = RGBA(r: 1.00, g: 0.62, b: 0.25)   // orange
        case .eva: color = RGBA(r: 0.88, g: 0.90, b: 0.95)   // silver
        }
        let built = makeStatAura(color: color, rising: rising)
        statAuraCache[key] = built
        return built
    }

    private static func makeStatAura(color: RGBA, rising: Bool) -> EffectClip? {
        let w = 40, h = 46, pw = 7, ph = 5, frames = 14, count = 6
        // Arrowheads point the way they travel: ^ rising, v sinking.
        let spark = chevron(width: pw, height: ph, color: color, up: rising)
        var raw: [RawStep] = []
        for f in 0..<frames {
            var out = RGBABuffer(width: w, height: h,
                                 pixels: [UInt8](repeating: 0, count: w * h * 4))
            let progress = Double(f) / Double(frames - 1)
            for j in 0..<count {
                // Columns spread by golden-angle hash; each particle staggers
                // its start so the aura streams instead of pulsing.
                let x = Double((j * 29) % (w - pw))
                var t = progress + Double((j * 37) % 10) / 10.0
                t -= t.rounded(.down)                       // wrap 0..1
                let yTravel = t * Double(h - ph)
                let y = rising ? Double(h - ph) - yTravel : yTravel
                blit(spark, onto: &out, x: Int(x), y: Int(y))
            }
            raw.append(RawStep(image: out, ticks: 2, dx: 0, dy: 0))
        }
        let rendered = raw.compactMap { s -> EffectClip.Step? in
            guard let img = PlatformImageIO.makeImage(s.image) else { return nil }
            return EffectClip.Step(image: img, ticks: s.ticks, dx: s.dx, dy: s.dy)
        }
        guard !rendered.isEmpty else { return nil }
        return EffectClip(steps: rendered, loop: false, headAnchored: false)
    }

    /// The companion clip (ROM anim2) played at the target just before the
    /// hit clip — the part the hit-slot priority used to drop entirely
    /// (Vine Whip's vine, Cut's slash arc, String Shot's threads, ...).
    /// Directional sets (Absorb's gather & co) pick the rotation for
    /// `octant`, same convention as projectile().
    static func coClip(forMove moveId: Int, octant: Int = 6) -> EffectClip? {
        guard let c = MoveEffects.map[moveId]?.co else { return nil }
        let idx = c.dirs == true ? (2 + (octant & 7)) % 8 : 0
        let key = moveId * 8 + idx
        if let cached = coCache[key] { return cached }
        let built = build(moveId: moveId, file: c.file, anim: c.anim + idx, loop: c.loop,
                          particle: c.particle == true, tint: c.tint == true,
                          headAnchored: false)
        coCache[key] = built
        return built
    }

    /// The projectile/travel clip for `moveId`, facing its travel direction.
    /// `octant` is the travel angle octant (0=E, 1=NE, ... CCW); directional
    /// sets (anim..anim+7) pick the matching rotation, single-sequence
    /// projectiles ignore it. The ROM's set order is CLOCKWISE from south —
    /// S,SE,E,NE,N,NW,W,SW, same as the monster sheet rows (proven by
    /// effect_0023's per-facing displacement offsets; the previous CCW
    /// assumption mirrored E/W and the diagonals).
    static func projectile(forMove moveId: Int, octant: Int = 6) -> EffectClip? {
        guard let p = MoveEffects.map[moveId]?.proj else { return nil }
        let idx = p.dirs == true ? (2 + (octant & 7)) % 8 : 0
        let key = moveId * 8 + idx
        if let cached = projCache[key] { return cached }
        let built = build(moveId: moveId, file: p.file, anim: p.anim + idx, loop: p.loop,
                          particle: p.particle == true, tint: p.tint == true, headAnchored: false)
        projCache[key] = built
        return built
    }

    private static func build(moveId: Int, file: Int, anim: Int, loop: Bool,
                              particle: Bool, tint doTint: Bool, headAnchored: Bool) -> EffectClip? {
        guard var steps = rawSteps(file: file, anim: anim) else { return nil }
        steps = cropAndCenter(steps)
        steps = capSize(steps)   // screen-filling art (Surf & co) fits battle scale
        // Source quirk: some drawn clips alternate real frames with BLANK
        // 1-tick spacers (Vine Whip: whip/blank/whip/blank — 6 ticks total),
        // a strobe that reads as no effect at all at desktop scale. Drop the
        // blanks and stretch blink-length clips to a readable length.
        // (Drawn art only: shared-file particle frames are legitimately tiny,
        // and their burst timing is composed later.)
        if !loop, !particle {
            let real = steps.filter { $0.image.width > 2 || $0.image.height > 2 }
            if !real.isEmpty, real.count < steps.count { steps = real }
            let total = steps.reduce(0) { $0 + $1.ticks }
            if total > 0, total < 12 {
                let k = (12 + total - 1) / total
                steps = steps.map { RawStep(image: $0.image, ticks: $0.ticks * k,
                                            dx: $0.dx, dy: $0.dy) }
            }
        }
        let type = GameData.moves[moveId]?.type
        if particle {
            // Shared-file particle frames are unrecoverable palette garbage
            // (solid single-color squares — the shape lived in runtime palette
            // gradients). Keep only each frame's SIZE and timing: draw a round
            // glow dot in its place (white flash for Normal/untyped, else the
            // type color), THEN compose the dots into the burst.
            let explosion = isExplosionMove(moveId)
            let neutral = type == nil || type == "Normal" || type == "None"
            let color = explosion ? RGBA(r: 1.0, g: 0.62, b: 0.25)   // blast orange
                      : neutral ? RGBA(white: 0.96) : TypeStyle.rgba(type)
            steps = steps.map {
                // The ROM's raw particle SIZE reads as a fat blob at desktop
                // scale (user report: Minimize spark, Water Gun hit) — keep
                // each frame's timing (and the burst spread below) but draw
                // the dot at 40%. Explosions keep full-size dots: the blast
                // should stay chunky.
                let dw = explosion ? $0.image.width : max(3, $0.image.width * 2 / 5)
                let dh = explosion ? $0.image.height : max(3, $0.image.height * 2 / 5)
                return RawStep(image: glowDot(width: dw, height: dh, color: color),
                               ticks: $0.ticks, dx: $0.dx, dy: $0.dy)
            }
            if explosion {
                // Denser, wider burst that engulfs the user instead of a spark.
                steps = composeBurst(steps, copies: 13, spread: 48)
                steps = capSize(steps, maxDim: 88)
            } else {
                steps = composeBurst(steps)
                steps = capSize(steps, maxDim: 46)   // a hit spark stays smaller than the mon
            }
        } else if doTint {
            // Drawn art with an approximate palette: re-hue, keep shading.
            let color = TypeStyle.rgba(type)
            steps = steps.map {
                RawStep(image: tint($0.image, with: color),
                        ticks: $0.ticks, dx: $0.dx, dy: $0.dy)
            }
        }
        // Strike columns (Thunderbolt & co, much taller than wide): lift the
        // clip so its bottom — the impact end — lands ON the target instead of
        // the column's middle skewering it. (The ROM's true placement lives in
        // engine code, not the extractable data; this is the readable heuristic.)
        var rise: CGFloat = 0
        let maxW = steps.map(\.image.width).max() ?? 0
        let maxH = steps.map(\.image.height).max() ?? 0
        if !particle, CGFloat(maxH) > 1.7 * CGFloat(maxW), maxH > 60 {
            rise = CGFloat(maxH) / 2 - 12
        }
        let rendered = steps.compactMap { s -> EffectClip.Step? in
            guard let img = PlatformImageIO.makeImage(s.image) else { return nil }
            return EffectClip.Step(image: img, ticks: s.ticks, dx: s.dx, dy: s.dy)
        }
        guard !rendered.isEmpty else { return nil }
        return EffectClip(steps: rendered, loop: loop, headAnchored: headAnchored, riseOffset: rise)
    }

    // MARK: raw frame loading

    private static func rawSteps(file: Int, anim: Int) -> [RawStep]? {
        let dir = String(format: "gamedata/effects/effect_%04d", file)
        if metaCache[file] == nil {
            guard let u = Resources.url("animations", ext: "json", subdir: dir),
                  let d = try? Data(contentsOf: u),
                  let m = try? JSONDecoder().decode(FileMeta.self, from: d) else { return nil }
            metaCache[file] = m
        }
        guard let a = metaCache[file]?.animations.first(where: { $0.animId == anim }),
              !a.frames.isEmpty else { return nil }
        var steps: [RawStep] = []
        var images: [Int: RGBABuffer] = [:]
        for f in a.frames {
            if images[f.frame] == nil {
                // The exporter skips empty frames — they're intentional blank
                // "blink" moments, so keep the step (and its timing) as a
                // transparent frame instead of dropping it.
                images[f.frame] = Sprite.loadBuffer(String(format: "F-%02d", f.frame),
                                                    subdir: "\(dir)/frames") ?? blankFrame
            }
            guard let img = images[f.frame] else { continue }
            steps.append(RawStep(
                image: img, ticks: max(1, f.duration),
                dx: signed16(f.offset.first ?? 0), dy: signed16(f.offset.count > 1 ? f.offset[1] : 0)))
        }
        return steps.isEmpty ? nil : steps
    }

    /// A 1x1 transparent frame standing in for unexported blank frames.
    private static let blankFrame = RGBABuffer(width: 1, height: 1, pixels: [0, 0, 0, 0])

    /// Offsets are stored as raw unsigned 16-bit values; fold back to signed.
    private static func signed16(_ v: Int) -> Int { v >= 32768 ? v - 65536 : v }

    // MARK: corrections

    /// Frames sit off-center inside large cells (e.g. at (48,159) of 96x208).
    /// Crop every frame to the animation's union bbox so the drawn content —
    /// not the cell — is what gets centered on the target.
    private static func cropAndCenter(_ steps: [RawStep]) -> [RawStep] {
        var union: CGRect?
        for s in steps {
            if let b = Sprite.opaqueBBox(s.image) { union = union.map { $0.union(b) } ?? b }
        }
        guard let box = union else { return steps }
        return steps.map {
            RawStep(image: $0.image.cropped(x: Int(box.minX), y: Int(box.minY),
                                            w: Int(box.width), h: Int(box.height)) ?? $0.image,
                    ticks: $0.ticks, dx: $0.dx, dy: $0.dy)
        }
    }

    /// Cap a clip's drawn size so screen-filling source art (Surf, Rock Slide —
    /// up to ~290px, meant to cover the game's whole 256x192 screen) doesn't
    /// dwarf the battle. Downscales every frame (and its offsets) uniformly.
    private static func capSize(_ steps: [RawStep], maxDim: Int = 140) -> [RawStep] {
        let biggest = steps.map { max($0.image.width, $0.image.height) }.max() ?? 0
        guard biggest > maxDim else { return steps }
        let f = Double(maxDim) / Double(biggest)
        return steps.map { s in
            RawStep(image: scaled(s.image, factor: f), ticks: s.ticks,
                    dx: Int(Double(s.dx) * f), dy: Int(Double(s.dy) * f))
        }
    }

    /// A shared-file effect is one tiny particle; the game draws many. Compose
    /// each step into a burst: a center copy plus a ring of copies spreading
    /// outward (golden-angle spacing) as the animation progresses. The canvas
    /// is sized to the full spread so edge particles never get sliced off.
    private static func composeBurst(_ steps: [RawStep], copies: Int = 7,
                                     spread: Int = 30) -> [RawStep] {
        let maxPart = steps.map { max($0.image.width, $0.image.height) }.max() ?? 16
        let canvas = 2 * spread + maxPart + 8   // ring radius peaks at `spread` (capped after)
        let n = max(1, steps.count - 1)
        return steps.enumerated().map { (i, s) in
            let progress = Double(i) / Double(n)
            var out = RGBABuffer(width: canvas, height: canvas,
                                 pixels: [UInt8](repeating: 0, count: canvas * canvas * 4))
            let w = Double(s.image.width), h = Double(s.image.height)
            let c = Double(canvas) / 2
            for j in 0..<copies {
                let jitter = 0.65 + 0.35 * Double((j * 37) % 10) / 9.0
                let r = (4 + Double(spread - 4) * progress) * jitter
                let angle = Double(j) * 2.399963        // golden angle
                let x = c + cos(angle) * r - w / 2
                let y = c + sin(angle) * r - h / 2
                blit(s.image, onto: &out, x: Int(x), y: Int(y))
            }
            return RawStep(image: out, ticks: s.ticks, dx: s.dx, dy: s.dy)
        }
    }

    /// A chevron (arrowhead) particle for the stat auras: ^ points up for a
    /// raise, v down for a drop — the mainline gen-4/5 read. Two mirrored
    /// diagonal strokes with a lighter core row.
    private static func chevron(width: Int, height: Int, color: RGBA, up: Bool) -> RGBABuffer {
        let w = max(5, width | 1)          // odd width keeps the tip centered
        let h = max(3, height)
        var out = RGBABuffer(width: w, height: h,
                             pixels: [UInt8](repeating: 0, count: w * h * 4))
        let mid = w / 2
        let core = color.blended(with: RGBA(white: 1), fraction: 0.45)
        func put(_ x: Int, _ y: Int, _ c: RGBA) {
            guard x >= 0, x < w, y >= 0, y < h else { return }
            let i = (y * w + x) * 4
            out.pixels[i] = UInt8(min(255, c.r * 255 * c.a))
            out.pixels[i + 1] = UInt8(min(255, c.g * 255 * c.a))
            out.pixels[i + 2] = UInt8(min(255, c.b * 255 * c.a))
            out.pixels[i + 3] = UInt8(min(255, c.a * 255))
        }
        // Slope 1 strokes, 2px thick, from the tip outward.
        for d in 0...mid {
            let y = up ? d : h - 1 - d
            guard y >= 0, y < h else { continue }
            for x in [mid - d, mid + d] {
                put(x, y, d == 0 ? core : color.withAlpha(0.92))
                let y2 = up ? y + 1 : y - 1
                put(x, y2, color.withAlpha(0.85))
            }
        }
        return out
    }

    /// A crisp round particle: an ellipse of `color` with a lighter core,
    /// replacing a broken square source frame of the same dimensions.
    private static func glowDot(width: Int, height: Int, color: RGBA) -> RGBABuffer {
        let w = max(2, width), h = max(2, height)
        var out = RGBABuffer(width: w, height: h,
                             pixels: [UInt8](repeating: 0, count: w * h * 4))
        fillEllipse(&out, cx: Double(w) / 2, cy: Double(h) / 2,
                    rx: Double(w) / 2, ry: Double(h) / 2, color: color.withAlpha(0.9))
        let core = color.blended(with: RGBA(white: 1), fraction: 0.55)
        fillEllipse(&out, cx: Double(w) / 2, cy: Double(h) / 2,
                    rx: Double(w) * 0.22, ry: Double(h) * 0.22, color: core)
        return out
    }

    /// Re-hue an approximate-palette frame with the move's type color: keep
    /// the sprite's luminosity/shape, replace hue+saturation — the PDF "color"
    /// blend mode, per pixel on the unpremultiplied values.
    private static func tint(_ img: RGBABuffer, with color: RGBA) -> RGBABuffer {
        var out = img
        let n = img.width * img.height
        out.pixels.withUnsafeMutableBytes { raw in
            let p = raw.bindMemory(to: UInt8.self).baseAddress!
            for i in 0..<n {
                let a = Double(p[i * 4 + 3])
                guard a > 0 else { continue }
                // Unpremultiply, take the backdrop's luminosity.
                let br = Double(p[i * 4]) / a
                let bg = Double(p[i * 4 + 1]) / a
                let bb = Double(p[i * 4 + 2]) / a
                let lum = 0.3 * br + 0.59 * bg + 0.11 * bb
                var (r, g, b) = setLum(color.r, color.g, color.b, lum)
                r = min(1, max(0, r)); g = min(1, max(0, g)); b = min(1, max(0, b))
                p[i * 4]     = UInt8(r * a)
                p[i * 4 + 1] = UInt8(g * a)
                p[i * 4 + 2] = UInt8(b * a)
            }
        }
        return out
    }

    /// PDF non-separable blend helper: shift (r,g,b) to luminosity `l`.
    private static func setLum(_ r0: Double, _ g0: Double, _ b0: Double,
                               _ l: Double) -> (Double, Double, Double) {
        let d = l - (0.3 * r0 + 0.59 * g0 + 0.11 * b0)
        var r = r0 + d, g = g0 + d, b = b0 + d
        let lum = l
        let mn = min(r, g, b), mx = max(r, g, b)
        if mn < 0 {
            let k = lum / max(0.0001, lum - mn)
            r = lum + (r - lum) * k; g = lum + (g - lum) * k; b = lum + (b - lum) * k
        }
        if mx > 1 {
            let k = (1 - lum) / max(0.0001, mx - lum)
            r = lum + (r - lum) * k; g = lum + (g - lum) * k; b = lum + (b - lum) * k
        }
        return (r, g, b)
    }

    // MARK: buffer primitives

    /// Nearest-neighbor uniform scale (keeps the pixel-art look).
    private static func scaled(_ img: RGBABuffer, factor f: Double) -> RGBABuffer {
        let w = max(1, Int(Double(img.width) * f))
        let h = max(1, Int(Double(img.height) * f))
        var pixels = [UInt8](repeating: 0, count: w * h * 4)
        let src = img.pixels
        for y in 0..<h {
            let sy = min(img.height - 1, Int(Double(y) / f))
            for x in 0..<w {
                let sx = min(img.width - 1, Int(Double(x) / f))
                let s = (sy * img.width + sx) * 4, d = (y * w + x) * 4
                pixels[d] = src[s]; pixels[d + 1] = src[s + 1]
                pixels[d + 2] = src[s + 2]; pixels[d + 3] = src[s + 3]
            }
        }
        return RGBABuffer(width: w, height: h, pixels: pixels)
    }

    /// Premultiplied src-over blit at (x, y), clipped to the canvas.
    private static func blit(_ img: RGBABuffer, onto out: inout RGBABuffer, x: Int, y: Int) {
        for sy in 0..<img.height {
            let dy = y + sy
            guard dy >= 0, dy < out.height else { continue }
            for sx in 0..<img.width {
                let dx = x + sx
                guard dx >= 0, dx < out.width else { continue }
                let s = (sy * img.width + sx) * 4
                let a = UInt32(img.pixels[s + 3])
                guard a > 0 else { continue }
                let d = (dy * out.width + dx) * 4
                if a == 255 {
                    out.pixels[d] = img.pixels[s]
                    out.pixels[d + 1] = img.pixels[s + 1]
                    out.pixels[d + 2] = img.pixels[s + 2]
                    out.pixels[d + 3] = 255
                } else {
                    let ia = 255 - a
                    for c in 0..<3 {
                        out.pixels[d + c] = UInt8((UInt32(img.pixels[s + c]) * 255
                                                   + UInt32(out.pixels[d + c]) * ia) / 255)
                    }
                    out.pixels[d + 3] = UInt8(min(255, a + UInt32(out.pixels[d + 3]) * ia / 255))
                }
            }
        }
    }

    /// Solid premultiplied ellipse fill (src-over) with a soft 1px edge.
    private static func fillEllipse(_ out: inout RGBABuffer, cx: Double, cy: Double,
                                    rx: Double, ry: Double, color: RGBA) {
        let y0 = max(0, Int(cy - ry)), y1 = min(out.height - 1, Int(cy + ry) + 1)
        let x0 = max(0, Int(cx - rx)), x1 = min(out.width - 1, Int(cx + rx) + 1)
        guard y0 <= y1, x0 <= x1, rx > 0, ry > 0 else { return }
        for y in y0...y1 {
            for x in x0...x1 {
                let nx = (Double(x) + 0.5 - cx) / rx
                let ny = (Double(y) + 0.5 - cy) / ry
                let d = (nx * nx + ny * ny).squareRoot()
                guard d < 1 else { continue }
                let edge = min(1.0, (1 - d) * max(rx, ry))   // soft rim
                let a = color.a * edge
                let s = ((y * out.width) + x) * 4
                let sr = UInt32(min(255, color.r * a * 255))
                let sg = UInt32(min(255, color.g * a * 255))
                let sb = UInt32(min(255, color.b * a * 255))
                let sa = UInt32(min(255, a * 255))
                let ia = 255 - sa
                out.pixels[s]     = UInt8(min(255, sr + UInt32(out.pixels[s]) * ia / 255))
                out.pixels[s + 1] = UInt8(min(255, sg + UInt32(out.pixels[s + 1]) * ia / 255))
                out.pixels[s + 2] = UInt8(min(255, sb + UInt32(out.pixels[s + 2]) * ia / 255))
                out.pixels[s + 3] = UInt8(min(255, sa + UInt32(out.pixels[s + 3]) * ia / 255))
            }
        }
    }
}

/// Tick-driven playback state for one running effect. Stationary (hit at the
/// target) when `from == to`; otherwise it travels from -> to over its
/// lifetime (projectile phase), cycling its frames while in flight.
struct RunningEffect {
    let clip: EffectClip
    let from: CGPoint
    let to: CGPoint
    var tick = 0
    let maxTicks: Int            // hard stop (event beat), also caps loops
    let delay: Int               // ticks to wait before the clip starts drawing

    init(clip: EffectClip, anchor: CGPoint, maxTicks: Int, delay: Int = 0) {
        self.init(clip: clip, from: anchor, to: anchor, maxTicks: maxTicks, delay: delay)
    }

    init(clip: EffectClip, from: CGPoint, to: CGPoint, maxTicks: Int, delay: Int = 0) {
        self.clip = clip
        self.from = from
        self.to = to
        self.maxTicks = max(1, maxTicks)
        self.delay = max(0, delay)
    }

    private var travels: Bool { from != to }

    var isDone: Bool {
        tick >= maxTicks || (!clip.loop && !travels && tick - delay >= clip.totalTicks)
    }

    /// Current frame + its global position, nil while delayed or finished.
    func current(scale: CGFloat) -> (PMFImage, CGPoint)? {
        guard !isDone, tick >= delay else { return nil }
        let local = tick - delay
        // Loops cycle; a non-loop clip in flight gets its whole animation
        // compressed into the travel time (a grow-then-drift sequence
        // completes mid-air instead of freezing on its first frames).
        var t = clip.loop ? local % max(1, clip.totalTicks)
              : travels ? min(clip.totalTicks - 1, local * clip.totalTicks / max(1, maxTicks - delay))
              : local
        for s in clip.steps {
            if t < s.ticks {
                // Flight progress excludes the delay — with it included, a
                // delayed traveling clip would pop in partway along its path.
                let f = travels ? CGFloat(tick - delay) / CGFloat(max(1, maxTicks - delay)) : 0
                let base = CGPoint(x: from.x + (to.x - from.x) * f,
                                   y: from.y + (to.y - from.y) * f)
                let up: CGFloat = (clip.headAnchored ? 10 : 0)
                    + (travels ? 0 : clip.riseOffset)   // strike columns land, not skewer
                let pos = CGPoint(x: base.x + CGFloat(s.dx) * scale,
                                  y: base.y - CGFloat(s.dy) * scale + up * scale)
                return (s.image, pos)
            }
            t -= s.ticks
        }
        return nil
    }

    mutating func advance() { tick += 1 }
}
