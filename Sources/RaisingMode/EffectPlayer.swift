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

import AppKit

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
    let proj: Proj?         // travel effect flown attacker -> target first
}

enum MoveEffects {
    static let map: [Int: MoveEffectRef] = load()

    private static func load() -> [Int: MoveEffectRef] {
        guard let u = Bundle.main.url(forResource: "move_effects", withExtension: "json",
                                      subdirectory: "gamedata"),
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
        let image: CGImage
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
    private static var clipCache: [Int: EffectClip?] = [:]   // hit clip per move id
    private static var projCache: [Int: EffectClip?] = [:]   // key: moveId*8 + facing

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
        return m
    }()

    static func statusClip(_ key: String) -> EffectClip? {
        statusMoveIds[key].flatMap { clip(forMove: $0) }
    }

    /// The on-target hit clip for `moveId` (fully corrected: cropped/centered,
    /// tinted, particle-composed), or nil when the move has no sprite effect.
    static func clip(forMove moveId: Int) -> EffectClip? {
        if let cached = clipCache[moveId] { return cached }
        var built: EffectClip?
        if let ref = MoveEffects.map[moveId], let file = ref.file, let anim = ref.anim {
            built = build(moveId: moveId, file: file, anim: anim, loop: ref.loop ?? false,
                          particle: ref.particle == true, tint: ref.tint == true,
                          headAnchored: ref.point == "HEAD")
        }
        clipCache[moveId] = built
        return built
    }

    /// Whether the move has a projectile phase at all.
    static func hasProjectile(_ moveId: Int) -> Bool {
        MoveEffects.map[moveId]?.proj != nil
    }

