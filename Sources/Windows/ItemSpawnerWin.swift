// Field-item spawner, Windows edition (Phase 5b) — a line-for-line mirror of
// the macOS ItemSpawner in Sources/macOS/RaisingMode/Items.swift, kept as a
// platform copy so the macOS file stays untouched (its ItemScene/NSScreen
// types would otherwise collide). Behavior must match: one item at a time at
// a random screen spot (D12), long random cooldown, despawn when ignored,
// pickup by walking over it, float-and-fade pickup animation.

import Foundation

/// What the overlay should draw for the current item frame (nil = nothing).
struct ItemSceneWin {
    let frame: PMFImage
    let pos: CGPoint
    let alpha: Double
}

final class ItemSpawnerWin {
    private let fast = ProcessInfo.processInfo.environment["PMF_FAST_BATTLE"] != nil
    private var cooldown = 0
    private var despawnTicks = 0
    private var current: GameItem?
    private var pos = CGPoint.zero
    private var pickupTicks = 0          // >0: float-and-fade pickup animation

    init() { cooldown = nextCooldown() }

    func update(followerPos: CGPoint, canPickup: Bool) -> ItemSceneWin? {
        if pickupTicks > 0 {
            pickupTicks -= 1
            if pickupTicks == 0 { current = nil; cooldown = nextCooldown() }
            guard let item = current, let icon = platformItemIcon(item) else { return nil }
            let t = 1.0 - Double(pickupTicks) / 40.0
            return ItemSceneWin(frame: icon,
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
        guard let item = current, let icon = platformItemIcon(item) else { return nil }
        let scale = AppSettings.shared.scale
        if canPickup, hypot(followerPos.x - pos.x, followerPos.y - pos.y) < 30 * scale {
            RaisingState.shared.addItem(item)
            pickupTicks = 40
        }
        return ItemSceneWin(frame: icon, pos: pos, alpha: 1.0)
    }

    private func union() -> CGRect {
        var r = CGRect.null
        for s in platformScreensWorld() { r = r.union(s) }
        if r.isNull { r = CGRect(x: 0, y: 0, width: 1440, height: 900) }
        return r
    }

    private func spawn() {
        let r = union()
        current = GameItem.randomSpawn()
        pos = CGPoint(x: .random(in: r.minX + 60 ... r.maxX - 60),
                      y: .random(in: r.minY + 60 ... r.maxY - 60))
        despawnTicks = (fast ? 60 : 10 * 60) * 60      // 1 min (fast) / 10 min
    }

    /// Debug: drop `item` (nil = weighted random) a short walk away from the
    /// follower, clamped on screen (macOS forceSpawn mirror).
    func forceSpawn(_ item: GameItem? = nil, near follower: CGPoint) {
        let r = union()
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
