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
}

// MARK: - Settings (persisted in UserDefaults)
final class AppSettings {
    static let shared = AppSettings()
    private let d = UserDefaults.standard

    static let gapRange: ClosedRange<Double> = 0...200
    static let speedRange: ClosedRange<Double> = 2...25
    static let scaleRange: ClosedRange<Double> = 1...5
    static let sleepRange: ClosedRange<Double> = 5...120

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

// MARK: - Character Controller
// The "brain": tracks the character in GLOBAL screen coordinates and picks the
// current animation frame. Rendering is done separately by one SpriteView per
// screen, so the character can cross between displays (which each own a space).
final class CharacterController {
    private var idle: [[CGImage]] = []
    private var walk: [[CGImage]] = []
    private var sleep: [[CGImage]] = []
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
    var position: CGPoint { pos }

    init() { setCharacter(AppSettings.shared.selectedCharacter) }

    // Load a character's sheets, sizing frames from its AnimData.xml.
    func setCharacter(_ folder: String) {
        let subdir = "characters/\(folder)"
        let xml = Sprite.loadText("AnimData", ext: "xml", subdir: subdir)
        shadowSize = xml.map { Sprite.shadowSize(in: $0) } ?? 1
        walk = framesFor("Walk-Anim", anim: "Walk", subdir: subdir, xml: xml)
        idle = framesFor("Idle-Anim", anim: "Idle", subdir: subdir, xml: xml)
        sleep = framesFor("Sleep-Anim", anim: "Sleep", subdir: subdir, xml: xml)
        if idle.isEmpty { idle = walk }    // some characters ship Walk only
        if sleep.isEmpty { sleep = idle }  // fall back when no sleep animation
        loaded = !walk.isEmpty
        tickCounter = 0
        idleTicks = 0
        if !loaded { NSLog("PokemonMouseFollower: failed to load character \(folder)") }
    }

    private func framesFor(_ png: String, anim: String, subdir: String, xml: String?) -> [[CGImage]] {
        guard let img = Sprite.loadCG(png, subdir: subdir) else { return [] }
        // Prefer AnimData; fall back to square cells assuming 8 direction rows.
        var cw = img.height / 8, ch = img.height / 8
        if let xml, let (w, h) = Sprite.frameSize(anim, in: xml) { cw = w; ch = h }
        guard cw > 0, ch > 0 else { return [] }
        let rows = max(1, img.height / ch)
        let cols = max(1, img.width / cw)
        return Sprite.slice(img, cols: cols, rows: rows, cellW: cw, cellH: ch)
    }

    // Advance one frame. `mouseGlobal` is already in global screen coordinates.
    func update(mouseGlobal: CGPoint) {
        guard loaded else { currentFrame = nil; return }

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
        let step: Int
        if moving { sheet = walk; step = walkStepTicks }
        else if sleeping { sheet = sleep; step = sleepStepTicks }
        else { sheet = idle; step = idleStepTicks }

        guard !sheet.isEmpty else { currentFrame = nil; return }
        let row = min(lastRow, sheet.count - 1)
        let frames = sheet[row]
        guard !frames.isEmpty else { currentFrame = nil; return }

        tickCounter += 1
        currentFrame = frames[(tickCounter / step) % frames.count]
    }
}

// MARK: - Sprite View (one per screen)
// Draws the shared character's current frame at its global position, offset by
// this screen's origin. The window (sized to one screen) clips it, so a sprite
// straddling two displays shows partially in each — seamless across monitors.
final class SpriteView: NSView {
    private let shadowLayer = CAGradientLayer()
    private let spriteLayer = CALayer()
    var screenOrigin: CGPoint = .zero

    // Shadow ellipse width as a fraction of frame width, by ShadowSize (0/1/2).
    private let shadowWidthFactor: [CGFloat] = [0.30, 0.45, 0.60]

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true

        // Soft radial-gradient ellipse: dark at center, fading to clear at edge.
        shadowLayer.type = .radial
        shadowLayer.colors = [CGColor(gray: 0, alpha: 0.35), CGColor(gray: 0, alpha: 0)]
        shadowLayer.locations = [0.0, 1.0]
        shadowLayer.startPoint = CGPoint(x: 0.5, y: 0.5)
        shadowLayer.endPoint = CGPoint(x: 1.0, y: 1.0)
        layer?.addSublayer(shadowLayer)   // behind the sprite

