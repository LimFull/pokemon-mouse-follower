// Raising mode — read-only detail window (#10, design D15).
//
// Shows the active Pokémon's state (level, gender, type, HP, stats, moves) and
// the party. When no game is in progress it offers a base-form starter picker.
// This is a normal clickable window (distinct from the click-through overlay).

import AppKit

final class RaisingDetailWindowController: NSObject {
    static let shared = RaisingDetailWindowController()

    private var window: NSWindow?
    private var starterPopup: NSPopUpButton?

    func show() {
        RaisingState.shared.dailyHealIfNeeded()
        let w = window ?? makeWindow()
        window = w
        rebuild()
        w.center()
        w.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: window

    private func makeWindow() -> NSWindow {
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 380, height: 460),
                         styleMask: [.titled, .closable], backing: .buffered, defer: false)
        w.title = L("detail.window.title")
        w.isReleasedWhenClosed = false
        w.backgroundColor = Palette.windowBG
        return w
    }

    private func rebuild() {
        guard let content = window?.contentView else { return }
        content.subviews.forEach { $0.removeFromSuperview() }

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.edgeInsets = NSEdgeInsets(top: 4, left: 4, bottom: 4, right: 4)

        if let mon = RaisingState.shared.active {
            buildActive(mon, into: stack)
        } else {
            buildEmpty(into: stack)
        }

        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 20),
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -24),
        ])
    }

    // MARK: empty state (starter picker)

    private func buildEmpty(into stack: NSStackView) {
        let msg = NSTextField(wrappingLabelWithString: L("detail.empty"))
        msg.font = .rounded(14, .medium)
        msg.textColor = Palette.label
        stack.addArrangedSubview(msg)

        let popup = NSPopUpButton(frame: .zero, pullsDown: false)
        for s in GameData.starters {
            popup.addItem(withTitle: "\(s.id) · \(Characters.displayName(s.id))")
            popup.lastItem?.tag = s.dex
        }
        starterPopup = popup

        let start = NSButton(title: L("detail.start"), target: self, action: #selector(startTapped))
        start.bezelStyle = .rounded
        start.bezelColor = Palette.accent
        start.contentTintColor = .white

        let row = NSStackView(views: [popup, start])
        row.orientation = .horizontal
        row.spacing = 10
        stack.addArrangedSubview(row)
    }

    @objc private func startTapped() {
        guard let dex = starterPopup?.selectedItem?.tag, dex > 0 else { return }
        RaisingState.shared.startNewGame(dex: dex)
        rebuild()
    }

    // MARK: active state (read-only)

    private func buildActive(_ mon: OwnedPokemon, into stack: NSStackView) {
        guard let s = mon.species else { return }
        let g = L("detail.gender.\(mon.gender.rawValue)")
        let types = [s.type1, s.type2].compactMap { $0 }.joined(separator: " / ")

        stack.addArrangedSubview(header("\(Characters.displayName(s.id))  \(g)"))
        stack.addArrangedSubview(kv("\(L("detail.level")) \(mon.level)", "\(L("detail.type")): \(types)"))

        let st = GameData.stats(s, level: mon.level)
        stack.addArrangedSubview(kv("\(L("detail.hp")): \(mon.currentHP) / \(mon.maxHP)",
                                    "\(L("detail.exp")): \(mon.exp)"))
        stack.addArrangedSubview(line("\(L("detail.stats")):  ATK \(st.atk)   DEF \(st.def)   SpA \(st.spAtk)   SpD \(st.spDef)"))

        stack.addArrangedSubview(sectionLabel(L("detail.moves")))
        for id in mon.moves {
            let m = GameData.moves[id]
            let name = m?.displayName ?? "Move \(id)"
            let meta = m.map { "\($0.type ?? "-")  ·  \($0.category ?? "-")  ·  Pow \($0.power)  ·  PP \($0.pp)" } ?? ""
            stack.addArrangedSubview(line("• \(name)   \(meta)"))
        }

        // Party roster (dex · name · Lv), if more than the active one.
        if RaisingState.shared.party.count > 1 {
            stack.addArrangedSubview(sectionLabel("\(L("detail.party"))  (\(RaisingState.shared.party.count)/\(RaisingState.maxParty))"))
            for p in RaisingState.shared.party {
                let faint = p.isFainted ? "  ✕" : ""
                stack.addArrangedSubview(line("• \(Characters.displayName(String(format: "%03d", p.dex)))  \(L("detail.level")) \(p.level)\(faint)"))
            }
        }

        let reset = NSButton(title: L("detail.reset"), target: self, action: #selector(resetTapped))
        reset.bezelStyle = .rounded
        stack.addArrangedSubview(reset)
    }

    @objc private func resetTapped() {
        let alert = NSAlert()
        alert.messageText = L("detail.reset")
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn {
            RaisingState.shared.reset()
            rebuild()
        }
    }

    // MARK: small builders

    private func header(_ t: String) -> NSTextField {
        let l = NSTextField(labelWithString: t)
        l.font = .rounded(20, .bold)
        l.textColor = Palette.accent
        return l
    }

    private func sectionLabel(_ t: String) -> NSTextField {
        let l = NSTextField(labelWithString: t)
        l.font = .rounded(13, .bold)
        l.textColor = Palette.label
        return l
    }

    private func line(_ t: String) -> NSTextField {
        let l = NSTextField(labelWithString: t)
        l.font = .rounded(13, .regular)
        l.textColor = Palette.label
        return l
    }

    private func kv(_ a: String, _ b: String) -> NSStackView {
        let row = NSStackView(views: [line(a), line(b)])
        row.orientation = .horizontal
        row.spacing = 24
        return row
    }
}
