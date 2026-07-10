// Raising mode — mainline-style evolution sequence (Gen 3 pacing, D8/#9).
//
// Reproduces the classic evolution scene on the overlay, matching the
// reference capture: the mon turns into a white silhouette, the old and new
// forms alternate with a shrink-grow morph that keeps accelerating, the
// screen whites out, and the new form is revealed amid white sparkles.
// The follower freezes in place for the ~5.5s sequence (as in the games).

import AppKit

final class EvolutionAnimator {
    private(set) var active = false
    private(set) var position = CGPoint.zero

    private var tick = 0
    private var oldSil: CGImage?
    private var newSil: CGImage?
    private var oldColored: CGImage?
    private var newColored: CGImage?
    private var canvas = 96

    // Timeline (60 ticks/s).
    private let silhouetteEnd = 50       // colored -> white silhouette
    private let morphEnd = 240           // alternating shrink/grow morphs
    private let flashEnd = 268           // white-out
    private let revealEnd = 350          // sparkly reveal of the new form

    func start(fromDex: Int, toDex: Int, at pos: CGPoint) {
        let oldFrame = CharacterPreviewView.idleDownFrames(Characters.folder(dex: fromDex)).first
        let newFrame = CharacterPreviewView.idleDownFrames(Characters.folder(dex: toDex)).first
        guard let oldFrame, let newFrame else { return }
        oldColored = oldFrame
        newColored = newFrame
        oldSil = EvolutionAnimator.silhouette(oldFrame)
        newSil = EvolutionAnimator.silhouette(newFrame)
        canvas = max(oldFrame.width, oldFrame.height, newFrame.width, newFrame.height) + 36
        position = pos
        tick = 0
        active = true
    }

    /// One 60fps step: the composed frame + the white-out glow (0...1).
    /// Returns nil when finished (the caller resumes normal rendering).
    func update() -> (frame: CGImage, glow: CGFloat)? {
        guard active else { return nil }
        defer { tick += 1 }
        if tick >= revealEnd { active = false; return nil }

        var glow: CGFloat = 0
        var image: CGImage?

        if tick < silhouetteEnd {
            // Crossfade the colored form into its white silhouette.
            let t = CGFloat(tick) / CGFloat(silhouetteEnd)
            image = compose { ctx in
                draw(oldColored, in: ctx, scale: 1, alpha: 1)
                draw(oldSil, in: ctx, scale: 1, alpha: t)
            }
        } else if tick < morphEnd {
            // Alternating morph: the visible silhouette shrinks away and the
            // other grows in, each cycle shorter than the last (accelerando).
            let t = tick - silhouetteEnd
            let span = morphEnd - silhouetteEnd
            let progress = CGFloat(t) / CGFloat(span)
            // Cycle length eases 48 -> 10 ticks.
            let cycleLen = max(10, Int(48 - 38 * progress))
            var acc = 0, phase = 0, inCycle = 0
            while true {
                let len = max(10, Int(48 - 38 * (CGFloat(acc) / CGFloat(span))))
                if acc + len > t { inCycle = t - acc; break }
                acc += len
                phase += 1
            }
            _ = cycleLen
            let cur = phase % 2 == 0 ? oldSil : newSil
            let nxt = phase % 2 == 0 ? newSil : oldSil
            let len = max(10, Int(48 - 38 * (CGFloat(acc) / CGFloat(span))))
            let half = len / 2
            glow = 0.15 + 0.25 * progress
            image = compose { ctx in
                if inCycle < half {
                    let s = 1.0 - 0.65 * CGFloat(inCycle) / CGFloat(half)      // shrink out
                    draw(cur, in: ctx, scale: s, alpha: 1)
                } else {
                    let s = 0.35 + 0.65 * CGFloat(inCycle - half) / CGFloat(max(1, len - half))
                    draw(nxt, in: ctx, scale: s, alpha: 1)                     // grow in
                }
                // A few escaping motes at each swap.
                if inCycle < 6 {
                    dots(in: ctx, count: 5, seed: phase, radius: 26 + CGFloat(inCycle) * 2,
                         alpha: 1 - CGFloat(inCycle) / 6)
                }
            }
        } else if tick < flashEnd {
            // White-out.
            let t = CGFloat(tick - morphEnd) / CGFloat(flashEnd - morphEnd)
            glow = 0.4 + 0.6 * t
            image = compose { ctx in
                draw(newSil, in: ctx, scale: 1, alpha: 1)
            }
        } else {
            // Reveal: silhouette fades into the colored new form, white
            // sparkles drifting up around it, the glow dying off.
            let t = CGFloat(tick - flashEnd) / CGFloat(revealEnd - flashEnd)
            glow = max(0, 1 - t * 2.2)
            image = compose { ctx in
                draw(newColored, in: ctx, scale: 1, alpha: 1)
                draw(newSil, in: ctx, scale: 1, alpha: max(0, 1 - t * 3))
                let twinkle = 0.5 + 0.5 * sin(CGFloat(tick) * 0.45)
                dots(in: ctx, count: 10, seed: 7, radius: 30 + t * 14,
                     alpha: (1 - t) * twinkle, rise: t * 16)
            }
        }

        guard let image else { active = false; return nil }
        return (image, glow)
    }

    // MARK: drawing helpers

    private func compose(_ body: (CGContext) -> Void) -> CGImage? {
        guard let ctx = CGContext(data: nil, width: canvas, height: canvas,
                                  bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        ctx.interpolationQuality = .none   // keep the pixel-art look
        body(ctx)
        return ctx.makeImage()
    }

    private func draw(_ img: CGImage?, in ctx: CGContext, scale: CGFloat, alpha: CGFloat) {
        guard let img, alpha > 0 else { return }
        let w = CGFloat(img.width) * scale, h = CGFloat(img.height) * scale
        let c = CGFloat(canvas) / 2
        ctx.setAlpha(alpha)
        ctx.draw(img, in: CGRect(x: c - w / 2, y: c - h / 2, width: w, height: h))
        ctx.setAlpha(1)
    }

    /// White motes scattered around the center (golden-angle placement).
    private func dots(in ctx: CGContext, count: Int, seed: Int,
                      radius: CGFloat, alpha: CGFloat, rise: CGFloat = 0) {
        guard alpha > 0 else { return }
        let c = CGFloat(canvas) / 2
        ctx.setFillColor(CGColor(gray: 1, alpha: min(1, alpha)))
        for j in 0..<count {
            let a = CGFloat(j + seed * 3) * 2.399963
            let r = radius * (0.55 + 0.45 * CGFloat((j * 29 + seed * 11) % 10) / 9)
            let d: CGFloat = 2 + CGFloat((j + seed) % 3)
            ctx.fillEllipse(in: CGRect(x: c + cos(a) * r - d / 2,
                                       y: c + sin(a) * r - d / 2 + rise,
                                       width: d, height: d))
        }
    }

    /// Solid white fill of the sprite's alpha shape.
    private static func silhouette(_ img: CGImage) -> CGImage? {
        let w = img.width, h = img.height
        guard let ctx = CGContext(data: nil, width: w, height: h,
                                  bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        let rect = CGRect(x: 0, y: 0, width: w, height: h)
        ctx.clip(to: rect, mask: img)
        ctx.setFillColor(CGColor(gray: 1, alpha: 1))
        ctx.fill(rect)
        return ctx.makeImage()
    }
}
