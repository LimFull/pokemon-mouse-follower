// Raising mode — type colors + a small colored "type badge" chip.
//
// EoS/mainline type names (see rom-extract TYPE_NAMES). ROM ships tiny
// palette-dependent type symbols; canonical type colors read cleaner in the UI.

import AppKit

enum TypeStyle {
    static func color(_ type: String?) -> NSColor {
        switch (type ?? "").lowercased() {
        case "normal":   return hex(0xA8A878)
        case "fire":     return hex(0xF08030)
        case "water":    return hex(0x6890F0)
        case "grass":    return hex(0x78C850)
        case "electric": return hex(0xF8C030)
        case "ice":      return hex(0x98D8D8)
        case "fighting": return hex(0xC03028)
        case "poison":   return hex(0xA040A0)
        case "ground":   return hex(0xE0C068)
        case "flying":   return hex(0xA890F0)
        case "psychic":  return hex(0xF85888)
        case "bug":      return hex(0xA8B820)
        case "rock":     return hex(0xB8A038)
        case "ghost":    return hex(0x705898)
        case "dragon":   return hex(0x7038F8)
        case "dark":     return hex(0x705848)
        case "steel":    return hex(0xB8B8D0)
        case "fairy":    return hex(0xEE99AC)
        default:         return hex(0x9AA0A6)   // Neutral / None / unknown
        }
    }

    private static func hex(_ v: Int) -> NSColor {
        NSColor(srgbRed: CGFloat((v >> 16) & 0xFF) / 255.0,
                green: CGFloat((v >> 8) & 0xFF) / 255.0,
                blue: CGFloat(v & 0xFF) / 255.0, alpha: 1)
    }
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
