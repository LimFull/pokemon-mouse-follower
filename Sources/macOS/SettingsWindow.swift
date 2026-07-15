// The settings window: character picker, sliders/toggles, UI scale,
// and the raising-mode side panel host.

import Cocoa

// MARK: - Settings Window
final class SettingsWindowController: NSObject {
    let window: NSWindow
    private weak var controller: CharacterController?
    private var valueLabels: [Int: NSTextField] = [:]
    private var popup: NSPopUpButton!
    private var preview: CharacterPreviewView!
    private var raisingPanel: RaisingPanelView?
    private var raisingCheckbox: NSButton?
    private let raisingPanelWidth: CGFloat = 340
    private var grid: NSGridView!
    private var topStack: NSStackView!      // character preview area (normal mode only)
    private var outer: NSStackView!
    private var zoomRoot: NSView!           // 1x document all content lays out in
    private var zoomHost: UIZoomHost!       // renders zoomRoot at the UI scale
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
        // Raising mode can flip on outside this window (picking a starter in
        // the standalone raising window) — keep the checkbox and the mode
        // layout in step.
        NotificationCenter.default.addObserver(
            self, selector: #selector(raisingStateChanged), name: .raisingChanged, object: nil)
    }

    deinit { NotificationCenter.default.removeObserver(self) }

