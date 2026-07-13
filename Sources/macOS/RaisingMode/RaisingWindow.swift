// Raising mode — the standalone raising window (user request): the party/bag
// panel from Settings in its own quick-access window, opened from the
// status-bar menu or the floating shortcut icon, and closed by clicking
// anywhere outside it.

import Cocoa

// MARK: - Standalone raising window

final class RaisingWindowController: NSObject, NSWindowDelegate {
    let window: NSWindow
    private let panel: RaisingPanelView
    private var zoomRoot: NSView!
    private var zoomHost: UIZoomHost!
    private var panelHeightC: NSLayoutConstraint!
    private let panelWidth: CGFloat = 340

    override init() {
        panel = RaisingPanelView(frame: .zero, showsSettings: false)
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: panelWidth, height: 400),
                          styleMask: [.titled, .closable], backing: .buffered, defer: false)
        super.init()
        window.title = L("detail.window.title")
        window.isReleasedWhenClosed = false
        window.backgroundColor = Palette.windowBG
        // Quick-access overlay feel: floats above normal windows, follows
        // the user to any Space, and never shows up in the window cycle.
        window.level = .floating
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        window.delegate = self

        let content = window.contentView!
        zoomRoot = NSView(frame: content.bounds)
        zoomHost = UIZoomHost(document: zoomRoot)
        content.addSubview(zoomHost)

        panel.translatesAutoresizingMaskIntoConstraints = false
        zoomRoot.addSubview(panel)
        // Top-pinned with a fixed height (same rule as the settings window:
        // pinning a bottom edge makes NSWindow shrink-wrap to the title bar).
        panelHeightC = panel.heightAnchor.constraint(equalToConstant: 400)
        NSLayoutConstraint.activate([
            panel.topAnchor.constraint(equalTo: zoomRoot.topAnchor),
            panel.leadingAnchor.constraint(equalTo: zoomRoot.leadingAnchor),
            panel.widthAnchor.constraint(equalToConstant: panelWidth),
            panelHeightC,
        ])
        panel.onContentChanged = { [weak self] in self?.applyWindowSize() }
        window.center()
    }

    /// Refresh + size + bring to front. `anchor` (the shortcut icon's frame,
    /// in screen coordinates) places the window next to the icon; nil keeps
    /// the window where the user last had it.
    func show(near anchor: NSRect? = nil) {
        panel.refresh()   // triggers onContentChanged -> applyWindowSize
        if let a = anchor { position(near: a) }
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    func toggle(near anchor: NSRect? = nil) {
        if window.isVisible { window.orderOut(nil) } else { show(near: anchor) }
    }

    /// Click-outside-to-close: any click that takes key status away — another
    /// app, the desktop, the settings window — dismisses the panel. The
    /// deferred check keeps the panel's own modal alerts (release/reset
    /// confirmations) from counting as "outside".
    func windowDidResignKey(_ notification: Notification) {
        DispatchQueue.main.async { [weak self] in
            guard let self, NSApp.modalWindow == nil, !self.window.isKeyWindow else { return }
            self.window.orderOut(nil)
        }
    }

    /// Same sizing rule as the settings window: content height capped, the
    /// top edge stays put, and the zoom host renders 1x layout at the UI scale.
    private func applyWindowSize() {
        let h = max(220, min(760, panel.contentHeight))
        panelHeightC.constant = h
        let k = AppSettings.shared.uiScale
        var f = window.frame
        let newH = h * k + (window.frame.height - (window.contentView?.frame.height ?? h * k))
        f.origin.y += f.size.height - newH     // keep the top edge where it was
        f.size.height = newH
        f.size.width = panelWidth * k
        window.setFrame(f, display: true)
        zoomHost.layoutZoomed(size1x: CGSize(width: panelWidth, height: h), k)
    }

    /// Next to the icon — to its left when it hugs the right screen edge,
    /// otherwise to its right — top-aligned and clamped to the visible frame.
    private func position(near a: NSRect) {
        let screen = NSScreen.screens.first { $0.frame.intersects(a) } ?? NSScreen.main
        guard let vf = screen?.visibleFrame else { return }
        let w = window.frame.width, h = window.frame.height
        var x = a.maxX + 10
        if x + w > vf.maxX { x = a.minX - 10 - w }
        var y = a.maxY - h                      // window top == icon top
        x = min(max(x, vf.minX + 8), vf.maxX - w - 8)
        y = min(max(y, vf.minY + 8), vf.maxY - h - 8)
        window.setFrameOrigin(NSPoint(x: x, y: y))
    }
}

