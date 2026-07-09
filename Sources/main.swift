import Cocoa
import QuartzCore
import ImageIO
import UniformTypeIdentifiers
import ServiceManagement

// Localized string lookup (en/ko/ja via *.lproj/Localizable.strings).
func L(_ key: String) -> String { NSLocalizedString(key, comment: "") }

// Launch-at-login backed by SMAppService (macOS 13+). The system owns the
// state, so it defaults to off (not registered) until the user opts in.
enum LoginItem {
    static var isEnabled: Bool { SMAppService.mainApp.status == .enabled }

    @discardableResult
    static func setEnabled(_ on: Bool) -> Bool {
        do {
            if on {
                if SMAppService.mainApp.status != .enabled { try SMAppService.mainApp.register() }
            } else {
                if SMAppService.mainApp.status == .enabled { try SMAppService.mainApp.unregister() }
            }
            return true
        } catch {
            NSLog("PokemonMouseFollower: login item toggle failed: \(error)")
            return false
        }
    }
}

// MARK: - Character catalog (National Dex 001–009)
struct CharacterInfo { let folder: String; let name: String }

enum Characters {
    // National Dex 001–151 display names.
    private static let names: [String] = [
        "Bulbasaur", "Ivysaur", "Venusaur", "Charmander", "Charmeleon", "Charizard",
        "Squirtle", "Wartortle", "Blastoise", "Caterpie", "Metapod", "Butterfree",
        "Weedle", "Kakuna", "Beedrill", "Pidgey", "Pidgeotto", "Pidgeot", "Rattata",
        "Raticate", "Spearow", "Fearow", "Ekans", "Arbok", "Pikachu", "Raichu",
        "Sandshrew", "Sandslash", "Nidoran♀", "Nidorina", "Nidoqueen", "Nidoran♂",
        "Nidorino", "Nidoking", "Clefairy", "Clefable", "Vulpix", "Ninetales",
        "Jigglypuff", "Wigglytuff", "Zubat", "Golbat", "Oddish", "Gloom", "Vileplume",
        "Paras", "Parasect", "Venonat", "Venomoth", "Diglett", "Dugtrio", "Meowth",
        "Persian", "Psyduck", "Golduck", "Mankey", "Primeape", "Growlithe", "Arcanine",
        "Poliwag", "Poliwhirl", "Poliwrath", "Abra", "Kadabra", "Alakazam", "Machop",
        "Machoke", "Machamp", "Bellsprout", "Weepinbell", "Victreebel", "Tentacool",
        "Tentacruel", "Geodude", "Graveler", "Golem", "Ponyta", "Rapidash", "Slowpoke",
        "Slowbro", "Magnemite", "Magneton", "Farfetch'd", "Doduo", "Dodrio", "Seel",
        "Dewgong", "Grimer", "Muk", "Shellder", "Cloyster", "Gastly", "Haunter",
        "Gengar", "Onix", "Drowzee", "Hypno", "Krabby", "Kingler", "Voltorb",
        "Electrode", "Exeggcute", "Exeggutor", "Cubone", "Marowak", "Hitmonlee",
        "Hitmonchan", "Lickitung", "Koffing", "Weezing", "Rhyhorn", "Rhydon", "Chansey",
        "Tangela", "Kangaskhan", "Horsea", "Seadra", "Goldeen", "Seaking", "Staryu",
        "Starmie", "Mr. Mime", "Scyther", "Jynx", "Electabuzz", "Magmar", "Pinsir",
        "Tauros", "Magikarp", "Gyarados", "Lapras", "Ditto", "Eevee", "Vaporeon",
        "Jolteon", "Flareon", "Porygon", "Omanyte", "Omastar", "Kabuto", "Kabutops",
        "Aerodactyl", "Snorlax", "Articuno", "Zapdos", "Moltres", "Dratini",
        "Dragonair", "Dragonite", "Mewtwo", "Mew",
        "Chikorita", "Bayleef", "Meganium", "Cyndaquil", "Quilava", "Typhlosion",
        "Totodile", "Croconaw", "Feraligatr", "Sentret", "Furret", "Hoothoot",
        "Noctowl", "Ledyba", "Ledian", "Spinarak", "Ariados", "Crobat", "Chinchou",
        "Lanturn", "Pichu", "Cleffa", "Igglybuff", "Togepi", "Togetic", "Natu",
        "Xatu", "Mareep", "Flaaffy", "Ampharos", "Bellossom", "Marill", "Azumarill",
        "Sudowoodo", "Politoed", "Hoppip", "Skiploom", "Jumpluff", "Aipom",
        "Sunkern", "Sunflora", "Yanma", "Wooper", "Quagsire", "Espeon", "Umbreon",
        "Murkrow", "Slowking", "Misdreavus", "Unown", "Wobbuffet", "Girafarig",
        "Pineco", "Forretress", "Dunsparce", "Gligar", "Steelix", "Snubbull",
        "Granbull", "Qwilfish", "Scizor", "Shuckle", "Heracross", "Sneasel",
        "Teddiursa", "Ursaring", "Slugma", "Magcargo", "Swinub", "Piloswine",
        "Corsola", "Remoraid", "Octillery", "Delibird", "Mantine", "Skarmory",
        "Houndour", "Houndoom", "Kingdra", "Phanpy", "Donphan", "Porygon2",
        "Stantler", "Smeargle", "Tyrogue", "Hitmontop", "Smoochum", "Elekid",
        "Magby", "Miltank", "Blissey", "Raikou", "Entei", "Suicune", "Larvitar",
        "Pupitar", "Tyranitar", "Lugia", "Ho-Oh", "Celebi",
    ]

    // Discover characters actually bundled (must have Walk-Anim.png). Robust to
    // missing dex numbers so partial downloads just don't appear in the list.
    static let all: [CharacterInfo] = discover()

    private static func discover() -> [CharacterInfo] {
        guard let root = Bundle.main.resourceURL?.appendingPathComponent("characters") else { return [] }
        let fm = FileManager.default
        let subs = (try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil,
                                                options: [.skipsHiddenFiles])) ?? []
        var infos: [CharacterInfo] = []
        for url in subs {
            let folder = url.lastPathComponent
            guard fm.fileExists(atPath: url.appendingPathComponent("Walk-Anim.png").path) else { continue }
            let dex = Int(folder) ?? 0
            let fallback = (dex >= 1 && dex <= names.count) ? names[dex - 1] : folder
            let key = "pokemon.\(folder)"
            let loc = L(key)                     // localized name (ko/ja); key echoes back if absent
            let disp = (loc == key) ? fallback : loc
            infos.append(.init(folder: folder, name: "\(folder) · \(disp)"))
        }
        return infos.sorted { $0.folder < $1.folder }
    }

    static func index(of folder: String) -> Int {
        all.firstIndex { $0.folder == folder } ?? 0
    }

    /// Localized species display name (no folder prefix) for a 3-digit id.
    static func displayName(_ folder: String) -> String {
        let dex = Int(folder) ?? 0
        let fallback = (dex >= 1 && dex <= names.count) ? names[dex - 1] : folder
        let key = "pokemon.\(folder)"
        let loc = L(key)
        return (loc == key) ? fallback : loc
    }
}

// MARK: - Settings (persisted in UserDefaults)
final class AppSettings {
    static let shared = AppSettings()
    private let d = UserDefaults.standard

    static let gapRange: ClosedRange<Double> = 0...200
    static let speedRange: ClosedRange<Double> = 2...25
    static let scaleRange: ClosedRange<Double> = 1...5
    static let sleepRange: ClosedRange<Double> = 5...120
    static let encounterRange: ClosedRange<Double> = 5...90   // avg minutes (D9)

    private func get(_ key: String, _ def: Double) -> CGFloat {
        d.object(forKey: key) == nil ? CGFloat(def) : CGFloat(d.double(forKey: key))
    }

