// Battle chrome, Windows edition (Phase 5b): HP bars, the wild's level tag,
// floating combat text, the PMD-style battle log and the full-screen move
// veil — everything SpriteView.renderBattle draws besides the sprites. One
// click-through layered window sized to the battle region redraws per tick
// (the region is a few hundred px, so the ULW upload stays cheap); the veil
// gets its own virtual-screen window shown only while a flash plays.

import WinSDK
import Foundation

// MARK: - GDI text -> alpha mask
// GDI won't write alpha into a 32bpp DIB, so text renders white-on-black into
// a scratch DIB and the green channel becomes the coverage mask.
private final class TextRasterizer {
    private var hdc: HDC?
    private var dib: HBITMAP?
    private var bits: UnsafeMutableRawPointer?
    private var w = 0, h = 0
    private var fonts: [Int32: HFONT] = [:]   // key: size*10 + weightClass

    deinit {
        for (_, f) in fonts { DeleteObject(f) }
        if let dib { DeleteObject(dib) }
        if let hdc { DeleteDC(hdc) }
    }

    private func font(size: Double, weight: Int32) -> HFONT? {
        let key = Int32(size) * 10 + (weight / 100)
        if let f = fonts[key] { return f }
        let name = Array("Segoe UI".utf16) + [0]
        let f = name.withUnsafeBufferPointer { buf -> HFONT? in
            CreateFontW(-Int32(size.rounded()), 0, 0, 0, weight, 0, 0, 0,
                        DWORD(DEFAULT_CHARSET), DWORD(OUT_DEFAULT_PRECIS),
                        DWORD(CLIP_DEFAULT_PRECIS), DWORD(ANTIALIASED_QUALITY),
                        DWORD(DEFAULT_PITCH), buf.baseAddress)
        }
        if let f { fonts[key] = f }
        return f
    }

    private func ensure(w needW: Int, h needH: Int) -> Bool {
        guard needW > w || needH > h || hdc == nil else { return true }
        if let dib { DeleteObject(dib); self.dib = nil }
        if hdc == nil {
            let screen = GetDC(nil)
            hdc = CreateCompatibleDC(screen)
            ReleaseDC(nil, screen)
        }
        w = max(w, needW, 128); h = max(h, needH, 32)
        var bmi = BITMAPINFO()
        bmi.bmiHeader.biSize = DWORD(MemoryLayout<BITMAPINFOHEADER>.size)
        bmi.bmiHeader.biWidth = Int32(w)
        bmi.bmiHeader.biHeight = -Int32(h)
        bmi.bmiHeader.biPlanes = 1
        bmi.bmiHeader.biBitCount = 32
        bmi.bmiHeader.biCompression = DWORD(BI_RGB)
        var raw: UnsafeMutableRawPointer? = nil
        dib = CreateDIBSection(hdc, &bmi, UINT(DIB_RGB_COLORS), &raw, nil, 0)
        bits = raw
        if let dib { SelectObject(hdc, dib) }
        return bits != nil
    }

    func measure(_ text: String, size: Double, weight: Int32) -> (w: Int, h: Int) {
        guard ensure(w: 8, h: 8), let hdc, let f = font(size: size, weight: weight) else {
            return (Int(Double(text.count) * size * 0.62), Int(size) + 4)
        }
        SelectObject(hdc, f)
        var sz = SIZE()
        let units = Array(text.utf16)
        units.withUnsafeBufferPointer {
            _ = GetTextExtentPoint32W(hdc, $0.baseAddress, Int32(units.count), &sz)
        }
        return (Int(sz.cx), Int(sz.cy))
    }

