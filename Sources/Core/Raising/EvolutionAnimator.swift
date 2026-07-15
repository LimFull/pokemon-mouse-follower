// Raising mode — mainline-style evolution sequence (Gen 3 pacing, D8/#9).
//
// Reproduces the classic evolution scene on the overlay, matching the
// reference capture: the mon turns into a white silhouette, the old and new
// forms alternate with a shrink-grow morph that keeps accelerating, the
// screen whites out, and the new form is revealed amid white sparkles.
// The follower freezes in place for the ~5.5s sequence (as in the games).
//
// Platform-neutral (Phase 5a): frames are composed on RGBABuffer (top-left
// origin, y-down) and returned as renderable PMFImages.

import Foundation

final class EvolutionAnimator {
    private(set) var active = false
    private(set) var position = CGPoint.zero

    // Evolutions announced while a scene is playing wait their turn: a shared
    // battle's EXP can evolve several participants, and each is "brought out"
    // for its own full sequence, in announce order (active mon first).
    private var queue: [(from: Int, to: Int)] = []

    private var tick = 0
    private var oldSil: RGBABuffer?
    private var newSil: RGBABuffer?
    private var oldColored: RGBABuffer?
    private var newColored: RGBABuffer?
    private var canvas = 96

    // Timeline (60 ticks/s).
    private let silhouetteEnd = 50       // colored -> white silhouette
    private let morphEnd = 240           // alternating shrink/grow morphs
    private let flashEnd = 268           // white-out
    private let revealEnd = 350          // sparkly reveal of the new form

    func start(fromDex: Int, toDex: Int, at pos: CGPoint) {
        if active {
            queue.append((fromDex, toDex))
            return
        }
        _ = begin(fromDex: fromDex, toDex: toDex, at: pos)
    }

    @discardableResult
    private func begin(fromDex: Int, toDex: Int, at pos: CGPoint) -> Bool {
        let oldFrame = Self.idleDownBuffers(Characters.folder(dex: fromDex)).first
        let newFrame = Self.idleDownBuffers(Characters.folder(dex: toDex)).first
        guard let oldFrame, let newFrame else { return false }
        oldColored = oldFrame
        newColored = newFrame
        oldSil = Self.silhouette(oldFrame)
        newSil = Self.silhouette(newFrame)
        canvas = max(oldFrame.width, oldFrame.height, newFrame.width, newFrame.height) + 36
        position = pos
        tick = 0
        active = true
        return true
    }

