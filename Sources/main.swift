import Cocoa
import QuartzCore
import ImageIO
import UniformTypeIdentifiers

// MARK: - Settings (persisted in UserDefaults)
final class AppSettings {
    static let shared = AppSettings()
    private let d = UserDefaults.standard

    // Bounds used by both the sliders and clamping.
    static let gapRange: ClosedRange<Double> = 0...200
    static let speedRange: ClosedRange<Double> = 2...25
    static let scaleRange: ClosedRange<Double> = 1...5

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
}

// MARK: - Sprite loading
enum Sprite {
    static func loadCG(_ name: String) -> CGImage? {
        guard let url = Bundle.main.url(forResource: name, withExtension: "png"),
              let data = try? Data(contentsOf: url),
              let src = CGImageSourceCreateWithData(data as CFData, nil),
              let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return nil }
        return img
    }

    // Slice a sprite sheet into [row][col] frames of `cell`×`cell` px (top-left origin).
    static func slice(_ image: CGImage, cols: Int, rows: Int, cell: Int) -> [[CGImage]] {
        var out: [[CGImage]] = []
        for r in 0..<rows {
            var rowArr: [CGImage] = []
            for c in 0..<cols {
                let rect = CGRect(x: c * cell, y: r * cell, width: cell, height: cell)
                if let cg = image.cropping(to: rect) { rowArr.append(cg) }
            }
            out.append(rowArr)
        }
        return out
    }
}

// MARK: - Character View
final class CharacterView: NSView {
    private let spriteLayer = CALayer()

    private var idle: [[CGImage]] = []
    private var walk: [[CGImage]] = []
    private var loaded = false

    private var pos = CGPoint.zero
    private var vel = CGVector.zero
    private var started = false

    private var tickCounter = 0
    private var lastRow = 0

    private let cell = 32
    private let slowRadius: CGFloat = 130       // start decelerating within this range
    private let accel: CGFloat = 0.55           // max velocity change per frame (ease-in/out)
    private let moveThreshold: CGFloat = 0.35

    private let walkStepTicks = 6
    private let idleStepTicks = 10

    // octant (0=E,1=NE,2=N,3=NW,4=W,5=SW,6=S,7=SE) -> sprite row (L/R mirrored).
    private let octantToRow = [2, 3, 4, 5, 6, 7, 0, 1]

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        loadSprites()
        spriteLayer.magnificationFilter = .nearest
        spriteLayer.contentsGravity = .resizeAspect
        layer?.addSublayer(spriteLayer)
        applyScale()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    private func loadSprites() {
        guard let idleSheet = Sprite.loadCG("Idle-Anim"),
              let walkSheet = Sprite.loadCG("Walk-Anim") else {
            NSLog("MouseFollower: failed to load sprite sheets from bundle")
            return
        }
        idle = Sprite.slice(idleSheet, cols: 8, rows: 8, cell: cell)
        walk = Sprite.slice(walkSheet, cols: 4, rows: 8, cell: cell)
        loaded = true
    }

    // Resize the sprite to the current scale setting (called on init and when changed).
    func applyScale() {
        let size = CGFloat(cell) * AppSettings.shared.scale
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        spriteLayer.bounds = CGRect(x: 0, y: 0, width: size, height: size)
        spriteLayer.position = pos
        CATransaction.commit()
    }

    func tick(mouseGlobal: CGPoint) {
        guard loaded, let win = window else { return }

        let gap = AppSettings.shared.followGap
        let maxSpeed = AppSettings.shared.maxSpeed

        let target = CGPoint(x: mouseGlobal.x - win.frame.origin.x,
                             y: mouseGlobal.y - win.frame.origin.y)

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
            let speedWanted = remaining < slowRadius
                ? maxSpeed * (remaining / slowRadius)
                : maxSpeed
            desired = CGVector(dx: dir.dx * speedWanted, dy: dir.dy * speedWanted)
        }

        var sdx = desired.dx - vel.dx
        var sdy = desired.dy - vel.dy
        let steerMag = (sdx * sdx + sdy * sdy).squareRoot()
        if steerMag > accel {
            sdx = sdx / steerMag * accel
            sdy = sdy / steerMag * accel
        }
        vel.dx += sdx
        vel.dy += sdy

        let speed = (vel.dx * vel.dx + vel.dy * vel.dy).squareRoot()
        if speed > maxSpeed {
            vel.dx = vel.dx / speed * maxSpeed
            vel.dy = vel.dy / speed * maxSpeed
        }

        pos.x += vel.dx
        pos.y += vel.dy

        let moving = speed > moveThreshold
        let frames: [CGImage]
        if moving {
            var deg = atan2(vel.dy, vel.dx) * 180 / .pi
            if deg < 0 { deg += 360 }
            let octant = Int((deg / 45).rounded()) % 8
            lastRow = octantToRow[octant]
            frames = walk[lastRow]
        } else {
            frames = idle[lastRow]
        }

