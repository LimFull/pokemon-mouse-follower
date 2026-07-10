// Raising mode — items, macOS layer: drawn icons and the overlay spawner
// (Phase 3a, design D12 / C3 / D8-1). The platform-neutral catalog (names,
// ball/heal stats, spawn weights) lives in Core/Raising/ItemCatalog.swift.
//
// A small curated catalog: balls and potions are common, revives and
// evolution items rare. Items appear at a random screen spot on a long
// timer; the active mon picks one up by walking over it (click-through
// stays intact, #12). Icons are drawn in code — no ROM graphics.

import AppKit

// MARK: drawn icon (16x16 points at 1x, pixel-art flavored)

private var gameItemIconCache: [GameItem: CGImage] = [:]

extension GameItem {
    var icon: CGImage? {
        if let c = gameItemIconCache[self] { return c }
        let img = drawIcon()
        if let img { gameItemIconCache[self] = img }
        return img
    }

    private func drawIcon() -> CGImage? {
        let s = 16
        guard let ctx = CGContext(data: nil, width: s, height: s,
                                  bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        let r = CGRect(x: 1, y: 1, width: 14, height: 14)
        func fill(_ c: NSColor) { ctx.setFillColor(c.usingColorSpace(.sRGB)!.cgColor) }

        switch self {
        case .pokeBall, .greatBall:
            // Bottom white half, top colored half, band + button.
            fill(.white); ctx.fillEllipse(in: r)
            ctx.saveGState()
            ctx.clip(to: CGRect(x: 0, y: 8, width: s, height: 8))
            fill(self == .pokeBall ? NSColor(srgbRed: 0.90, green: 0.20, blue: 0.22, alpha: 1)
                                   : NSColor(srgbRed: 0.23, green: 0.42, blue: 0.85, alpha: 1))
            ctx.fillEllipse(in: r)
            ctx.restoreGState()
            fill(NSColor(white: 0.15, alpha: 1)); ctx.fill(CGRect(x: 1, y: 7, width: 14, height: 2))
            fill(.white); ctx.fillEllipse(in: CGRect(x: 6, y: 6, width: 4, height: 4))
            ctx.setStrokeColor(NSColor(white: 0.15, alpha: 1).cgColor)
            ctx.strokeEllipse(in: CGRect(x: 6, y: 6, width: 4, height: 4))
        case .potion, .superPotion:
            let body = self == .potion ? NSColor(srgbRed: 0.62, green: 0.36, blue: 0.86, alpha: 1)
                                       : NSColor(srgbRed: 0.95, green: 0.62, blue: 0.18, alpha: 1)
            fill(body)
            ctx.fill(CGRect(x: 4, y: 1, width: 8, height: 9))          // bottle body
            ctx.fillEllipse(in: CGRect(x: 4, y: 0, width: 8, height: 6))
            ctx.fill(CGRect(x: 6, y: 10, width: 4, height: 3))          // neck
            fill(NSColor(white: 0.8, alpha: 1)); ctx.fill(CGRect(x: 5, y: 13, width: 6, height: 2))  // cap
            fill(NSColor(white: 1, alpha: 0.45)); ctx.fill(CGRect(x: 5, y: 3, width: 2, height: 5))  // shine
        case .fullHeal:
            // Yellow spray bottle, nozzle to the left with a puff of mist.
            fill(NSColor(srgbRed: 0.97, green: 0.80, blue: 0.20, alpha: 1))
            ctx.fill(CGRect(x: 6, y: 1, width: 8, height: 9))           // bottle body
            fill(NSColor(white: 0.35, alpha: 1))
            ctx.fill(CGRect(x: 7, y: 10, width: 6, height: 4))          // trigger head
            ctx.fill(CGRect(x: 4, y: 11, width: 3, height: 2))          // nozzle
            fill(NSColor(white: 1, alpha: 0.45)); ctx.fill(CGRect(x: 7, y: 3, width: 2, height: 5))  // shine
            fill(NSColor(white: 0.92, alpha: 0.9))
            ctx.fillEllipse(in: CGRect(x: 1, y: 12, width: 2, height: 2))  // mist
            ctx.fillEllipse(in: CGRect(x: 2, y: 9, width: 2, height: 2))
        case .revive:
            fill(NSColor(srgbRed: 0.98, green: 0.83, blue: 0.25, alpha: 1))
            // diamond
            ctx.move(to: CGPoint(x: 8, y: 1)); ctx.addLine(to: CGPoint(x: 15, y: 8))
            ctx.addLine(to: CGPoint(x: 8, y: 15)); ctx.addLine(to: CGPoint(x: 1, y: 8))
            ctx.closePath(); ctx.fillPath()
            fill(NSColor(white: 1, alpha: 0.55)); ctx.fillEllipse(in: CGRect(x: 5, y: 7, width: 4, height: 4))
        case .fireStone, .thunderStone, .waterStone, .leafStone, .moonStone, .sunStone:
            let c: NSColor
            switch self {
            case .fireStone: c = TypeStyle.color("Fire")
            case .thunderStone: c = TypeStyle.color("Electric")
            case .waterStone: c = TypeStyle.color("Water")
            case .leafStone: c = TypeStyle.color("Grass")
            case .moonStone: c = NSColor(srgbRed: 0.55, green: 0.50, blue: 0.75, alpha: 1)
            default: c = NSColor(srgbRed: 0.95, green: 0.55, blue: 0.25, alpha: 1)
            }
            fill(c)
            // faceted gem: hexagon
            ctx.move(to: CGPoint(x: 8, y: 1)); ctx.addLine(to: CGPoint(x: 14, y: 5))
            ctx.addLine(to: CGPoint(x: 14, y: 11)); ctx.addLine(to: CGPoint(x: 8, y: 15))
            ctx.addLine(to: CGPoint(x: 2, y: 11)); ctx.addLine(to: CGPoint(x: 2, y: 5))
            ctx.closePath(); ctx.fillPath()
            fill(NSColor(white: 1, alpha: 0.5)); ctx.fill(CGRect(x: 5, y: 8, width: 3, height: 4))
        case .linkCord:
            ctx.setStrokeColor(NSColor(white: 0.55, alpha: 1).cgColor)
            ctx.setLineWidth(2.5)
            ctx.strokeEllipse(in: CGRect(x: 2, y: 4, width: 10, height: 10))   // coiled cable
            fill(NSColor(srgbRed: 0.35, green: 0.65, blue: 0.9, alpha: 1))
            ctx.fill(CGRect(x: 11, y: 1, width: 4, height: 5))                 // plug
        case .friendCandy:
            fill(NSColor(srgbRed: 0.96, green: 0.55, blue: 0.70, alpha: 1))
            ctx.fillEllipse(in: CGRect(x: 2, y: 2, width: 12, height: 12))
            fill(NSColor(srgbRed: 1.0, green: 0.80, blue: 0.88, alpha: 1))
            ctx.fillEllipse(in: CGRect(x: 5, y: 6, width: 5, height: 5))
        }
        return ctx.makeImage()
    }
}

/// What the overlay should draw for the current item frame (nil = nothing).
struct ItemScene {
    let frame: CGImage
    let pos: CGPoint
    let alpha: Double
}

/// Spawns one item at a time at a random screen spot (D12): long random
/// cooldown, despawns if ignored, picked up by the active mon walking over it.
final class ItemSpawner {
    private let fast = ProcessInfo.processInfo.environment["PMF_FAST_BATTLE"] != nil
    private var cooldown = 0
    private var despawnTicks = 0
    private var current: GameItem?
    private var pos = CGPoint.zero
    private var pickupTicks = 0          // >0: float-and-fade pickup animation

