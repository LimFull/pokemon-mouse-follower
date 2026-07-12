// The follower "brain": position/velocity steering after the cursor and
// the current animation frame (walk/idle/sleep/faint/battle poses).
// Platform-neutral: frames are opaque PMFImage handles, all math runs in
// global y-up world coordinates (design/windows-port.md W2/W4).

import Foundation

// MARK: - Character Controller
// The "brain": tracks the character in GLOBAL screen coordinates and picks the
// current animation frame. Rendering is done separately by one SpriteView per
// screen, so the character can cross between displays (which each own a space).
/// Battle pose for a combatant during playback (design D2/D2-1).
enum BattlePose: Equatable {
    case stand      // idle, facing the opponent
    case attack     // Attack-Anim (contact moves)
    case shoot      // Shoot-Anim (projectile moves; falls back to attack)
    case hurt       // Hurt-Anim while damage lands
    case sleep      // Sleep-Anim while asleep (loops)
    /// The move's ROM caster anim group (moves.json caster_anim): each
    /// renderer resolves the index through ITS species' AnimData.xml
    /// (fetch-rom-pose-anims.sh sheets) — the same index maps to different
    /// sheet names per species. Missing sheet -> the pre-ROM heuristic pose
    /// (`ranged` ? shoot : attack).
    case rom(index: Int, ranged: Bool)
}

final class CharacterController {
    private var idle: [[PMFImage]] = []
    private var walk: [[PMFImage]] = []
    private var sleep: [[PMFImage]] = []
    private var faint: [[PMFImage]] = []       // Faint-Anim (may be absent -> rotate fallback)
    private var attack: [[PMFImage]] = []      // battle poses (D2-1); empty -> idle fallback
    private var shoot: [[PMFImage]] = []
    private var hurt: [[PMFImage]] = []
    private var romPoseCache: [Int: [[PMFImage]]] = [:]   // BattlePose.rom sheets, lazy
    private var poseXML: String?                           // this character's AnimData.xml
    private var basePoseSubdir = ""                        // base folder for alt-color fallback
    private var faintTick = 0
    private(set) var faintRotation: CGFloat = 0   // z-rotation for the fallback faint pose
    // Shadow anchor per frame, parallel to the sheets above (position + size).
    private var idleShadow: [[ShadowAnchor]] = []
    private var walkShadow: [[ShadowAnchor]] = []
    private var sleepShadow: [[ShadowAnchor]] = []
    // Fixed PMD footprint template (small/medium/large), used as a fallback size.
    private let shadowTemplate: [CGSize] = [CGSize(width: 8, height: 4),
                                            CGSize(width: 14, height: 6),
                                            CGSize(width: 22, height: 8)]
    private(set) var loaded = false

    private var pos = CGPoint.zero        // global screen coordinates (y-up)
    private var vel = Vec2.zero
    private var started = false

    private var tickCounter = 0
    private var idleTicks = 0             // frames spent not moving (drives sleep)
    private var lastRow = 0
    /// The follower dozed off (idle past the sleep delay). Raising mode reads
    /// this for the faster resting regen; only update(mouseGlobal:) drives it.
    private(set) var isSleeping = false
    private var loadedSubdir = ""         // sheet dir in memory (setCharacter dedupe)

    private let slowRadius: CGFloat = 130
    private let accel: CGFloat = 0.55
    private let moveThreshold: CGFloat = 0.35
    private let walkStepTicks = 6
    private let idleStepTicks = 10
    private let sleepStepTicks = 14
    private let fps: CGFloat = 60

    // octant (0=E,1=NE,2=N,3=NW,4=W,5=SW,6=S,7=SE) -> sprite row (PMD direction order).
    private let octantToRow = [2, 3, 4, 5, 6, 7, 0, 1]

    // Latest frame + its global position, consumed by the per-screen views.
    private(set) var currentFrame: PMFImage?
    private(set) var shadowSize = 1       // 0=small, 1=medium, 2=large (from AnimData.xml)
    private(set) var currentShadow = ShadowAnchor(offset: .zero, size: CGSize(width: 14, height: 6))
    var position: CGPoint { pos }

    init() { setCharacter(RaisingState.shared.followerFolder) }

