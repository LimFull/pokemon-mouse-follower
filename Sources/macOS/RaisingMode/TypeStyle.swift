// Raising mode — type colors (macOS bridge) + a small colored "type badge"
// chip. The canonical palette lives in Core/Raising/TypeStyleCore.swift.

import AppKit

extension NSColor {
    convenience init(_ rgba: RGBA) {
        self.init(srgbRed: rgba.r, green: rgba.g, blue: rgba.b, alpha: rgba.a)
    }
}

extension RGBA {
    var cgColor: CGColor { NSColor(self).cgColor }
}

extension TypeStyle {
    static func color(_ type: String?) -> NSColor { NSColor(rgba(type)) }
}

/// A small pill showing a type name on its type color.
final class TypeBadge: NSView {
    init(_ type: String) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = TypeStyle.color(type).cgColor
        layer?.cornerRadius = 8

        let label = NSTextField(labelWithString: type.uppercased())
        label.font = .systemFont(ofSize: 10, weight: .heavy)
        label.textColor = .white
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 9),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -9),
            heightAnchor.constraint(equalToConstant: 16),
        ])
    }
    required init?(coder: NSCoder) { fatalError("not used") }
}
