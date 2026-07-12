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
    private var bagExpanded = false        // bag card disclosure state
    private var starterPopup: NSPopUpButton?

    /// Called whenever a refresh may have changed the content height, so the
    /// settings window can resize to fit.
    var onContentChanged: (() -> Void)?

    /// Height the current content actually needs (top offset + stack + margin).
    var contentHeight: CGFloat {
        guard let root = subviews.first as? NSStackView else { return 0 }
        root.layoutSubtreeIfNeeded()
        return root.fittingSize.height + 22 + 24
    }

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

    /// Keep the panel fresh while it's open: every second during a battle
    /// (live gauge drives the potion buttons), every minute for the fainted
    /// members' revive countdown.
    private var countdownTimer: Timer?
    private var timerTicks = 0
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        countdownTimer?.invalidate()
        countdownTimer = nil
        guard window != nil else { return }
        let t = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            guard let self, self.window != nil else { return }
            self.timerTicks += 1
            if BattleController.current?.isBattling == true { self.refresh(); return }
            if self.timerTicks % 60 == 0,
               RaisingState.shared.party.contains(where: { $0.isFainted }) { self.refresh() }
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
            buildDetail(displayMon(RaisingState.shared.party[i], at: i), into: root)
        } else {
            buildList(root)
        }
        onContentChanged?()
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

    /// The mon as it should be DISPLAYED right now: while its battle plays,
    /// the active member's HP and ailment come from the live playback gauge —
    /// the save only updates when the battle ends, so rows/detail would lag
    /// a whole fight behind otherwise.
    private func displayMon(_ mon: OwnedPokemon, at index: Int) -> OwnedPokemon {
        guard index == RaisingState.shared.save.activeIndex,
              let bc = BattleController.current,
              let frac = bc.playerGaugeFraction else { return mon }
        var live = mon
        live.currentHP = max(0, min(mon.maxHP, Int((frac * Double(mon.maxHP)).rounded())))
        live.status = bc.playerLiveStatus
        return live
    }

    // MARK: party list (mainline party-menu style)

    private func buildList(_ root: NSStackView) {
        let party = RaisingState.shared.party
        root.addArrangedSubview(sectionLabel("\(L("detail.party"))  \(party.count)/\(RaisingState.maxParty)"))

        let activeIdx = RaisingState.shared.save.activeIndex
        let recallPending = BattleController.current?.recallPending ?? false
        for (i, mon) in party.enumerated() {
            let row = PartyRowView(mon: displayMon(mon, at: i), isActive: i == activeIdx,
                                   onClick: { [weak self] in
                                       self?.detailIndex = i
                                       self?.refresh()
                                   },
                                   onSendOut: mon.isFainted || i == activeIdx ? nil : {
                                       RaisingState.shared.setActive(i)
                                   },
                                   onRecall: i == activeIdx ? {
                                       RaisingState.shared.recall()
                                   } : nil,
                                   recallPending: recallPending)
            root.addArrangedSubview(row)
        }

        // Bag (D12): a collapsible, game-styled card. Header always visible;
        // expanding reveals a scrollable item list so a stuffed bag never
        // pushes the reset button off-panel.
        root.setCustomSpacing(16, after: root.arrangedSubviews.last ?? root)
        root.addArrangedSubview(bagHeader())
        if bagExpanded { root.addArrangedSubview(bagCard()) }

        // Raising-only settings (moved off the general pane): encounter
        // interval + master switches for wild and item spawns.
        root.setCustomSpacing(16, after: root.arrangedSubviews.last ?? root)
        root.addArrangedSubview(sectionLabel("⚙︎ " + L("raising.settings")))
        root.addArrangedSubview(encounterRow())
        let wildCB = NSButton(checkboxWithTitle: L("label.wildspawn"), target: self,
                              action: #selector(wildSpawnToggled(_:)))
        wildCB.state = AppSettings.shared.wildSpawnsEnabled ? .on : .off
        wildCB.font = .rounded(12, .medium)
        root.addArrangedSubview(wildCB)
        let itemCB = NSButton(checkboxWithTitle: L("label.itemspawn"), target: self,
                              action: #selector(itemSpawnToggled(_:)))
        itemCB.state = AppSettings.shared.itemSpawnsEnabled ? .on : .off
        itemCB.font = .rounded(12, .medium)
        root.addArrangedSubview(itemCB)
        let dmgCB = NSButton(checkboxWithTitle: L("label.damagenumbers"), target: self,
                             action: #selector(damageNumbersToggled(_:)))
        dmgCB.state = AppSettings.shared.damageNumbersEnabled ? .on : .off
        dmgCB.font = .rounded(12, .medium)
        root.addArrangedSubview(dmgCB)
        let logCB = NSButton(checkboxWithTitle: L("label.battlelog"), target: self,
                             action: #selector(battleLogToggled(_:)))
        logCB.state = AppSettings.shared.battleLogEnabled ? .on : .off
        logCB.font = .rounded(12, .medium)
        root.addArrangedSubview(logCB)

        root.setCustomSpacing(18, after: root.arrangedSubviews.last ?? root)
        let reset = NSButton(title: L("detail.reset"), target: self, action: #selector(resetTapped))
        reset.bezelStyle = .rounded
        root.addArrangedSubview(reset)
    }

    // MARK: raising settings

    private var encounterValueLabel: NSTextField?

    private func encounterRow() -> NSStackView {
        let label = monoLabel(L("label.encounter"), 12, .medium)
        let slider = NSSlider(value: Double(AppSettings.shared.encounterMinutes),
                              minValue: AppSettings.encounterRange.lowerBound,
                              maxValue: AppSettings.encounterRange.upperBound,
                              target: self, action: #selector(encounterChanged(_:)))
        slider.isContinuous = true
        slider.translatesAutoresizingMaskIntoConstraints = false
        slider.widthAnchor.constraint(equalToConstant: 130).isActive = true
        let value = monoLabel(String(format: "%.0fm", AppSettings.shared.encounterMinutes), 12, .semibold)
        value.textColor = Palette.ink
        encounterValueLabel = value
        let row = NSStackView(views: [label, slider, value])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 8
        return row
    }

    @objc private func encounterChanged(_ sender: NSSlider) {
        AppSettings.shared.encounterMinutes = CGFloat(sender.doubleValue)
        encounterValueLabel?.stringValue = String(format: "%.0fm", sender.doubleValue)
    }

    @objc private func wildSpawnToggled(_ sender: NSButton) {
        AppSettings.shared.wildSpawnsEnabled = (sender.state == .on)
    }

    @objc private func itemSpawnToggled(_ sender: NSButton) {
        AppSettings.shared.itemSpawnsEnabled = (sender.state == .on)
    }

    @objc private func battleLogToggled(_ sender: NSButton) {
        AppSettings.shared.battleLogEnabled = (sender.state == .on)
    }

    @objc private func damageNumbersToggled(_ sender: NSButton) {
        AppSettings.shared.damageNumbersEnabled = (sender.state == .on)
    }

    // MARK: bag UI

    private func bagHeader() -> NSButton {
        let total = GameItem.allCases.reduce(0) { $0 + RaisingState.shared.itemCount($1) }
        let b = NSButton(title: "", target: self, action: #selector(bagToggled))
        b.isBordered = false
        b.alignment = .left
        b.attributedTitle = NSAttributedString(
            string: "\(L("detail.bag"))  ·  \(total)  \(bagExpanded ? "▾" : "▸")",
            attributes: [.font: NSFont.rounded(13, .bold), .foregroundColor: Palette.ink])
        // Bundled backpack SVG (Lucide, ISC) as a template so it tints with
        // the appearance; the old 🎒 emoji couldn't follow the palette.
        if let url = Bundle.main.url(forResource: "backpack", withExtension: "svg"),
           let icon = NSImage(contentsOf: url) {
            icon.size = NSSize(width: 15, height: 15)
            icon.isTemplate = true
            b.image = icon
            b.imagePosition = .imageLeading
            b.contentTintColor = Palette.ink
        }
        return b
    }

    @objc private func bagToggled() {
        bagExpanded.toggle()
        refresh()
    }

    /// The opened bag: capture toggle on top, then a scrollable item list.
    private func bagCard() -> NSView {
        let card = NSView()
        card.translatesAutoresizingMaskIntoConstraints = false
        card.wantsLayer = true
        card.layer?.cornerRadius = 10
        card.layer?.borderWidth = 1.5
        effectiveAppearance.performAsCurrentDrawingAppearance {
            card.layer?.backgroundColor = Palette.cardBottom.cgColor
            card.layer?.borderColor = Palette.accent.withAlphaComponent(0.45).cgColor
        }

        // Capture toggle (#2): balls only fly in battle while this is on.
        let toggle = NSButton(checkboxWithTitle: L("bag.capture"), target: self,
                              action: #selector(captureToggled(_:)))
        toggle.state = RaisingState.shared.captureEnabled ? .on : .off
        toggle.font = .rounded(12, .semibold)
        toggle.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(toggle)

        let divider = NSBox()
        divider.boxType = .separator
        divider.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(divider)

        // Scrollable item list.
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 7
        stack.edgeInsets = NSEdgeInsets(top: 6, left: 10, bottom: 6, right: 10)
        stack.translatesAutoresizingMaskIntoConstraints = false
        let bag = GameItem.allCases.filter { RaisingState.shared.itemCount($0) > 0 }
        if bag.isEmpty {
            stack.addArrangedSubview(monoLabel("—", 12, .regular))
        }
        for item in bag {
            stack.addArrangedSubview(bagRow(item, count: RaisingState.shared.itemCount(item)))
        }
        let doc = FlippedView()
        doc.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: doc.topAnchor),
            stack.leadingAnchor.constraint(equalTo: doc.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: doc.trailingAnchor),
        ])
        doc.layoutSubtreeIfNeeded()
        let contentH = stack.fittingSize.height
        doc.frame = NSRect(x: 0, y: 0, width: Self.contentWidth - 8, height: contentH)

        let scroll = NSScrollView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.documentView = doc
        card.addSubview(scroll)

        let listH = min(150, contentH)
        NSLayoutConstraint.activate([
            card.widthAnchor.constraint(equalToConstant: Self.contentWidth),
            toggle.topAnchor.constraint(equalTo: card.topAnchor, constant: 9),
            toggle.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 12),
            divider.topAnchor.constraint(equalTo: toggle.bottomAnchor, constant: 8),
            divider.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 10),
            divider.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -10),
            scroll.topAnchor.constraint(equalTo: divider.bottomAnchor, constant: 2),
            scroll.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 4),
            scroll.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -4),
            scroll.heightAnchor.constraint(equalToConstant: listH),
            scroll.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -8),
        ])
        return card
    }

    @objc private func captureToggled(_ sender: NSButton) {
        RaisingState.shared.setCaptureEnabled(sender.state == .on)
    }

    /// One bag line: pixel icon + name, count right-aligned like a game menu.
    private func bagRow(_ item: GameItem, count: Int) -> NSView {
        let icon = NSImageView()
        if let cg = item.icon {
            icon.image = NSImage(cgImage: cg, size: NSSize(width: 16, height: 16))
        }
        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.widthAnchor.constraint(equalToConstant: 18).isActive = true
        icon.heightAnchor.constraint(equalToConstant: 18).isActive = true
        let name = monoLabel(item.displayName, 12, .medium)
        let qty = monoLabel("×\(count)", 12, .semibold)
        qty.textColor = Palette.ink
        let row = NSStackView(views: [icon, name, NSView(), qty])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 8
        row.translatesAutoresizingMaskIntoConstraints = false
        row.widthAnchor.constraint(equalToConstant: Self.contentWidth - 44).isActive = true
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
        back.contentTintColor = Palette.ink
        back.attributedTitle = NSAttributedString(string: "‹ \(L("detail.party"))",
            attributes: [.foregroundColor: Palette.ink, .font: NSFont.rounded(13, .semibold)])
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
        let st = GameData.stats(s, level: mon.level, ivs: mon.ivs)
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
        // Each row carries a PMD-style ON/OFF switch: OFF moves stay known but
        // the battle AI skips them; all OFF -> the weak typeless regular attack.
        inner.addArrangedSubview(divider())
        inner.addArrangedSubview(monoLabel("▶ \(L("detail.moves"))", 12, .bold))
        for id in mon.moves {
            let enabled = mon.isMoveEnabled(id)
            let name = moveRow(id, enabled: enabled)
            name.setContentHuggingPriority(.defaultLow, for: .horizontal)
            let toggle = NSSwitch()
            toggle.controlSize = .mini
            toggle.state = enabled ? .on : .off
            toggle.target = self
            toggle.action = #selector(moveToggled(_:))
            toggle.tag = id
            toggle.toolTip = L("detail.move.toggle.tip")
            let row = NSStackView(views: [name, toggle])
            row.orientation = .horizontal
            row.alignment = .centerY
            row.spacing = 8
            row.widthAnchor.constraint(equalToConstant: Self.contentWidth - 28).isActive = true
            inner.addArrangedSubview(row)
            if expandedMove == id { inner.addArrangedSubview(moveDetailInline(id)) }
        }
        if !mon.moves.isEmpty, mon.moves.allSatisfy({ !mon.isMoveEnabled($0) }) {
            let hint = monoLabel(L("detail.moves.alloff"), 11, .regular)
            hint.textColor = .secondaryLabelColor
            inner.addArrangedSubview(hint)
        }

        // Usable items on this mon (Phase 3c): potions when hurt, a revive
        // when fainted, evolution items when they'd trigger one (C3/D8-1).
        // While its battle plays, the follower's potions stay VISIBLE even at
        // a full gauge (just disabled) — entering a fight at 100% must not
        // hide the buttons forever; the battle timer refresh enables them the
        // moment the gauge dips.
        guard let idx = detailIndex else { return }
        let state = RaisingState.shared
        let battlingActive = idx == state.save.activeIndex
            && BattleController.current?.playerGaugeFraction != nil
        let shown = GameItem.allCases.filter { item in
            if state.canUseItem(item, at: idx) { return true }
            return battlingActive && (item.healAmount > 0 || item.curesStatus) && state.itemCount(item) > 0
        }
        if !shown.isEmpty {
            let itemStack = NSStackView()
            itemStack.orientation = .vertical
            itemStack.alignment = .leading
            itemStack.spacing = 6
            for item in shown {
                let b = NSButton(title: "\(item.displayName)  ×\(state.itemCount(item))",
                                 target: self, action: #selector(useItemTapped(_:)))
                b.bezelStyle = .rounded
                b.tag = item.rawValue
                b.isEnabled = state.canUseItem(item, at: idx)
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
        if idx == RaisingState.shared.save.activeIndex {
            let back = NSButton(title: L("detail.recall"), target: self, action: #selector(recallActiveTapped))
            back.bezelStyle = .rounded
            back.contentTintColor = Palette.danger
            if BattleController.current?.recallPending == true {
                back.isEnabled = false
            }
            actions.addArrangedSubview(back)
        } else if !mon.isFainted {
            let out = NSButton(title: L("detail.sendout"), target: self, action: #selector(sendOutTapped))
            out.bezelStyle = .rounded
            out.contentTintColor = .systemBlue
            actions.addArrangedSubview(out)
        }
        let release = NSButton(title: L("detail.release"), target: self, action: #selector(releaseTapped))
        release.bezelStyle = .rounded
        release.contentTintColor = .systemRed
        actions.addArrangedSubview(release)
        root.addArrangedSubview(actions)
    }

    @objc private func sendOutTapped() {
        guard let i = detailIndex else { return }
        RaisingState.shared.setActive(i)
        refresh()
    }

    @objc private func recallActiveTapped() {
        RaisingState.shared.recall()
        refresh()
    }

    @objc private func useItemTapped(_ sender: NSButton) {
        guard let i = detailIndex, let item = GameItem(rawValue: sender.tag) else { return }
        let evolved = RaisingState.shared.useItem(item, at: i)
        if let to = evolved {
            let a = NSAlert()
            a.messageText = Characters.displayName(dex: to)
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
        a.informativeText = Characters.displayName(dex: mon.dex)
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
            a.messageText = Characters.displayName(dex: from) + L("evo.suffix")
            a.informativeText = "→ \(Characters.displayName(dex: to))"
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

    // A clickable move line (monospace, retro) that expands/collapses its
    // detail. A toggled-OFF move renders dimmed.
    private func moveRow(_ id: Int, enabled: Bool = true) -> NSButton {
        let m = GameData.moves[id]
        let name = m?.displayName ?? "Move \(id)"
        let arrow = expandedMove == id ? "▾" : "▸"
        let b = NSButton(title: "", target: self, action: #selector(moveTapped(_:)))
        b.isBordered = false
        b.tag = id
        b.alignment = .left
        b.attributedTitle = NSAttributedString(string: "\(arrow) \(name)", attributes: [
            .font: NSFont.monospacedSystemFont(ofSize: 12, weight: .regular),
            .foregroundColor: enabled ? Palette.label : NSColor.tertiaryLabelColor])
        return b
    }

    @objc private func moveTapped(_ sender: NSButton) {
        expandedMove = (expandedMove == sender.tag) ? nil : sender.tag
        refresh()
    }

    @objc private func moveToggled(_ sender: NSSwitch) {
        guard let i = detailIndex else { return }
        RaisingState.shared.setMoveEnabled(sender.tag, sender.state == .on, at: i)
        refresh()   // re-dim the row / show or hide the all-OFF hint
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

        if let d = m.localizedDesc, !d.isEmpty {
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
            if let d = m.localizedDesc, !d.isEmpty {
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

/// Frame-based container whose y grows downward (rows lay out top-down).
final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

final class PartyRowView: NSView {
    private let onClick: () -> Void
    private let onSendOut: (() -> Void)?
    private let onRecall: (() -> Void)?
    override var isFlipped: Bool { true }

    /// `isActive` marks the mon currently out on the desktop; `onSendOut`
    /// (when non-nil) shows the swap button that makes this one the follower,
    /// `onRecall` the withdraw button that puts the active one away.
    /// `recallPending` disables the withdraw button while a mid-battle recall
    /// waits for the turn to finish.
    init(mon: OwnedPokemon, isActive: Bool,
         onClick: @escaping () -> Void, onSendOut: (() -> Void)?,
         onRecall: (() -> Void)? = nil, recallPending: Bool = false) {
        self.onClick = onClick
        self.onSendOut = onSendOut
        self.onRecall = onRecall
        super.init(frame: NSRect(x: 0, y: 0, width: 300, height: 50))
        translatesAutoresizingMaskIntoConstraints = false
        widthAnchor.constraint(equalToConstant: 300).isActive = true
        heightAnchor.constraint(equalToConstant: 50).isActive = true
        wantsLayer = true
        layer?.cornerRadius = 10
        layer?.backgroundColor = Palette.cardTop.cgColor
        layer?.borderWidth = isActive ? 2 : 1
        layer?.borderColor = isActive ? Palette.accent.cgColor : Palette.cardBorder.cgColor

        let folder = Characters.folder(dex: mon.dex)

        let sprite = NSImageView(frame: NSRect(x: 6, y: 5, width: 40, height: 40))
        sprite.image = CharacterPreviewView.stillImage(folder)
        sprite.imageScaling = .scaleProportionallyUpOrDown
        addSubview(sprite)

        var title = "\(Characters.displayName(folder))   \(L("detail.level"))\(mon.level)"
        if isActive { title = "▶ " + title }
        let name = NSTextField(labelWithString: title)
        name.font = .rounded(13, .semibold)
        name.textColor = mon.isFainted ? .systemRed : (isActive ? Palette.ink : Palette.label)
        name.frame = NSRect(x: 54, y: 6, width: 210, height: 18)
        addSubview(name)

        let bar = HPBarView(current: mon.currentHP, max: mon.maxHP, width: 150)
        bar.frame = NSRect(x: 54, y: 30, width: 150, height: 8)
        addSubview(bar)

        let hp = NSTextField(labelWithString: mon.isFainted
            ? "\(L("detail.revive.in")) \(OwnedPokemon.timeUntilDailyHeal)"
            : "\(mon.currentHP)/\(mon.maxHP)")
        hp.font = .monospacedSystemFont(ofSize: 9, weight: .medium)
        hp.textColor = mon.isFainted ? .systemRed : Palette.label
        hp.alignment = .right
        hp.frame = NSRect(x: 152, y: 27, width: 108, height: 14)
        addSubview(hp)

        if let badge = StatusBadge(mon: mon) {
            addSubview(badge)
            NSLayoutConstraint.activate([
                badge.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -36),
                badge.topAnchor.constraint(equalTo: topAnchor, constant: 7),
            ])
        }

        if onSendOut != nil {
            let b = NSButton(title: "", target: self, action: #selector(sendOutTapped))
            b.isBordered = false
            if let img = NSImage(systemSymbolName: "arrowshape.right.circle.fill",
                                 accessibilityDescription: "send out")?
                .withSymbolConfiguration(.init(pointSize: 19, weight: .semibold)) {
                b.image = img
                b.contentTintColor = .systemBlue
            } else {
                b.title = "▶"
            }
            b.frame = NSRect(x: 268, y: 13, width: 26, height: 24)
            b.toolTip = L("detail.sendout")
            addSubview(b)
        }
        if onRecall != nil {
            let b = NSButton(title: "", target: self, action: #selector(recallTapped))
            b.isBordered = false
            if let img = NSImage(systemSymbolName: "arrowshape.left.circle.fill",
                                 accessibilityDescription: "recall")?
                .withSymbolConfiguration(.init(pointSize: 19, weight: .semibold)) {
                b.image = img
                b.contentTintColor = Palette.danger
            } else {
                b.title = "◀"
            }
            b.frame = NSRect(x: 268, y: 13, width: 26, height: 24)
            b.toolTip = L("detail.recall")
            if recallPending { b.isEnabled = false; b.alphaValue = 0.4 }
            addSubview(b)
        }
    }
    required init?(coder: NSCoder) { fatalError("not used") }

    @objc private func sendOutTapped() { onSendOut?() }
    @objc private func recallTapped() { onRecall?() }

    override func mouseDown(with event: NSEvent) { onClick() }
}