        spriteLayer.magnificationFilter = .nearest
        spriteLayer.contentsGravity = .resize
        layer?.addSublayer(spriteLayer)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func render(_ frame: CGImage?, globalPos: CGPoint, shadowSize: Int) {
        guard let frame else { spriteLayer.isHidden = true; shadowLayer.isHidden = true; return }
        let s = AppSettings.shared.scale
        let x = globalPos.x - screenOrigin.x
        let y = globalPos.y - screenOrigin.y
        CATransaction.begin()
        CATransaction.setDisableActions(true)

        // Shadow: an ellipse on the ground, centered under the sprite. Every frame
        // is centered on globalPos, so one rule works for all characters; only the
        // width (from ShadowSize) varies. Constant opacity, size-only variation —
        // matching how the source format actually renders shadows.
        if AppSettings.shared.showShadow {
            let sz = max(0, min(shadowWidthFactor.count - 1, shadowSize))
            let w = CGFloat(frame.width) * shadowWidthFactor[sz] * s
            let h = w * 0.35
            shadowLayer.isHidden = false
            shadowLayer.bounds = CGRect(x: 0, y: 0, width: w, height: h)
            // Nudge toward the sprite's feet (slightly below center).
            shadowLayer.position = CGPoint(x: x, y: y - CGFloat(frame.height) * s * 0.18)
        } else {
            shadowLayer.isHidden = true
        }

        spriteLayer.isHidden = false
        spriteLayer.bounds = CGRect(x: 0, y: 0,
                                    width: CGFloat(frame.width) * s,
                                    height: CGFloat(frame.height) * s)
        spriteLayer.contents = frame
        spriteLayer.position = CGPoint(x: x, y: y)
        CATransaction.commit()
    }
}

// MARK: - Settings Window
final class SettingsWindowController: NSObject {
    let window: NSWindow
    private weak var controller: CharacterController?
    private var valueLabels: [Int: NSTextField] = [:]

    init(controller: CharacterController) {
        self.controller = controller
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 380),
                          styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = L("settings.window.title")
        window.isReleasedWhenClosed = false
        super.init()
        buildUI()
        window.center()
    }

    private func buildUI() {
        let s = AppSettings.shared
        let grid = NSGridView()
        grid.translatesAutoresizingMaskIntoConstraints = false
        grid.rowSpacing = 16
        grid.columnSpacing = 12

        grid.addRow(with: [makeLabel(L("label.character")), makePopup(), NSGridCell.emptyContentView])
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
        grid.addRow(with: [makeLabel(L("label.shadow")), makeShadowCheckbox(), NSGridCell.emptyContentView])
        grid.addRow(with: [makeLabel(L("label.launch")), makeLaunchCheckbox(), NSGridCell.emptyContentView])

        grid.column(at: 0).xPlacement = .trailing
        grid.column(at: 1).width = 180

        let content = window.contentView!
        content.addSubview(grid)
        NSLayoutConstraint.activate([
            grid.centerXAnchor.constraint(equalTo: content.centerXAnchor),
            grid.centerYAnchor.constraint(equalTo: content.centerYAnchor),
        ])
    }

    private func makeShadowCheckbox() -> NSButton {
        let cb = NSButton(checkboxWithTitle: "", target: self, action: #selector(shadowToggled(_:)))
        cb.state = AppSettings.shared.showShadow ? .on : .off
        return cb
    }

    @objc private func shadowToggled(_ sender: NSButton) {
        AppSettings.shared.showShadow = (sender.state == .on)
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
        return l
    }

    private func makeValueLabel(_ tag: Int, text: String) -> NSTextField {
        let l = NSTextField(labelWithString: text)
        l.alignment = .left
        l.font = .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
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
        let folder = Characters.all[sender.indexOfSelectedItem].folder
        AppSettings.shared.selectedCharacter = folder
        controller?.setCharacter(folder)
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
        if CommandLine.arguments.contains("--show-settings") { showSettings() }
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
        menu.addItem(.separator())
        let quit = NSMenuItem(title: L("menu.quit"), action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
        statusItem.menu = menu
    }

    private func setupTimer() {
        let t = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            guard let self, self.running else { return }
            self.controller.update(mouseGlobal: NSEvent.mouseLocation)
            for (_, view) in self.overlays {
                view.render(self.controller.currentFrame,
                            globalPos: self.controller.position,
                            shadowSize: self.controller.shadowSize)
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

    @objc private func quit() {
        NSApplication.shared.terminate(nil)
    }
}

// MARK: - Entry point
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
