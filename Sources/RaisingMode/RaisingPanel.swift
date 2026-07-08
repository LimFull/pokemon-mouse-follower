// Raising mode — the panel embedded on the right of the Settings window (#10).
//
// Two views: a mainline-style party list (sprite + name + HP, up to 6) and a
// Gen 1/2-style summary shown when a party member is clicked. When no game is
// in progress it offers a base-form starter picker. Normal clickable UI
// (distinct from the click-through overlay).

import AppKit

final class RaisingPanelView: NSView {
    private var detailIndex: Int?          // nil = list/empty mode
    private var expandedMove: Int?         // move id whose description is expanded
    private var starterPopup: NSPopUpButton?

    private static let contentWidth: CGFloat = 300

    override init(frame: NSRect) {
        super.init(frame: frame)
        refresh()
    }
    required init?(coder: NSCoder) { fatalError("not used") }

    func refresh() {
        RaisingState.shared.dailyHealIfNeeded()
        subviews.forEach { $0.removeFromSuperview() }

        let root = NSStackView()
        root.orientation = .vertical
        root.alignment = .leading
        root.spacing = 10
        root.translatesAutoresizingMaskIntoConstraints = false
        addSubview(root)
        NSLayoutConstraint.activate([
            root.topAnchor.constraint(equalTo: topAnchor, constant: 22),
            root.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 20),
        ])

