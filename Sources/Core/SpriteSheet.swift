// Sprite sheet loading/slicing and the PMD marker-sheet readers (shadow
// anchors, AnimData frame sizes). Platform-neutral (design/windows-port.md
// W2): decoding lands in an RGBABuffer, all pixel analysis happens on the
// buffer, and PlatformImageIO converts cells to renderable PMFImages.

import Foundation

// MARK: - Sprite loading / slicing
enum Sprite {
    static func loadBuffer(_ name: String, subdir: String) -> RGBABuffer? {
        guard let url = Resources.url(name, ext: "png", subdir: subdir) else { return nil }
        return PlatformImageIO.decodePNG(url)
    }

    static func loadText(_ name: String, ext: String, subdir: String) -> String? {
        guard let url = Resources.url(name, ext: ext, subdir: subdir) else { return nil }
        return try? String(contentsOf: url, encoding: .utf8)
    }

    // Slice into [row][col] cells (top-left origin). Cells may be non-square.
    static func slice(_ buffer: RGBABuffer, cols: Int, rows: Int, cellW: Int, cellH: Int) -> [[RGBABuffer]] {
        var out: [[RGBABuffer]] = []
        for r in 0..<rows {
            var rowArr: [RGBABuffer] = []
            for c in 0..<cols {
                if let cell = buffer.cropped(x: c * cellW, y: r * cellH, w: cellW, h: cellH) {
                    rowArr.append(cell)
                }
            }
            out.append(rowArr)
        }
        return out
    }

    // Load a sheet PNG and slice it into [row][col] cells using AnimData frame
    // sizes (falling back to square cells across 8 direction rows).
    static func slicedSheetBuffers(_ png: String, anim: String, subdir: String, xml: String?) -> [[RGBABuffer]] {
        guard let img = loadBuffer(png, subdir: subdir) else { return [] }
        var cw = img.height / 8, ch = img.height / 8
        if let xml, let (w, h) = frameSize(anim, in: xml) { cw = w; ch = h }
        guard cw > 0, ch > 0 else { return [] }
        return slice(img, cols: max(1, img.width / cw), rows: max(1, img.height / ch),
                     cellW: cw, cellH: ch)
    }

    /// Renderable frames for a sheet (the pre-W2 slicedSheet signature — macOS
    /// callers keep receiving CGImages through the PMFImage typealias).
    static func slicedSheet(_ png: String, anim: String, subdir: String, xml: String?) -> [[PMFImage]] {
        images(slicedSheetBuffers(png, anim: anim, subdir: subdir, xml: xml))
    }

    /// Convert sliced cells to renderable frames.
    static func images(_ cells: [[RGBABuffer]]) -> [[PMFImage]] {
        cells.map { $0.compactMap { PlatformImageIO.makeImage($0) } }
    }

    /// 8-direction octant of a movement vector (0=E,1=NE,2=N,...,7=SE) — the
    /// PMD sprite sheets' direction resolution.
    static func octant(dx: CGFloat, dy: CGFloat) -> Int {
        var deg = atan2(dy, dx) * 180 / .pi
        if deg < 0 { deg += 360 }
        return Int((deg / 45).rounded()) % 8
    }

    // Shadow marker read from a PMD "-Shadow" cell: the ground-contact center
    // (white pixel) and the footprint size for the given ShadowSize, taken from
    // the nested color regions (green = small, red = medium, blue = large; each
    // encloses the smaller ones). All in image (top-left origin) pixels; nil if
    // the cell has no marker.
    static func shadowMarker(_ cell: RGBABuffer, shadowSize: Int) -> (center: CGPoint, size: CGSize)? {
        let w = cell.width, h = cell.height
        guard w > 0, h > 0 else { return nil }
        let buf = cell.pixels
        var wx = 0.0, wy = 0.0, wn = 0                  // white center pixel(s)
        var cx = 0.0, cy = 0.0, cn = 0                  // any marker pixel (fallback center)
        var sMinX = w, sMinY = h, sMaxX = -1, sMaxY = -1  // footprint for selected size
        var aMinX = w, aMinY = h, aMaxX = -1, aMaxY = -1  // footprint of all regions (fallback)
        for y in 0..<h {                                // buffer row 0 is the top of the image
            let base = y * w * 4
            for x in 0..<w {
                if buf[base + x * 4 + 3] <= 10 { continue }
                let r = buf[base + x * 4], g = buf[base + x * 4 + 1], b = buf[base + x * 4 + 2]
                let white = r > 200 && g > 200 && b > 200
                let blue  = b > 200 && r < 80 && g < 80
                let red   = r > 200 && g < 80 && b < 80
                let green = g > 200 && r < 80 && b < 80
                guard white || blue || red || green else { continue }
                if white { wx += Double(x); wy += Double(y); wn += 1 }
                cx += Double(x); cy += Double(y); cn += 1
                if x < aMinX { aMinX = x }; if x > aMaxX { aMaxX = x }
                if y < aMinY { aMinY = y }; if y > aMaxY { aMaxY = y }
                // Nested selection: small ⊂ medium ⊂ large.
                let inSize = shadowSize <= 0 ? green
                           : shadowSize == 1 ? (green || red)
                           : (green || red || blue)
                if inSize || white {
                    if x < sMinX { sMinX = x }; if x > sMaxX { sMaxX = x }
                    if y < sMinY { sMinY = y }; if y > sMaxY { sMaxY = y }
                }
            }
        }
        guard aMaxX >= 0, cn > 0 else { return nil }
        let center = wn > 0 ? CGPoint(x: wx / Double(wn), y: wy / Double(wn))
                            : CGPoint(x: cx / Double(cn), y: cy / Double(cn))
        let size = sMaxX >= 0 ? CGSize(width: sMaxX - sMinX + 1, height: sMaxY - sMinY + 1)
                              : CGSize(width: aMaxX - aMinX + 1, height: aMaxY - aMinY + 1)
        return (center, size)
    }

