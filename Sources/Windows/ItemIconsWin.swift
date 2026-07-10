// Item icons on Windows (Phase 5b): an RGBABuffer raster port of the macOS
// CGContext drawings in Sources/macOS/RaisingMode/Items.swift — same 16x16
// pixel-art shapes, no ROM graphics. The tiny canvas keeps a CG-style y-up
// coordinate system so the shape code transcribes 1:1 from the macOS file.

import Foundation

/// 16x16 premultiplied-RGBA canvas with CG-flavored (y-up) drawing helpers.
private struct IconCanvas {
    static let side = 16
    var px = [UInt8](repeating: 0, count: side * side * 4)
    var fillColor = RGBA(white: 0)

    mutating func setFill(_ c: RGBA) { fillColor = c }

    /// Premultiplied src-over of fillColor at canvas pixel (top-down index).
    private mutating func blend(_ ix: Int, _ iy: Int, _ coverage: Double) {
        guard ix >= 0, ix < Self.side, iy >= 0, iy < Self.side, coverage > 0 else { return }
        let a = UInt32(max(0, min(1, fillColor.a * coverage)) * 255)
        guard a > 0 else { return }
        let p = (iy * Self.side + ix) * 4
        let ia = 255 - a
        px[p]     = UInt8((UInt32(fillColor.r * 255) * a / 255) + UInt32(px[p]) * ia / 255)
        px[p + 1] = UInt8((UInt32(fillColor.g * 255) * a / 255) + UInt32(px[p + 1]) * ia / 255)
        px[p + 2] = UInt8((UInt32(fillColor.b * 255) * a / 255) + UInt32(px[p + 2]) * ia / 255)
        px[p + 3] = UInt8(min(255, a + UInt32(px[p + 3]) * ia / 255))
    }

    /// Iterate canvas pixels whose CG-space (y-up) center falls in the test.
    private mutating func rasterize(_ inside: (Double, Double) -> Double) {
        for iy in 0..<Self.side {
            let cgY = Double(Self.side - 1 - iy) + 0.5   // y-up center
            for ix in 0..<Self.side {
                let cgX = Double(ix) + 0.5
                blend(ix, iy, inside(cgX, cgY))
            }
        }
    }

    mutating func fill(x: Double, y: Double, w: Double, h: Double,
                       clipTopHalfAbove: Double? = nil) {
        rasterize { px, py in
            guard px >= x, px <= x + w, py >= y, py <= y + h else { return 0 }
            if let clip = clipTopHalfAbove, py < clip { return 0 }
            return 1
        }
    }

    mutating func fillEllipse(x: Double, y: Double, w: Double, h: Double,
                              clipTopHalfAbove: Double? = nil) {
        let cx = x + w / 2, cy = y + h / 2, rx = w / 2, ry = h / 2
        rasterize { px, py in
            if let clip = clipTopHalfAbove, py < clip { return 0 }
            let nx = (px - cx) / rx, ny = (py - cy) / ry
            return nx * nx + ny * ny <= 1 ? 1 : 0
        }
    }

    mutating func strokeEllipse(x: Double, y: Double, w: Double, h: Double, width: Double) {
        let cx = x + w / 2, cy = y + h / 2, rx = w / 2, ry = h / 2
        rasterize { px, py in
            let nx = (px - cx) / rx, ny = (py - cy) / ry
            let d = (nx * nx + ny * ny).squareRoot()
            // Band around the unit circle, half the stroke width each side
            // (approximated in normalized space against the mean radius).
            let halfW = width / 2 / ((rx + ry) / 2)
            return abs(d - 1) <= halfW ? 1 : 0
        }
    }

    /// Convex polygon fill (diamond, hexagon) via the even-odd half-plane test.
    mutating func fillPolygon(_ pts: [(Double, Double)]) {
        rasterize { px, py in
            var inside = false
            var j = pts.count - 1
            for i in 0..<pts.count {
                let (xi, yi) = pts[i], (xj, yj) = pts[j]
                if (yi > py) != (yj > py),
                   px < (xj - xi) * (py - yi) / (yj - yi) + xi {
                    inside.toggle()
                }
                j = i
            }
            return inside ? 1 : 0
        }
    }

    var buffer: RGBABuffer { RGBABuffer(width: Self.side, height: Self.side, pixels: px) }
}

enum ItemIconsWin {
    private static var cache: [GameItem: PMFImage] = [:]

    static func icon(_ item: GameItem) -> PMFImage? {
        if let c = cache[item] { return c }
        let img = PlatformImageIO.makeImage(draw(item))
        if let img { cache[item] = img }
        return img
    }