    init() { cooldown = nextCooldown() }

    func update(followerPos: CGPoint, canPickup: Bool) -> ItemScene? {
        if pickupTicks > 0 {
            pickupTicks -= 1
            if pickupTicks == 0 { current = nil; cooldown = nextCooldown() }
            guard let item = current, let icon = item.icon else { return nil }
            let t = 1.0 - Double(pickupTicks) / 40.0
            return ItemScene(frame: icon,
                             pos: CGPoint(x: pos.x, y: pos.y + CGFloat(t) * 22),
                             alpha: 1.0 - t)
        }
        guard AppSettings.shared.raisingMode, AppSettings.shared.itemSpawnsEnabled,
              RaisingState.shared.hasActiveGame else {
            current = nil
            return nil
        }
        if current == nil {
            cooldown -= 1
            if cooldown <= 0 { spawn() }
            return nil
        }
        despawnTicks -= 1
        if despawnTicks <= 0 { current = nil; cooldown = nextCooldown(); return nil }
        guard let item = current, let icon = item.icon else { return nil }
        let scale = AppSettings.shared.scale
        if canPickup, hypot(followerPos.x - pos.x, followerPos.y - pos.y) < 30 * scale {
            RaisingState.shared.addItem(item)
            pickupTicks = 40
        }
        return ItemScene(frame: icon, pos: pos, alpha: 1.0)
    }

    private func spawn() {
        var r = CGRect.null
        for s in NSScreen.screens { r = r.union(s.frame) }
        if r.isNull { r = CGRect(x: 0, y: 0, width: 1440, height: 900) }
        current = GameItem.randomSpawn()
        pos = CGPoint(x: .random(in: r.minX + 60 ... r.maxX - 60),
                      y: .random(in: r.minY + 60 ... r.maxY - 60))
        despawnTicks = (fast ? 60 : 10 * 60) * 60      // 1 min (fast) / 10 min
    }

    /// Debug: drop `item` (nil = weighted random) a short walk away from the
    /// follower — far enough that the pickup can be watched/recorded, clamped
    /// on screen. Replaces whatever is out; the spawn timer restarts normally
    /// after the pickup/despawn.
    func forceSpawn(_ item: GameItem? = nil, near follower: CGPoint) {
        var r = CGRect.null
        for s in NSScreen.screens { r = r.union(s.frame) }
        if r.isNull { r = CGRect(x: 0, y: 0, width: 1440, height: 900) }
        pickupTicks = 0
        current = item ?? GameItem.randomSpawn()
        let angle = CGFloat.random(in: 0 ..< 2 * .pi)
        let d = 220 * AppSettings.shared.scale
        pos = CGPoint(x: min(max(follower.x + cos(angle) * d, r.minX + 60), r.maxX - 60),
                      y: min(max(follower.y + sin(angle) * d, r.minY + 60), r.maxY - 60))
        despawnTicks = (fast ? 60 : 10 * 60) * 60
    }

    private func nextCooldown() -> Int {
        fast ? 8 * 60 : Int.random(in: (10 * 60)...(20 * 60)) * 60   // 8s / 10–20 min
    }
}
