// Per-screen overlay view: draws the follower, wild battles, items and
// combat chrome (HP bars, tags, effects) at global positions.

import Cocoa
import QuartzCore

// MARK: - Sprite View (one per screen)
// Draws the shared character's current frame at its global position, offset by
// this screen's origin. The window (sized to one screen) clips it, so a sprite
// straddling two displays shows partially in each — seamless across monitors.
final class SpriteView: NSView {
    private let shadowLayer = CAGradientLayer()
    private let spriteLayer = CALayer()
    // Battle scene: wild sprite + an HP bar (track+fill) over each combatant,
    // plus a move-effect sprite over the hit target (D22).
    private let wildLayer = CALayer()
    private let effectLayer = CALayer()
    private let itemLayer = CALayer()
    private let pHPTrack = CALayer(); private let pHPFill = CALayer()
    private let wHPTrack = CALayer(); private let wHPFill = CALayer()
    private let levelLabel = CATextLayer()   // "Lv.n" above the wild's head
    private let floatLabel = CATextLayer()   // floating combat tag (Miss / effectiveness)
    private let screenFlashLayer = CALayer() // full-screen veil (Psychic-class moves)
    // Evolution burst: radial white glow over the follower (design D8/#9).
    private let glowLayer = CAGradientLayer()
    var screenOrigin: CGPoint = .zero

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true

        // Ground ellipse: a solid, uniform-opacity core (matching the source's
        // flat shadow) with just the outer edge softened so it doesn't look cut out.
        shadowLayer.type = .radial
        shadowLayer.colors = [CGColor(gray: 0, alpha: 0.30),
                              CGColor(gray: 0, alpha: 0.30),
                              CGColor(gray: 0, alpha: 0)]
        shadowLayer.locations = [0.0, 0.7, 1.0]
        shadowLayer.startPoint = CGPoint(x: 0.5, y: 0.5)
        shadowLayer.endPoint = CGPoint(x: 1.0, y: 1.0)
        layer?.addSublayer(shadowLayer)   // behind the sprite

        spriteLayer.magnificationFilter = .nearest
        spriteLayer.contentsGravity = .resize
        layer?.addSublayer(spriteLayer)

        wildLayer.magnificationFilter = .nearest
        wildLayer.contentsGravity = .resize
        wildLayer.isHidden = true
        layer?.addSublayer(wildLayer)
        for (t, f) in [(pHPTrack, pHPFill), (wHPTrack, wHPFill)] {
            t.backgroundColor = CGColor(gray: 0.1, alpha: 0.55); t.cornerRadius = 2.5; t.isHidden = true
            f.cornerRadius = 2.5; f.isHidden = true
            layer?.addSublayer(t); layer?.addSublayer(f)
        }

        itemLayer.magnificationFilter = .nearest
        itemLayer.contentsGravity = .resize
        itemLayer.isHidden = true
        layer?.addSublayer(itemLayer)

        levelLabel.alignmentMode = .center
        levelLabel.cornerRadius = 5
        levelLabel.backgroundColor = CGColor(gray: 0.08, alpha: 0.62)
        levelLabel.foregroundColor = CGColor(gray: 1, alpha: 0.95)
        levelLabel.isHidden = true
        layer?.addSublayer(levelLabel)

        screenFlashLayer.isHidden = true
        layer?.addSublayer(screenFlashLayer)

        floatLabel.alignmentMode = .center
        floatLabel.shadowColor = NSColor.black.cgColor
        floatLabel.shadowOpacity = 0.9
        floatLabel.shadowRadius = 1.5
        floatLabel.shadowOffset = CGSize(width: 0, height: -1)
        floatLabel.isHidden = true
        layer?.addSublayer(floatLabel)

        glowLayer.type = .radial
        glowLayer.colors = [CGColor(gray: 1, alpha: 0.95),
                            CGColor(gray: 1, alpha: 0.55),
                            CGColor(gray: 1, alpha: 0)]
        glowLayer.locations = [0.0, 0.55, 1.0]
        glowLayer.startPoint = CGPoint(x: 0.5, y: 0.5)
        glowLayer.endPoint = CGPoint(x: 1.0, y: 1.0)
        glowLayer.isHidden = true
        layer?.addSublayer(glowLayer)