    /// Coverage mask for `text` (0...255 per pixel, mask width x height).
    func mask(_ text: String, size: Double, weight: Int32) -> (px: [UInt8], w: Int, h: Int)? {
        let m = measure(text, size: size, weight: weight)
        guard m.w > 0, m.h > 0, ensure(w: m.w, h: m.h),
              let hdc, let bits, let f = font(size: size, weight: weight) else { return nil }
        SelectObject(hdc, f)
        // black background, white text
        let stride = w
        let px32 = bits.assumingMemoryBound(to: UInt32.self)
        for y in 0..<m.h { memset(px32 + y * stride, 0, m.w * 4) }
        SetBkMode(hdc, TRANSPARENT)
        SetTextColor(hdc, 0x00FFFFFF)
        let units = Array(text.utf16)
        units.withUnsafeBufferPointer {
            _ = ExtTextOutW(hdc, 0, 0, 0, nil, $0.baseAddress, UINT(units.count), nil)
        }
        var out = [UInt8](repeating: 0, count: m.w * m.h)
        for y in 0..<m.h {
            for x in 0..<m.w {
                out[y * m.w + x] = UInt8((px32[y * stride + x] >> 8) & 0xFF)   // green
            }
        }
        return (out, m.w, m.h)
    }
}

// MARK: - chrome canvas (premultiplied BGRA pixel ops)
private struct ChromeCanvas {
    var bits: UnsafeMutablePointer<UInt8>
    let w: Int, h: Int

    func blend(_ x: Int, _ y: Int, _ color: RGBA, _ coverage: Double = 1) {
        guard x >= 0, x < w, y >= 0, y < h else { return }
        let a = UInt32(max(0, min(1, color.a * coverage)) * 255)
        guard a > 0 else { return }
        let p = (y * w + x) * 4
        let ia = 255 - a
        bits[p]     = UInt8(UInt32(color.b * 255) * a / 255 + UInt32(bits[p]) * ia / 255)
        bits[p + 1] = UInt8(UInt32(color.g * 255) * a / 255 + UInt32(bits[p + 1]) * ia / 255)
        bits[p + 2] = UInt8(UInt32(color.r * 255) * a / 255 + UInt32(bits[p + 2]) * ia / 255)
        bits[p + 3] = UInt8(min(255, a + UInt32(bits[p + 3]) * ia / 255))
    }

    func fillRoundRect(x: Double, y: Double, w rw: Double, h rh: Double,
                       radius: Double, color: RGBA) {
        let x0 = max(0, Int(x)), x1 = min(w - 1, Int(x + rw))
        let y0 = max(0, Int(y)), y1 = min(h - 1, Int(y + rh))
        guard x0 <= x1, y0 <= y1 else { return }
        let r = min(radius, min(rw, rh) / 2)
        for py in y0...y1 {
            for px in x0...x1 {
                let fx = Double(px) + 0.5, fy = Double(py) + 0.5
                // distance to the rounded-rect interior
                let cx = min(max(fx, x + r), x + rw - r)
                let cy = min(max(fy, y + r), y + rh - r)
                let dx = fx - cx, dy = fy - cy
                if dx * dx + dy * dy <= r * r { blend(px, py, color) }
            }
        }
    }

    func drawMask(_ mask: (px: [UInt8], w: Int, h: Int), at x: Int, _ y: Int,
                  color: RGBA, alpha: Double = 1, maxW: Int = .max) {
        let cw = min(mask.w, maxW)
        for my in 0..<mask.h {
            for mx in 0..<cw {
                let cov = Double(mask.px[my * mask.w + mx]) / 255
                if cov > 0 { blend(x + mx, y + my, color, cov * alpha) }
            }
        }
    }
}

// MARK: - battle chrome
final class BattleChrome {
    private var hwnd: HWND?
    private var hdcMem: HDC?
    private var dib: HBITMAP?
    private var dibBits: UnsafeMutableRawPointer?
    private var dibW = 0, dibH = 0
    private var visible = false
    private let text = TextRasterizer()

    // Full-virtual-screen veil (rare, brief) — own window + solid DIB.
    private var veilHwnd: HWND?
    private var veilDC: HDC?
    private var veilDib: HBITMAP?
    private var veilBits: UnsafeMutableRawPointer?
    private var veilW = 0, veilH = 0
    private var veilColorKey = ""
    private var veilVisible = false

    init?() {
        hwnd = createOverlayWindow()
        guard hwnd != nil else { return nil }
    }

    deinit {
        if let dib { DeleteObject(dib) }
        if let hdcMem { DeleteDC(hdcMem) }
        if let hwnd { DestroyWindow(hwnd) }
        if let veilDib { DeleteObject(veilDib) }
        if let veilDC { DeleteDC(veilDC) }
        if let veilHwnd { DestroyWindow(veilHwnd) }
    }