    var followGap: CGFloat {
        get { get("followGap", 100) }
        set { d.set(Double(newValue), forKey: "followGap") }
    }
    var maxSpeed: CGFloat {
        get { get("maxSpeed", 5) }
        set { d.set(Double(newValue), forKey: "maxSpeed") }
    }
    var scale: CGFloat {
        get { get("scale", 2) }
        set { d.set(Double(newValue), forKey: "scale") }
    }
    var sleepDelay: CGFloat {
        get { get("sleepDelay", 30) }
        set { d.set(Double(newValue), forKey: "sleepDelay") }
    }
    var selectedCharacter: String {
        get { d.string(forKey: "character") ?? "007" }
        set { d.set(newValue, forKey: "character") }
    }
    var showShadow: Bool {
        get { d.bool(forKey: "showShadow") }   // defaults to false when unset
        set { d.set(newValue, forKey: "showShadow") }
    }
    // Use the alternate-color sprite variant when a character has one.
    var altColor: Bool {
        get { d.bool(forKey: "altColor") }
        set { d.set(newValue, forKey: "altColor") }
    }
    // Raising mode vs. the normal follower. Design: design/raising-mode.md.
    var raisingMode: Bool {
        get { d.bool(forKey: "raisingMode") }   // defaults to false when unset
        set { d.set(newValue, forKey: "raisingMode") }
    }
    // Average minutes between wild encounters (D9: 빈도는 설정 조절).
    var encounterMinutes: CGFloat {
        get { get("encounterMinutes", 45) }
        set { d.set(Double(newValue), forKey: "encounterMinutes") }
    }
    // Master switches for wild encounters / item spawns (default on).
    var wildSpawnsEnabled: Bool {
        get { d.object(forKey: "wildSpawnsEnabled") == nil ? true : d.bool(forKey: "wildSpawnsEnabled") }
        set { d.set(newValue, forKey: "wildSpawnsEnabled") }
    }
    var itemSpawnsEnabled: Bool {
        get { d.object(forKey: "itemSpawnsEnabled") == nil ? true : d.bool(forKey: "itemSpawnsEnabled") }
        set { d.set(newValue, forKey: "itemSpawnsEnabled") }
    }
}

// MARK: - Sprite loading / slicing
enum Sprite {
    static func loadCG(_ name: String, subdir: String) -> CGImage? {
        guard let url = Bundle.main.url(forResource: name, withExtension: "png", subdirectory: subdir),
              let data = try? Data(contentsOf: url),
              let src = CGImageSourceCreateWithData(data as CFData, nil),
              let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return nil }
        return img
    }

    static func loadText(_ name: String, ext: String, subdir: String) -> String? {
        guard let url = Bundle.main.url(forResource: name, withExtension: ext, subdirectory: subdir) else { return nil }
        return try? String(contentsOf: url, encoding: .utf8)
    }

    // Slice into [row][col] frames (top-left origin). Cells may be non-square.
    static func slice(_ image: CGImage, cols: Int, rows: Int, cellW: Int, cellH: Int) -> [[CGImage]] {
        var out: [[CGImage]] = []
        for r in 0..<rows {
            var rowArr: [CGImage] = []
            for c in 0..<cols {
                let rect = CGRect(x: c * cellW, y: r * cellH, width: cellW, height: cellH)
                if let cg = image.cropping(to: rect) { rowArr.append(cg) }
            }
            out.append(rowArr)
        }
        return out
    }

    // Shadow marker center from a PMD "-Shadow" sheet cell, in image (top-left
    // origin) pixel coords. The sheet marks the shadow center with a single white
    // pixel (inside nested blue/red/green size regions); prefer that, else fall
    // back to the centroid of all opaque pixels. Returns nil if the cell is empty.
    // Shadow marker read from a PMD "-Shadow" cell: the ground-contact center
    // (white pixel) and the footprint size for the given ShadowSize, taken from
    // the nested color regions (green = small, red = medium, blue = large; each
    // encloses the smaller ones). All in image (top-left origin) pixels; nil if
    // the cell has no marker.
    static func shadowMarker(_ img: CGImage, shadowSize: Int) -> (center: CGPoint, size: CGSize)? {
        let w = img.width, h = img.height
        guard w > 0, h > 0 else { return nil }
        var buf = [UInt8](repeating: 0, count: w * h * 4)
        guard let ctx = CGContext(data: &buf, width: w, height: h,
                                  bitsPerComponent: 8, bytesPerRow: w * 4,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
        var wx = 0.0, wy = 0.0, wn = 0                  // white center pixel(s)
        var cx = 0.0, cy = 0.0, cn = 0                  // any marker pixel (fallback center)
        var sMinX = w, sMinY = h, sMaxX = -1, sMaxY = -1  // footprint for selected size
        var aMinX = w, aMinY = h, aMaxX = -1, aMaxY = -1  // footprint of all regions (fallback)
        for y in 0..<h {                                // buffer row 0 is the top of the image
            let base = y * w * 4
            for x in 0..<w {
                if buf[base + x * 4 + 3] <= 10 { continue }
                let r = buf[base + x * 4], g = buf[base + x * 4 + 1], b = buf[base + x * 4 + 2]
                let white = r > 200 && g > 200 && b > 200
                let blue  = b > 200 && r < 80 && g < 80
                let red   = r > 200 && g < 80 && b < 80
                let green = g > 200 && r < 80 && b < 80
                guard white || blue || red || green else { continue }
                if white { wx += Double(x); wy += Double(y); wn += 1 }
                cx += Double(x); cy += Double(y); cn += 1
                if x < aMinX { aMinX = x }; if x > aMaxX { aMaxX = x }
                if y < aMinY { aMinY = y }; if y > aMaxY { aMaxY = y }
                // Nested selection: small ⊂ medium ⊂ large.
                let inSize = shadowSize <= 0 ? green
                           : shadowSize == 1 ? (green || red)
                           : (green || red || blue)
                if inSize || white {
                    if x < sMinX { sMinX = x }; if x > sMaxX { sMaxX = x }
                    if y < sMinY { sMinY = y }; if y > sMaxY { sMaxY = y }
                }
            }
        }
        guard aMaxX >= 0, cn > 0 else { return nil }
        let center = wn > 0 ? CGPoint(x: wx / Double(wn), y: wy / Double(wn))
                            : CGPoint(x: cx / Double(cn), y: cy / Double(cn))
        let size = sMaxX >= 0 ? CGSize(width: sMaxX - sMinX + 1, height: sMaxY - sMinY + 1)
                              : CGSize(width: aMaxX - aMinX + 1, height: aMaxY - aMinY + 1)
        return (center, size)
    }

    // Bounding box of non-transparent pixels, in image (top-left origin) pixel
    // coords. Returns nil if the frame is fully transparent.
    static func opaqueBBox(_ img: CGImage, alphaThreshold: UInt8 = 12) -> CGRect? {
        let w = img.width, h = img.height
        guard w > 0, h > 0 else { return nil }
        var alpha = [UInt8](repeating: 0, count: w * h)
        guard let ctx = CGContext(data: &alpha, width: w, height: h,
                                  bitsPerComponent: 8, bytesPerRow: w,
                                  space: CGColorSpaceCreateDeviceGray(),
                                  bitmapInfo: CGImageAlphaInfo.alphaOnly.rawValue) else { return nil }
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
        // Buffer row 0 is the top of the image (top-left origin).
        var minX = w, minY = h, maxX = -1, maxY = -1
        for y in 0..<h {
            let base = y * w
            for x in 0..<w where alpha[base + x] >= alphaThreshold {
                if x < minX { minX = x }
                if x > maxX { maxX = x }
                if y < minY { minY = y }
                if y > maxY { maxY = y }
            }
        }
        guard maxX >= 0 else { return nil }
        return CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)
    }

    // Read <FrameWidth>/<FrameHeight> for a named <Anim> from AnimData.xml text.
    static func frameSize(_ anim: String, in xml: String) -> (Int, Int)? {
        for block in xml.components(separatedBy: "</Anim>") where block.contains("<Name>\(anim)</Name>") {
            if let w = intBetween(block, "<FrameWidth>", "</FrameWidth>"),
               let h = intBetween(block, "<FrameHeight>", "</FrameHeight>") {
                return (w, h)
            }
        }
        return nil
    }

    // Read <ShadowSize> (0=small, 1=medium, 2=large). Defaults to medium.
    static func shadowSize(in xml: String) -> Int {
        return intBetween(xml, "<ShadowSize>", "</ShadowSize>") ?? 1
    }

    private static func intBetween(_ s: String, _ a: String, _ b: String) -> Int? {
        guard let r1 = s.range(of: a),
              let r2 = s.range(of: b, range: r1.upperBound..<s.endIndex) else { return nil }
        return Int(s[r1.upperBound..<r2.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines))
    }
}

// Per-frame shadow placement, in image pixels: where to draw the ellipse
// (offset is y-up from the tile center) and how big (footprint size).
struct ShadowAnchor {
    var offset: CGPoint
    var size: CGSize
}

