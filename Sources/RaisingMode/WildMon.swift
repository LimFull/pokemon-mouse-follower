// Raising mode — a wandering wild encounter sprite (Phase 2c polish).
//
// A lightweight autonomous character: loads the 8-direction Walk/Idle sheets,
// wanders the screen (stop-and-go), and can turn to face a point (so it looks at
// the player when a battle starts). Reuses the shared Sprite slicing helpers.

import AppKit

final class WildMon {
    private var walk: [[CGImage]] = []
    private var idle: [[CGImage]] = []
    private let octantToRow = [2, 3, 4, 5, 6, 7, 0, 1]

    private(set) var pos: CGPoint = .zero
    private(set) var currentFrame: CGImage?
    private var target: CGPoint = .zero
    private var pauseTicks = 0
    private var tick = 0
    private var row = 0                 // facing row (0 = down)
    private let speed: CGFloat = 1.5

    init?(dex: Int) {
        let subdir = "characters/\(String(format: "%03d", dex))"
        let xml = Sprite.loadText("AnimData", ext: "xml", subdir: subdir)
        walk = Self.sheet("Walk-Anim", "Walk", subdir, xml)
        idle = Self.sheet("Idle-Anim", "Idle", subdir, xml)
        if idle.isEmpty { idle = walk }
        guard !walk.isEmpty else { return nil }
        frame(moving: false)
    }

    func place(at p: CGPoint) {
        pos = p; target = p; pauseTicks = Int.random(in: 30...90)
        frame(moving: false)
    }

    func setPos(_ p: CGPoint) { pos = p }

    /// Stop-and-go wandering inside `bounds`.
    func wander(bounds: CGRect) {
        tick += 1
        if pauseTicks > 0 { pauseTicks -= 1; frame(moving: false); return }
        let dx = target.x - pos.x, dy = target.y - pos.y
        let dist = hypot(dx, dy)
        if dist < 6 {
            if Bool.random() {
                pauseTicks = Int.random(in: 40...140)
            } else {
                target = CGPoint(x: .random(in: bounds.minX + 60 ... bounds.maxX - 60),
                                 y: .random(in: bounds.minY + 60 ... bounds.maxY - 60))
            }
            frame(moving: false)
            return
        }
        let vx = dx / dist * speed, vy = dy / dist * speed
        pos.x += vx; pos.y += vy
        faceVector(vx, vy)
        frame(moving: true)
    }

    /// Stand still, turned toward `point` (used when a battle starts).
    func faceStanding(toward point: CGPoint) {
        tick += 1
        faceVector(point.x - pos.x, point.y - pos.y)
        frame(moving: false)
    }

    // MARK: internals

    private func faceVector(_ vx: CGFloat, _ vy: CGFloat) {
        guard abs(vx) > 0.01 || abs(vy) > 0.01 else { return }
        var deg = atan2(vy, vx) * 180 / .pi
        if deg < 0 { deg += 360 }
        row = octantToRow[Int((deg / 45).rounded()) % 8]
    }

    private func frame(moving: Bool) {
        let sheet = moving ? walk : idle
        guard !sheet.isEmpty else { return }
        let r = min(row, sheet.count - 1)
        let frames = sheet[r]
        guard !frames.isEmpty else { return }
        currentFrame = frames[(tick / (moving ? 6 : 10)) % frames.count]
    }

    private static func sheet(_ png: String, _ anim: String, _ subdir: String, _ xml: String?) -> [[CGImage]] {
        guard let img = Sprite.loadCG(png, subdir: subdir) else { return [] }
        var cw = img.height / 8, ch = img.height / 8
        if let xml, let (w, h) = Sprite.frameSize(anim, in: xml) { cw = w; ch = h }
        guard cw > 0, ch > 0 else { return [] }
        let rows = max(1, img.height / ch), cols = max(1, img.width / cw)
        return Sprite.slice(img, cols: cols, rows: rows, cellW: cw, cellH: ch)
    }
}