    func hide() {
        if visible { visible = false; ShowWindow(hwnd, SW_HIDE) }
        hideVeil()
    }

    private func hideVeil() {
        if veilVisible { veilVisible = false; ShowWindow(veilHwnd, SW_HIDE) }
    }

    /// Draw every non-sprite battle element for `scene` (nil hides the lot).
    func present(_ scene: BattleScene?) {
        guard let scene else { hide(); return }
        let s = AppSettings.shared.scale

        // ---- collect elements in world coords (y-up, centers) --------------
        struct Tag { let text: String; let size: Double; let weight: Int32
                     let boxW: Double; let boxH: Double; let center: CGPoint
                     let bg: RGBA?; let color: RGBA; let alpha: Double }
        var tags: [Tag] = []
        var bars: [(center: CGPoint, frac: Double)] = []

        if scene.showBars {
            let top = 20 * s
            bars.append((CGPoint(x: scene.playerPos.x, y: scene.playerPos.y + top), scene.playerHP))
            bars.append((CGPoint(x: scene.wildPos.x, y: scene.wildPos.y + top), scene.wildHP))
        }
        if let lv = scene.wildLevel {
            let fs = Double(min(16, max(9, 6 * s)))
            let t = "Lv.\(lv)"
            let m = text.measure(t, size: fs, weight: 700)
            tags.append(Tag(text: t, size: fs, weight: 700,
                            boxW: Double(m.w) + 10, boxH: fs + 6,
                            center: CGPoint(x: scene.wildPos.x,
                                            y: scene.wildPos.y + (scene.showBars ? 30 : 22) * s),
                            bg: RGBA(white: 0.08, alpha: 0.62),
                            color: RGBA(white: 1, alpha: 0.95), alpha: scene.wildAlpha))
        }
        if let ft = scene.floatText, scene.floatAlpha > 0.01 {
            let fs = Double(min(18, max(10, 7 * s)))
            let m = text.measure(ft, size: fs, weight: 900)
            tags.append(Tag(text: ft, size: fs, weight: 900,
                            boxW: Double(m.w) + 12, boxH: fs + 4,
                            center: scene.floatPos, bg: nil,
                            color: scene.floatColor, alpha: scene.floatAlpha))
        }

        // Battle log: measured lines, box anchored top-center at logAnchor.
        let logLines = scene.logLines.filter { $0.1 > 0 }
        let logFS = Double(min(14, max(9, 5 * s)))
        let lineH = logFS + 4
        var logW = 0.0, logH = 0.0
        if !logLines.isEmpty {
            var maxW = 0.0
            for (line, _) in logLines {
                maxW = max(maxW, Double(text.measure(line, size: logFS, weight: 600).w))
            }
            logW = min(340, maxW + 16)
            logH = Double(logLines.count) * lineH + 10
        }

        // ---- chrome window rect: union of everything (world, y-up) ---------
        var minX = CGFloat.greatestFiniteMagnitude, maxX = -CGFloat.greatestFiniteMagnitude
        var minY = CGFloat.greatestFiniteMagnitude, maxY = -CGFloat.greatestFiniteMagnitude
        func include(cx: CGFloat, cy: CGFloat, w: CGFloat, h: CGFloat) {
            minX = min(minX, cx - w / 2); maxX = max(maxX, cx + w / 2)
            minY = min(minY, cy - h / 2); maxY = max(maxY, cy + h / 2)
        }
        for b in bars { include(cx: b.center.x, cy: b.center.y, w: 46, h: 5) }
        for t in tags { include(cx: t.center.x, cy: t.center.y, w: CGFloat(t.boxW), h: CGFloat(t.boxH)) }
        if !logLines.isEmpty {
            include(cx: scene.logAnchor.x, cy: scene.logAnchor.y - CGFloat(logH) / 2,
                    w: CGFloat(logW), h: CGFloat(logH))
        }
        presentVeil(scene)
        guard minX < maxX, minY < maxY else {
            if visible { visible = false; ShowWindow(hwnd, SW_HIDE) }
            return
        }
        minX -= 4; maxX += 4; minY -= 4; maxY += 4
        let w = Int((maxX - minX).rounded(.up)), h = Int((maxY - minY).rounded(.up))
        guard w > 0, h > 0, ensureDIB(w: w, h: h), let dibBits else { return }

        // world -> canvas (top-down): x' = x - minX, y' = maxY - y
        func cvs(_ p: CGPoint) -> (Double, Double) {
            (Double(p.x - minX), Double(maxY - p.y))
        }

        let canvas = ChromeCanvas(bits: dibBits.assumingMemoryBound(to: UInt8.self), w: w, h: h)
        memset(dibBits, 0, w * h * 4)

        // ---- HP bars (track + left-anchored fill, SpriteView.layoutHP) -----
        for bar in bars {
            let (cx, cy) = cvs(bar.center)
            let bw = 46.0, bh = 5.0
            canvas.fillRoundRect(x: cx - bw / 2, y: cy - bh / 2, w: bw, h: bh,
                                 radius: 2.5, color: RGBA(white: 0.1, alpha: 0.55))
            let frac = max(0, min(1, bar.frac))
            if frac > 0 {
                let fw = max(1, bw * frac)
                let color = frac > 0.5 ? RGBA(r: 0.16, g: 0.80, b: 0.25)
                          : frac > 0.2 ? RGBA(r: 1.0, g: 0.80, b: 0.0)
                                       : RGBA(r: 1.0, g: 0.23, b: 0.19)
                canvas.fillRoundRect(x: cx - bw / 2, y: cy - bh / 2, w: fw, h: bh,
                                     radius: 2.5, color: color)
            }
        }

        // ---- tags (level pill, floating combat text with drop shadow) ------
        for tag in tags {
            let (cx, cy) = cvs(tag.center)
            if let bg = tag.bg {
                canvas.fillRoundRect(x: cx - tag.boxW / 2, y: cy - tag.boxH / 2,
                                     w: tag.boxW, h: tag.boxH, radius: 5,
                                     color: bg.withAlpha(bg.a * tag.alpha))
            }
            if let m = text.mask(tag.text, size: tag.size, weight: tag.weight) {
                let tx = Int(cx - Double(m.w) / 2), ty = Int(cy - Double(m.h) / 2)
                if tag.bg == nil {   // float text: soft shadow underneath
                    canvas.drawMask(m, at: tx, ty + 1,
                                    color: RGBA(white: 0, alpha: 0.9), alpha: tag.alpha)
                }
                canvas.drawMask(m, at: tx, ty, color: tag.color, alpha: tag.alpha)
            }
        }

        // ---- battle log box (oldest line on top, per-line fade) ------------
        if !logLines.isEmpty {
            let (ax, ay) = cvs(scene.logAnchor)   // top-center anchor
            let bx = ax - logW / 2, by = ay
            canvas.fillRoundRect(x: bx, y: by, w: logW, h: logH, radius: 6,
                                 color: RGBA(white: 0.08, alpha: 0.62))
            for (i, line) in logLines.enumerated() {
                guard let m = text.mask(line.0, size: logFS, weight: 600) else { continue }
                let ly = by + 5 + Double(i) * lineH + (lineH - Double(m.h)) / 2
                canvas.drawMask(m, at: Int(bx + 8), Int(ly),
                                color: RGBA(white: 1, alpha: 0.95), alpha: line.1,
                                maxW: Int(logW - 16))
            }
        }

        // ---- upload -------------------------------------------------------
        let topLeft = ScreenAdapter.toNative(CGPoint(x: minX, y: maxY))
        var ptSrc = POINT(x: 0, y: 0)
        var size = SIZE(cx: Int32(w), cy: Int32(h))
        var ptDst = POINT(x: topLeft.x, y: topLeft.y)
        var blend = BLENDFUNCTION(BlendOp: 0, BlendFlags: 0,
                                  SourceConstantAlpha: 255, AlphaFormat: 1)
        UpdateLayeredWindow(hwnd, nil, &ptDst, &size, hdcMem, &ptSrc, 0, &blend, 2 /*ULW_ALPHA*/)
        if !visible {
            visible = true
            ShowWindow(hwnd, 8 /*SW_SHOWNA*/)
        }
    }

