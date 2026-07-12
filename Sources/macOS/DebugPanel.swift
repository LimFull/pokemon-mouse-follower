// Dev-only debug panel (user request): a floating window that stays open
// like the settings panel, with every DebugCatalog action one click away —
// no more 디버그 submenu diving per test. Menu-bar entry: "디버그 패널…".

import AppKit

final class DebugPanelController: NSObject {
    private var panel: NSPanel?
    private var flat: [DebugAction] = []

    func show(sections: [DebugSection]) {
        if panel == nil { build(sections) }
        NSApp.activate(ignoringOtherApps: true)
        panel?.makeKeyAndOrderFront(nil)
    }

    private func build(_ sections: [DebugSection]) {
        flat = sections.flatMap(\.actions)

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        stack.edgeInsets = NSEdgeInsets(top: 12, left: 14, bottom: 14, right: 14)

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
