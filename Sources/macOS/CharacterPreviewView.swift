// Settings-window character preview (down-facing idle loop) and the
// still-image helper used by party rows.

import Cocoa
import QuartzCore

// MARK: - Character Preview
// Plays a character's downward-facing Idle animation (sprite row 0 = South),
// respecting the alt-color setting. Used at the top of the settings window.
final class CharacterPreviewView: NSView {
    private let imgLayer = CALayer()
    private var frames: [CGImage] = []
    private var idx = 0
    private var timer: Timer?

    private let card = CAGradientLayer()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        // Soft drop shadow on the host layer; the rounded gradient card sits inside.
        layer?.masksToBounds = false
        layer?.shadowColor = NSColor.black.cgColor
        layer?.shadowOpacity = 0.14
        layer?.shadowRadius = 7
        layer?.shadowOffset = CGSize(width: 0, height: -2)
        card.cornerRadius = 18
        card.masksToBounds = true
        card.startPoint = CGPoint(x: 0.5, y: 0)
        card.endPoint = CGPoint(x: 0.5, y: 1)
        card.borderWidth = 1
        layer?.addSublayer(card)
        imgLayer.magnificationFilter = .nearest
        imgLayer.contentsGravity = .resizeAspect
        card.addSublayer(imgLayer)
        applyColors()
    }

    required init?(coder: NSCoder) { fatalError("not used") }
    override var intrinsicContentSize: NSSize { NSSize(width: 96, height: 96) }
    override func layout() {
        super.layout()
        card.frame = bounds
        imgLayer.frame = bounds.insetBy(dx: 12, dy: 12)
    }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); applyColors() }

    private func applyColors() {
        // CALayer cgColors don't auto-update with appearance, so resolve them here.
        (effectiveAppearance).performAsCurrentDrawingAppearance {
            card.colors = [Palette.cardTop.cgColor, Palette.cardBottom.cgColor]
            card.borderColor = Palette.cardBorder.cgColor
        }
    }

    func setCharacter(_ folder: String) {
        frames = CharacterPreviewView.idleDownFrames(folder)
        idx = 0
        imgLayer.contents = frames.first
        timer?.invalidate(); timer = nil
        guard frames.count > 1 else { return }
        let t = Timer(timeInterval: 0.18, repeats: true) { [weak self] _ in
            guard let self, !self.frames.isEmpty else { return }
            self.idx = (self.idx + 1) % self.frames.count
            CATransaction.begin(); CATransaction.setDisableActions(true)
            self.imgLayer.contents = self.frames[self.idx]
            CATransaction.commit()
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    deinit { timer?.invalidate() }

    /// A still down-facing idle frame for `folder`, as an NSImage (party rows etc.).
    static func stillImage(_ folder: String) -> NSImage? {
        guard let cg = idleDownFrames(folder).first else { return nil }
        return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
    }

    // Row 0 (facing down) of the Idle sheet, falling back to Walk if needed.
    static func idleDownFrames(_ folder: String) -> [CGImage] {
        let subdir = Characters.spriteSubdir(folder)
        let xml = Sprite.loadText("AnimData", ext: "xml", subdir: subdir)
        for (png, anim) in [("Idle-Anim", "Idle"), ("Walk-Anim", "Walk")] {
            let sheet = Sprite.slicedSheet(png, anim: anim, subdir: subdir, xml: xml)
            guard let down = sheet.first, !down.isEmpty else { continue }
            // Sprites sit high in their tile (empty space below for the shadow), so
            // crop to the opaque bounds — shared across frames so they stay aligned —
            // and the character ends up centered in the preview box, not the tile.
            var box: CGRect?
            for f in down { if let b = Sprite.opaqueBBox(f) { box = box.map { $0.union(b) } ?? b } }
            guard let crop = box else { return down }
            return down.map { $0.cropping(to: crop) ?? $0 }
        }
        return []
    }
}
