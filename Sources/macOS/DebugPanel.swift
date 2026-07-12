// Dev-only debug panel (user request): a floating window that stays open
// like the settings panel, with every DebugCatalog action one click away —
// no more 디버그 submenu diving per test. Menu-bar entry: "디버그 패널…".

import AppKit

final class DebugPanelController: NSObject {
    private var panel: NSPanel?
    private var flat: [DebugAction] = []
    // Custom battle: pick any opponent + up to 4 moves. "완전 랜덤" only
    // DICE-ROLLS the form — the start button is the single trigger.
    private var startCustom: ((Int, [Int]) -> Void)?
    private var speciesBox: NSComboBox?
    private var moveBoxes: [NSComboBox] = []
    private var moveToggles: [NSButton] = []
    private var speciesList: [(name: String, dex: Int)] = []
    private var moveNameList: [(name: String, id: Int)] = []
    private var speciesByName: [String: Int] = [:]
    private var movesByName: [String: Int] = [:]

    func show(sections: [DebugSection],
              startCustom: @escaping (Int, [Int]) -> Void) {
        self.startCustom = startCustom
        if panel == nil { build(sections) }
        NSApp.activate(ignoringOtherApps: true)
        panel?.makeKeyAndOrderFront(nil)
    }

    /// The custom-battle rows: species + 4 move combo boxes (autocompleting
    /// text fields backed by the full lists) and the two start buttons.
    private func customBattleViews() -> [NSView] {
        func combo(_ names: [String], placeholder: String, width: CGFloat) -> NSComboBox {
            let cb = NSComboBox()
            cb.completes = true
            cb.addItems(withObjectValues: names)
            cb.placeholderString = placeholder
            cb.controlSize = .small
            cb.font = .systemFont(ofSize: 11)
            cb.widthAnchor.constraint(equalToConstant: width).isActive = true
            return cb
        }
        speciesList = DebugCatalog.speciesChoices
        speciesByName = Dictionary(speciesList.map { ($0.name, $0.dex) }, uniquingKeysWith: { a, _ in a })
        moveNameList = DebugCatalog.moveChoices
        movesByName = Dictionary(moveNameList.map { ($0.name, $0.id) }, uniquingKeysWith: { a, _ in a })

        let sp = combo(speciesList.map(\.name), placeholder: "상대 포켓몬", width: 150)
        speciesBox = sp
        moveBoxes = (1...4).map { combo(moveNameList.map(\.name), placeholder: "기술 \($0)", width: 122) }
        // Per-slot on/off: an OFF slot is excluded from the loadout without
        // clearing what's typed in it.
        moveToggles = (0..<4).map { _ in
            let t = NSButton(checkboxWithTitle: "", target: nil, action: nil)
            t.state = .on
            t.controlSize = .small
            return t
        }

        let startBtn = NSButton(title: "커스텀 배틀 시작", target: self, action: #selector(fireCustom))
        let randomBtn = NSButton(title: "완전 랜덤", target: self, action: #selector(fireRandom))
        for b in [startBtn, randomBtn] {
            b.bezelStyle = .rounded
            b.controlSize = .small
            b.font = .systemFont(ofSize: 11)
        }

        func hstack(_ views: [NSView]) -> NSStackView {
            let r = NSStackView(views: views)
            r.orientation = .horizontal
            r.spacing = 6
            return r
        }
        return [hstack([sp, startBtn, randomBtn]),
                hstack([moveBoxes[0], moveToggles[0], moveBoxes[1], moveToggles[1]]),
                hstack([moveBoxes[2], moveToggles[2], moveBoxes[3], moveToggles[3]])]
    }

    @objc private func fireCustom() {
        let name = speciesBox?.stringValue.trimmingCharacters(in: .whitespaces) ?? ""
        guard let dex = speciesByName[name] else { NSSound.beep(); return }
        let mv = zip(moveBoxes, moveToggles).compactMap { box, toggle -> Int? in
            guard toggle.state == .on else { return nil }
            return movesByName[box.stringValue.trimmingCharacters(in: .whitespaces)]
        }
        startCustom?(dex, mv)
    }

    /// Dice-roll the form: random species + 4 distinct random moves land in
    /// the combo boxes so the loadout is visible (and tweakable) before the
    /// start button fires it.
    @objc private func fireRandom() {
        let loadout = DebugCatalog.randomLoadout()
        if let name = speciesList.first(where: { $0.dex == loadout.dex })?.name {
            speciesBox?.stringValue = name
        }
        for (i, box) in moveBoxes.enumerated() {
            moveToggles[i].state = .on   // a fresh roll re-includes every slot
            guard i < loadout.moves.count,
                  let name = moveNameList.first(where: { $0.id == loadout.moves[i] })?.name else {
                box.stringValue = ""
                continue
            }
            box.stringValue = name
        }
    }

    private func build(_ sections: [DebugSection]) {
        flat = sections.flatMap(\.actions)

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        stack.edgeInsets = NSEdgeInsets(top: 12, left: 14, bottom: 14, right: 14)

        let customLabel = NSTextField(labelWithString: "커스텀 배틀 — 포켓몬·기술 직접 지정 (빈 기술칸은 자연 기술셋)")
        customLabel.font = .boldSystemFont(ofSize: 11)
        customLabel.textColor = .secondaryLabelColor
        stack.addArrangedSubview(customLabel)
        customBattleViews().forEach { stack.addArrangedSubview($0) }
        stack.addArrangedSubview(NSView())

        var tag = 0
        for section in sections {
            let label = NSTextField(labelWithString: section.title)
            label.font = .boldSystemFont(ofSize: 11)
            label.textColor = .secondaryLabelColor
            stack.addArrangedSubview(label)
            // Two buttons per row keeps the long encounter list compact.
            var row: NSStackView?
            for action in section.actions {
                let b = NSButton(title: action.title, target: self, action: #selector(fire(_:)))
                b.tag = tag; tag += 1
                b.bezelStyle = .rounded
                b.controlSize = .small
                b.font = .systemFont(ofSize: 11)
                if let r = row, r.arrangedSubviews.count < 2 {
                    r.addArrangedSubview(b)
                    row = nil
                } else {
                    let r = NSStackView(views: [b])
                    r.orientation = .horizontal
                    r.spacing = 6
                    stack.addArrangedSubview(r)
                    row = r
                }
            }
            stack.addArrangedSubview(NSView())   // small section gap
        }

        let size = stack.fittingSize
        let p = NSPanel(contentRect: NSRect(origin: .zero, size: size),
                        styleMask: [.titled, .closable, .utilityWindow],
                        backing: .buffered, defer: false)
        p.title = "디버그"
        p.level = .floating                       // stays above the overlays
        p.isReleasedWhenClosed = false
        p.hidesOnDeactivate = false               // keep it up while testing the app
        stack.frame = NSRect(origin: .zero, size: size)
        p.contentView = stack
        p.center()
        panel = p
    }

    @objc private func fire(_ sender: NSButton) {
        guard flat.indices.contains(sender.tag) else { return }
        flat[sender.tag].run()
    }
}
