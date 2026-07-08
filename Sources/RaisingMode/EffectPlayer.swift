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
    let file: Int
    let anim: Int
    let loop: Bool
    let point: String       // HEAD / CENTER / ... — anchor on the target
    let particle: Bool?     // single-particle art: compose a burst of copies
    let tint: Bool?         // approximate palette: re-hue with the type color
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
    private static var clipCache: [Int: EffectClip?] = [:]   // per move id

    /// The clip for `moveId` (fully corrected: cropped/centered, tinted,
    /// particle-composed), or nil when the move has no sprite effect.
    static func clip(forMove moveId: Int) -> EffectClip? {
        if let cached = clipCache[moveId] { return cached }
        let built = build(forMove: moveId)
        clipCache[moveId] = built
        return built
    }

    private static func build(forMove moveId: Int) -> EffectClip? {
        guard let ref = MoveEffects.map[moveId] else { return nil }
        guard var steps = rawSteps(file: ref.file, anim: ref.anim) else { return nil }
        steps = cropAndCenter(steps)
        if ref.particle == true { steps = composeBurst(steps) }
        if ref.tint == true {
            let type = GameData.moves[moveId]?.type
            if ref.particle == true {
                // Particle frames cycle through broken palette rows (purple/
                // black/green rainbow) — flat-fill their silhouette instead.
                // Normal/untyped get a white impact flash, others their type color.
                let neutral = type == nil || type == "Normal" || type == "None"
                let color = neutral ? NSColor(white: 0.96, alpha: 1) : TypeStyle.color(type)
                steps = steps.map {
                    EffectClip.Step(image: maskFill($0.image, with: color),
                                    ticks: $0.ticks, dx: $0.dx, dy: $0.dy)
                }
            } else {
                // Drawn art with an approximate palette: re-hue, keep shading.
                let color = TypeStyle.color(type)
                steps = steps.map {
                    EffectClip.Step(image: tint($0.image, with: color),
                                    ticks: $0.ticks, dx: $0.dx, dy: $0.dy)
                }
            }
        }
        return EffectClip(steps: steps, loop: ref.loop, headAnchored: ref.point == "HEAD")
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
                images[f.frame] = Sprite.loadCG(String(format: "F-%02d", f.frame),
                                                subdir: "\(dir)/frames")
            }
            guard let img = images[f.frame] else { continue }
            steps.append(EffectClip.Step(
                image: img, ticks: max(1, f.duration),
                dx: signed16(f.offset.first ?? 0), dy: signed16(f.offset.count > 1 ? f.offset[1] : 0)))
        }
        return steps.isEmpty ? nil : steps
    }

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

    /// A shared-file effect is one tiny particle; the game draws many. Compose
    /// each step into a burst: a center copy plus a ring of copies spreading
    /// outward (golden-angle spacing) as the animation progresses.
    private static func composeBurst(_ steps: [EffectClip.Step]) -> [EffectClip.Step] {
        let canvas = 72
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

    /// Flat-fill a frame's alpha silhouette with `color` (particle frames,
    /// whose own colors are unreconstructable palette garbage).
    private static func maskFill(_ img: CGImage, with color: NSColor) -> CGImage {
        let w = img.width, h = img.height
        guard let ctx = CGContext(data: nil, width: w, height: h,
                                  bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let srgb = color.usingColorSpace(.sRGB)
        else { return img }
        let rect = CGRect(x: 0, y: 0, width: w, height: h)
        ctx.clip(to: rect, mask: img)
        ctx.setFillColor(srgb.cgColor)
        ctx.fill(rect)
        return ctx.makeImage() ?? img
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

/// Tick-driven playback state for one running effect.
struct RunningEffect {
    let clip: EffectClip
    let anchor: CGPoint          // global position of the hit target
    var tick = 0
    let maxTicks: Int            // hard stop (event beat), also caps loops

    init(clip: EffectClip, anchor: CGPoint, maxTicks: Int) {
        self.clip = clip
        self.anchor = anchor
        self.maxTicks = maxTicks
    }

    var isDone: Bool { tick >= maxTicks || (!clip.loop && tick >= clip.totalTicks) }

    /// Current frame + its global position, nil when finished.
    func current(scale: CGFloat) -> (CGImage, CGPoint)? {
        guard !isDone else { return nil }
        var t = clip.loop ? tick % max(1, clip.totalTicks) : tick
        for s in clip.steps {
            if t < s.ticks {
                let up: CGFloat = clip.headAnchored ? 10 : 0
                let pos = CGPoint(x: anchor.x + CGFloat(s.dx) * scale,
                                  y: anchor.y - CGFloat(s.dy) * scale + up * scale)
                return (s.image, pos)
            }
            t -= s.ticks
        }
        return nil
    }

    mutating func advance() { tick += 1 }
}