    // Load a character's sheets, sizing frames from its AnimData.xml. Uses the
    // alt-color variant (characters/<folder>/altcolor) when enabled and present.
    func setCharacter(_ folder: String) {
        let subdir = Characters.spriteSubdir(folder)
        // Same sheets already loaded — nothing to reload. raisingChanged fires
        // on ANY party/bag change (the ~7.5s sleep-regen tick included), and a
        // full reload resets the idle clock below, waking a sleeping follower.
        if loaded, subdir == loadedSubdir { return }
        loadedSubdir = subdir
        let xml = Sprite.loadText("AnimData", ext: "xml", subdir: subdir)
        poseXML = xml
        romPoseCache = [:]
        shadowSize = xml.map { Sprite.shadowSize(in: $0) } ?? 1
        // walk/idle/sleep keep their sliced buffers around long enough to
        // compute shadow anchors (marker sheet or alpha fallback).
        let walkCells = Sprite.slicedSheetBuffers("Walk-Anim", anim: "Walk", subdir: subdir, xml: xml)
        let idleCells = Sprite.slicedSheetBuffers("Idle-Anim", anim: "Idle", subdir: subdir, xml: xml)
        let sleepCells = Sprite.slicedSheetBuffers("Sleep-Anim", anim: "Sleep", subdir: subdir, xml: xml)
        walk = Sprite.images(walkCells)
        idle = Sprite.images(idleCells)
        sleep = Sprite.images(sleepCells)
        // Prefer the current (alt-color) folder's battle sheets; fall back to
        // the base folder when the variant doesn't ship them.
        faint = Sprite.slicedSheet("Faint-Anim", anim: "Faint", subdir: subdir, xml: xml)
        attack = Sprite.slicedSheet("Attack-Anim", anim: "Attack", subdir: subdir, xml: xml)
        shoot = Sprite.slicedSheet("Shoot-Anim", anim: "Shoot", subdir: subdir, xml: xml)
        hurt = Sprite.slicedSheet("Hurt-Anim", anim: "Hurt", subdir: subdir, xml: xml)
        let baseSubdir = "characters/\(folder)"
        basePoseSubdir = baseSubdir
        if subdir != baseSubdir {
            let baseXml = Sprite.loadText("AnimData", ext: "xml", subdir: baseSubdir)
            if faint.isEmpty { faint = Sprite.slicedSheet("Faint-Anim", anim: "Faint", subdir: baseSubdir, xml: baseXml) }
            if attack.isEmpty { attack = Sprite.slicedSheet("Attack-Anim", anim: "Attack", subdir: baseSubdir, xml: baseXml) }
            if shoot.isEmpty { shoot = Sprite.slicedSheet("Shoot-Anim", anim: "Shoot", subdir: baseSubdir, xml: baseXml) }
            if hurt.isEmpty { hurt = Sprite.slicedSheet("Hurt-Anim", anim: "Hurt", subdir: baseSubdir, xml: baseXml) }
        }
        if shoot.isEmpty { shoot = attack }   // 37 species ship no Shoot sheet
        // Shadow anchors from the matching -Shadow marker sheet (alpha fallback
        // if a marker sheet is missing). Computed before the sheet fallbacks so
        // each maps to its own frames.
        walkShadow = markerShadow("Walk-Shadow", anim: "Walk", subdir: subdir, xml: xml, fallback: walkCells)
        idleShadow = idleCells.isEmpty ? [] : markerShadow("Idle-Shadow", anim: "Idle", subdir: subdir, xml: xml, fallback: idleCells)
        sleepShadow = sleepCells.isEmpty ? [] : markerShadow("Sleep-Shadow", anim: "Sleep", subdir: subdir, xml: xml, fallback: sleepCells)
        if idle.isEmpty { idle = walk; idleShadow = walkShadow }     // some characters ship Walk only
        if sleep.isEmpty { sleep = idle; sleepShadow = idleShadow }  // fall back when no sleep animation
        loaded = !walk.isEmpty
        tickCounter = 0
        idleTicks = 0
        if !loaded { NSLog("PokemonMouseFollower: failed to load character \(folder)") }
    }

    // Per-frame shadow anchor from the "-Shadow" marker sheet: position (y-up
    // offset from the tile center) and footprint size, both read from the marker
    // regions. Falls back to alpha-based feet detection if the sheet is absent.
    private func markerShadow(_ png: String, anim: String, subdir: String,
                              xml: String?, fallback: [[RGBABuffer]]) -> [[ShadowAnchor]] {
        let cells = Sprite.slicedSheetBuffers(png, anim: anim, subdir: subdir, xml: xml)
        guard !cells.isEmpty else { return shadowAnchors(fallback) }
        let templateSize = shadowTemplate[max(0, min(shadowTemplate.count - 1, shadowSize))]
        return cells.map { row in
            row.map { cell -> ShadowAnchor in
                let w = CGFloat(cell.width), h = CGFloat(cell.height)
                if let m = Sprite.shadowMarker(cell, shadowSize: shadowSize) {
                    return ShadowAnchor(offset: CGPoint(x: m.center.x - w / 2, y: h / 2 - m.center.y),
                                        size: m.size)
                }
                return ShadowAnchor(offset: CGPoint(x: 0, y: h / 2 - h * 0.72), size: templateSize)
            }
        }
    }