// MARK: - Character Controller
// The "brain": tracks the character in GLOBAL screen coordinates and picks the
// current animation frame. Rendering is done separately by one SpriteView per
// screen, so the character can cross between displays (which each own a space).
/// Battle pose for a combatant during playback (design D2/D2-1).
enum BattlePose {
    case stand      // idle, facing the opponent
    case attack     // Attack-Anim (contact moves)
    case shoot      // Shoot-Anim (projectile moves; falls back to attack)
    case hurt       // Hurt-Anim while damage lands
    case sleep      // Sleep-Anim while asleep (loops)
}

final class CharacterController {
    private var idle: [[CGImage]] = []
    private var walk: [[CGImage]] = []
    private var sleep: [[CGImage]] = []
    private var faint: [[CGImage]] = []       // Faint-Anim (may be absent -> rotate fallback)
    private var attack: [[CGImage]] = []      // battle poses (D2-1); empty -> idle fallback
    private var shoot: [[CGImage]] = []
    private var hurt: [[CGImage]] = []
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
    private var vel = CGVector.zero
    private var started = false

    private var tickCounter = 0
    private var idleTicks = 0             // frames spent not moving (drives sleep)
    private var lastRow = 0

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
    private(set) var currentFrame: CGImage?
    private(set) var shadowSize = 1       // 0=small, 1=medium, 2=large (from AnimData.xml)
    private(set) var currentShadow = ShadowAnchor(offset: .zero, size: CGSize(width: 14, height: 6))
    var position: CGPoint { pos }

    init() { setCharacter(RaisingState.shared.followerFolder) }

    // Load a character's sheets, sizing frames from its AnimData.xml. Uses the
    // alt-color variant (characters/<folder>/altcolor) when enabled and present.
    func setCharacter(_ folder: String) {
        var subdir = "characters/\(folder)"
        if AppSettings.shared.altColor,
           Bundle.main.url(forResource: "AnimData", withExtension: "xml",
                           subdirectory: "\(subdir)/altcolor") != nil {
            subdir += "/altcolor"
        }
        let xml = Sprite.loadText("AnimData", ext: "xml", subdir: subdir)
        shadowSize = xml.map { Sprite.shadowSize(in: $0) } ?? 1
        walk = slicedSheet("Walk-Anim", anim: "Walk", subdir: subdir, xml: xml)
        idle = slicedSheet("Idle-Anim", anim: "Idle", subdir: subdir, xml: xml)
        sleep = slicedSheet("Sleep-Anim", anim: "Sleep", subdir: subdir, xml: xml)
        // Prefer the current (alt-color) folder's battle sheets; fall back to
        // the base folder when the variant doesn't ship them.
        faint = slicedSheet("Faint-Anim", anim: "Faint", subdir: subdir, xml: xml)
        attack = slicedSheet("Attack-Anim", anim: "Attack", subdir: subdir, xml: xml)
        shoot = slicedSheet("Shoot-Anim", anim: "Shoot", subdir: subdir, xml: xml)
        hurt = slicedSheet("Hurt-Anim", anim: "Hurt", subdir: subdir, xml: xml)
        let baseSubdir = "characters/\(folder)"
        if subdir != baseSubdir {
            let baseXml = Sprite.loadText("AnimData", ext: "xml", subdir: baseSubdir)
            if faint.isEmpty { faint = slicedSheet("Faint-Anim", anim: "Faint", subdir: baseSubdir, xml: baseXml) }
            if attack.isEmpty { attack = slicedSheet("Attack-Anim", anim: "Attack", subdir: baseSubdir, xml: baseXml) }
            if shoot.isEmpty { shoot = slicedSheet("Shoot-Anim", anim: "Shoot", subdir: baseSubdir, xml: baseXml) }
            if hurt.isEmpty { hurt = slicedSheet("Hurt-Anim", anim: "Hurt", subdir: baseSubdir, xml: baseXml) }
        }
        if shoot.isEmpty { shoot = attack }   // 37 species ship no Shoot sheet
        // Shadow anchors from the matching -Shadow marker sheet (alpha fallback
        // if a marker sheet is missing). Computed before the sheet fallbacks so
        // each maps to its own frames.
        walkShadow = markerShadow("Walk-Shadow", anim: "Walk", subdir: subdir, xml: xml, fallback: walk)
        idleShadow = idle.isEmpty ? [] : markerShadow("Idle-Shadow", anim: "Idle", subdir: subdir, xml: xml, fallback: idle)
        sleepShadow = sleep.isEmpty ? [] : markerShadow("Sleep-Shadow", anim: "Sleep", subdir: subdir, xml: xml, fallback: sleep)
        if idle.isEmpty { idle = walk; idleShadow = walkShadow }     // some characters ship Walk only
        if sleep.isEmpty { sleep = idle; sleepShadow = idleShadow }  // fall back when no sleep animation
        loaded = !walk.isEmpty
        tickCounter = 0
        idleTicks = 0
        if !loaded { NSLog("PokemonMouseFollower: failed to load character \(folder)") }
    }

    // Load a sheet PNG and slice it into [row][col] cells using AnimData frame
    // sizes (falling back to square cells across 8 direction rows).
    private func slicedSheet(_ png: String, anim: String, subdir: String, xml: String?) -> [[CGImage]] {
        guard let img = Sprite.loadCG(png, subdir: subdir) else { return [] }
        var cw = img.height / 8, ch = img.height / 8
        if let xml, let (w, h) = Sprite.frameSize(anim, in: xml) { cw = w; ch = h }
        guard cw > 0, ch > 0 else { return [] }
        let rows = max(1, img.height / ch)
        let cols = max(1, img.width / cw)
        return Sprite.slice(img, cols: cols, rows: rows, cellW: cw, cellH: ch)
    }