    // Shape-for-shape transcription of Items.swift drawIcon (CG y-up coords).
    private static func draw(_ item: GameItem) -> RGBABuffer {
        var c = IconCanvas()
        let s = 16.0
        switch item {
        case .pokeBall, .greatBall:
            // Bottom white half, top colored half, band + button.
            c.setFill(RGBA(white: 1)); c.fillEllipse(x: 1, y: 1, w: 14, h: 14)
            c.setFill(item == .pokeBall ? RGBA(r: 0.90, g: 0.20, b: 0.22)
                                        : RGBA(r: 0.23, g: 0.42, b: 0.85))
            c.fillEllipse(x: 1, y: 1, w: 14, h: 14, clipTopHalfAbove: 8)
            c.setFill(RGBA(white: 0.15)); c.fill(x: 1, y: 7, w: 14, h: 2)
            c.setFill(RGBA(white: 1)); c.fillEllipse(x: 6, y: 6, w: 4, h: 4)
            c.setFill(RGBA(white: 0.15)); c.strokeEllipse(x: 6, y: 6, w: 4, h: 4, width: 1)
        case .potion, .superPotion:
            c.setFill(item == .potion ? RGBA(r: 0.62, g: 0.36, b: 0.86)
                                      : RGBA(r: 0.95, g: 0.62, b: 0.18))
            c.fill(x: 4, y: 1, w: 8, h: 9)                  // bottle body
            c.fillEllipse(x: 4, y: 0, w: 8, h: 6)
            c.fill(x: 6, y: 10, w: 4, h: 3)                 // neck
            c.setFill(RGBA(white: 0.8)); c.fill(x: 5, y: 13, w: 6, h: 2)          // cap
            c.setFill(RGBA(white: 1, alpha: 0.45)); c.fill(x: 5, y: 3, w: 2, h: 5) // shine
        case .fullHeal:
            // Yellow spray bottle, nozzle to the left with a puff of mist.
            c.setFill(RGBA(r: 0.97, g: 0.80, b: 0.20))
            c.fill(x: 6, y: 1, w: 8, h: 9)                  // bottle body
            c.setFill(RGBA(white: 0.35))
            c.fill(x: 7, y: 10, w: 6, h: 4)                 // trigger head
            c.fill(x: 4, y: 11, w: 3, h: 2)                 // nozzle
            c.setFill(RGBA(white: 1, alpha: 0.45)); c.fill(x: 7, y: 3, w: 2, h: 5) // shine
            c.setFill(RGBA(white: 0.92, alpha: 0.9))
            c.fillEllipse(x: 1, y: 12, w: 2, h: 2)          // mist
            c.fillEllipse(x: 2, y: 9, w: 2, h: 2)
        case .revive:
            c.setFill(RGBA(r: 0.98, g: 0.83, b: 0.25))
            c.fillPolygon([(8, 1), (15, 8), (8, 15), (1, 8)])   // diamond
            c.setFill(RGBA(white: 1, alpha: 0.55)); c.fillEllipse(x: 5, y: 7, w: 4, h: 4)
        case .fireStone, .thunderStone, .waterStone, .leafStone, .moonStone, .sunStone:
            let color: RGBA
            switch item {
            case .fireStone: color = TypeStyle.rgba("Fire")
            case .thunderStone: color = TypeStyle.rgba("Electric")
            case .waterStone: color = TypeStyle.rgba("Water")
            case .leafStone: color = TypeStyle.rgba("Grass")
            case .moonStone: color = RGBA(r: 0.55, g: 0.50, b: 0.75)
            default: color = RGBA(r: 0.95, g: 0.55, b: 0.25)
            }
            c.setFill(color)
            c.fillPolygon([(8, 1), (14, 5), (14, 11), (8, 15), (2, 11), (2, 5)])  // hexagon gem
            c.setFill(RGBA(white: 1, alpha: 0.5)); c.fill(x: 5, y: 8, w: 3, h: 4)
        case .linkCord:
            c.setFill(RGBA(white: 0.55))
            c.strokeEllipse(x: 2, y: 4, w: 10, h: 10, width: 2.5)   // coiled cable
            c.setFill(RGBA(r: 0.35, g: 0.65, b: 0.9))
            c.fill(x: 11, y: 1, w: 4, h: 5)                          // plug
        case .friendCandy:
            c.setFill(RGBA(r: 0.96, g: 0.55, b: 0.70))
            c.fillEllipse(x: 2, y: 2, w: 12, h: 12)
            c.setFill(RGBA(r: 1.0, g: 0.80, b: 0.88))
            c.fillEllipse(x: 5, y: 6, w: 5, h: 5)
        }
        _ = s
        return c.buffer
    }
}