        if !RaisingState.shared.hasActiveGame {
            buildEmpty(root)
        } else if let i = detailIndex, RaisingState.shared.party.indices.contains(i) {
            buildDetail(RaisingState.shared.party[i], into: root)
        } else {
            buildList(root)
        }
    }

    // MARK: empty state (starter picker)

    private func buildEmpty(_ root: NSStackView) {
        let msg = NSTextField(wrappingLabelWithString: L("detail.empty"))
        msg.font = .rounded(14, .medium)
        msg.textColor = Palette.label
        msg.preferredMaxLayoutWidth = Self.contentWidth
        root.addArrangedSubview(msg)

        let popup = NSPopUpButton(frame: .zero, pullsDown: false)
        for s in GameData.starters {
            popup.addItem(withTitle: "\(s.id) · \(Characters.displayName(s.id))")
            popup.lastItem?.tag = s.dex
        }
        popup.widthAnchor.constraint(equalToConstant: Self.contentWidth).isActive = true
        starterPopup = popup
        root.addArrangedSubview(popup)

        let start = NSButton(title: L("detail.start"), target: self, action: #selector(startTapped))
        start.bezelStyle = .rounded
        start.bezelColor = Palette.accent
        start.contentTintColor = .white
        root.addArrangedSubview(start)
    }

    @objc private func startTapped() {
        guard let dex = starterPopup?.selectedItem?.tag, dex > 0 else { return }
        RaisingState.shared.startNewGame(dex: dex)
        detailIndex = nil
        refresh()
    }

    // MARK: party list (mainline party-menu style)

    private func buildList(_ root: NSStackView) {
        let party = RaisingState.shared.party
        root.addArrangedSubview(sectionLabel("\(L("detail.party"))  \(party.count)/\(RaisingState.maxParty)"))

        for (i, mon) in party.enumerated() {
            let row = PartyRowView(mon: mon) { [weak self] in
                self?.detailIndex = i
                self?.refresh()
            }
            root.addArrangedSubview(row)
        }

        root.setCustomSpacing(18, after: root.arrangedSubviews.last ?? root)
        let reset = NSButton(title: L("detail.reset"), target: self, action: #selector(resetTapped))
        reset.bezelStyle = .rounded
        root.addArrangedSubview(reset)
    }

    @objc private func resetTapped() {
        let alert = NSAlert()
        alert.messageText = L("detail.reset")
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn {
            RaisingState.shared.reset()
            detailIndex = nil
            refresh()
        }
    }

    // MARK: detail (Gen 1/2 summary style)

    private func buildDetail(_ mon: OwnedPokemon, into root: NSStackView) {
        guard let s = mon.species else { return }

        let back = NSButton(title: "‹ \(L("detail.party"))", target: self, action: #selector(backToList))
        back.bezelStyle = .rounded
        back.isBordered = false
        back.contentTintColor = Palette.accent
        back.attributedTitle = NSAttributedString(string: "‹ \(L("detail.party"))",
            attributes: [.foregroundColor: Palette.accent, .font: NSFont.rounded(13, .semibold)])
        root.addArrangedSubview(back)

        // Bordered retro summary box.
        let box = NSView()
        box.translatesAutoresizingMaskIntoConstraints = false
        box.wantsLayer = true
        box.layer?.cornerRadius = 8
        box.layer?.borderWidth = 2
        applyBoxColors(box)
        box.widthAnchor.constraint(equalToConstant: Self.contentWidth).isActive = true
        root.addArrangedSubview(box)

        let inner = NSStackView()
        inner.orientation = .vertical
        inner.alignment = .leading
        inner.spacing = 8
        inner.translatesAutoresizingMaskIntoConstraints = false
        box.addSubview(inner)
        NSLayoutConstraint.activate([
            inner.topAnchor.constraint(equalTo: box.topAnchor, constant: 12),
            inner.leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: 14),
            inner.trailingAnchor.constraint(equalTo: box.trailingAnchor, constant: -14),
            inner.bottomAnchor.constraint(equalTo: box.bottomAnchor, constant: -12),
        ])

        // Header: sprite + name/level/gender/type.
        let sprite = NSImageView()
        sprite.image = CharacterPreviewView.stillImage(s.id)
        sprite.imageScaling = .scaleProportionallyUpOrDown
        sprite.translatesAutoresizingMaskIntoConstraints = false
        sprite.widthAnchor.constraint(equalToConstant: 68).isActive = true
        sprite.heightAnchor.constraint(equalToConstant: 68).isActive = true

        let g = L("detail.gender.\(mon.gender.rawValue)")
        let typeRow = NSStackView(views: [monoLabel("\(L("detail.level"))\(mon.level)", 12, .medium)])
        typeRow.orientation = .horizontal
        typeRow.alignment = .centerY
        typeRow.spacing = 6
        for t in [s.type1, s.type2].compactMap({ $0 }) { typeRow.addArrangedSubview(TypeBadge(t)) }
        let headText = NSStackView(views: [
            monoLabel("\(Characters.displayName(s.id))  \(g)", 15, .bold),
            typeRow,
        ])
        headText.orientation = .vertical
        headText.alignment = .leading
        headText.spacing = 6
        let header = NSStackView(views: [sprite, headText])
        header.orientation = .horizontal
        header.alignment = .centerY
        header.spacing = 12
        inner.addArrangedSubview(header)

        // HP line + bar.
        inner.addArrangedSubview(monoLabel("\(L("detail.hp"))  \(mon.currentHP)/\(mon.maxHP)", 12, .semibold))
        inner.addArrangedSubview(HPBarView(current: mon.currentHP, max: mon.maxHP, width: Self.contentWidth - 28))

        // Stats block (EoS model: no Speed stat).
        let st = GameData.stats(s, level: mon.level)
        let statsText = [
            String(format: "ATTACK   %4d", st.atk),
            String(format: "DEFENSE  %4d", st.def),
            String(format: "SP.ATK   %4d", st.spAtk),
            String(format: "SP.DEF   %4d", st.spDef),
        ].joined(separator: "\n")
        inner.addArrangedSubview(divider())
        inner.addArrangedSubview(monoLabel(statsText, 12, .medium))
        inner.addArrangedSubview(monoLabel("\(L("detail.exp"))  \(mon.exp)", 11, .regular))

        // Moves (click a row to expand/collapse its type + description inline).
        inner.addArrangedSubview(divider())
        inner.addArrangedSubview(monoLabel("▶ \(L("detail.moves"))", 12, .bold))
        for id in mon.moves {
            inner.addArrangedSubview(moveRow(id))
            if expandedMove == id { inner.addArrangedSubview(moveDetailInline(id)) }
        }

        // TEMP (Phase 1): a training button to grant EXP so growth/evolution can
        // be exercised before battles exist (Phase 2 replaces this with battle EXP).
        let train = NSButton(title: L("train.button"), target: self, action: #selector(trainTapped))
        train.bezelStyle = .rounded
        root.addArrangedSubview(train)
    }

    @objc private func trainTapped() {
        guard let i = detailIndex, RaisingState.shared.party.indices.contains(i) else { return }
        RaisingState.shared.setActive(i)
        let result = RaisingState.shared.gainExp(300)     // demo amount
        for moveId in result.pendingMoves { promptLearn(moveId) }
        if let from = result.evolvedFrom, let to = result.evolvedTo {
            let a = NSAlert()
            a.messageText = Characters.displayName(String(format: "%03d", from)) + L("evo.suffix")
            a.informativeText = "→ \(Characters.displayName(String(format: "%03d", to)))"
            a.runModal()
        }
        refresh()
    }

    /// Party is full (4 moves): ask which move to forget, or decline (#5).
    private func promptLearn(_ moveId: Int) {
        guard let i = detailIndex, RaisingState.shared.party.indices.contains(i) else { return }
        let mon = RaisingState.shared.party[i]
        let newName = GameData.moves[moveId]?.displayName ?? "Move \(moveId)"
        let a = NSAlert()
        a.messageText = "\(L("learn.title"))  \(newName)"
        a.informativeText = moveDetailText(moveId)          // type · PP · power · description
        for id in mon.moves {
            a.addButton(withTitle: GameData.moves[id]?.displayName ?? "Move \(id)")
        }
        a.addButton(withTitle: L("learn.skip"))
        a.buttons.first?.keyEquivalent = ""                 // no default/highlighted button
        let slot = a.runModal().rawValue - NSApplication.ModalResponse.alertFirstButtonReturn.rawValue
        RaisingState.shared.learnMove(moveId, replacing: slot < mon.moves.count ? slot : nil)
    }

    // A clickable move line (monospace, retro) that expands/collapses its detail.
    private func moveRow(_ id: Int) -> NSButton {
        let m = GameData.moves[id]
        let name = (m?.displayName ?? "Move \(id)").padding(toLength: 14, withPad: " ", startingAt: 0)
        let arrow = expandedMove == id ? "▾" : "▸"
        let b = NSButton(title: "", target: self, action: #selector(moveTapped(_:)))
        b.isBordered = false
        b.tag = id
        b.alignment = .left
        b.attributedTitle = NSAttributedString(string: "\(arrow) \(name) PP \(m?.pp ?? 0)", attributes: [
            .font: NSFont.monospacedSystemFont(ofSize: 12, weight: .regular),
            .foregroundColor: Palette.label])
        return b
    }

    @objc private func moveTapped(_ sender: NSButton) {
        expandedMove = (expandedMove == sender.tag) ? nil : sender.tag
        refresh()
    }

    // Inline expansion under a move row: type badge, category/PP/power, description.
    private func moveDetailInline(_ id: Int) -> NSView {
        let box = NSStackView()
        box.orientation = .vertical
        box.alignment = .leading
        box.spacing = 5
        box.edgeInsets = NSEdgeInsets(top: 0, left: 18, bottom: 6, right: 0)
        guard let m = GameData.moves[id] else { return box }

        let meta = NSStackView(views: [TypeBadge(m.type ?? "Neutral")])
        meta.orientation = .horizontal
        meta.alignment = .centerY
        meta.spacing = 8
        var info = m.category ?? ""
        info += "   PP \(m.pp)"
        if m.power > 0 { info += "   \(L("move.power")) \(m.power)" }
        meta.addArrangedSubview(monoLabel(info, 11, .medium))
        box.addArrangedSubview(meta)

        if let d = m.desc, !d.isEmpty {
            let desc = NSTextField(wrappingLabelWithString: d)
            desc.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
            desc.textColor = Palette.label
            desc.preferredMaxLayoutWidth = Self.contentWidth - 40
            box.addArrangedSubview(desc)
        }
        return box
    }

    /// "<Type> · <Category> · PP nn · Power nn\n\n<description>" for a move.
    private func moveDetailText(_ id: Int) -> String {
        guard let m = GameData.moves[id] else { return "" }
        var head = "\(m.type ?? "-")   ·   \(m.category ?? "-")   ·   PP \(m.pp)"
        if m.power > 0 { head += "   ·   \(L("move.power")) \(m.power)" }
        let desc = m.desc ?? ""
        return desc.isEmpty ? head : "\(head)\n\n\(desc)"
    }

    @objc private func backToList() {
        detailIndex = nil
        refresh()
    }

    // MARK: small builders

    private func sectionLabel(_ t: String) -> NSTextField {
        let l = NSTextField(labelWithString: t)
        l.font = .rounded(13, .bold)
        l.textColor = Palette.label
        return l
    }

    private func monoLabel(_ t: String, _ size: CGFloat, _ weight: NSFont.Weight) -> NSTextField {
        let l = NSTextField(labelWithString: t)
        l.font = .monospacedSystemFont(ofSize: size, weight: weight)
        l.textColor = Palette.label
        l.maximumNumberOfLines = 0
        return l
    }

    private func divider() -> NSBox {
        let b = NSBox()
        b.boxType = .separator
        b.translatesAutoresizingMaskIntoConstraints = false
        b.widthAnchor.constraint(equalToConstant: Self.contentWidth - 28).isActive = true
        return b
    }

    private func applyBoxColors(_ box: NSView) {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            box.layer?.backgroundColor = Palette.cardTop.cgColor
            box.layer?.borderColor = Palette.cardBorder.cgColor
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        refresh()
    }

}

// MARK: - HP bar (track + ratio-colored fill), works in both stack & frame layout

final class HPBarView: NSView {
    private let w: CGFloat
    init(current: Int, max: Int, width: CGFloat) {
        self.w = width
        super.init(frame: NSRect(x: 0, y: 0, width: width, height: 8))
        wantsLayer = true
        layer?.cornerRadius = 4
        layer?.backgroundColor = NSColor.quaternaryLabelColor.cgColor

        let ratio = max > 0 ? Swift.max(0, Swift.min(1, CGFloat(current) / CGFloat(max))) : 0
        let fill = NSView(frame: NSRect(x: 0, y: 0, width: Swift.max(2, width * ratio), height: 8))
        fill.autoresizingMask = []
        fill.wantsLayer = true
        fill.layer?.cornerRadius = 4
        let color: NSColor = ratio > 0.5 ? .systemGreen : (ratio > 0.2 ? .systemYellow : .systemRed)
        fill.layer?.backgroundColor = color.cgColor
        addSubview(fill)
    }
    required init?(coder: NSCoder) { fatalError("not used") }
    override var intrinsicContentSize: NSSize { NSSize(width: w, height: 8) }
}

// MARK: - Party row (sprite + name + Lv + HP bar), clickable

final class PartyRowView: NSView {
    private let onClick: () -> Void
    override var isFlipped: Bool { true }

    init(mon: OwnedPokemon, onClick: @escaping () -> Void) {
        self.onClick = onClick
        super.init(frame: NSRect(x: 0, y: 0, width: 300, height: 50))
        translatesAutoresizingMaskIntoConstraints = false
        widthAnchor.constraint(equalToConstant: 300).isActive = true
        heightAnchor.constraint(equalToConstant: 50).isActive = true
        wantsLayer = true
        layer?.cornerRadius = 10
        layer?.backgroundColor = Palette.cardTop.cgColor
        layer?.borderWidth = 1
        layer?.borderColor = Palette.cardBorder.cgColor

        let folder = String(format: "%03d", mon.dex)

        let sprite = NSImageView(frame: NSRect(x: 6, y: 5, width: 40, height: 40))
        sprite.image = CharacterPreviewView.stillImage(folder)
        sprite.imageScaling = .scaleProportionallyUpOrDown
        addSubview(sprite)

        let name = NSTextField(labelWithString: "\(Characters.displayName(folder))   \(L("detail.level"))\(mon.level)")
        name.font = .rounded(13, .semibold)
        name.textColor = mon.isFainted ? .systemRed : Palette.label
        name.frame = NSRect(x: 54, y: 6, width: 240, height: 18)
        addSubview(name)

        let bar = HPBarView(current: mon.currentHP, max: mon.maxHP, width: 170)
        bar.frame = NSRect(x: 54, y: 30, width: 170, height: 8)
        addSubview(bar)

        let hp = NSTextField(labelWithString: "\(mon.currentHP)/\(mon.maxHP)")
        hp.font = .monospacedSystemFont(ofSize: 11, weight: .medium)
        hp.textColor = Palette.label
        hp.frame = NSRect(x: 230, y: 27, width: 66, height: 14)
        addSubview(hp)
    }
    required init?(coder: NSCoder) { fatalError("not used") }

    override func mouseDown(with event: NSEvent) { onClick() }
}