    // Per-frame shadow anchor from the "-Shadow" marker sheet: position (y-up
    // offset from the tile center) and footprint size, both read from the marker
    // regions. Falls back to alpha-based feet detection if the sheet is absent.
    private func markerShadow(_ png: String, anim: String, subdir: String,
                              xml: String?, fallback: [[CGImage]]) -> [[ShadowAnchor]] {
        let cells = slicedSheet(png, anim: anim, subdir: subdir, xml: xml)
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
    private func shadowAnchors(_ sheet: [[CGImage]]) -> [[ShadowAnchor]] {
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

        var desired = CGVector.zero
        if remaining > 0.001 && dist > 0.001 {
            let dir = CGVector(dx: dx / dist, dy: dy / dist)
            let speedWanted = remaining < slowRadius ? maxSpeed * (remaining / slowRadius) : maxSpeed
            desired = CGVector(dx: dir.dx * speedWanted, dy: dir.dy * speedWanted)
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
            var deg = atan2(vel.dy, vel.dx) * 180 / .pi
            if deg < 0 { deg += 360 }
            let octant = Int((deg / 45).rounded()) % 8
            lastRow = octantToRow[octant]
        } else {
            idleTicks += 1
        }

        // Idle long enough -> sleep.
        let sleeping = !moving && CGFloat(idleTicks) / fps >= AppSettings.shared.sleepDelay

        let sheet: [[CGImage]]
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
    func face(_ point: CGPoint, pose: BattlePose = .stand, poseTick: Int = 0) {
        guard loaded else { return }
        faintRotation = 0   // healed/awake — clear the fallback faint tilt
        let dx = point.x - pos.x, dy = point.y - pos.y
        if abs(dx) > 0.01 || abs(dy) > 0.01 {
            var deg = atan2(dy, dx) * 180 / .pi
            if deg < 0 { deg += 360 }
            lastRow = octantToRow[Int((deg / 45).rounded()) % 8]
        }
        let poseSheet: [[CGImage]]
        switch pose {
        case .attack: poseSheet = attack
        case .shoot: poseSheet = shoot
        case .hurt: poseSheet = hurt
        case .sleep: poseSheet = sleep
        case .stand: poseSheet = []
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

    /// Restart the faint sequence (call once when the mon is knocked out).
    func startFaint() { faintTick = 0 }

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

// MARK: - UI style (cute, Pokémon-flavored settings look)
extension NSFont {
    /// Friendly rounded system font; falls back to the default if unavailable.
    static func rounded(_ size: CGFloat, _ weight: NSFont.Weight = .regular) -> NSFont {
        let base = NSFont.systemFont(ofSize: size, weight: weight)
        guard let d = base.fontDescriptor.withDesign(.rounded) else { return base }
        return NSFont(descriptor: d, size: size) ?? base
    }
}
enum Palette {
    static func dynamic(_ light: NSColor, _ dark: NSColor) -> NSColor {
        NSColor(name: nil) { $0.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light }
    }
    static let accent = NSColor(srgbRed: 1.0, green: 0.44, blue: 0.42, alpha: 1)   // warm coral-red
    static let windowBG = dynamic(NSColor(srgbRed: 1.0, green: 0.98, blue: 0.95, alpha: 1),
                                  NSColor(srgbRed: 0.11, green: 0.11, blue: 0.13, alpha: 1))
    static let cardTop = dynamic(.white, NSColor(srgbRed: 0.18, green: 0.18, blue: 0.20, alpha: 1))
    static let cardBottom = dynamic(NSColor(srgbRed: 0.96, green: 0.95, blue: 1.0, alpha: 1),
                                    NSColor(srgbRed: 0.14, green: 0.14, blue: 0.16, alpha: 1))
    static let cardBorder = dynamic(NSColor(srgbRed: 0.90, green: 0.88, blue: 0.94, alpha: 1),
                                    NSColor(srgbRed: 0.30, green: 0.30, blue: 0.34, alpha: 1))
    static let label = dynamic(NSColor(srgbRed: 0.38, green: 0.35, blue: 0.42, alpha: 1),
                               NSColor(srgbRed: 0.80, green: 0.80, blue: 0.84, alpha: 1))
}

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
        var subdir = "characters/\(folder)"
        if AppSettings.shared.altColor,
           Bundle.main.url(forResource: "AnimData", withExtension: "xml",
                           subdirectory: "\(subdir)/altcolor") != nil {
            subdir += "/altcolor"
        }
        let xml = Sprite.loadText("AnimData", ext: "xml", subdir: subdir)
        for (png, anim) in [("Idle-Anim", "Idle"), ("Walk-Anim", "Walk")] {
            guard let img = Sprite.loadCG(png, subdir: subdir) else { continue }
            var cw = img.height / 8, ch = img.height / 8
            if let xml, let (w, h) = Sprite.frameSize(anim, in: xml) { cw = w; ch = h }
            guard cw > 0, ch > 0 else { continue }
            let rows = max(1, img.height / ch), cols = max(1, img.width / cw)
            let sheet = Sprite.slice(img, cols: cols, rows: rows, cellW: cw, cellH: ch)
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

// MARK: - Settings Window
final class SettingsWindowController: NSObject {
    let window: NSWindow
    private weak var controller: CharacterController?
    private var valueLabels: [Int: NSTextField] = [:]
    private var popup: NSPopUpButton!
    private var preview: CharacterPreviewView!
    private var raisingPanel: RaisingPanelView?
    private let raisingPanelWidth: CGFloat = 340
    private var grid: NSGridView!
    private var topStack: NSStackView!      // character preview area (normal mode only)
    private var outer: NSStackView!
    private var leftHeightC: NSLayoutConstraint!
    private var dividerHeightC: NSLayoutConstraint!
    private var panelHeightC: NSLayoutConstraint!

    init(controller: CharacterController) {
        self.controller = controller
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 596),
                          styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = L("settings.window.title")
        window.isReleasedWhenClosed = false
        window.backgroundColor = Palette.windowBG
        super.init()
        buildUI()
        window.center()
    }

    private func buildUI() {
        let s = AppSettings.shared
        grid = NSGridView()
        grid.translatesAutoresizingMaskIntoConstraints = false
        grid.rowSpacing = 16
        grid.columnSpacing = 12

        popup = makePopup()
        grid.addRow(with: [makeLabel(L("label.character")), popup, NSGridCell.emptyContentView])
        grid.addRow(with: [makeLabel(L("label.distance")),
                           makeSlider(tag: 0, range: AppSettings.gapRange, value: Double(s.followGap)),
                           makeValueLabel(0, text: fmt(0, s.followGap))])
        grid.addRow(with: [makeLabel(L("label.speed")),
                           makeSlider(tag: 1, range: AppSettings.speedRange, value: Double(s.maxSpeed)),
                           makeValueLabel(1, text: fmt(1, s.maxSpeed))])
        grid.addRow(with: [makeLabel(L("label.size")),
                           makeSlider(tag: 2, range: AppSettings.scaleRange, value: Double(s.scale)),
                           makeValueLabel(2, text: fmt(2, s.scale))])
        grid.addRow(with: [makeLabel(L("label.sleep")),
                           makeSlider(tag: 3, range: AppSettings.sleepRange, value: Double(s.sleepDelay)),
                           makeValueLabel(3, text: fmt(3, s.sleepDelay))])
        grid.addRow(with: [makeLabel(L("label.altcolor")), makeAltColorCheckbox(), NSGridCell.emptyContentView])
        grid.addRow(with: [makeLabel(L("label.shadow")), makeShadowCheckbox(), NSGridCell.emptyContentView])
        grid.addRow(with: [makeLabel(L("label.launch")), makeLaunchCheckbox(), NSGridCell.emptyContentView])
        grid.addRow(with: [makeLabel(L("label.raising")), makeRaisingCheckbox(), NSGridCell.emptyContentView])

        grid.column(at: 0).xPlacement = .trailing
        grid.column(at: 1).width = 180

        // Preview of the selected character (down-facing idle) with prev/next
        // arrows, plus a random picker — above the character dropdown.
        preview = CharacterPreviewView(frame: NSRect(x: 0, y: 0, width: 96, height: 96))
        preview.translatesAutoresizingMaskIntoConstraints = false
        preview.widthAnchor.constraint(equalToConstant: 96).isActive = true
        preview.heightAnchor.constraint(equalToConstant: 96).isActive = true
        let previewRow = NSStackView(views: [makeStepButton("‹", #selector(prevCharacter)),
                                             preview,
                                             makeStepButton("›", #selector(nextCharacter))])
        previewRow.orientation = .horizontal
        previewRow.alignment = .centerY
        previewRow.spacing = 16
        topStack = NSStackView(views: [previewRow, makeRandomButton()])
        topStack.orientation = .vertical
        topStack.alignment = .centerX
        topStack.spacing = 12

        outer = NSStackView(views: [topStack, grid])
        outer.orientation = .vertical
        outer.alignment = .centerX
        outer.spacing = 22
        outer.translatesAutoresizingMaskIntoConstraints = false

        let content = window.contentView!

        // Left column holds the existing settings at a fixed width; the raising
        // panel lives to its right and is revealed by widening the window.
        let leftColumn = NSView()
        leftColumn.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(leftColumn)
        leftColumn.addSubview(outer)

        let divider = NSBox()
        divider.boxType = .separator
        divider.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(divider)

        let panel = RaisingPanelView(frame: .zero)
        panel.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(panel)
        raisingPanel = panel

        // NOTE: pin only tops + fixed heights (never subview.bottom == content.bottom),
        // otherwise NSWindow shrink-wraps its height to the Auto Layout fitting size
        // and the window collapses to the title bar. The height constants are
        // retuned to the actual content by applyWindowSize().
        leftHeightC = leftColumn.heightAnchor.constraint(equalToConstant: 596)
        dividerHeightC = divider.heightAnchor.constraint(equalToConstant: 572)
        panelHeightC = panel.heightAnchor.constraint(equalToConstant: 596)
        NSLayoutConstraint.activate([
            leftColumn.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            leftColumn.topAnchor.constraint(equalTo: content.topAnchor),
            leftColumn.widthAnchor.constraint(equalToConstant: 400),
            leftHeightC,
            outer.centerXAnchor.constraint(equalTo: leftColumn.centerXAnchor),
            outer.topAnchor.constraint(equalTo: leftColumn.topAnchor, constant: 26),

            divider.leadingAnchor.constraint(equalTo: leftColumn.trailingAnchor),
            divider.topAnchor.constraint(equalTo: content.topAnchor, constant: 12),
            dividerHeightC,
            divider.widthAnchor.constraint(equalToConstant: 1),

            panel.leadingAnchor.constraint(equalTo: divider.trailingAnchor),
            panel.topAnchor.constraint(equalTo: content.topAnchor),
            panel.widthAnchor.constraint(equalToConstant: raisingPanelWidth),
            panelHeightC,
        ])

        preview.setCharacter(AppSettings.shared.selectedCharacter)
        updateModeVisibility()
        panel.onContentChanged = { [weak self] in self?.applyWindowSize(animate: false) }

        if AppSettings.shared.raisingMode {
            panel.refresh()
        }
        applyWindowSize(animate: false)
    }

    /// In raising mode the follower IS the active raising mon, so the whole
    /// character-picker area (preview, arrows, random, dropdown) is moot.
    private func updateModeVisibility() {
        let raising = AppSettings.shared.raisingMode
        topStack.isHidden = raising
        grid.row(at: 0).isHidden = raising   // character dropdown row
    }

    /// Size the window to its actual content: the taller of the left column
    /// and (in raising mode) the panel — no dead space below either.
    private func applyWindowSize(animate: Bool) {
        let raising = AppSettings.shared.raisingMode
        outer.layoutSubtreeIfNeeded()
        let leftH = outer.fittingSize.height + 26 + 20
        var h = leftH
        if raising, let panel = raisingPanel {
            h = max(leftH, min(760, panel.contentHeight))
        }
        leftHeightC.constant = h
        dividerHeightC.constant = h - 24
        panelHeightC.constant = h
        let width: CGFloat = 400 + (raising ? raisingPanelWidth + 1 : 0)
        var f = window.frame
        let newH = h + (window.frame.height - (window.contentView?.frame.height ?? h))
        f.origin.y += f.size.height - newH     // keep the top edge where it was
        f.size.height = newH
        f.size.width = width
        window.setFrame(f, display: true, animate: animate)
    }


    private func makeStepButton(_ title: String, _ action: Selector) -> NSButton {
        let b = NSButton(title: "", target: self, action: action)
        b.bezelStyle = .rounded
        b.attributedTitle = NSAttributedString(string: title, attributes: [
            .foregroundColor: Palette.accent, .font: NSFont.rounded(20, .bold)])
        b.widthAnchor.constraint(equalToConstant: 42).isActive = true
        return b
    }

    private func makeRandomButton() -> NSButton {
        let b = NSButton(title: "", target: self, action: #selector(randomCharacter))
        b.bezelStyle = .rounded
        b.bezelColor = Palette.accent
        b.contentTintColor = .white
        b.attributedTitle = NSAttributedString(string: L("button.random"), attributes: [
            .foregroundColor: NSColor.white, .font: NSFont.rounded(13, .semibold)])
        if let dice = Self.diceIcon() {
            b.image = dice
            b.imagePosition = .imageLeading
        }
        return b
    }

    // A crisp vector dice icon (SF Symbol), tinted to match the button.
    private static func diceIcon() -> NSImage? {
        let cfg = NSImage.SymbolConfiguration(pointSize: 14, weight: .bold)
        for name in ["die.face.5", "die.face.6", "dice.fill", "dice"] {
            if let img = NSImage(systemSymbolName: name, accessibilityDescription: "Random")?
                .withSymbolConfiguration(cfg) {
                img.isTemplate = true
                return img
            }
        }
        return nil
    }

    private func makeShadowCheckbox() -> NSButton {
        let cb = NSButton(checkboxWithTitle: "", target: self, action: #selector(shadowToggled(_:)))
        cb.state = AppSettings.shared.showShadow ? .on : .off
        return cb
    }

    @objc private func shadowToggled(_ sender: NSButton) {
        AppSettings.shared.showShadow = (sender.state == .on)
    }

    private func makeAltColorCheckbox() -> NSButton {
        let cb = NSButton(checkboxWithTitle: "", target: self, action: #selector(altColorToggled(_:)))
        cb.state = AppSettings.shared.altColor ? .on : .off
        return cb
    }

    @objc private func altColorToggled(_ sender: NSButton) {
        AppSettings.shared.altColor = (sender.state == .on)
        controller?.setCharacter(RaisingState.shared.followerFolder)     // reload with/without variant
        preview.setCharacter(AppSettings.shared.selectedCharacter)       // refresh preview color
    }

    private func makeLaunchCheckbox() -> NSButton {
        let cb = NSButton(checkboxWithTitle: "", target: self, action: #selector(launchToggled(_:)))
        cb.state = LoginItem.isEnabled ? .on : .off
        return cb
    }

    @objc private func launchToggled(_ sender: NSButton) {
        let wantOn = sender.state == .on
        if !LoginItem.setEnabled(wantOn) {
            sender.state = wantOn ? .off : .on   // revert on failure
        }
    }

    private func makeRaisingCheckbox() -> NSButton {
        let cb = NSButton(checkboxWithTitle: "", target: self, action: #selector(raisingToggled(_:)))
        cb.state = AppSettings.shared.raisingMode ? .on : .off
        return cb
    }

    @objc private func raisingToggled(_ sender: NSButton) {
        let on = sender.state == .on
        AppSettings.shared.raisingMode = on
        updateModeVisibility()
        raisingPanel?.refresh()
        applyWindowSize(animate: true)
        NotificationCenter.default.post(name: .raisingChanged, object: nil)   // switch follower
    }

    private func makePopup() -> NSPopUpButton {
        let popup = NSPopUpButton(frame: .zero, pullsDown: false)
        popup.addItems(withTitles: Characters.all.map { $0.name })
        popup.selectItem(at: Characters.index(of: AppSettings.shared.selectedCharacter))
        popup.target = self
        popup.action = #selector(characterChanged(_:))
        return popup
    }

    private func makeLabel(_ text: String) -> NSTextField {
        let l = NSTextField(labelWithString: text)
        l.alignment = .right
        l.font = .rounded(13, .medium)
        l.textColor = Palette.label
        return l
    }

    private func makeValueLabel(_ tag: Int, text: String) -> NSTextField {
        let l = NSTextField(labelWithString: text)
        l.alignment = .left
        l.font = .rounded(13, .semibold)
        l.textColor = Palette.accent
        l.widthAnchor.constraint(equalToConstant: 44).isActive = true
        valueLabels[tag] = l
        return l
    }

    private func makeSlider(tag: Int, range: ClosedRange<Double>, value: Double) -> NSSlider {
        let slider = NSSlider(value: value, minValue: range.lowerBound, maxValue: range.upperBound,
                              target: self, action: #selector(sliderChanged(_:)))
        slider.tag = tag
        slider.isContinuous = true
        return slider
    }

    private func fmt(_ tag: Int, _ v: CGFloat) -> String {
        switch tag {
        case 2: return String(format: "%.1f×", v)
        case 3: return String(format: "%.0fs", v)
        default: return String(format: "%.0f", v)
        }
    }

    @objc private func characterChanged(_ sender: NSPopUpButton) {
        applyCharacter(Characters.all[sender.indexOfSelectedItem].folder)
    }

    @objc private func prevCharacter() { stepCharacter(-1) }
    @objc private func nextCharacter() { stepCharacter(1) }

    private func stepCharacter(_ delta: Int) {
        let all = Characters.all
        guard !all.isEmpty else { return }
        let i = Characters.index(of: AppSettings.shared.selectedCharacter)
        let n = ((i + delta) % all.count + all.count) % all.count
        applyCharacter(all[n].folder)
    }

    @objc private func randomCharacter() {
        let all = Characters.all
        guard !all.isEmpty else { return }
        applyCharacter(all[Int.random(in: 0..<all.count)].folder)
    }

    // Single place that switches character: persist, sync the dropdown, reload
    // the live follower, and refresh the preview.
    private func applyCharacter(_ folder: String) {
        AppSettings.shared.selectedCharacter = folder
        popup.selectItem(at: Characters.index(of: folder))
        controller?.setCharacter(RaisingState.shared.followerFolder)   // raising mon keeps priority
        preview.setCharacter(folder)
    }

    @objc private func sliderChanged(_ sender: NSSlider) {
        let v = CGFloat(sender.doubleValue)
        let s = AppSettings.shared
        switch sender.tag {
        case 0: s.followGap = v
        case 1: s.maxSpeed = v
        case 2: s.scale = v   // reflected on the next render tick
        case 3: s.sleepDelay = v
        default: break
        }
        valueLabels[sender.tag]?.stringValue = fmt(sender.tag, v)
    }

    func show() {
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }
}

// MARK: - App Delegate
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let controller = CharacterController()
    private let battle = BattleController()
    private let items = ItemSpawner()
    private var wasFainted = false
    private let evolution = EvolutionAnimator()   // mainline evolution scene (D8/#9)
    private var regenCounter = 0            // out-of-battle +1 HP tick (~30s)
    private var overlays: [(window: NSWindow, view: SpriteView)] = []
    private var statusItem: NSStatusItem!
    private var timer: Timer?
    private var running = true
    private var settingsController: SettingsWindowController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupWindows()
        setupStatusItem()
        setupTimer()
        NotificationCenter.default.addObserver(
            self, selector: #selector(screensChanged),
            name: NSApplication.didChangeScreenParametersNotification, object: nil)
        NotificationCenter.default.addObserver(
            self, selector: #selector(raisingChanged), name: .raisingChanged, object: nil)
        NotificationCenter.default.addObserver(
            self, selector: #selector(raisingEvolved(_:)), name: .raisingEvolved, object: nil)
        if CommandLine.arguments.contains("--show-settings") { showSettings() }
        // Debug: preview the on-overlay prompts (C1) without earning them.
        if ProcessInfo.processInfo.environment["PMF_TEST_PROMPT"] != nil,
           let mon = RaisingState.shared.active {
            PromptCenter.shared.enqueue(.learnMove(monIndex: 0, moveId: mon.moves.first ?? 154))
            PromptCenter.shared.enqueue(.fullParty(captured: mon))
        }
    }

    // The active raising mon (or the normal character) should be the follower.
    @objc private func raisingChanged() {
        controller.setCharacter(RaisingState.shared.followerFolder)
    }

    // A mon just evolved: play the mainline evolution scene in place
    // (silhouette -> accelerating morph -> white-out -> sparkly reveal).
    @objc private func raisingEvolved(_ note: Notification) {
        guard AppSettings.shared.raisingMode,
              let from = note.userInfo?["from"] as? Int,
              let to = note.userInfo?["to"] as? Int else { return }
        evolution.start(fromDex: from, toDex: to, at: controller.position)
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showSettings()
        return true
    }

    // One transparent overlay window per screen. A single window can't span
    // displays when "Displays have separate Spaces" is on, so we use one each.
    private func setupWindows() {
        for (w, _) in overlays { w.close() }   // deterministic teardown, no ghost windows
        overlays.removeAll()

        for screen in NSScreen.screens {
            let frame = screen.frame
            let window = NSWindow(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false   // ARC owns the lifetime via `overlays`
            window.isOpaque = false
            window.backgroundColor = .clear
            window.hasShadow = false
            window.ignoresMouseEvents = true
            window.level = .init(rawValue: Int(CGWindowLevelForKey(.overlayWindow)))
            window.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
            window.setFrame(frame, display: true)

            let view = SpriteView(frame: NSRect(origin: .zero, size: frame.size))
            view.screenOrigin = frame.origin
            view.isHidden = !running
            window.contentView = view
            window.orderFrontRegardless()

            overlays.append((window, view))
        }
    }

    @objc private func screensChanged() { setupWindows() }

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            if let img = NSImage(systemSymbolName: "pawprint.fill", accessibilityDescription: "Pokémon Mouse Follower") {
                img.isTemplate = true
                button.image = img
            } else {
                button.title = "🐾"
            }
        }
        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "Pokémon Mouse Follower", action: nil, keyEquivalent: ""))
        menu.addItem(.separator())
        let settings = NSMenuItem(title: L("menu.settings"), action: #selector(showSettings), keyEquivalent: ",")
        settings.target = self
        menu.addItem(settings)
        let toggle = NSMenuItem(title: L("menu.pause"), action: #selector(toggleRunning), keyEquivalent: "p")
        toggle.target = self
        menu.addItem(toggle)
        // Debug submenu: instant battles against curated opponents (each
        // exercises a status/effect path), plus item/EXP/heal shortcuts.
        let debug = NSMenuItem(title: "디버그", action: nil, keyEquivalent: "")
        let dm = NSMenu()
        func encounter(_ title: String, _ dex: Int) {
            let it = NSMenuItem(title: title, action: #selector(debugEncounter(_:)), keyEquivalent: "")
            it.target = self
            it.tag = dex
            dm.addItem(it)
        }
        encounter("즉시 배틀: 랜덤", 0)
        encounter("즉시 배틀: 피카츄 (마비)", 25)
        encounter("즉시 배틀: 슬리프 (최면술·에스퍼)", 96)
        encounter("즉시 배틀: 식스테일 (화상)", 37)
        encounter("즉시 배틀: 아보 (독)", 23)
        encounter("즉시 배틀: 루주라 (얼음·헤롱헤롱)", 124)
        encounter("즉시 배틀: 별가사리 (물대포)", 120)
        dm.addItem(.separator())
        let items = NSMenuItem(title: "테스트 아이템 지급", action: #selector(debugGiveItems), keyEquivalent: "")
        items.target = self
        dm.addItem(items)
        let heal = NSMenuItem(title: "파티 전체 회복", action: #selector(debugHealAll), keyEquivalent: "")
        heal.target = self
        dm.addItem(heal)
        let lvl = NSMenuItem(title: "활성 포켓몬 +1 레벨", action: #selector(debugLevelUp), keyEquivalent: "")
        lvl.target = self
        dm.addItem(lvl)
        let evo = NSMenuItem(title: "활성 포켓몬 진화 레벨까지", action: #selector(debugLevelToEvolution), keyEquivalent: "")
        evo.target = self
        dm.addItem(evo)
        let wander = NSMenuItem(title: "야생 스폰 (배회)", action: #selector(debugSpawn), keyEquivalent: "")
        wander.target = self
        dm.addItem(wander)
        dm.addItem(.separator())
        // Force a status on the active mon — it carries into the next battle,
        // so the skip/residual visuals are testable without RNG.
        for (title, key) in [("내 포켓몬: 마비", "paralysis"), ("내 포켓몬: 화상", "burn"),
                             ("내 포켓몬: 독", "poison"), ("내 포켓몬: 수면", "sleep"),
                             ("내 포켓몬: 얼음", "freeze"), ("내 포켓몬: 상태 해제", "")] {
            let it = NSMenuItem(title: title, action: #selector(debugSetStatus(_:)), keyEquivalent: "")
            it.target = self
            it.representedObject = key
            dm.addItem(it)
        }
        debug.submenu = dm
        menu.addItem(debug)
        menu.addItem(.separator())
        let quit = NSMenuItem(title: L("menu.quit"), action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
        statusItem.menu = menu
    }

    private func setupTimer() {
        let t = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            guard let self, self.running else { return }
            let cursor = NSEvent.mouseLocation
            // The evolution scene freezes the follower and takes over its
            // rendering until it completes (mainline behavior).
            let evoFrame = self.evolution.active ? self.evolution.update() : nil
            let evolving = evoFrame != nil
            // Recalled: a game is running but nobody is sent out — no follower.
            let recalled = AppSettings.shared.raisingMode
                && RaisingState.shared.hasActiveGame
                && RaisingState.shared.active == nil
            let fainted = AppSettings.shared.raisingMode
                && (RaisingState.shared.active?.isFainted ?? false)
            if evolving || recalled {
                // hold position; no walking/facing while evolving or recalled
            } else if fainted {
                // A knocked-out active mon plays the faint animation once and stays
                // put where it fell (it doesn't follow the cursor).
                if !self.wasFainted { self.controller.startFaint(); self.wasFainted = true }
                self.controller.updateFainted()
            } else {
                self.wasFainted = false
                if !self.battle.isBattling {
                    // Roams after the cursor; encounters happen by chance.
                    self.controller.update(mouseGlobal: cursor)
                }
            }
            let playerPos = evolving ? self.evolution.position : self.controller.position
            let scene = self.battle.update(playerGlobalPos: playerPos)
            if self.battle.isBattling, !evolving, let sc = scene {
                // Face the wild; play the battle pose the controller picked.
                self.controller.face(sc.wildPos, pose: sc.playerPose, poseTick: sc.playerPoseTick)
            }
            // Slow out-of-battle recovery: +1 HP to hurt members every ~30s.
            if AppSettings.shared.raisingMode && !self.battle.isBattling {
                self.regenCounter += 1
                if self.regenCounter >= 30 * 60 {
                    self.regenCounter = 0
                    RaisingState.shared.regenTick()
                }
            }
            // Items: the mon picks one up by walking over it (not mid-battle).
            let itemScene = self.items.update(followerPos: self.controller.position,
                                              canPickup: !self.battle.isBattling && !fainted && !recalled)
            // Sidestep offset while the follower dodges a missed attack (#10).
            var renderPos = playerPos
            if let sc = scene, !evolving {
                renderPos.x += sc.playerDodge.x
                renderPos.y += sc.playerDodge.y
            }
            for (_, view) in self.overlays {
                if let (frame, glow) = evoFrame {
                    view.render(frame, globalPos: renderPos,
                                shadow: self.controller.currentShadow, glow: glow)
                } else {
                    view.render(recalled ? nil : self.controller.currentFrame,
                                globalPos: renderPos,
                                shadow: self.controller.currentShadow,
                                rotation: self.controller.faintRotation)
                }
                view.renderBattle(scene)
                view.renderItem(itemScene)
            }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    @objc private func showSettings() {
        if settingsController == nil {
            settingsController = SettingsWindowController(controller: controller)
        }
        settingsController?.show()
    }

    @objc private func toggleRunning(_ sender: NSMenuItem) {
        running.toggle()
        sender.title = running ? L("menu.pause") : L("menu.resume")
        for (_, view) in overlays { view.isHidden = !running }
    }

    @objc private func debugSpawn() { battle.forceSpawn() }

    @objc private func debugEncounter(_ sender: NSMenuItem) {
        battle.forceEncounter(dex: sender.tag > 0 ? sender.tag : nil)
    }

    @objc private func debugGiveItems() {
        let st = RaisingState.shared
        st.addItem(.pokeBall, 5)
        st.addItem(.greatBall, 2)
        st.addItem(.potion, 3)
        st.addItem(.superPotion, 2)
        st.addItem(.revive, 2)
        for stone: GameItem in [.fireStone, .thunderStone, .waterStone, .leafStone,
                                .moonStone, .sunStone, .linkCord, .friendCandy] {
            st.addItem(stone, 1)
        }
    }

    @objc private func debugHealAll() {
        let st = RaisingState.shared
        for i in st.party.indices { st.healMon(at: i) }
    }

    @objc private func debugSetStatus(_ sender: NSMenuItem) {
        let key = sender.representedObject as? String ?? ""
        RaisingState.shared.setStatusDebug(key.isEmpty ? nil : key)
    }

    /// Grant EXP through the real growth path (level-ups, move prompts,
    /// evolution + burst) — exactly what a battle win would do.
    private func debugGainExp(_ amount: Int) {
        let st = RaisingState.shared
        guard st.hasActiveGame, amount > 0 else { return }
        let idx = st.save.activeIndex
        let result = st.gainExp(amount)
        for moveId in result.pendingMoves {
            PromptCenter.shared.enqueue(.learnMove(monIndex: idx, moveId: moveId))
        }
    }

    @objc private func debugLevelUp() {
        guard let mon = RaisingState.shared.active else { return }
        debugGainExp(mon.expToNext.remaining)
    }

    @objc private func debugLevelToEvolution() {
        let st = RaisingState.shared
        guard let mon = st.active, let s = mon.species, mon.level < 100 else { return }
        // Jump to the nearest LEVEL-evolution threshold above the current
        // level; species without one just gain a single level.
        let target = s.evolutions
            .filter { $0.method == "LEVEL" && $0.param1 > mon.level }
            .map(\.param1)
            .min()
        guard let target, s.expCurve.indices.contains(target - 1) else {
            debugLevelUp()
            return
        }
        debugGainExp(s.expCurve[target - 1] - mon.exp)
    }

    @objc private func quit() {
        NSApplication.shared.terminate(nil)
    }
}

// MARK: - Entry point

// Debug hook: `--dump-effect <moveId> <outDir>` writes the corrected effect
// clip's frames as PNGs (visual check of crop/tint/particle composition).
if let i = CommandLine.arguments.firstIndex(of: "--dump-effect"),
   CommandLine.arguments.count > i + 2, let moveId = Int(CommandLine.arguments[i + 1]) {
    let dir = URL(fileURLWithPath: CommandLine.arguments[i + 2])
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    func dump(_ clip: EffectClip?, _ prefix: String) {
        guard let clip else { return }
        for (n, s) in clip.steps.enumerated() {
            let u = dir.appendingPathComponent(String(format: "%@-%02d.png", prefix, n))
            if let d = CGImageDestinationCreateWithURL(u as CFURL, UTType.png.identifier as CFString, 1, nil) {
                CGImageDestinationAddImage(d, s.image, nil)
                CGImageDestinationFinalize(d)
            }
        }
        print("dumped \(prefix): \(clip.steps.count) steps (\(clip.totalTicks) ticks) for move \(moveId) → \(dir.path)")
    }
    dump(EffectPlayer.clip(forMove: moveId), "step")
    dump(EffectPlayer.projectile(forMove: moveId), "proj")
    dump(EffectPlayer.projectile(forMove: moveId, octant: 0), "projE")   // flying east
    exit(0)
}

// Debug hook: `--dump-icons <outDir>` writes every drawn item icon as PNG.
if let i = CommandLine.arguments.firstIndex(of: "--dump-icons"), CommandLine.arguments.count > i + 1 {
    let dir = URL(fileURLWithPath: CommandLine.arguments[i + 1])
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    for item in GameItem.allCases {
        guard let cg = item.icon,
              let d = CGImageDestinationCreateWithURL(
                dir.appendingPathComponent("\(item.rawValue)-\(item.nameKey).png") as CFURL,
                UTType.png.identifier as CFString, 1, nil) else { continue }
        CGImageDestinationAddImage(d, cg, nil)
        CGImageDestinationFinalize(d)
    }
    print("dumped \(GameItem.allCases.count) icons → \(dir.path)")
    exit(0)
}

// Debug hook: `--dump-evolution <fromDex> <toDex> <outDir>` writes the
// evolution scene's frames (every 10 ticks) for a visual check.
if let i = CommandLine.arguments.firstIndex(of: "--dump-evolution"),
   CommandLine.arguments.count > i + 3,
   let fromDex = Int(CommandLine.arguments[i + 1]), let toDex = Int(CommandLine.arguments[i + 2]) {
    let dir = URL(fileURLWithPath: CommandLine.arguments[i + 3])
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let anim = EvolutionAnimator()
    anim.start(fromDex: fromDex, toDex: toDex, at: .zero)
    var n = 0, tick = 0
    while let (frame, glow) = anim.update() {
        if tick % 10 == 0 {
            let u = dir.appendingPathComponent(String(format: "e%03d-g%02.0f.png", tick, glow * 10))
            if let d = CGImageDestinationCreateWithURL(u as CFURL, UTType.png.identifier as CFString, 1, nil) {
                CGImageDestinationAddImage(d, frame, nil)
                CGImageDestinationFinalize(d)
                n += 1
            }
        }
        tick += 1
    }
    print("dumped \(n) evolution frames over \(tick) ticks → \(dir.path)")
    exit(0)
}

// Debug hook: `--selftest-raising` exercises the raising-mode data/state layer
// against the bundled game data, prints a report, and exits. Harmless otherwise.
if CommandLine.arguments.contains("--selftest-raising") {
    print("GameData: species=\(GameData.species.count) moves=\(GameData.moves.count) starters=\(GameData.starters.count)")
    let st = RaisingState.shared
    st.reset()
    st.startNewGame(dex: 1)
    if let m = st.active, let s = m.species {
        let sv = GameData.stats(s, level: m.level)
        print("start: \(Characters.displayName(s.id)) Lv\(m.level) \(m.gender.rawValue) HP=\(m.currentHP)/\(m.maxHP) ATK\(sv.atk) DEF\(sv.def) moves=\(m.moves)")
    } else { print("start FAILED — GameData not loaded from bundle?") }
    // Growth: give enough EXP to level up through the L16 evolution.
    st.setActive(0)
    let g = st.gainExp(50000)
    if let m = st.active {
        let evo = (g.evolvedFrom != nil) ? "\(g.evolvedFrom!)->\(g.evolvedTo!)" : "none"
        print("train: Lv\(m.level) dex=\(m.dex) \(Characters.displayName(String(format: "%03d", m.dex))) moves=\(m.moves) evolved=\(evo) auto=\(g.learnedMoves) pending=\(g.pendingMoves)")
        let (left, frac) = m.expToNext
        print("exp gauge: toNext=\(left) frac=\(String(format: "%.2f", frac)) (expect 0<frac<1, left>0)")
    }
    print("followerFolder(raising off)=\(st.followerFolder)")
    // Battle: active mon vs a wild Pidgey (dex 16).
    print("typechart types=\(TypeChart.chart.count)")
    if let p = Battler(mon: st.active!), let w = Battler(wildDex: 16, level: 12) {
        let r = BattleEngine.run(player: p, wild: w)
        print("battle: \(p.name) L\(p.level) \(p.gender.rawValue) vs wild \(w.name) L\(w.level) \(w.gender.rawValue) → \(r.playerWon ? "WIN" : "LOSE") in \(r.events.count) events, exp=\(r.expGained) (base \(w.baseExp)), endStatus=\(r.playerEndStatus ?? "none")")
        for e in r.events.prefix(4) {
            print("  \(e.actorIsPlayer ? "▶" : "◀") [\(e.kind)] \(e.moveName): \(e.damage) dmg x\(e.effectiveness) (tgt \(e.targetIsPlayer ? "P" : "W") HP \(e.targetHP)/\(e.targetMaxHP))\(e.statusApplied.map { " +\($0)" } ?? "")\(e.fainted ? " FAINT" : "")")
        }
    }
    // Status conditions (D19): Thunder Wave-style paralysis + burn chip damage.
    if let p = Battler(wildDex: 25, level: 20), let w = Battler(wildDex: 16, level: 18) {
        let r = BattleEngine.run(player: p, wild: w)
        let statuses = r.events.compactMap { $0.statusApplied }
        let kinds = Set(r.events.map { "\($0.kind)" })
        print("status battle: Pikachu vs Pidgey → statuses=\(statuses) kinds=\(kinds.sorted())")
    }
    // Move-effect sprites (D22): mapping + frames load from the bundle.
    print("move effects mapped=\(MoveEffects.map.count)")
    for (label, id) in [("Tackle", 154), ("Ember", 262), ("Thunderbolt", 129)] {
        if let c = EffectPlayer.clip(forMove: id) {
            print("  effect \(label): steps=\(c.steps.count) ticks=\(c.totalTicks) loop=\(c.loop) head=\(c.headAnchored)")
        } else { print("  effect \(label): MISSING") }
    }
    // Status visuals: every condition resolves to a playable proxy clip.
    let statusKeys = ["burn", "poison", "paralyzed", "frozen", "infatuated"]
    print("status clips:", statusKeys.map { "\($0)=\(EffectPlayer.statusClip($0) != nil ? "ok" : "MISSING")" }.joined(separator: " "))
    // Gender ratios (G): Magnemite genderless, Nidoran♀ always female, Chansey female.
    for d in [81, 29, 113] {
        if let s = GameData.species[d] {
            let g = (0..<6).map { _ in Gender.random(genderRate: s.genderRate).rawValue.prefix(1) }.joined()
            print("gender \(s.displayName) rate=\(s.genderRate ?? 99): \(g)")
        }
    }
    // Capture (D11): a hurt, statused, high-catch-rate wild should catch fast.
    if let w = Battler(wildDex: 16, level: 5) {   // Pidgey, capture_rate 255
        w.currentHP = 1
        w.status = .sleep
        var caught = 0
        for _ in 0..<20 where BattleEngine.attemptCapture(wild: w, ball: .pokeBall).0 { caught += 1 }
        print("capture: Pidgey 1HP asleep — \(caught)/20 throws caught (expect most)")
    }
    // Items: inventory round-trip + a full engine run with balls.
    st.addItem(.pokeBall, 3)
    st.addItem(.potion)
    // A slight level edge: the wild survives into the 50% throw window but
    // the player reliably lives long enough to throw.
    if let p2 = Battler(wildDex: 7, level: 7), let w2 = Battler(wildDex: 16, level: 5) {
        let r = BattleEngine.run(player: p2, wild: w2, balls: [.pokeBall, .pokeBall, .pokeBall])
        let ballEvents = r.events.filter { $0.kind == .ball }
            .map { "\($0.shakes)s" + ($0.caught ? "O" : "X") }
        print("ball battle: thrown=\(r.ballsUsed.count) events=\(ballEvents) captured=\(r.captured)")
        if r.captured { _ = st.addCaptured(from: w2); print("party after capture=\(st.party.count)") }
    }
    print("bag: pokeball=\(st.itemCount(.pokeBall)) potion=\(st.itemCount(.potion)) canUsePotionOnHurt=\(st.canUseItem(.potion, at: 0))")
    // Wild battle-pose sheets actually load (attack frame differs from idle).
    if let wm = WildMon(dex: 7) {
        wm.place(at: .zero)
        wm.faceStanding(toward: CGPoint(x: 10, y: 0))
        let idleFrame = wm.currentFrame
        wm.faceStanding(toward: CGPoint(x: 10, y: 0), pose: .attack, poseTick: 12)
        let atkDistinct = wm.currentFrame !== idleFrame
        wm.faceStanding(toward: CGPoint(x: 10, y: 0), pose: .hurt, poseTick: 6)
        let hurtDistinct = wm.currentFrame !== idleFrame
        print("wild pose sheets: attack distinct=\(atkDistinct) hurt distinct=\(hurtDistinct) (expect true true)")
    }
    // Over-leveled capture evolves on the next level (#11): Lv20 Caterpie -> Metapod at 21.
    let caterpie = st.makeMon(species: GameData.species[10]!, level: 20)
    _ = st.addToParty(caterpie)
    st.setActive(st.party.count - 1)
    let need = (GameData.species[10]!.expCurve[20]) - caterpie.exp
    let g11 = st.gainExp(need)
    print("overlevel evo: Lv\(st.active!.level) dex=\(st.active!.dex) evolved=\(g11.evolvedFrom ?? 0)->\(g11.evolvedTo ?? 0) (expect 10->11)")
    st.setActive(0)
    // Wild pool (#12): evolved forms gated by their LEVEL thresholds.
    print("minWildLevel: Metapod=\(GameData.minWildLevel[11] ?? -1) Butterfree=\(GameData.minWildLevel[12] ?? -1) Charizard=\(GameData.minWildLevel[6] ?? -1) Pikachu=\(GameData.minWildLevel[25] ?? -1)")
    print("wildPool(5) has Butterfree: \(GameData.wildPool(atLevel: 5).contains(12)) (expect false), size=\(GameData.wildPool(atLevel: 5).count)")
    // Overlay-prompt state ops (C1): full-party capture resolve + indexed learnMove.
    if let w3 = Battler(wildDex: 25, level: 9), let cap = st.capturedMon(from: w3), let s16 = GameData.species[16] {
        while st.partyHasRoom { _ = st.addToParty(st.makeMon(species: s16, level: 4)) }
        st.resolveCapture(cap, releasing: 0)
        print("fullparty resolve: party=\(st.party.count)/6 last=\(st.party.last!.dex) (expect 25)")
        st.learnMove(999, replacing: 0, at: 1)
        print("indexed learnMove: party[1].moves[0]=\(st.party[1].moves.first ?? -1) (expect 999)")
    }
    // Headless battle playback: force a contact encounter and tick the
    // controller through the whole fight, counting effect frames drawn.
    do {
        let hadRaising = AppSettings.shared.raisingMode
        AppSettings.shared.raisingMode = true
        let bc = BattleController()
        let p = CGPoint(x: 500, y: 500)
        bc.forceSpawn(at: CGPoint(x: 520, y: 500))    // inside battle range
        var effectFrames = 0, battleTicks = 0
        let trace = ProcessInfo.processInfo.environment["PMF_TRACE_BATTLE"] != nil
        var hadFX = false, hadFlashP = false, hadFlashW = false
        var lastPose = BattlePose.stand
        for tick in 0..<20_000 {
            let scene = bc.update(playerGlobalPos: p)
            if bc.isBattling { battleTicks += 1 }
            if scene?.effectFrame != nil { effectFrames += 1 }
            if trace, let sc = scene, bc.isBattling {
                let fx = sc.effectFrame != nil
                if fx != hadFX { print("  t\(tick) effect \(fx ? "ON" : "off")"); hadFX = fx }
                if sc.flashPlayer != hadFlashP { if sc.flashPlayer { print("  t\(tick) FLASH player (impact)") }; hadFlashP = sc.flashPlayer }
                if sc.flashWild != hadFlashW { if sc.flashWild { print("  t\(tick) FLASH wild (impact)") }; hadFlashW = sc.flashWild }
                if sc.playerPose != lastPose { print("  t\(tick) playerPose -> \(sc.playerPose)"); lastPose = sc.playerPose }
            }
            if scene == nil && battleTicks > 0 { break }   // battle done + despawned
        }
        let m = RaisingState.shared.active!
        print("playback: battleTicks=\(battleTicks) effectFrames=\(effectFrames) → \(Characters.displayName(String(format: "%03d", m.dex))) Lv\(m.level) HP \(m.currentHP)/\(m.maxHP) status=\(m.status ?? "none")")
        AppSettings.shared.raisingMode = hadRaising
    }
    if let s7 = GameData.species[7] { _ = st.addToParty(st.makeMon(species: s7, level: 5)) }
    print("party=\(st.party.count) dailyHealNeededSameDay=\(st.dailyHealIfNeeded())")
    let savePath = (FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!)
        .appendingPathComponent("PokemonMouseFollower/raising.json")
    print("save exists=\(FileManager.default.fileExists(atPath: savePath.path)) at \(savePath.path)")
    st.reset()   // leave no test state behind
    exit(0)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