    // Fallback anchor when a marker sheet is missing: position from alpha-based
    // feet detection (bottom-center of opaque pixels, grounded across the sheet),
    // size from the fixed PMD template for this character's ShadowSize.
    private func shadowAnchors(_ sheet: [[RGBABuffer]]) -> [[ShadowAnchor]] {
        let size = shadowTemplate[max(0, min(shadowTemplate.count - 1, shadowSize))]
        var sheetBottomIY = -1        // lowest opaque row over all frames
        var frameW = 0, frameH = 0
        var boxes: [[CGRect?]] = []
        for row in sheet {
            var rowBoxes: [CGRect?] = []
            for img in row {
                frameW = img.width; frameH = img.height
                let box = Sprite.opaqueBBox(img)
                if let box { sheetBottomIY = max(sheetBottomIY, Int(box.maxY)) }
                rowBoxes.append(box)
            }
            boxes.append(rowBoxes)
        }
        let groundIY = sheetBottomIY >= 0 ? CGFloat(sheetBottomIY) : CGFloat(frameH) * 0.72
        let cx = CGFloat(frameW) / 2, cy = CGFloat(frameH) / 2
        return boxes.map { rowBoxes in
            rowBoxes.map { box -> ShadowAnchor in
                let centerX = box.map { $0.midX } ?? cx
                return ShadowAnchor(offset: CGPoint(x: centerX - cx, y: cy - groundIY), size: size)
            }
        }
    }

    // Advance one frame. `mouseGlobal` is already in global screen coordinates.
    func update(mouseGlobal: CGPoint) {
        guard loaded else { currentFrame = nil; return }
        faintRotation = 0   // healed/awake — clear the fallback faint tilt

        let gap = AppSettings.shared.followGap
        let maxSpeed = AppSettings.shared.maxSpeed
        let target = mouseGlobal

        if !started {
            pos = CGPoint(x: target.x, y: target.y - gap)
            vel = .zero
            started = true
        }

        let dx = target.x - pos.x
        let dy = target.y - pos.y
        let dist = (dx * dx + dy * dy).squareRoot()
        let remaining = dist - gap

        var desired = Vec2.zero
        if remaining > 0.001 && dist > 0.001 {
            let dir = Vec2(dx: dx / dist, dy: dy / dist)
            let speedWanted = remaining < slowRadius ? maxSpeed * (remaining / slowRadius) : maxSpeed
            desired = Vec2(dx: dir.dx * speedWanted, dy: dir.dy * speedWanted)
        }

        var sdx = desired.dx - vel.dx
        var sdy = desired.dy - vel.dy
        let steerMag = (sdx * sdx + sdy * sdy).squareRoot()
        if steerMag > accel { sdx = sdx / steerMag * accel; sdy = sdy / steerMag * accel }
        vel.dx += sdx
        vel.dy += sdy

        let speed = (vel.dx * vel.dx + vel.dy * vel.dy).squareRoot()
        if speed > maxSpeed { vel.dx = vel.dx / speed * maxSpeed; vel.dy = vel.dy / speed * maxSpeed }

        pos.x += vel.dx
        pos.y += vel.dy

        let moving = speed > moveThreshold
        if moving {
            idleTicks = 0
            face(dx: vel.dx, dy: vel.dy)
        } else {
            idleTicks += 1
        }

        // Idle long enough -> sleep.
        let sleeping = !moving && CGFloat(idleTicks) / fps >= AppSettings.shared.sleepDelay
        isSleeping = sleeping

        let sheet: [[PMFImage]]
        let shadow: [[ShadowAnchor]]
        let step: Int
        if moving { sheet = walk; shadow = walkShadow; step = walkStepTicks }
        else if sleeping { sheet = sleep; shadow = sleepShadow; step = sleepStepTicks }
        else { sheet = idle; shadow = idleShadow; step = idleStepTicks }

        guard !sheet.isEmpty else { currentFrame = nil; return }
        let row = min(lastRow, sheet.count - 1)
        let frames = sheet[row]
        guard !frames.isEmpty else { currentFrame = nil; return }

        tickCounter += 1
        let col = (tickCounter / step) % frames.count
        currentFrame = frames[col]
        if row < shadow.count, col < shadow[row].count {
            currentShadow = shadow[row][col]
        }
    }

