// Raising mode — move-effect sprite playback (Phase 2d, design D22).
//
// gamedata/move_effects.json maps a move id to an effect file + animation
// (built by rom-extract/build_effects.py); gamedata/effects/effect_NNNN/ holds
// the frame PNGs and per-frame timing. EffectPlayer turns that into a tick-
// driven frame sequence the BattleController overlays on the hit target.

import AppKit

struct MoveEffectRef: Codable {
    let file: Int
    let anim: Int
    let loop: Bool
    let point: String       // HEAD / CENTER / ... — anchor on the target
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

    // Cache: effect file -> (parsed anims, frame image cache).
    private static var metaCache: [Int: FileMeta] = [:]
    private static var frameCache: [String: CGImage] = [:]

    /// The clip for `moveId`, or nil when the move has no sprite effect.
    static func clip(forMove moveId: Int) -> EffectClip? {
        guard let ref = MoveEffects.map[moveId] else { return nil }
        return clip(file: ref.file, anim: ref.anim, loop: ref.loop,
                    headAnchored: ref.point == "HEAD")
    }

    /// A specific effect animation (also used directly, e.g. evolution burst).
    static func clip(file: Int, anim: Int, loop: Bool = false, headAnchored: Bool = false) -> EffectClip? {
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
        for f in a.frames {
            let key = "\(file)/\(f.frame)"
            if frameCache[key] == nil {
                frameCache[key] = Sprite.loadCG(String(format: "F-%02d", f.frame), subdir: "\(dir)/frames")
            }
            guard let img = frameCache[key] else { continue }
            steps.append(EffectClip.Step(
                image: img, ticks: max(1, f.duration),
                dx: signed16(f.offset.first ?? 0), dy: signed16(f.offset.count > 1 ? f.offset[1] : 0)))
        }
        return steps.isEmpty ? nil : EffectClip(steps: steps, loop: loop, headAnchored: headAnchored)
    }

    /// Offsets are stored as raw unsigned 16-bit values; fold back to signed.
    private static func signed16(_ v: Int) -> Int { v >= 32768 ? v - 65536 : v }
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
