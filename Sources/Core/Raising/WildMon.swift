// Raising mode — a wandering wild encounter sprite (Phase 2c polish).
//
// A lightweight autonomous character: loads the 8-direction Walk/Idle sheets,
// wanders the screen (stop-and-go), and can turn to face a point (so it looks at
// the player when a battle starts). Reuses the shared Sprite slicing helpers.

import Foundation

final class WildMon {
    private var walk: [[PMFImage]] = []
    private var idle: [[PMFImage]] = []
    private var attack: [[PMFImage]] = []   // battle poses (D2-1); empty -> idle
    private var shoot: [[PMFImage]] = []
    private var romPoseCache: [Int: [[PMFImage]]] = [:]   // BattlePose.rom sheets, lazy
    private var poseSubdir = ""
    private var poseBase = ""
    private var poseXML: String?
    private var hurt: [[PMFImage]] = []
    private var sleep: [[PMFImage]] = []
    private let octantToRow = [2, 3, 4, 5, 6, 7, 0, 1]

    private(set) var pos: CGPoint = .zero
    private(set) var currentFrame: PMFImage?
    private var target: CGPoint = .zero
    private var pauseTicks = 0
    private var tick = 0
    private var row = 0                 // facing row (0 = down)
    private let speed: CGFloat = 1.5

    init?(dex: Int) {
        guard loadSheets(dex: dex) else { return nil }
        frame(moving: false)
    }

    /// Swap to another species' sheets in place — Transform (D2): position,
    /// facing and wander state stay put, only the look changes. Keeps the
    /// current look when the target's sheets are missing.
    @discardableResult
    func setSpecies(dex: Int) -> Bool {
        guard loadSheets(dex: dex) else { return false }
        frame(moving: false)
        return true
    }

    private func loadSheets(dex: Int) -> Bool {
        // Honor the alt-color setting like the follower does; the variant may
        // ship only some sheets, so fall back per-sheet to the base folder
        // (same pattern as CharacterController.setCharacter).
        let base = "characters/\(Characters.folder(dex: dex))"
        let subdir = Characters.spriteSubdir(Characters.folder(dex: dex))
        let xml = Sprite.loadText("AnimData", ext: "xml", subdir: subdir)
        poseSubdir = subdir
        poseBase = base
        poseXML = xml
        romPoseCache = [:]
        func load(_ png: String, _ anim: String) -> [[PMFImage]] {
            let sheet = Sprite.slicedSheet(png, anim: anim, subdir: subdir, xml: xml)
            guard sheet.isEmpty, subdir != base else { return sheet }
            let baseXml = Sprite.loadText("AnimData", ext: "xml", subdir: base)
            return Sprite.slicedSheet(png, anim: anim, subdir: base, xml: baseXml)
        }
        let newWalk = load("Walk-Anim", "Walk")
        guard !newWalk.isEmpty else { return false }
        walk = newWalk
        idle = load("Idle-Anim", "Idle")
        attack = load("Attack-Anim", "Attack")
        shoot = load("Shoot-Anim", "Shoot")
        hurt = load("Hurt-Anim", "Hurt")
        sleep = load("Sleep-Anim", "Sleep")
        if idle.isEmpty { idle = walk }
        if shoot.isEmpty { shoot = attack }
        return true
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
                // Short hops only: each leg is capped so the wild meanders
                // around where it spawned instead of trekking edge-to-edge —
                // a screen crossing kept steamrolling over the follower and
                // starting battles nobody asked for.
                let angle = CGFloat.random(in: 0 ..< 2 * .pi)
                let leg = CGFloat.random(in: 90...280)
                target = CGPoint(
                    x: min(max(pos.x + cos(angle) * leg, bounds.minX + 60), bounds.maxX - 60),
                    y: min(max(pos.y + sin(angle) * leg, bounds.minY + 60), bounds.maxY - 60))
            }
            frame(moving: false)
            return
        }
        let vx = dx / dist * speed, vy = dy / dist * speed
        pos.x += vx; pos.y += vy
        faceVector(vx, vy)
        frame(moving: true)
    }

    /// Walk straight toward `p` (a noticed player — it comes to challenge you).
    func approach(_ p: CGPoint) {
        tick += 1
        let dx = p.x - pos.x, dy = p.y - pos.y
        let dist = hypot(dx, dy)
        guard dist > 1 else { frame(moving: false); return }
        let vx = dx / dist * speed, vy = dy / dist * speed
        pos.x += vx; pos.y += vy
        faceVector(vx, vy)
        frame(moving: true)
    }

    /// Stand still, turned toward `point` (used when a battle starts). `pose`
    /// plays a battle sheet once from `poseTick`, holding its last frame (D2-1).
    /// Lazy ROM pose sheet (BattlePose.rom) — same resolution and alt-color
    /// fallback as CharacterController.romSheet. Cached (misses included).
    private func romSheet(_ index: Int) -> [[PMFImage]] {
        if let cached = romPoseCache[index] { return cached }
        var sheet: [[PMFImage]] = []
        if let xml = poseXML, let name = Sprite.animName(forIndex: index, in: xml) {
            sheet = Sprite.slicedSheet("\(name)-Anim", anim: name, subdir: poseSubdir, xml: xml)
        }
        if sheet.isEmpty, poseSubdir != poseBase,
           let baseXml = Sprite.loadText("AnimData", ext: "xml", subdir: poseBase),
           let name = Sprite.animName(forIndex: index, in: baseXml) {
            sheet = Sprite.slicedSheet("\(name)-Anim", anim: name, subdir: poseBase, xml: baseXml)
        }
        romPoseCache[index] = sheet
        return sheet
    }

    func faceStanding(toward point: CGPoint, pose: BattlePose = .stand, poseTick: Int = 0) {
        tick += 1
        faceVector(point.x - pos.x, point.y - pos.y)
        let poseSheet: [[PMFImage]]
        switch pose {
        case .attack: poseSheet = attack
        case .shoot: poseSheet = shoot
        case .hurt: poseSheet = hurt
        case .sleep: poseSheet = sleep
        case .stand: poseSheet = []
        case .rom(let index, let ranged):
            let sheet = romSheet(index)
            poseSheet = sheet.isEmpty ? (ranged ? shoot : attack) : sheet
        }
        if !poseSheet.isEmpty {
            let r = min(row, poseSheet.count - 1)
            if !poseSheet[r].isEmpty {
                // Sleep loops; the action poses play once and hold.
                let col = pose == .sleep ? (poseTick / 12) % poseSheet[r].count
                                         : min(poseSheet[r].count - 1, poseTick / 3)
                currentFrame = poseSheet[r][col]
                return
            }
        }
        frame(moving: false)
    }

    // MARK: internals

    private func faceVector(_ vx: CGFloat, _ vy: CGFloat) {
        guard abs(vx) > 0.01 || abs(vy) > 0.01 else { return }
        row = octantToRow[Sprite.octant(dx: vx, dy: vy)]
    }

    private func frame(moving: Bool) {
        let sheet = moving ? walk : idle
        guard !sheet.isEmpty else { return }
        let r = min(row, sheet.count - 1)
        let frames = sheet[r]
        guard !frames.isEmpty else { return }
        currentFrame = frames[(tick / (moving ? 6 : 10)) % frames.count]
    }

}
