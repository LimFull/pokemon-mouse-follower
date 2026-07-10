// Raising mode — canonical type colors (platform-neutral half; the macOS
// TypeBadge chip and NSColor bridge live in Sources/macOS/RaisingMode/
// TypeStyle.swift).
//
// EoS/mainline type names (see rom-extract TYPE_NAMES). ROM ships tiny
// palette-dependent type symbols; canonical type colors read cleaner in the UI.

enum TypeStyle {
    static func rgba(_ type: String?) -> RGBA {
        switch (type ?? "").lowercased() {
        case "normal":   return RGBA(hex: 0xA8A878)
        case "fire":     return RGBA(hex: 0xF08030)
        case "water":    return RGBA(hex: 0x6890F0)
        case "grass":    return RGBA(hex: 0x78C850)
        case "electric": return RGBA(hex: 0xF8C030)
        case "ice":      return RGBA(hex: 0x98D8D8)
        case "fighting": return RGBA(hex: 0xC03028)
        case "poison":   return RGBA(hex: 0xA040A0)
        case "ground":   return RGBA(hex: 0xE0C068)
        case "flying":   return RGBA(hex: 0xA890F0)
        case "psychic":  return RGBA(hex: 0xF85888)
        case "bug":      return RGBA(hex: 0xA8B820)
        case "rock":     return RGBA(hex: 0xB8A038)
        case "ghost":    return RGBA(hex: 0x705898)
        case "dragon":   return RGBA(hex: 0x7038F8)
        case "dark":     return RGBA(hex: 0x705848)
        case "steel":    return RGBA(hex: 0xB8B8D0)
        case "fairy":    return RGBA(hex: 0xEE99AC)
        default:         return RGBA(hex: 0x9AA0A6)   // Neutral / None / unknown
        }
    }
}
