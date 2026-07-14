// Global (system-wide) pause hotkey and its settings recorder control.
//
// Carbon's RegisterEventHotKey is the right tool here: the hotkey fires even
// when the app isn't focused, is consumed (doesn't leak to other apps), and —
// unlike NSEvent global monitors — needs no Accessibility/Input-Monitoring
// permission. The recorder is a small NSButton that captures the next
// modifier+key chord.

import Cocoa
import Carbon.HIToolbox

// MARK: - Registration

final class GlobalHotkey {
    var onFire: (() -> Void)?
    private var hotKeyRef: EventHotKeyRef?
    private var eventHandler: EventHandlerRef?

    /// Install the process-wide hot-key event handler once (call at launch).
    func install() {
        guard eventHandler == nil else { return }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                 eventKind: UInt32(kEventHotKeyPressed))
        let this = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(GetApplicationEventTarget(), { _, _, userData in
            if let userData {
                Unmanaged<GlobalHotkey>.fromOpaque(userData).takeUnretainedValue().onFire?()
            }
            return noErr
        }, 1, &spec, this, &eventHandler)
    }

    /// (Re)bind to a Carbon key code + modifier mask; keyCode < 0 unbinds.
    func bind(keyCode: Int, modifiers: Int) {
        unbind()
        guard keyCode >= 0 else { return }
        let id = EventHotKeyID(signature: OSType(0x504D4648) /* 'PMFH' */, id: 1)
        RegisterEventHotKey(UInt32(keyCode), UInt32(modifiers), id,
                            GetApplicationEventTarget(), 0, &hotKeyRef)
    }

    func unbind() {
        if let r = hotKeyRef { UnregisterEventHotKey(r); hotKeyRef = nil }
    }

    /// Apply the currently-saved binding from settings.
    func applyFromSettings() {
        bind(keyCode: AppSettings.shared.pauseHotkeyKeyCode,
             modifiers: AppSettings.shared.pauseHotkeyModifiers)
    }

    deinit {
        unbind()
        if let h = eventHandler { RemoveEventHandler(h) }
    }
}

// MARK: - Settings recorder control

/// Click to record, then press a modifier+key chord. Esc cancels; Delete/
/// Backspace clears the binding. Reports (keyCode, carbonModifiers, label);
/// keyCode == -1 means "cleared / no hotkey".
final class HotkeyRecorderButton: NSButton {
    var onChange: ((_ keyCode: Int, _ carbonModifiers: Int, _ label: String) -> Void)?
    private var recording = false
    private var monitor: Any?

    init() {
        super.init(frame: .zero)
        bezelStyle = .rounded
        setButtonType(.momentaryPushIn)
        target = self
        action = #selector(startRecording)
        widthAnchor.constraint(greaterThanOrEqualToConstant: 130).isActive = true
        refreshTitle()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) unused") }

    func refreshTitle() {
        if recording { title = L("hotkey.recording"); return }
        title = AppSettings.shared.pauseHotkeyKeyCode < 0 ? L("hotkey.none")
                                                          : AppSettings.shared.pauseHotkeyLabel
    }

    @objc private func startRecording() {
        guard !recording else { return }
        recording = true
        refreshTitle()
        window?.makeFirstResponder(self)
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { [weak self] ev in
            self?.handle(ev)
            return nil   // swallow keys while recording
        }
    }

    private func stopRecording() {
        recording = false
        if let m = monitor { NSEvent.removeMonitor(m); monitor = nil }
        refreshTitle()
    }

    private func handle(_ ev: NSEvent) {
        guard ev.type == .keyDown else { return }   // ignore lone modifier changes
        let key = Int(ev.keyCode)
        if key == kVK_Escape { stopRecording(); return }
        if key == kVK_Delete || key == kVK_ForwardDelete {
            onChange?(-1, 0, L("hotkey.none")); stopRecording(); return
        }
        let flags = ev.modifierFlags.intersection(.deviceIndependentFlagsMask)
        // Require ⌘/⌥/⌃ so we never capture a bare keystroke as a global hotkey.
        guard flags.contains(.command) || flags.contains(.option) || flags.contains(.control) else {
            NSSound.beep(); return
        }
        onChange?(key, Self.carbonModifiers(flags), Self.label(flags: flags, event: ev))
        stopRecording()
    }

    override func resignFirstResponder() -> Bool {
        if recording { stopRecording() }   // clicking away cancels cleanly
        return super.resignFirstResponder()
    }

    static func carbonModifiers(_ flags: NSEvent.ModifierFlags) -> Int {
        var m = 0
        if flags.contains(.command) { m |= cmdKey }
        if flags.contains(.option)  { m |= optionKey }
        if flags.contains(.control) { m |= controlKey }
        if flags.contains(.shift)   { m |= shiftKey }
        return m
    }

    static func label(flags: NSEvent.ModifierFlags, event: NSEvent) -> String {
        var s = ""
        if flags.contains(.control) { s += "⌃" }
        if flags.contains(.option)  { s += "⌥" }
        if flags.contains(.shift)   { s += "⇧" }
        if flags.contains(.command) { s += "⌘" }
        return s + keyName(event)
    }

    private static func keyName(_ ev: NSEvent) -> String {
        if let special = specialKeys[Int(ev.keyCode)] { return special }
        let chars = (ev.charactersIgnoringModifiers ?? "").uppercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return chars.isEmpty ? "?" : chars
    }

    private static let specialKeys: [Int: String] = [
        kVK_Space: "Space", kVK_Return: "↩", kVK_Tab: "⇥",
        kVK_LeftArrow: "←", kVK_RightArrow: "→", kVK_UpArrow: "↑", kVK_DownArrow: "↓",
        kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4", kVK_F5: "F5", kVK_F6: "F6",
        kVK_F7: "F7", kVK_F8: "F8", kVK_F9: "F9", kVK_F10: "F10", kVK_F11: "F11", kVK_F12: "F12",
    ]
}