    /// One 60fps step: the composed frame + the white-out glow (0...1).
    /// Returns nil when finished (the caller resumes normal rendering).
    /// A finished scene rolls straight into the next queued evolution.
    func update() -> (frame: PMFImage, glow: CGFloat)? {
        guard active else { return nil }
        defer { tick += 1 }
        if tick >= revealEnd {
            var started = false
            while !queue.isEmpty, !started {
                let next = queue.removeFirst()
                started = begin(fromDex: next.from, toDex: next.to, at: position)
            }
            if !started { active = false; return nil }
        }

        var glow: CGFloat = 0
        var image: RGBABuffer?

        if tick < silhouetteEnd {
            // Crossfade the colored form into its white silhouette.
            let t = Double(tick) / Double(silhouetteEnd)
            image = compose { buf in
                draw(oldColored, in: &buf, scale: 1, alpha: 1)
                draw(oldSil, in: &buf, scale: 1, alpha: t)
            }
        } else if tick < morphEnd {
            // Alternating morph: the visible silhouette shrinks away and the
            // other grows in, each cycle shorter than the last (accelerando).
            let t = tick - silhouetteEnd
            let span = morphEnd - silhouetteEnd
            let progress = Double(t) / Double(span)
            var acc = 0, phase = 0, inCycle = 0
            while true {
                let len = max(10, Int(48 - 38 * (Double(acc) / Double(span))))
                if acc + len > t { inCycle = t - acc; break }
                acc += len
                phase += 1
            }
            let cur = phase % 2 == 0 ? oldSil : newSil
            let nxt = phase % 2 == 0 ? newSil : oldSil
            let len = max(10, Int(48 - 38 * (Double(acc) / Double(span))))
            let half = len / 2
            glow = 0.15 + 0.25 * progress
            image = compose { buf in
                if inCycle < half {
                    let s = 1.0 - 0.65 * Double(inCycle) / Double(half)      // shrink out
                    draw(cur, in: &buf, scale: s, alpha: 1)
                } else {
                    let s = 0.35 + 0.65 * Double(inCycle - half) / Double(max(1, len - half))
                    draw(nxt, in: &buf, scale: s, alpha: 1)                  // grow in
                }
                // A few escaping motes at each swap.
                if inCycle < 6 {
                    dots(in: &buf, count: 5, seed: phase, radius: 26 + Double(inCycle) * 2,
                         alpha: 1 - Double(inCycle) / 6)
                }
            }
        } else if tick < flashEnd {
            // White-out.
            let t = Double(tick - morphEnd) / Double(flashEnd - morphEnd)
            glow = 0.4 + 0.6 * t
            image = compose { buf in
                draw(newSil, in: &buf, scale: 1, alpha: 1)
            }
        } else {
            // Reveal: silhouette fades into the colored new form, white
            // sparkles drifting up around it, the glow dying off.
            let t = Double(tick - flashEnd) / Double(revealEnd - flashEnd)
            glow = max(0, 1 - t * 2.2)
            image = compose { buf in
                draw(newColored, in: &buf, scale: 1, alpha: 1)
                draw(newSil, in: &buf, scale: 1, alpha: max(0, 1 - t * 3))
                let twinkle = 0.5 + 0.5 * sin(Double(tick) * 0.45)
                dots(in: &buf, count: 10, seed: 7, radius: 30 + t * 14,
                     alpha: (1 - t) * twinkle, rise: t * 16)
            }
        }

        guard let image, let rendered = PlatformImageIO.makeImage(image) else {
            active = false
            return nil
        }
        return (rendered, glow)
    }

    // MARK: drawing helpers (RGBABuffer, y-down)

    private func compose(_ body: (inout RGBABuffer) -> Void) -> RGBABuffer {
        var buf = RGBABuffer(width: canvas, height: canvas,
                             pixels: [UInt8](repeating: 0, count: canvas * canvas * 4))
        body(&buf)
        return buf
    }

    /// Nearest-scaled, alpha-weighted src-over blit centered on the canvas.
    private func draw(_ img: RGBABuffer?, in buf: inout RGBABuffer, scale: Double, alpha: Double) {
        guard let img, alpha > 0 else { return }
        let w = max(1, Int(Double(img.width) * scale))
        let h = max(1, Int(Double(img.height) * scale))
        let ox = (buf.width - w) / 2, oy = (buf.height - h) / 2
        let aMul = min(1, max(0, alpha))
        for y in 0..<h {
            let dy = oy + y
            guard dy >= 0, dy < buf.height else { continue }
            let sy = min(img.height - 1, Int(Double(y) / scale))
            for x in 0..<w {
                let dx = ox + x
                guard dx >= 0, dx < buf.width else { continue }
                let sx = min(img.width - 1, Int(Double(x) / scale))
                let s = (sy * img.width + sx) * 4
                let sa = UInt32(Double(img.pixels[s + 3]) * aMul)
                guard sa > 0 else { continue }
                let sr = UInt32(Double(img.pixels[s]) * aMul)
                let sg = UInt32(Double(img.pixels[s + 1]) * aMul)
                let sb = UInt32(Double(img.pixels[s + 2]) * aMul)
                let d = (dy * buf.width + dx) * 4
                let ia = 255 - sa
                buf.pixels[d]     = UInt8(min(255, sr + UInt32(buf.pixels[d]) * ia / 255))
                buf.pixels[d + 1] = UInt8(min(255, sg + UInt32(buf.pixels[d + 1]) * ia / 255))
                buf.pixels[d + 2] = UInt8(min(255, sb + UInt32(buf.pixels[d + 2]) * ia / 255))
                buf.pixels[d + 3] = UInt8(min(255, sa + UInt32(buf.pixels[d + 3]) * ia / 255))
            }
        }
    }