        effectLayer.magnificationFilter = .nearest
        effectLayer.contentsGravity = .resize
        effectLayer.isHidden = true
        layer?.addSublayer(effectLayer)   // above everything: the move effect
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    /// Draw the wild encounter / battle overlay (nil hides it). Also applies the
    /// hit-flash to the player sprite drawn by `render`.
    func renderBattle(_ scene: BattleScene?) {
        guard let scene else {
            wildLayer.isHidden = true
            effectLayer.isHidden = true
            levelLabel.isHidden = true
            floatLabel.isHidden = true
            screenFlashLayer.isHidden = true
            [pHPTrack, pHPFill, wHPTrack, wHPFill].forEach { $0.isHidden = true }
            spriteLayer.opacity = 1
            return
        }
        let s = AppSettings.shared.scale
        let wx = scene.wildPos.x - screenOrigin.x, wy = scene.wildPos.y - screenOrigin.y
        let px = scene.playerPos.x - screenOrigin.x, py = scene.playerPos.y - screenOrigin.y
        CATransaction.begin(); CATransaction.setDisableActions(true)

        wildLayer.isHidden = false
        wildLayer.bounds = CGRect(x: 0, y: 0, width: CGFloat(scene.wildFrame.width) * s,
                                  height: CGFloat(scene.wildFrame.height) * s)
        wildLayer.contents = scene.wildFrame
        wildLayer.position = CGPoint(x: wx, y: wy)
        wildLayer.opacity = scene.flashWild ? 0.25 : Float(scene.wildAlpha)
        spriteLayer.opacity = scene.flashPlayer ? 0.25 : Float(scene.playerAlpha)

        if scene.showBars {
            let top = 20 * s
            layoutHP(pHPTrack, pHPFill, center: CGPoint(x: px, y: py + top), frac: scene.playerHP)
            layoutHP(wHPTrack, wHPFill, center: CGPoint(x: wx, y: wy + top), frac: scene.wildHP)
        } else {
            [pHPTrack, pHPFill, wHPTrack, wHPFill].forEach { $0.isHidden = true }
        }

        if let fx = scene.effectFrame {
            effectLayer.isHidden = false
            effectLayer.bounds = CGRect(x: 0, y: 0, width: CGFloat(fx.width) * s,
                                        height: CGFloat(fx.height) * s)
            effectLayer.contents = fx
            effectLayer.position = CGPoint(x: scene.effectPos.x - screenOrigin.x,
                                           y: scene.effectPos.y - screenOrigin.y)
        } else {
            effectLayer.isHidden = true
        }

        let bs = window?.backingScaleFactor ?? 2
        // Level tag above the wild's head (#1) — above the HP bar in battle.
        if let lv = scene.wildLevel {
            let fs = min(16, max(9, 6 * s))
            levelLabel.isHidden = false
            levelLabel.contentsScale = bs
            levelLabel.font = NSFont.rounded(fs, .bold)
            levelLabel.fontSize = fs
            levelLabel.string = "Lv.\(lv)"
            let w = (CGFloat("Lv.\(lv)".count) * fs * 0.62) + 10
            levelLabel.bounds = CGRect(x: 0, y: 0, width: w, height: fs + 6)
            levelLabel.position = CGPoint(x: wx, y: wy + (scene.showBars ? 30 : 22) * s)
            levelLabel.opacity = Float(scene.wildAlpha)
        } else {
            levelLabel.isHidden = true
        }

        // Full-screen veil for Psychic-class moves (type-colored, brief).
        if scene.screenFlash > 0 {
            screenFlashLayer.isHidden = false
            screenFlashLayer.frame = bounds
            screenFlashLayer.backgroundColor = scene.screenColor
            screenFlashLayer.opacity = Float(scene.screenFlash * 0.22)
        } else {
            screenFlashLayer.isHidden = true
        }

        // Floating combat tag over the defender: Miss / Super Effective! / ...
        if let text = scene.floatText {
            let fs = min(18, max(10, 7 * s))
            floatLabel.isHidden = false
            floatLabel.contentsScale = bs
            floatLabel.font = NSFont.rounded(fs, .heavy)
            floatLabel.fontSize = fs
            floatLabel.string = text
            floatLabel.foregroundColor = scene.floatColor
            floatLabel.bounds = CGRect(x: 0, y: 0,
                                       width: CGFloat(text.count) * fs * 0.62 + 12,
                                       height: fs + 4)
            floatLabel.position = CGPoint(x: scene.floatPos.x - screenOrigin.x,
                                          y: scene.floatPos.y - screenOrigin.y)
            floatLabel.opacity = Float(scene.floatAlpha)
        } else {
            floatLabel.isHidden = true
        }
        CATransaction.commit()
    }

