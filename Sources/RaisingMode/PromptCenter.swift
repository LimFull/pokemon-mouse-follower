// Raising mode — on-overlay decision prompts (design C1 / #5 / #14 / D14).
//
// Battles run unattended on the click-through overlay, but two moments need
// player input: replacing a move when a 5th is learned (D7/#5) and choosing
// who to release when a capture lands with a full party (D14/#14). C1 resolves
// this by making ONLY the prompt clickable: instead of un-click-through-ing a
// fullscreen overlay window (which would block the desktop), a small card
// window exactly the prompt's size floats at the same overlay level — clicks
// outside it behave as always.
//
// Prompts queue up and show one at a time; each survives until answered.

import AppKit

enum OverlayPrompt {
    case learnMove(monIndex: Int, moveId: Int)
    case fullParty(captured: OwnedPokemon)
}

final class PromptCenter: NSObject {
    static let shared = PromptCenter()

    private var queue: [OverlayPrompt] = []
    private var window: NSWindow?
    private var current: OverlayPrompt?
    private var actions: [() -> Void] = []   // per shown button, by tag

    func enqueue(_ prompt: OverlayPrompt) {
        queue.append(prompt)
        showNextIfIdle()
    }

    // MARK: presentation

    private func showNextIfIdle() {
        guard window == nil, !queue.isEmpty else { return }
        let p = queue.removeFirst()
        current = p
        switch p {
        case .learnMove(let monIndex, let moveId): showLearnMove(monIndex: monIndex, moveId: moveId)
        case .fullParty(let mon): showFullParty(captured: mon)
        }
    }

    private func dismiss() {
        window?.close()
        window = nil
        current = nil
        actions = []
        showNextIfIdle()
    }

    private func showLearnMove(monIndex: Int, moveId: Int) {
        guard RaisingState.shared.party.indices.contains(monIndex) else { dismiss(); return }
        let mon = RaisingState.shared.party[monIndex]
        let newName = GameData.moves[moveId]?.displayName ?? "Move \(moveId)"
        var subtitle = Characters.displayName(String(format: "%03d", mon.dex))
        if let m = GameData.moves[moveId] {
            subtitle += "  ·  \(m.type ?? "—")"
            if m.effectivePower > 0 { subtitle += "  \(L("move.power")) \(m.effectivePower)" }
            subtitle += "  \(L("move.accuracy")) \(m.accuracyText)"
        }
        var buttons: [(String, () -> Void)] = mon.moves.enumerated().map { (slot, id) in
            ("→ \(GameData.moves[id]?.displayName ?? "Move \(id)")", {
                RaisingState.shared.learnMove(moveId, replacing: slot, at: monIndex)
            })
        }
        buttons.append((L("learn.skip"), {
            RaisingState.shared.learnMove(moveId, replacing: nil, at: monIndex)
        }))
        present(title: "\(L("learn.title"))  \(newName)", subtitle: subtitle, buttons: buttons)
    }

    private func showFullParty(captured mon: OwnedPokemon) {
        let caughtName = Characters.displayName(String(format: "%03d", mon.dex))
        var buttons: [(String, () -> Void)] = RaisingState.shared.party.enumerated().map { (i, member) in
            let name = Characters.displayName(String(format: "%03d", member.dex))
            return ("\(L("detail.release")): \(name)  Lv\(member.level)", {
                RaisingState.shared.resolveCapture(mon, releasing: i)
            })
        }
        buttons.append((L("prompt.full.keep"), {}))   // abandon the new catch
        present(title: L("prompt.full.title"),
                subtitle: "\(L("prompt.caught.title")): \(caughtName)  Lv\(mon.level)",
                buttons: buttons)
    }

    /// Build and show the card window: title, subtitle, one button per choice.
    private func present(title: String, subtitle: String, buttons: [(String, () -> Void)]) {
        actions = buttons.map { $0.1 }

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 14, left: 16, bottom: 14, right: 16)
        stack.translatesAutoresizingMaskIntoConstraints = false

        let t = NSTextField(labelWithString: title)
        t.font = .rounded(14, .bold)
        t.textColor = Palette.label
        stack.addArrangedSubview(t)
        let s = NSTextField(labelWithString: subtitle)
        s.font = .rounded(11, .medium)
        s.textColor = Palette.accent
        stack.addArrangedSubview(s)
        stack.setCustomSpacing(12, after: s)

        for (i, b) in buttons.enumerated() {
            let btn = NSButton(title: b.0, target: self, action: #selector(choiceTapped(_:)))
            btn.bezelStyle = .rounded
            btn.tag = i
            btn.font = .rounded(12, .semibold)
            stack.addArrangedSubview(btn)
        }

        let card = NSView()
        card.wantsLayer = true
        card.layer?.cornerRadius = 14
        card.layer?.borderWidth = 1.5
        card.layer?.backgroundColor = Palette.cardTop.cgColor
        card.layer?.borderColor = Palette.accent.withAlphaComponent(0.6).cgColor
        card.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: card.topAnchor),
            stack.bottomAnchor.constraint(equalTo: card.bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: card.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: card.trailingAnchor),
        ])
        card.layoutSubtreeIfNeeded()
        let size = stack.fittingSize

        // Bottom-center of the screen the cursor is on (visible but out of the way).
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) }
            ?? NSScreen.main
        let sf = screen?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1440, height: 900)
        let origin = CGPoint(x: sf.midX - size.width / 2, y: sf.minY + 110)

        let w = PromptWindow(contentRect: CGRect(origin: origin, size: size),
                             styleMask: .borderless, backing: .buffered, defer: false)
        w.isReleasedWhenClosed = false
        w.isOpaque = false
        w.backgroundColor = .clear
        w.hasShadow = true
        w.level = .init(rawValue: Int(CGWindowLevelForKey(.overlayWindow)) + 1)
        w.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        card.frame = CGRect(origin: .zero, size: size)
        w.contentView = card
        w.orderFrontRegardless()
        window = w
    }

    @objc private func choiceTapped(_ sender: NSButton) {
        let act = actions.indices.contains(sender.tag) ? actions[sender.tag] : nil
        act?()
        dismiss()
    }
}

/// Borderless but still key-able so its buttons take clicks immediately.
private final class PromptWindow: NSWindow {
    override var canBecomeKey: Bool { true }
}