    /// White motes scattered around the center (golden-angle placement).
    /// `rise` drifts them upward — negative y in the buffer's y-down space.
    private func dots(in buf: inout RGBABuffer, count: Int, seed: Int,
                      radius: Double, alpha: Double, rise: Double = 0) {
        guard alpha > 0 else { return }
        let c = Double(canvas) / 2
        let a = min(1, alpha)
        for j in 0..<count {
            let angle = Double(j + seed * 3) * 2.399963
            let r = radius * (0.55 + 0.45 * Double((j * 29 + seed * 11) % 10) / 9)
            let d = 2.0 + Double((j + seed) % 3)
            fillCircle(&buf, cx: c + cos(angle) * r, cy: c - sin(angle) * r - rise,
                       radius: d / 2, alpha: a)
        }
    }

    private func fillCircle(_ buf: inout RGBABuffer, cx: Double, cy: Double,
                            radius: Double, alpha: Double) {
        let y0 = max(0, Int(cy - radius)), y1 = min(buf.height - 1, Int(cy + radius) + 1)
        let x0 = max(0, Int(cx - radius)), x1 = min(buf.width - 1, Int(cx + radius) + 1)
        guard y0 <= y1, x0 <= x1 else { return }
        let sa = UInt32(min(255, alpha * 255))
        let ia = 255 - sa
        for y in y0...y1 {
            for x in x0...x1 {
                let ddx = Double(x) + 0.5 - cx, ddy = Double(y) + 0.5 - cy
                guard ddx * ddx + ddy * ddy <= radius * radius else { continue }
                let d = (y * buf.width + x) * 4
                buf.pixels[d]     = UInt8(min(255, sa + UInt32(buf.pixels[d]) * ia / 255))
                buf.pixels[d + 1] = UInt8(min(255, sa + UInt32(buf.pixels[d + 1]) * ia / 255))
                buf.pixels[d + 2] = UInt8(min(255, sa + UInt32(buf.pixels[d + 2]) * ia / 255))
                buf.pixels[d + 3] = UInt8(min(255, sa + UInt32(buf.pixels[d + 3]) * ia / 255))
            }
        }
    }

    /// Solid white fill of the sprite's alpha shape.
    private static func silhouette(_ img: RGBABuffer) -> RGBABuffer {
        var out = img
        let n = img.width * img.height
        for i in 0..<n {
            let a = out.pixels[i * 4 + 3]
            out.pixels[i * 4] = a       // premultiplied white = alpha in every channel
            out.pixels[i * 4 + 1] = a
            out.pixels[i * 4 + 2] = a
        }
        return out
    }

    /// Row 0 (facing down) of the Idle sheet, falling back to Walk, cropped to
    /// the frames' shared opaque bounds — the buffer twin of the macOS
    /// CharacterPreviewView.idleDownFrames.
    static func idleDownBuffers(_ folder: String) -> [RGBABuffer] {
        let subdir = Characters.spriteSubdir(folder)
        let xml = Sprite.loadText("AnimData", ext: "xml", subdir: subdir)
        for (png, anim) in [("Idle-Anim", "Idle"), ("Walk-Anim", "Walk")] {
            let cells = Sprite.slicedSheetBuffers(png, anim: anim, subdir: subdir, xml: xml)
            guard let down = cells.first, !down.isEmpty else { continue }
            var box: CGRect?
            for f in down { if let b = Sprite.opaqueBBox(f) { box = box.map { $0.union(b) } ?? b } }
            guard let crop = box else { return down }
            return down.map {
                $0.cropped(x: Int(crop.minX), y: Int(crop.minY),
                           w: Int(crop.width), h: Int(crop.height)) ?? $0
            }
        }
        return []
    }
}