    private func layoutHP(_ track: CALayer, _ fill: CALayer, center: CGPoint, frac: Double) {
        let w: CGFloat = 46, h: CGFloat = 5
        track.isHidden = false
        track.bounds = CGRect(x: 0, y: 0, width: w, height: h); track.position = center
        guard frac > 0 else { fill.isHidden = true; return }   // empty at 0 HP
        fill.isHidden = false
        let fw = max(1, w * CGFloat(min(1, frac)))
        fill.bounds = CGRect(x: 0, y: 0, width: fw, height: h)
        fill.position = CGPoint(x: center.x - (w - fw) / 2, y: center.y)   // left-anchored
        fill.backgroundColor = (frac > 0.5 ? NSColor.systemGreen
                                : frac > 0.2 ? NSColor.systemYellow : NSColor.systemRed).cgColor
    }

    /// Draw the spawned item (nil hides it). Pixel-art icon, scale-following.
    func renderItem(_ scene: ItemScene?) {
        guard let scene else { itemLayer.isHidden = true; return }
        let s = AppSettings.shared.scale
        CATransaction.begin(); CATransaction.setDisableActions(true)
        itemLayer.isHidden = false
        itemLayer.contents = scene.frame
        itemLayer.bounds = CGRect(x: 0, y: 0, width: CGFloat(scene.frame.width) * s,
                                  height: CGFloat(scene.frame.height) * s)
        itemLayer.position = CGPoint(x: scene.pos.x - screenOrigin.x,
                                     y: scene.pos.y - screenOrigin.y)
        itemLayer.opacity = Float(scene.alpha)
        CATransaction.commit()
    }

    func render(_ frame: CGImage?, globalPos: CGPoint, shadow: ShadowAnchor,
                rotation: CGFloat = 0, glow: CGFloat = 0) {
        guard let frame else {
            spriteLayer.isHidden = true; shadowLayer.isHidden = true; glowLayer.isHidden = true
            return
        }
        let s = AppSettings.shared.scale
        let x = globalPos.x - screenOrigin.x
        let y = globalPos.y - screenOrigin.y
        CATransaction.begin()
        CATransaction.setDisableActions(true)

        // Shadow: an ellipse at the sprite's ground contact. Both the position
        // (offset from tile center, y-up) and the footprint size come from the
        // character's -Shadow marker sheet, so each pokemon/animation gets the
        // exact anchor and size the source art specifies.
        if AppSettings.shared.showShadow {
            shadowLayer.isHidden = false
            shadowLayer.bounds = CGRect(x: 0, y: 0,
                                        width: max(shadow.size.width * s, 1),
                                        height: max(shadow.size.height * s, 1))
            shadowLayer.position = CGPoint(x: x + shadow.offset.x * s,
                                           y: y + shadow.offset.y * s)
        } else {
            shadowLayer.isHidden = true
        }

        spriteLayer.isHidden = false
        spriteLayer.bounds = CGRect(x: 0, y: 0,
                                    width: CGFloat(frame.width) * s,
                                    height: CGFloat(frame.height) * s)
        spriteLayer.contents = frame
        spriteLayer.position = CGPoint(x: x, y: y)
        spriteLayer.transform = rotation == 0 ? CATransform3DIdentity
                                              : CATransform3DMakeRotation(rotation, 0, 0, 1)

        // Evolution burst: a white radial glow swelling over the sprite.
        if glow > 0 {
            let d = max(CGFloat(frame.width), CGFloat(frame.height)) * s * (1.1 + 0.5 * glow)
            glowLayer.isHidden = false
            glowLayer.bounds = CGRect(x: 0, y: 0, width: d, height: d)
            glowLayer.position = CGPoint(x: x, y: y)
            glowLayer.opacity = Float(glow)
        } else {
            glowLayer.isHidden = true
        }
        CATransaction.commit()
    }
}