    /// Stand in place (no movement) turned to face `point` — used during a
    /// battle. `pose` selects a battle sheet (D2-1): attack/shoot/hurt play
    /// once from `poseTick` and hold their last frame; stand cycles idle.
    /// Lazy ROM pose sheet (BattlePose.rom): the caster_anim index resolved
    /// through this character's AnimData.xml, alt-color -> base fallback like
    /// the fixed battle set. Cached (including misses) per character.
    private func romSheet(_ index: Int) -> [[PMFImage]] {
        if let cached = romPoseCache[index] { return cached }
        var sheet: [[PMFImage]] = []
        if let xml = poseXML, let name = Sprite.animName(forIndex: index, in: xml) {
            sheet = Sprite.slicedSheet("\(name)-Anim", anim: name, subdir: loadedSubdir, xml: xml)
        }
        if sheet.isEmpty, loadedSubdir != basePoseSubdir,
           let baseXml = Sprite.loadText("AnimData", ext: "xml", subdir: basePoseSubdir),
           let name = Sprite.animName(forIndex: index, in: baseXml) {
            sheet = Sprite.slicedSheet("\(name)-Anim", anim: name, subdir: basePoseSubdir, xml: baseXml)
        }
        romPoseCache[index] = sheet
        return sheet
    }

    func face(_ point: CGPoint, pose: BattlePose = .stand, poseTick: Int = 0) {
        guard loaded else { return }
        faintRotation = 0   // healed/awake — clear the fallback faint tilt
        face(dx: point.x - pos.x, dy: point.y - pos.y)
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
            let row = min(lastRow, poseSheet.count - 1)
            if !poseSheet[row].isEmpty {
                // Sleep loops; the action poses play once and hold.
                let col = pose == .sleep ? (poseTick / 12) % poseSheet[row].count
                                         : min(poseSheet[row].count - 1, poseTick / 3)
                currentFrame = poseSheet[row][col]
                return   // keep the previous shadow anchor during the pose
            }
        }
        let sheet = idle.isEmpty ? walk : idle
        let shadow = idle.isEmpty ? walkShadow : idleShadow
        guard !sheet.isEmpty else { return }
        let row = min(lastRow, sheet.count - 1)
        guard !sheet[row].isEmpty else { return }
        tickCounter += 1
        let col = (tickCounter / idleStepTicks) % sheet[row].count
        currentFrame = sheet[row][col]
        if row < shadow.count, col < shadow[row].count { currentShadow = shadow[row][col] }
    }

    /// Turn toward a direction vector (no-op for a negligible one).
    private func face(dx: CGFloat, dy: CGFloat) {
        guard abs(dx) > 0.01 || abs(dy) > 0.01 else { return }
        lastRow = octantToRow[Sprite.octant(dx: dx, dy: dy)]
    }

    /// Restart the faint sequence (call once when the mon is knocked out).
    /// `near` seeds the position when the app launches with an already-fainted
    /// active mon: update(mouseGlobal:) never runs while fainted, so without
    /// this the sprite would render at the world origin — half off the
    /// bottom-left screen corner. A mon that faints mid-run keeps its spot.
    func startFaint(near target: CGPoint) {
        faintTick = 0
        if !started {
            pos = clampToScreen(CGPoint(x: target.x, y: target.y - AppSettings.shared.followGap),
                                margin: 60)
            started = true
        }
    }

    /// Play the Faint animation once and hold its last frame, in place. When no
    /// Faint sheet exists, collapse the idle sprite onto its side instead.
    func updateFainted() {
        guard loaded else { return }
        faintTick += 1
        if !faint.isEmpty {
            faintRotation = 0
            let row = min(lastRow, faint.count - 1)
            let frames = faint[row]
            if !frames.isEmpty {
                let step = 6
                currentFrame = frames[min(frames.count - 1, (faintTick - 1) / step)]
            }
        } else {
            let sheet = idle.isEmpty ? walk : idle
            if !sheet.isEmpty {
                let row = min(lastRow, sheet.count - 1)
                currentFrame = sheet[row].first
            }
            faintRotation = min(1.0, CGFloat(faintTick) / 18.0) * (.pi / 2)   // 0 -> lying on its side
        }
    }
}