    /// Sync the checkbox + mode layout when the setting changed elsewhere;
    /// a no-op when this window's own toggle was the source.
    @objc private func raisingStateChanged() {
        let on = AppSettings.shared.raisingMode
        guard let cb = raisingCheckbox, cb.state != (on ? .on : .off) else { return }
        cb.state = on ? .on : .off
        updateModeVisibility()
        raisingPanel?.refresh()
        applyWindowSize(animate: true)
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
        grid.addRow(with: [makeLabel(L("label.altcolor")), makeCheckbox(on: AppSettings.shared.altColor, action: #selector(altColorToggled(_:))), NSGridCell.emptyContentView])
        grid.addRow(with: [makeLabel(L("label.shadow")), makeCheckbox(on: AppSettings.shared.showShadow, action: #selector(shadowToggled(_:))), NSGridCell.emptyContentView])
        grid.addRow(with: [makeLabel(L("label.hidefromcapture")), makeCheckbox(on: AppSettings.shared.hideFromCapture, action: #selector(hideFromCaptureToggled(_:))), NSGridCell.emptyContentView])
        let hotkeyRecorder = HotkeyRecorderButton {
            (AppSettings.shared.pauseHotkeyKeyCode, AppSettings.shared.pauseHotkeyLabel)
        }
        hotkeyRecorder.onChange = { code, mods, label in
            AppSettings.shared.pauseHotkeyKeyCode = code
            AppSettings.shared.pauseHotkeyModifiers = mods
            AppSettings.shared.pauseHotkeyLabel = label
            NotificationCenter.default.post(name: .pauseHotkeyChanged, object: nil)
        }
        grid.addRow(with: [makeLabel(L("label.pausehotkey")), hotkeyRecorder, NSGridCell.emptyContentView])
        let raisingHotkeyRecorder = HotkeyRecorderButton {
            (AppSettings.shared.raisingHotkeyKeyCode, AppSettings.shared.raisingHotkeyLabel)
        }
        raisingHotkeyRecorder.onChange = { code, mods, label in
            AppSettings.shared.raisingHotkeyKeyCode = code
            AppSettings.shared.raisingHotkeyModifiers = mods
            AppSettings.shared.raisingHotkeyLabel = label
            NotificationCenter.default.post(name: .raisingHotkeyChanged, object: nil)
        }
        grid.addRow(with: [makeLabel(L("label.raisinghotkey")), raisingHotkeyRecorder, NSGridCell.emptyContentView])
        grid.addRow(with: [makeLabel(L("label.launch")), makeCheckbox(on: LoginItem.isEnabled, action: #selector(launchToggled(_:))), NSGridCell.emptyContentView])
        grid.addRow(with: [makeLabel(L("label.uiscale")), makeUIScalePopup(), NSGridCell.emptyContentView])
        let raisingCB = makeCheckbox(on: AppSettings.shared.raisingMode, action: #selector(raisingToggled(_:)))
        raisingCheckbox = raisingCB
        grid.addRow(with: [makeLabel(L("label.raising")), raisingCB, NSGridCell.emptyContentView])
        grid.addRow(with: [makeLabel(L("label.raisingicon")), makeCheckbox(on: AppSettings.shared.raisingIconEnabled, action: #selector(raisingIconToggled(_:))), NSGridCell.emptyContentView])

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

        // Everything lays out in zoomRoot at 1x coordinates; zoomHost renders
        // it at the UI scale (applyWindowSize sizes both and the window).
        zoomRoot = NSView(frame: content.bounds)
        zoomHost = UIZoomHost(document: zoomRoot)
        content.addSubview(zoomHost)

        // Left column holds the existing settings at a fixed width; the raising
        // panel lives to its right and is revealed by widening the window.
        let leftColumn = NSView()
        leftColumn.translatesAutoresizingMaskIntoConstraints = false
        zoomRoot.addSubview(leftColumn)
        leftColumn.addSubview(outer)

        let divider = NSBox()
        divider.boxType = .separator
        divider.translatesAutoresizingMaskIntoConstraints = false
        zoomRoot.addSubview(divider)

        let panel = RaisingPanelView(frame: .zero)
        panel.translatesAutoresizingMaskIntoConstraints = false
        zoomRoot.addSubview(panel)
        raisingPanel = panel

        // NOTE: pin only tops + fixed heights (never subview.bottom == content.bottom),
        // otherwise NSWindow shrink-wraps its height to the Auto Layout fitting size
        // and the window collapses to the title bar. The height constants are
        // retuned to the actual content by applyWindowSize().
        leftHeightC = leftColumn.heightAnchor.constraint(equalToConstant: 596)
        dividerHeightC = divider.heightAnchor.constraint(equalToConstant: 572)
        panelHeightC = panel.heightAnchor.constraint(equalToConstant: 596)
        NSLayoutConstraint.activate([
            leftColumn.leadingAnchor.constraint(equalTo: zoomRoot.leadingAnchor),
            leftColumn.topAnchor.constraint(equalTo: zoomRoot.topAnchor),
            leftColumn.widthAnchor.constraint(equalToConstant: 400),
            leftHeightC,
            outer.centerXAnchor.constraint(equalTo: leftColumn.centerXAnchor),
            outer.topAnchor.constraint(equalTo: leftColumn.topAnchor, constant: 26),

            divider.leadingAnchor.constraint(equalTo: leftColumn.trailingAnchor),
            divider.topAnchor.constraint(equalTo: zoomRoot.topAnchor, constant: 12),
            dividerHeightC,
            divider.widthAnchor.constraint(equalToConstant: 1),

            panel.leadingAnchor.constraint(equalTo: divider.trailingAnchor),
            panel.topAnchor.constraint(equalTo: zoomRoot.topAnchor),
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
        // Window and zoomRoot take the zoomed size; the content above keeps
        // laying out in 1x coordinates inside zoomRoot's scaled bounds.
        let k = AppSettings.shared.uiScale
        let width: CGFloat = 400 + (raising ? raisingPanelWidth + 1 : 0)
        var f = window.frame
        let newH = h * k + (window.frame.height - (window.contentView?.frame.height ?? h * k))
        f.origin.y += f.size.height - newH     // keep the top edge where it was
        f.size.height = newH
        f.size.width = width * k
        window.setFrame(f, display: true, animate: animate)
        zoomHost.layoutZoomed(size1x: CGSize(width: width, height: h), k)
    }

    private func makeUIScalePopup() -> NSPopUpButton {
        let p = NSPopUpButton(frame: .zero, pullsDown: false)
        p.target = self
        p.action = #selector(uiScaleChanged(_:))
        for s in AppSettings.uiScaleSteps { p.addItem(withTitle: "\(Int(s * 100))%") }
        let cur = Double(AppSettings.shared.uiScale)
        p.selectItem(at: AppSettings.uiScaleSteps.firstIndex { abs($0 - cur) < 0.01 } ?? 0)
        return p
    }

    @objc private func uiScaleChanged(_ sender: NSPopUpButton) {
        setUIScale(CGFloat(AppSettings.uiScaleSteps[sender.indexOfSelectedItem]))
    }

    /// Live UI-scale change (popup + selftest hook).
    func setUIScale(_ k: CGFloat) {
        AppSettings.shared.uiScale = k
        applyWindowSize(animate: false)
    }


    private func makeStepButton(_ title: String, _ action: Selector) -> NSButton {
        let b = NSButton(title: "", target: self, action: action)
        b.bezelStyle = .rounded
        b.attributedTitle = NSAttributedString(string: title, attributes: [
            .foregroundColor: Palette.ink, .font: NSFont.rounded(20, .bold)])
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

    private func makeCheckbox(on: Bool, action: Selector) -> NSButton {
        let cb = NSButton(checkboxWithTitle: "", target: self, action: action)
        cb.state = on ? .on : .off
        return cb
    }

    @objc private func shadowToggled(_ sender: NSButton) {
        AppSettings.shared.showShadow = (sender.state == .on)
    }

    @objc private func hideFromCaptureToggled(_ sender: NSButton) {
        AppSettings.shared.hideFromCapture = (sender.state == .on)
        NotificationCenter.default.post(name: .captureProtectionChanged, object: nil)
    }

    @objc private func altColorToggled(_ sender: NSButton) {
        AppSettings.shared.altColor = (sender.state == .on)
        controller?.setCharacter(RaisingState.shared.followerFolder)     // reload with/without variant
        preview.setCharacter(AppSettings.shared.selectedCharacter)       // refresh preview color
    }

    @objc private func launchToggled(_ sender: NSButton) {
        let wantOn = sender.state == .on
        if !LoginItem.setEnabled(wantOn) {
            sender.state = wantOn ? .off : .on   // revert on failure
        }
    }

    @objc private func raisingIconToggled(_ sender: NSButton) {
        AppSettings.shared.raisingIconEnabled = (sender.state == .on)
        NotificationCenter.default.post(name: .raisingIconChanged, object: nil)
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
        l.textColor = Palette.ink
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
