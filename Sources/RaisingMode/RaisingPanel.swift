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
        // Live refresh on captures, pickups, evolutions, party edits.
        NotificationCenter.default.addObserver(
            self, selector: #selector(stateChanged), name: .raisingChanged, object: nil)
    }
    required init?(coder: NSCoder) { fatalError("not used") }
    deinit { NotificationCenter.default.removeObserver(self) }

    @objc private func stateChanged() {
        if window != nil { refresh() }
    }

    /// Keep fainted members' revive countdown fresh while the panel is open.
    private var countdownTimer: Timer?
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        countdownTimer?.invalidate()
        countdownTimer = nil
        guard window != nil else { return }
        let t = Timer(timeInterval: 60, repeats: true) { [weak self] _ in
            guard let self, self.window != nil else { return }
            if RaisingState.shared.party.contains(where: { $0.isFainted }) { self.refresh() }
        }
        RunLoop.main.add(t, forMode: .common)
        countdownTimer = t
    }

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

        // Bag (D12): everything picked up off the overlay, with counts.
        let bag = GameItem.allCases.filter { RaisingState.shared.itemCount($0) > 0 }
        if !bag.isEmpty {
            root.setCustomSpacing(16, after: root.arrangedSubviews.last ?? root)
            root.addArrangedSubview(sectionLabel(L("detail.bag")))
            for item in bag {
                root.addArrangedSubview(bagRow(item, count: RaisingState.shared.itemCount(item)))
            }
        }

        root.setCustomSpacing(18, after: root.arrangedSubviews.last ?? root)
        let reset = NSButton(title: L("detail.reset"), target: self, action: #selector(resetTapped))
        reset.bezelStyle = .rounded
        root.addArrangedSubview(reset)
    }

    /// One bag line: pixel icon + "name ×count".
    private func bagRow(_ item: GameItem, count: Int) -> NSView {
        let icon = NSImageView()
        if let cg = item.icon {
            icon.image = NSImage(cgImage: cg, size: NSSize(width: 16, height: 16))
        }
        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.widthAnchor.constraint(equalToConstant: 18).isActive = true
        icon.heightAnchor.constraint(equalToConstant: 18).isActive = true
        let row = NSStackView(views: [icon, monoLabel("\(item.displayName)  ×\(count)", 12, .medium)])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 8
        return row
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

        // HP line + status badge + bar.
        let hpRow = NSStackView(views: [monoLabel("\(L("detail.hp"))  \(mon.currentHP)/\(mon.maxHP)", 12, .semibold)])
        hpRow.orientation = .horizontal
        hpRow.alignment = .centerY
        hpRow.spacing = 8
        if let badge = StatusBadge(mon: mon) { hpRow.addArrangedSubview(badge) }
        inner.addArrangedSubview(hpRow)
        inner.addArrangedSubview(HPBarView(current: mon.currentHP, max: mon.maxHP, width: Self.contentWidth - 28))
        if mon.isFainted {
            // Countdown to the daily heal (D23) that will revive it.
            let l = monoLabel("\(L("detail.revive.in"))  \(OwnedPokemon.timeUntilDailyHeal)", 11, .semibold)
            l.textColor = .systemRed
            inner.addArrangedSubview(l)
        }

        // Stats block (EoS model: no Speed stat).
        let st = GameData.stats(s, level: mon.level)
        let statsText = [
            String(format: "ATTACK   %4d", st.atk),
            String(format: "DEFENSE  %4d", st.def),
            String(format: "SP.ATK   %4d", st.spAtk),
            String(format: "SP.DEF   %4d", st.spDef),
            String(format: "SPEED    %4d", st.spe),
        ].joined(separator: "\n")
        inner.addArrangedSubview(divider())
        inner.addArrangedSubview(monoLabel(statsText, 12, .medium))
        // EXP: remaining to the next level + a gauge over this level's span.
        let (expLeft, expFrac) = mon.expToNext
        inner.addArrangedSubview(monoLabel("\(L("detail.exp.next"))  \(expLeft)", 11, .regular))
        inner.addArrangedSubview(HPBarView(current: Int(expFrac * 1000), max: 1000,
                                           width: Self.contentWidth - 28, color: .systemBlue))

        // Moves (click a row to expand/collapse its type + description inline).
        inner.addArrangedSubview(divider())
        inner.addArrangedSubview(monoLabel("▶ \(L("detail.moves"))", 12, .bold))
        for id in mon.moves {
            inner.addArrangedSubview(moveRow(id))
            if expandedMove == id { inner.addArrangedSubview(moveDetailInline(id)) }
        }

        // Usable items on this mon (Phase 3c): potions when hurt, a revive
        // when fainted, evolution items when they'd trigger one (C3/D8-1).
        guard let idx = detailIndex else { return }
        let usable = GameItem.allCases.filter { RaisingState.shared.canUseItem($0, at: idx) }
        if !usable.isEmpty {
            let itemStack = NSStackView()
            itemStack.orientation = .vertical
            itemStack.alignment = .leading
            itemStack.spacing = 6
            for item in usable {
                let b = NSButton(title: "\(item.displayName)  ×\(RaisingState.shared.itemCount(item))",
                                 target: self, action: #selector(useItemTapped(_:)))
                b.bezelStyle = .rounded
                b.tag = item.rawValue
                if let cg = item.icon {
                    b.image = NSImage(cgImage: cg, size: NSSize(width: 16, height: 16))
                    b.imagePosition = .imageLeading
                }
                itemStack.addArrangedSubview(b)
            }
            root.addArrangedSubview(itemStack)
        }

        // Debug trainer (kept for PMF_FAST_BATTLE test runs only) + release.
        let actions = NSStackView(views: [])
        actions.orientation = .horizontal
        actions.spacing = 8
        if ProcessInfo.processInfo.environment["PMF_FAST_BATTLE"] != nil {
            let train = NSButton(title: L("train.button"), target: self, action: #selector(trainTapped))
            train.bezelStyle = .rounded
            actions.addArrangedSubview(train)
        }
        let release = NSButton(title: L("detail.release"), target: self, action: #selector(releaseTapped))
        release.bezelStyle = .rounded
        release.contentTintColor = .systemRed
        actions.addArrangedSubview(release)
        root.addArrangedSubview(actions)
    }

    @objc private func useItemTapped(_ sender: NSButton) {
        guard let i = detailIndex, let item = GameItem(rawValue: sender.tag) else { return }
        let evolved = RaisingState.shared.useItem(item, at: i)
        if let to = evolved {
            let a = NSAlert()
            a.messageText = Characters.displayName(String(format: "%03d", to))
            a.informativeText = L("evo.suffix")
            a.runModal()
        }
        refresh()
    }

    /// Release the mon back to the wild (D14) after a confirmation.
    @objc private func releaseTapped() {
        guard let i = detailIndex, RaisingState.shared.party.indices.contains(i) else { return }
        let mon = RaisingState.shared.party[i]
        let a = NSAlert()
        a.messageText = L("detail.release")
        a.informativeText = Characters.displayName(String(format: "%03d", mon.dex))
        a.addButton(withTitle: "OK")
        a.addButton(withTitle: "Cancel")
        if a.runModal() == .alertFirstButtonReturn {
            RaisingState.shared.release(at: i)
            detailIndex = nil
            refresh()
        }
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
        a.accessoryView = moveAccessoryView(moveId)         // type badge + PP/power + description
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
        let name = m?.displayName ?? "Move \(id)"
        let arrow = expandedMove == id ? "▾" : "▸"
        let b = NSButton(title: "", target: self, action: #selector(moveTapped(_:)))
        b.isBordered = false
        b.tag = id
        b.alignment = .left
        b.attributedTitle = NSAttributedString(string: "\(arrow) \(name)", attributes: [
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

        // Line 1: type badge + category. Line 2: power/accuracy — kept on
        // its own row so it never overflows the card width and gets clipped.
        let meta = NSStackView(views: [TypeBadge(m.type ?? "Neutral"),
                                       monoLabel(m.category ?? "", 11, .medium)])
        meta.orientation = .horizontal
        meta.alignment = .centerY
        meta.spacing = 8
        box.addArrangedSubview(meta)
        var stats = ""
        if m.effectivePower > 0 { stats += "\(L("move.power")) \(m.effectivePower)   " }
        stats += "\(L("move.accuracy")) \(m.accuracyText)"
        box.addArrangedSubview(monoLabel(stats, 11, .medium))

        if let d = m.desc, !d.isEmpty {
            let desc = NSTextField(wrappingLabelWithString: d)
            desc.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
            desc.textColor = Palette.label
            desc.preferredMaxLayoutWidth = Self.contentWidth - 40
            box.addArrangedSubview(desc)
        }
        return box
    }

    /// A boxed view (type badge + category/PP/power + description) for the
    /// learn-move NSAlert accessory, so the new move's type shows as a color badge.
    private func moveAccessoryView(_ id: Int) -> NSView {
        let width: CGFloat = 260
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false
        if let m = GameData.moves[id] {
            let meta = NSStackView(views: [TypeBadge(m.type ?? "Neutral"),
                                           monoLabel(m.category ?? "", 11, .medium)])
            meta.orientation = .horizontal
            meta.alignment = .centerY
            meta.spacing = 8
            stack.addArrangedSubview(meta)
            var stats = ""
            if m.effectivePower > 0 { stats += "\(L("move.power")) \(m.effectivePower)   " }
            stats += "\(L("move.accuracy")) \(m.accuracyText)"
            stack.addArrangedSubview(monoLabel(stats, 11, .medium))
            if let d = m.desc, !d.isEmpty {
                let desc = NSTextField(wrappingLabelWithString: d)
                desc.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
                desc.textColor = Palette.label
                desc.preferredMaxLayoutWidth = width
                stack.addArrangedSubview(desc)
            }
        }
        // NSAlert lays out accessory views best by frame; size it via Auto Layout
        // then freeze the fitting height into an explicit frame.
        let container = NSView(frame: NSRect(x: 0, y: 0, width: width, height: 10))
        container.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            stack.topAnchor.constraint(equalTo: container.topAnchor),
            stack.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        container.layoutSubtreeIfNeeded()
        container.frame = NSRect(x: 0, y: 0, width: width, height: stack.fittingSize.height)
        return container
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

// MARK: - Status badge (mainline-style PAR/SLP/BRN/PSN/FRZ chip; FNT when fainted)

final class StatusBadge: NSView {
    private static let style: [String: (String, NSColor)] = [
        "paralysis": ("PAR", .systemYellow),
        "sleep": ("SLP", .systemGray),
        "burn": ("BRN", .systemOrange),
        "poison": ("PSN", .systemPurple),
        "freeze": ("FRZ", .systemTeal),
        "fainted": ("FNT", .systemRed),
    ]

    /// nil when the mon is healthy (no badge to show).
    init?(mon: OwnedPokemon) {
        let key = mon.isFainted ? "fainted" : (mon.status ?? "")
        guard let (abbr, color) = StatusBadge.style[key] else { return nil }
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerRadius = 4
        layer?.backgroundColor = color.withAlphaComponent(0.9).cgColor
        let l = NSTextField(labelWithString: abbr)
        l.font = .monospacedSystemFont(ofSize: 10, weight: .bold)
        l.textColor = .white
        l.translatesAutoresizingMaskIntoConstraints = false
        addSubview(l)
        NSLayoutConstraint.activate([
            l.centerXAnchor.constraint(equalTo: centerXAnchor),
            l.centerYAnchor.constraint(equalTo: centerYAnchor),
            widthAnchor.constraint(equalTo: l.widthAnchor, constant: 10),
            heightAnchor.constraint(equalTo: l.heightAnchor, constant: 4),
        ])
    }
    required init?(coder: NSCoder) { fatalError("not used") }
}

// MARK: - HP bar (track + ratio-colored fill), works in both stack & frame layout

final class HPBarView: NSView {
    private let w: CGFloat
    /// Ratio-colored (green/yellow/red) by default; pass `color` for a fixed
    /// fill (e.g. the blue EXP gauge).
    init(current: Int, max: Int, width: CGFloat, color: NSColor? = nil) {
        self.w = width
        super.init(frame: NSRect(x: 0, y: 0, width: width, height: 8))
        wantsLayer = true
        layer?.cornerRadius = 4
        layer?.backgroundColor = NSColor.quaternaryLabelColor.cgColor

        let ratio = max > 0 ? Swift.max(0, Swift.min(1, CGFloat(current) / CGFloat(max))) : 0
        if ratio > 0 {                       // no sliver of fill at 0 HP
            let fill = NSView(frame: NSRect(x: 0, y: 0, width: Swift.max(2, width * ratio), height: 8))
            fill.autoresizingMask = []
            fill.wantsLayer = true
            fill.layer?.cornerRadius = 4
            let auto: NSColor = ratio > 0.5 ? .systemGreen : (ratio > 0.2 ? .systemYellow : .systemRed)
            fill.layer?.backgroundColor = (color ?? auto).cgColor
            addSubview(fill)
        }
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

        let hp = NSTextField(labelWithString: mon.isFainted
            ? "\(L("detail.revive.in")) \(OwnedPokemon.timeUntilDailyHeal)"
            : "\(mon.currentHP)/\(mon.maxHP)")
        hp.font = .monospacedSystemFont(ofSize: 10, weight: .medium)
        hp.textColor = mon.isFainted ? .systemRed : Palette.label
        hp.alignment = .right
        hp.frame = NSRect(x: 180, y: 27, width: 116, height: 14)
        addSubview(hp)

        if let badge = StatusBadge(mon: mon) {
            addSubview(badge)
            NSLayoutConstraint.activate([
                badge.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
                badge.topAnchor.constraint(equalTo: topAnchor, constant: 7),
            ])
        }
    }
    required init?(coder: NSCoder) { fatalError("not used") }

    override func mouseDown(with event: NSEvent) { onClick() }
}
