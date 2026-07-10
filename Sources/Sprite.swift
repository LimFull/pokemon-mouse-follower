// Sprite sheet loading/slicing and the PMD marker-sheet readers
// (shadow anchors, AnimData frame sizes).

import Cocoa
import ImageIO

// MARK: - Sprite loading / slicing
enum Sprite {
    static func loadCG(_ name: String, subdir: String) -> CGImage? {
        guard let url = Bundle.main.url(forResource: name, withExtension: "png", subdirectory: subdir),
              let data = try? Data(contentsOf: url),
              let src = CGImageSourceCreateWithData(data as CFData, nil),
              let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return nil }
        return img
    }

    static func loadText(_ name: String, ext: String, subdir: String) -> String? {
        guard let url = Bundle.main.url(forResource: name, withExtension: ext, subdirectory: subdir) else { return nil }
        return try? String(contentsOf: url, encoding: .utf8)
    }

    // Slice into [row][col] frames (top-left origin). Cells may be non-square.
    static func slice(_ image: CGImage, cols: Int, rows: Int, cellW: Int, cellH: Int) -> [[CGImage]] {
        var out: [[CGImage]] = []
        for r in 0..<rows {
            var rowArr: [CGImage] = []
            for c in 0..<cols {
                let rect = CGRect(x: c * cellW, y: r * cellH, width: cellW, height: cellH)
                if let cg = image.cropping(to: rect) { rowArr.append(cg) }
            }
            out.append(rowArr)
        }
        return out
    }

    // Load a sheet PNG and slice it into [row][col] cells using AnimData frame
    // sizes (falling back to square cells across 8 direction rows).
    static func slicedSheet(_ png: String, anim: String, subdir: String, xml: String?) -> [[CGImage]] {
        guard let img = loadCG(png, subdir: subdir) else { return [] }
        var cw = img.height / 8, ch = img.height / 8
        if let xml, let (w, h) = frameSize(anim, in: xml) { cw = w; ch = h }
        guard cw > 0, ch > 0 else { return [] }
        return slice(img, cols: max(1, img.width / cw), rows: max(1, img.height / ch),
                     cellW: cw, cellH: ch)
    }

    /// 8-direction octant of a movement vector (0=E,1=NE,2=N,...,7=SE) — the
    /// PMD sprite sheets' direction resolution.
    static func octant(dx: CGFloat, dy: CGFloat) -> Int {
        var deg = atan2(dy, dx) * 180 / .pi
        if deg < 0 { deg += 360 }
        return Int((deg / 45).rounded()) % 8
    }

    // Shadow marker center from a PMD "-Shadow" sheet cell, in image (top-left
    // origin) pixel coords. The sheet marks the shadow center with a single white
    // pixel (inside nested blue/red/green size regions); prefer that, else fall
    // back to the centroid of all opaque pixels. Returns nil if the cell is empty.
    // Shadow marker read from a PMD "-Shadow" cell: the ground-contact center
    // (white pixel) and the footprint size for the given ShadowSize, taken from
    // the nested color regions (green = small, red = medium, blue = large; each
    // encloses the smaller ones). All in image (top-left origin) pixels; nil if
    // the cell has no marker.
    static func shadowMarker(_ img: CGImage, shadowSize: Int) -> (center: CGPoint, size: CGSize)? {
        let w = img.width, h = img.height
        guard w > 0, h > 0 else { return nil }
        var buf = [UInt8](repeating: 0, count: w * h * 4)
        guard let ctx = CGContext(data: &buf, width: w, height: h,
                                  bitsPerComponent: 8, bytesPerRow: w * 4,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
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
    static func opaqueBBox(_ img: CGImage, alphaThreshold: UInt8 = 12) -> CGRect? {
        let w = img.width, h = img.height
        guard w > 0, h > 0 else { return nil }
        var alpha = [UInt8](repeating: 0, count: w * h)
        guard let ctx = CGContext(data: &alpha, width: w, height: h,
                                  bitsPerComponent: 8, bytesPerRow: w,
                                  space: CGColorSpaceCreateDeviceGray(),
                                  bitmapInfo: CGImageAlphaInfo.alphaOnly.rawValue) else { return nil }
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
        // Buffer row 0 is the top of the image (top-left origin).
        var minX = w, minY = h, maxX = -1, maxY = -1
        for y in 0..<h {
            let base = y * w
            for x in 0..<w where alpha[base + x] >= alphaThreshold {
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