    private func ensureDIB(w: Int, h: Int) -> Bool {
        if hdcMem == nil {
            let screen = GetDC(nil)
            hdcMem = CreateCompatibleDC(screen)
            ReleaseDC(nil, screen)
        }
        if w <= dibW && h <= dibH && dib != nil {
            // reuse the larger DIB, but rows must match the drawn width — so
            // only reuse exact widths; otherwise realloc.
            if w == dibW { return true }
        }
        if let dib { DeleteObject(dib); self.dib = nil }
        var bmi = BITMAPINFO()
        bmi.bmiHeader.biSize = DWORD(MemoryLayout<BITMAPINFOHEADER>.size)
        bmi.bmiHeader.biWidth = Int32(w)
        bmi.bmiHeader.biHeight = -Int32(h)
        bmi.bmiHeader.biPlanes = 1
        bmi.bmiHeader.biBitCount = 32
        bmi.bmiHeader.biCompression = DWORD(BI_RGB)
        var raw: UnsafeMutableRawPointer? = nil
        dib = CreateDIBSection(hdcMem, &bmi, UINT(DIB_RGB_COLORS), &raw, nil, 0)
        dibBits = raw
        dibW = w; dibH = h
        if let dib { SelectObject(hdcMem, dib) }
        return dibBits != nil
    }