    /// The projectile/travel clip for `moveId`, facing its travel direction.
    /// `octant` is the travel angle octant (0=E, 1=NE, ... CCW); directional
    /// sets (anim..anim+7, ROM order S,SW,W,NW,N,NE,E,SE) pick the matching
    /// rotation, single-sequence projectiles ignore it.
    static func projectile(forMove moveId: Int, octant: Int = 6) -> EffectClip? {
        guard let p = MoveEffects.map[moveId]?.proj else { return nil }
        let idx = p.dirs == true ? (6 - (octant & 7) + 8) % 8 : 0
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
        let type = GameData.moves[moveId]?.type
        if particle {
            // Shared-file particle frames are unrecoverable palette garbage
            // (solid single-color squares — the shape lived in runtime palette
            // gradients). Keep only each frame's SIZE and timing: draw a round
            // glow dot in its place (white flash for Normal/untyped, else the
            // type color), THEN compose the dots into the burst.
            let neutral = type == nil || type == "Normal" || type == "None"
            let color = neutral ? NSColor(white: 0.96, alpha: 1) : TypeStyle.color(type)
            steps = steps.map {
                EffectClip.Step(image: glowDot(width: $0.image.width,
                                               height: $0.image.height, color: color) ?? $0.image,
                                ticks: $0.ticks, dx: $0.dx, dy: $0.dy)
            }
            steps = composeBurst(steps)
            steps = capSize(steps, maxDim: 46)   // a hit spark stays smaller than the mon
        } else if doTint {
            // Drawn art with an approximate palette: re-hue, keep shading.
            let color = TypeStyle.color(type)
            steps = steps.map {
                EffectClip.Step(image: tint($0.image, with: color),
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
        return EffectClip(steps: steps, loop: loop, headAnchored: headAnchored, riseOffset: rise)
    }

    // MARK: raw frame loading

    private static func rawSteps(file: Int, anim: Int) -> [EffectClip.Step]? {
        let dir = String(format: "gamedata/effects/effect_%04d", file)
        if metaCache[file] == nil {
            guard let u = Bundle.main.url(forResource: "animations", withExtension: "json",
                                          subdirectory: dir),
                  let d = try? Data(contentsOf: u),
                  let m = try? JSONDecoder().decode(FileMeta.self, from: d) else { return nil }
            metaCache[file] = m
        }
        guard let a = metaCache[file]?.animations.first(where: { $0.animId == anim }),
              !a.frames.isEmpty else { return nil }
        var steps: [EffectClip.Step] = []
        var images: [Int: CGImage] = [:]
        for f in a.frames {
            if images[f.frame] == nil {
                // The exporter skips empty frames — they're intentional blank
                // "blink" moments, so keep the step (and its timing) as a
                // transparent frame instead of dropping it.
                images[f.frame] = Sprite.loadCG(String(format: "F-%02d", f.frame),
                                                subdir: "\(dir)/frames") ?? blankFrame
            }
            guard let img = images[f.frame] else { continue }
            steps.append(EffectClip.Step(
                image: img, ticks: max(1, f.duration),
                dx: signed16(f.offset.first ?? 0), dy: signed16(f.offset.count > 1 ? f.offset[1] : 0)))
        }
        return steps.isEmpty ? nil : steps
    }

    /// A 1x1 transparent frame standing in for unexported blank frames.
    private static let blankFrame: CGImage? = {
        let ctx = CGContext(data: nil, width: 1, height: 1, bitsPerComponent: 8,
                            bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        return ctx?.makeImage()
    }()

    /// Offsets are stored as raw unsigned 16-bit values; fold back to signed.
    private static func signed16(_ v: Int) -> Int { v >= 32768 ? v - 65536 : v }

    // MARK: corrections

    /// Frames sit off-center inside large cells (e.g. at (48,159) of 96x208).
    /// Crop every frame to the animation's union bbox so the drawn content —
    /// not the cell — is what gets centered on the target.
    private static func cropAndCenter(_ steps: [EffectClip.Step]) -> [EffectClip.Step] {
        var union: CGRect?
        for s in steps {
            if let b = Sprite.opaqueBBox(s.image) { union = union.map { $0.union(b) } ?? b }
        }
        guard let box = union else { return steps }
        return steps.map {
            EffectClip.Step(image: $0.image.cropping(to: box) ?? $0.image,
                            ticks: $0.ticks, dx: $0.dx, dy: $0.dy)
        }
    }

    /// Cap a clip's drawn size so screen-filling source art (Surf, Rock Slide —
    /// up to ~290px, meant to cover the game's whole 256x192 screen) doesn't
    /// dwarf the battle. Downscales every frame (and its offsets) uniformly.
    private static func capSize(_ steps: [EffectClip.Step], maxDim: Int = 140) -> [EffectClip.Step] {
        let biggest = steps.map { max($0.image.width, $0.image.height) }.max() ?? 0
        guard biggest > maxDim else { return steps }
        let f = CGFloat(maxDim) / CGFloat(biggest)
        return steps.map { s in
            let w = max(1, Int(CGFloat(s.image.width) * f))
            let h = max(1, Int(CGFloat(s.image.height) * f))
            guard let ctx = CGContext(data: nil, width: w, height: h,
                                      bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            else { return s }
            ctx.interpolationQuality = .none   // keep the pixel-art look
            ctx.draw(s.image, in: CGRect(x: 0, y: 0, width: w, height: h))
            return EffectClip.Step(image: ctx.makeImage() ?? s.image, ticks: s.ticks,
                                   dx: Int(CGFloat(s.dx) * f), dy: Int(CGFloat(s.dy) * f))
        }
    }

    /// A shared-file effect is one tiny particle; the game draws many. Compose
    /// each step into a burst: a center copy plus a ring of copies spreading
    /// outward (golden-angle spacing) as the animation progresses. The canvas
    /// is sized to the full spread so edge particles never get sliced off.
    private static func composeBurst(_ steps: [EffectClip.Step]) -> [EffectClip.Step] {
        let maxPart = steps.map { max($0.image.width, $0.image.height) }.max() ?? 16
        let canvas = 2 * 30 + maxPart + 8   // ring radius peaks at 30 (capped after)
        let copies = 7
        let n = max(1, steps.count - 1)
        return steps.enumerated().map { (i, s) in
            let progress = CGFloat(i) / CGFloat(n)
            guard let ctx = CGContext(data: nil, width: canvas, height: canvas,
                                      bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            else { return s }
            let w = CGFloat(s.image.width), h = CGFloat(s.image.height)
            let c = CGFloat(canvas) / 2
            for j in 0..<copies {
                let jitter = 0.65 + 0.35 * CGFloat((j * 37) % 10) / 9.0
                let r = (4 + 26 * progress) * jitter
                let angle = CGFloat(j) * 2.399963        // golden angle
                let x = c + cos(angle) * r - w / 2
                let y = c + sin(angle) * r - h / 2
                ctx.draw(s.image, in: CGRect(x: x, y: y, width: w, height: h))
            }
            return EffectClip.Step(image: ctx.makeImage() ?? s.image,
                                   ticks: s.ticks, dx: s.dx, dy: s.dy)
        }
    }

    /// A crisp round particle: an ellipse of `color` with a lighter core,
    /// replacing a broken square source frame of the same dimensions.
    private static func glowDot(width: Int, height: Int, color: NSColor) -> CGImage? {
        let w = max(2, width), h = max(2, height)
        guard let ctx = CGContext(data: nil, width: w, height: h,
                                  bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let srgb = color.usingColorSpace(.sRGB)
        else { return nil }
        let rect = CGRect(x: 0, y: 0, width: w, height: h)
        ctx.setFillColor(srgb.withAlphaComponent(0.9).cgColor)
        ctx.fillEllipse(in: rect)
        let core = rect.insetBy(dx: CGFloat(w) * 0.28, dy: CGFloat(h) * 0.28)
        ctx.setFillColor(srgb.blended(withFraction: 0.55, of: .white)?.cgColor
                         ?? NSColor.white.cgColor)
        ctx.fillEllipse(in: core)
        return ctx.makeImage()
    }

    /// Re-hue an approximate-palette frame with the move's type color: keep
    /// the sprite's luminosity/shape, replace hue+saturation (.color blend).
    private static func tint(_ img: CGImage, with color: NSColor) -> CGImage {
        let w = img.width, h = img.height
        guard let ctx = CGContext(data: nil, width: w, height: h,
                                  bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let srgb = color.usingColorSpace(.sRGB)
        else { return img }
        let rect = CGRect(x: 0, y: 0, width: w, height: h)
        ctx.draw(img, in: rect)
        ctx.clip(to: rect, mask: img)      // keep the sprite's alpha shape
        ctx.setBlendMode(.color)
        ctx.setFillColor(srgb.cgColor)
        ctx.fill(rect)
        return ctx.makeImage() ?? img
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
    func current(scale: CGFloat) -> (CGImage, CGPoint)? {
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
                let f = travels ? CGFloat(tick) / CGFloat(maxTicks) : 0
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