    // Bounding box of non-transparent pixels, in image (top-left origin) pixel
    // coords. Returns nil if the frame is fully transparent.
    static func opaqueBBox(_ cell: RGBABuffer, alphaThreshold: UInt8 = 12) -> CGRect? {
        let w = cell.width, h = cell.height
        guard w > 0, h > 0 else { return nil }
        let buf = cell.pixels
        var minX = w, minY = h, maxX = -1, maxY = -1
        for y in 0..<h {
            let base = y * w * 4
            for x in 0..<w where buf[base + x * 4 + 3] >= alphaThreshold {
                if x < minX { minX = x }
                if x > maxX { maxX = x }
                if y < minY { minY = y }
                if y > maxY { maxY = y }
            }
        }
        guard maxX >= 0 else { return nil }
        return CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)
    }

    // Read <FrameWidth>/<FrameHeight> for a named <Anim> from AnimData.xml text.
    static func frameSize(_ anim: String, in xml: String) -> (Int, Int)? {
        for block in xml.components(separatedBy: "</Anim>") where block.contains("<Name>\(anim)</Name>") {
            if let w = intBetween(block, "<FrameWidth>", "</FrameWidth>"),
               let h = intBetween(block, "<FrameHeight>", "</FrameHeight>") {
                return (w, h)
            }
        }
        return nil
    }

    // Read <ShadowSize> (0=small, 1=medium, 2=large). Defaults to medium.
    static func shadowSize(in xml: String) -> Int {
        return intBetween(xml, "<ShadowSize>", "</ShadowSize>") ?? 1
    }

    // The sheet NAME serving ROM anim group `index` (move_animations
    // "animation" -> the species' AnimData.xml <Index>), CopyOf chains
    // resolved: Strike CopyOf Attack -> "Attack" (that name owns the .png
    // and the frame size). nil when the species has no anim at that index.
    static func animName(forIndex index: Int, in xml: String) -> String? {
        var copyOf: [String: String] = [:]
        var found: String?
        for block in xml.components(separatedBy: "</Anim>") {
            guard let name = textBetween(block, "<Name>", "</Name>") else { continue }
            if let c = textBetween(block, "<CopyOf>", "</CopyOf>") { copyOf[name] = c }
            if intBetween(block, "<Index>", "</Index>") == index { found = name }
        }
        guard var name = found else { return nil }
        var seen = Set<String>()
        while let next = copyOf[name], seen.insert(name).inserted { name = next }
        return name
    }

    private static func textBetween(_ s: String, _ a: String, _ b: String) -> String? {
        guard let r1 = s.range(of: a),
              let r2 = s.range(of: b, range: r1.upperBound..<s.endIndex) else { return nil }
        return String(s[r1.upperBound..<r2.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func intBetween(_ s: String, _ a: String, _ b: String) -> Int? {
        guard let r1 = s.range(of: a),
              let r2 = s.range(of: b, range: r1.upperBound..<s.endIndex) else { return nil }
        return Int(s[r1.upperBound..<r2.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines))
    }
}

// Per-frame shadow placement, in image pixels: where to draw the ellipse
// (offset is y-up from the tile center) and how big (footprint size).
struct ShadowAnchor {
    var offset: CGPoint
    var size: CGSize
}