    // MARK: veil (full-screen move flash; SpriteView screenFlashLayer mirror)
    private func presentVeil(_ scene: BattleScene) {
        guard scene.screenFlash > 0.01 else { hideVeil(); return }
        if veilHwnd == nil { veilHwnd = createOverlayWindow() }
        guard let veilHwnd else { return }
        let vw = Int(ScreenAdapter.nativeW), vh = Int(ScreenAdapter.nativeH)
        guard vw > 0, vh > 0 else { return }
        let colorKey = "\(Int(scene.screenColor.r * 255)),\(Int(scene.screenColor.g * 255)),\(Int(scene.screenColor.b * 255)),\(vw)x\(vh)"
        if veilDC == nil {
            let screen = GetDC(nil)
            veilDC = CreateCompatibleDC(screen)
            ReleaseDC(nil, screen)
        }
        if vw != veilW || vh != veilH || veilDib == nil {
            if let veilDib { DeleteObject(veilDib) }
            var bmi = BITMAPINFO()
            bmi.bmiHeader.biSize = DWORD(MemoryLayout<BITMAPINFOHEADER>.size)
            bmi.bmiHeader.biWidth = Int32(vw)
            bmi.bmiHeader.biHeight = -Int32(vh)
            bmi.bmiHeader.biPlanes = 1
            bmi.bmiHeader.biBitCount = 32
            bmi.bmiHeader.biCompression = DWORD(BI_RGB)
            var raw: UnsafeMutableRawPointer? = nil
            veilDib = CreateDIBSection(veilDC, &bmi, UINT(DIB_RGB_COLORS), &raw, nil, 0)
            veilBits = raw
            veilW = vw; veilH = vh
            veilColorKey = ""
            if let veilDib { SelectObject(veilDC, veilDib) }
        }
        guard let veilBits else { return }
        if colorKey != veilColorKey {
            // opaque color fill; the flash strength rides SourceConstantAlpha.
            let pixel = (UInt32(255) << 24)
                | (UInt32(scene.screenColor.r * 255) << 16)
                | (UInt32(scene.screenColor.g * 255) << 8)
                | UInt32(scene.screenColor.b * 255)
            let p32 = veilBits.assumingMemoryBound(to: UInt32.self)
            for i in 0..<(vw * vh) { p32[i] = pixel }
            veilColorKey = colorKey
        }
        var ptSrc = POINT(x: 0, y: 0)
        var size = SIZE(cx: Int32(vw), cy: Int32(vh))
        var ptDst = POINT(x: ScreenAdapter.nativeX, y: ScreenAdapter.nativeY)
        var blend = BLENDFUNCTION(BlendOp: 0, BlendFlags: 0,
                                  SourceConstantAlpha: UInt8(max(0, min(1, scene.screenFlash * 0.22)) * 255),
                                  AlphaFormat: 1)
        UpdateLayeredWindow(veilHwnd, nil, &ptDst, &size, veilDC, &ptSrc, 0, &blend, 2)
        if !veilVisible {
            veilVisible = true
            ShowWindow(veilHwnd, 8 /*SW_SHOWNA*/)
        }
    }
}
