// Shared UI style: the pinned-zoom host for UI scaling, rounded font
// helper, and the app palette.

import Cocoa

// MARK: - UI style (cute, Pokémon-flavored settings look)
/// Renders a 1x-laid-out document view zoomed by AppSettings.uiScale, via
/// NSScrollView magnification — the OS zoom path (pinch-zoom), so it stays
/// vector-crisp and correct with layer-backed views (scaleUnitSquare is not:
/// its bounds transform scales about the wrong corner once AppKit hoists the
/// hierarchy into layers). The magnification is pinned so the user's own
/// pinch gesture can't change it.
final class UIZoomHost: NSScrollView {
    init(document: NSView) {
        super.init(frame: .zero)
        drawsBackground = false
        hasVerticalScroller = false
        hasHorizontalScroller = false
        verticalScrollElasticity = .none
        horizontalScrollElasticity = .none
        allowsMagnification = true
        documentView = document
    }
    required init?(coder: NSCoder) { fatalError("not used") }

    /// Size the document to its 1x size and the host to the zoomed size.
    func layoutZoomed(size1x: CGSize, _ k: CGFloat) {
        documentView?.frame = CGRect(origin: .zero, size: size1x)
        // Re-pin in an order that keeps min <= max at every step — going up
        // from an already-pinned factor, setting min first throws (and going
        // down, max first would).
        maxMagnification = max(k, maxMagnification)
        minMagnification = k
        maxMagnification = k
        magnification = k
        frame = CGRect(x: 0, y: 0, width: size1x.width * k, height: size1x.height * k)
        contentView.scroll(to: .zero)
    }
}
extension NSFont {
    /// Friendly rounded system font; falls back to the default if unavailable.
    static func rounded(_ size: CGFloat, _ weight: NSFont.Weight = .regular) -> NSFont {
        let base = NSFont.systemFont(ofSize: size, weight: weight)
        guard let d = base.fontDescriptor.withDesign(.rounded) else { return base }
        return NSFont(descriptor: d, size: size) ?? base
    }
}
enum Palette {
    static func dynamic(_ light: NSColor, _ dark: NSColor) -> NSColor {
        NSColor(name: nil) { $0.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light }
    }
    // General highlight (labels, values, active borders, action buttons):
    // calm indigo in the violet family the labels/cards already lean toward —
    // red is reserved for actual danger (fainted, release, recall).
    static let accent = dynamic(NSColor(srgbRed: 0.42, green: 0.36, blue: 0.80, alpha: 1),
                                NSColor(srgbRed: 0.64, green: 0.62, blue: 0.98, alpha: 1))
    // Emphasized TEXT: grayish near-black (near-white in dark mode) — colored
    // accents are for borders/fills, not prose.
    static let ink = dynamic(NSColor(srgbRed: 0.18, green: 0.17, blue: 0.20, alpha: 1),
                             NSColor(srgbRed: 0.92, green: 0.92, blue: 0.94, alpha: 1))
    static let danger = NSColor(srgbRed: 1.0, green: 0.44, blue: 0.42, alpha: 1)   // warm coral-red
    static let windowBG = dynamic(NSColor(srgbRed: 1.0, green: 0.98, blue: 0.95, alpha: 1),
                                  NSColor(srgbRed: 0.11, green: 0.11, blue: 0.13, alpha: 1))
    static let cardTop = dynamic(.white, NSColor(srgbRed: 0.18, green: 0.18, blue: 0.20, alpha: 1))
    static let cardBottom = dynamic(NSColor(srgbRed: 0.96, green: 0.95, blue: 1.0, alpha: 1),
                                    NSColor(srgbRed: 0.14, green: 0.14, blue: 0.16, alpha: 1))
    static let cardBorder = dynamic(NSColor(srgbRed: 0.90, green: 0.88, blue: 0.94, alpha: 1),
                                    NSColor(srgbRed: 0.30, green: 0.30, blue: 0.34, alpha: 1))
    static let label = dynamic(NSColor(srgbRed: 0.38, green: 0.35, blue: 0.42, alpha: 1),
                               NSColor(srgbRed: 0.80, green: 0.80, blue: 0.84, alpha: 1))
}