        guard !frames.isEmpty else { return }
        tickCounter += 1
        let step = moving ? walkStepTicks : idleStepTicks
        let idx = (tickCounter / step) % frames.count

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        spriteLayer.contents = frames[idx]
        spriteLayer.position = pos
        CATransaction.commit()
    }
}

// MARK: - Settings Window
final class SettingsWindowController: NSObject {
    let window: NSWindow
    private weak var characterView: CharacterView?
    private var valueLabels: [Int: NSTextField] = [:]

    init(characterView: CharacterView) {
        self.characterView = characterView
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 360, height: 210),
                          styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Mouse Follower 설정"
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

        grid.addRow(with: [makeLabel("커서와의 거리"),
                           makeSlider(tag: 0, range: AppSettings.gapRange, value: Double(s.followGap)),
                           makeValueLabel(0, text: fmt(0, s.followGap))])
        grid.addRow(with: [makeLabel("최대 속도"),
                           makeSlider(tag: 1, range: AppSettings.speedRange, value: Double(s.maxSpeed)),
                           makeValueLabel(1, text: fmt(1, s.maxSpeed))])
        grid.addRow(with: [makeLabel("캐릭터 크기"),
                           makeSlider(tag: 2, range: AppSettings.scaleRange, value: Double(s.scale)),
                           makeValueLabel(2, text: fmt(2, s.scale))])

        grid.column(at: 0).xPlacement = .trailing
        grid.column(at: 1).width = 170

        let content = window.contentView!
        content.addSubview(grid)
        NSLayoutConstraint.activate([
            grid.centerXAnchor.constraint(equalTo: content.centerXAnchor),
            grid.centerYAnchor.constraint(equalTo: content.centerYAnchor),
        ])
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
        tag == 2 ? String(format: "%.1f×", v) : String(format: "%.0f", v)
    }

    @objc private func sliderChanged(_ sender: NSSlider) {
        let v = CGFloat(sender.doubleValue)
        let s = AppSettings.shared
        switch sender.tag {
        case 0: s.followGap = v
        case 1: s.maxSpeed = v
        case 2: s.scale = v; characterView?.applyScale()
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
    private var window: NSWindow!
    private var characterView: CharacterView!
    private var statusItem: NSStatusItem!
    private var timer: Timer?
    private var running = true
    private var settingsController: SettingsWindowController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupWindow()
        setupStatusItem()
        setupTimer()
        NotificationCenter.default.addObserver(
            self, selector: #selector(screensChanged),
            name: NSApplication.didChangeScreenParametersNotification, object: nil)
    }

    // Re-launching the app (double-click while running) opens the settings window.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showSettings()
        return true
    }

    private func totalScreenFrame() -> NSRect {
        var frame = NSRect.zero
        for screen in NSScreen.screens {
            frame = frame.isEmpty ? screen.frame : frame.union(screen.frame)
        }
        return frame.isEmpty ? (NSScreen.main?.frame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)) : frame
    }

    private func setupWindow() {
        let frame = totalScreenFrame()
        window = NSWindow(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.ignoresMouseEvents = true
        window.level = .init(rawValue: Int(CGWindowLevelForKey(.overlayWindow)))
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        window.setFrame(frame, display: true)

        characterView = CharacterView(frame: NSRect(origin: .zero, size: frame.size))
        window.contentView = characterView
        window.orderFrontRegardless()
    }

    @objc private func screensChanged() {
        let frame = totalScreenFrame()
        window.setFrame(frame, display: true)
        characterView.frame = NSRect(origin: .zero, size: frame.size)
    }

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            if let img = NSImage(systemSymbolName: "pawprint.fill", accessibilityDescription: "Mouse Follower") {
                img.isTemplate = true
                button.image = img
            } else {
                button.title = "🐾"
            }
        }
        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "Mouse Follower", action: nil, keyEquivalent: ""))
        menu.addItem(.separator())
        let settings = NSMenuItem(title: "Settings…", action: #selector(showSettings), keyEquivalent: ",")
        settings.target = self
        menu.addItem(settings)
        let toggle = NSMenuItem(title: "Pause", action: #selector(toggleRunning), keyEquivalent: "p")
        toggle.target = self
        menu.addItem(toggle)
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
        statusItem.menu = menu
    }

    private func setupTimer() {
        let t = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            guard let self, self.running else { return }
            self.characterView.tick(mouseGlobal: NSEvent.mouseLocation)
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    @objc private func showSettings() {
        if settingsController == nil {
            settingsController = SettingsWindowController(characterView: characterView)
        }
        settingsController?.show()
    }

    @objc private func toggleRunning(_ sender: NSMenuItem) {
        running.toggle()
        sender.title = running ? "Pause" : "Resume"
        characterView.isHidden = !running
    }

    @objc private func quit() {
        NSApplication.shared.terminate(nil)
    }
}

// MARK: - Entry point
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)   // no Dock icon, menu-bar only
app.run()