// MARK: - Floating shortcut icon

/// The draggable bag icon (settings-gated): drag it anywhere, click it to
/// toggle the raising window. Position persists across launches.
final class RaisingShortcutIcon {
    private(set) var window: NSPanel?
    var onClick: (() -> Void)?

    private static let size: CGFloat = 46

    func setVisible(_ on: Bool) {
        if !on {
            window?.orderOut(nil)
            window = nil
            return
        }
        guard window == nil else { window?.orderFrontRegardless(); return }
        let s = Self.size
        let origin = AppSettings.shared.raisingIconPos ?? Self.defaultOrigin()
        let w = NSPanel(contentRect: NSRect(x: origin.x, y: origin.y, width: s, height: s),
                        styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        w.isReleasedWhenClosed = false
        w.isOpaque = false
        w.backgroundColor = .clear
        w.hasShadow = true
        w.level = .floating
        w.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        w.contentView = RaisingShortcutIconView(
            onClick: { [weak self] in self?.onClick?() },
            onMoved: { AppSettings.shared.raisingIconPos = $0 })
        window = w
        clampToScreen()
        w.orderFrontRegardless()
    }

    /// Keep the icon reachable after display changes (a monitor unplugged
    /// could strand it off every screen).
    func clampToScreen() {
        guard let w = window else { return }
        let f = w.frame
        if NSScreen.screens.contains(where: { $0.visibleFrame.intersects(f) }) { return }
        w.setFrameOrigin(Self.defaultOrigin())
    }

    /// Bottom-right of the main screen, off the Dock/menu bar.
    private static func defaultOrigin() -> NSPoint {
        let vf = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        return NSPoint(x: vf.maxX - size - 24, y: vf.minY + 24)
    }
}

private final class RaisingShortcutIconView: NSView {
    private let onClick: () -> Void
    private let onMoved: (CGPoint) -> Void
    private var downMouse = CGPoint.zero
    private var downOrigin = CGPoint.zero
    private var dragged = false

    init(onClick: @escaping () -> Void, onMoved: @escaping (CGPoint) -> Void) {
        self.onClick = onClick
        self.onMoved = onMoved
        super.init(frame: NSRect(x: 0, y: 0, width: 46, height: 46))
        wantsLayer = true
        layer?.cornerRadius = 12
        layer?.borderWidth = 1.5
        applyColors()
        toolTip = L("detail.window.title")

        // The same bundled backpack SVG the bag header uses, accent-tinted.
        let icon = NSImageView(frame: bounds.insetBy(dx: 10, dy: 10))
        if let url = Bundle.main.url(forResource: "backpack", withExtension: "svg"),
           let img = NSImage(contentsOf: url) {
            img.isTemplate = true
            icon.image = img
            icon.contentTintColor = Palette.accent
        }
        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.autoresizingMask = [.width, .height]
        addSubview(icon)
    }
    required init?(coder: NSCoder) { fatalError("not used") }

    private func applyColors() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = Palette.cardTop.cgColor
            layer?.borderColor = Palette.cardBorder.cgColor
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyColors()
    }

    // Drag moves the icon window; a press that never strays past the slop
    // radius is a click. Global mouse coordinates — the window itself moves
    // under the cursor mid-drag, so view-local deltas would feed back.
    override func mouseDown(with event: NSEvent) {
        downMouse = NSEvent.mouseLocation
        downOrigin = window?.frame.origin ?? .zero
        dragged = false
    }

    override func mouseDragged(with event: NSEvent) {
        let m = NSEvent.mouseLocation
        let dx = m.x - downMouse.x, dy = m.y - downMouse.y
        if abs(dx) > 3 || abs(dy) > 3 { dragged = true }
        guard dragged else { return }
        window?.setFrameOrigin(NSPoint(x: downOrigin.x + dx, y: downOrigin.y + dy))
    }

    override func mouseUp(with event: NSEvent) {
        if dragged {
            if let o = window?.frame.origin { onMoved(o) }
        } else {
            onClick()
        }
    }
}
