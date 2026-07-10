// One click-through layered window per rendered entity (design/windows-port.md
// W3): the window is exactly the sprite's rendered size, moves with
// SetWindowPos, and repaints via UpdateLayeredWindow only when the frame or
// its styling changes. Composes the ground shadow + nearest-scaled sprite
// into a premultiplied BGRA DIB — the Windows counterpart of SpriteView's
// shadow/sprite layers.

import WinSDK
import Foundation

private let kWS_EX_OVERLAY: DWORD = 0x0008_0000   // WS_EX_LAYERED
    | 0x0000_0020   // WS_EX_TRANSPARENT (click-through)
    | 0x0000_0080   // WS_EX_TOOLWINDOW (no Alt-Tab entry)
    | 0x0800_0000   // WS_EX_NOACTIVATE
    | 0x0000_0008   // WS_EX_TOPMOST
private let kWS_POPUP: DWORD = 0x8000_0000
private let kULW_ALPHA: DWORD = 2
private let kSW_SHOWNA: Int32 = 8

private var overlayClassRegistered = false
private let overlayClassName = Array("PMFOverlay".utf16) + [0]

private func registerOverlayClass() {
    guard !overlayClassRegistered else { return }
    var wc = WNDCLASSW()
    wc.lpfnWndProc = { hwnd, msg, wp, lp in DefWindowProcW(hwnd, msg, wp, lp) }
    wc.hInstance = GetModuleHandleW(nil)
    overlayClassName.withUnsafeBufferPointer { wc.lpszClassName = $0.baseAddress }
    if RegisterClassW(&wc) != 0 { overlayClassRegistered = true }
}

final class OverlaySprite {
    private var hwnd: HWND?
    private var hdcMem: HDC?
    private var dib: HBITMAP?
    private var dibBits: UnsafeMutableRawPointer?
    private var dibW = 0, dibH = 0
    private var visible = false

    // Content signature — repaint only when it changes (frames swap every
    // 6–14 ticks; moves happen every tick).
    private var lastFrame: ObjectIdentifier?
    private var lastScale: CGFloat = 0
    private var lastShadowKey: String = ""

    init?() {
        registerOverlayClass()
        hwnd = overlayClassName.withUnsafeBufferPointer { cls in
            CreateWindowExW(kWS_EX_OVERLAY, cls.baseAddress, nil, kWS_POPUP,
                            0, 0, 1, 1, nil, nil, GetModuleHandleW(nil), nil)
        }
        guard hwnd != nil else { return nil }
    }

    deinit {
        if let dib { DeleteObject(dib) }
        if let hdcMem { DeleteDC(hdcMem) }
        if let hwnd { DestroyWindow(hwnd) }
    }

    func hide() {
        guard visible else { return }
        visible = false
        ShowWindow(hwnd, SW_HIDE)
    }

    /// Draw `frame` centered at `worldPos` (nil hides), mirroring
    /// SpriteView.render: nearest scale, optional marker-anchored shadow.
    func present(frame: Win32Image?, worldPos: CGPoint, shadow: ShadowAnchor,
                 scale: CGFloat, showShadow: Bool) {
        guard let frame else { hide(); return }
        let w = max(1, Int((CGFloat(frame.width) * scale).rounded()))
        let h = max(1, Int((CGFloat(frame.height) * scale).rounded()))

        let shadowKey = showShadow
            ? "\(Int(shadow.offset.x * 10)),\(Int(shadow.offset.y * 10)),\(Int(shadow.size.width * 10)),\(Int(shadow.size.height * 10))"
            : "off"
        let needsRepaint = lastFrame != ObjectIdentifier(frame) || lastScale != scale
            || lastShadowKey != shadowKey || dibW != w || dibH != h

        let native = ScreenAdapter.toNative(worldPos)
        let left = native.x - Int32(w / 2)
        let top = native.y - Int32(h / 2)

        if needsRepaint {
            ensureDIB(w: w, h: h)
            guard let dibBits else { return }
            compose(frame: frame, shadow: showShadow ? shadow : nil, scale: scale,
                    into: dibBits, w: w, h: h)
            var ptSrc = POINT(x: 0, y: 0)
            var size = SIZE(cx: Int32(w), cy: Int32(h))
            var ptDst = POINT(x: left, y: top)
            var blend = BLENDFUNCTION(BlendOp: 0 /*AC_SRC_OVER*/, BlendFlags: 0,
                                      SourceConstantAlpha: 255, AlphaFormat: 1 /*AC_SRC_ALPHA*/)
            UpdateLayeredWindow(hwnd, nil, &ptDst, &size, hdcMem, &ptSrc, 0, &blend, kULW_ALPHA)
            lastFrame = ObjectIdentifier(frame)
            lastScale = scale
            lastShadowKey = shadowKey
        } else {
            SetWindowPos(hwnd, nil, left, top, 0, 0,
                         UINT(SWP_NOSIZE | SWP_NOZORDER | SWP_NOACTIVATE))
        }

        if !visible {
            visible = true
            ShowWindow(hwnd, kSW_SHOWNA)
        }
    }

    // MARK: - composition

    private func ensureDIB(w: Int, h: Int) {
        guard w != dibW || h != dibH || dib == nil else { return }
        if let dib { DeleteObject(dib); self.dib = nil }
        if hdcMem == nil {
            let screen = GetDC(nil)
            hdcMem = CreateCompatibleDC(screen)
            ReleaseDC(nil, screen)
        }
        var bmi = BITMAPINFO()
        bmi.bmiHeader.biSize = DWORD(MemoryLayout<BITMAPINFOHEADER>.size)
        bmi.bmiHeader.biWidth = Int32(w)
        bmi.bmiHeader.biHeight = -Int32(h)   // top-down
        bmi.bmiHeader.biPlanes = 1
        bmi.bmiHeader.biBitCount = 32
        bmi.bmiHeader.biCompression = DWORD(BI_RGB)
        var bits: UnsafeMutableRawPointer? = nil
        dib = CreateDIBSection(hdcMem, &bmi, UINT(DIB_RGB_COLORS), &bits, nil, 0)
        dibBits = bits
        dibW = w; dibH = h
        if let dib { SelectObject(hdcMem, dib) }
    }

    /// Shadow ellipse under the sprite, then the nearest-scaled frame over it,
    /// premultiplied BGRA. Shadow look matches SpriteView's radial layer:
    /// flat 30% black to 70% of the radius, fading to 0 at the edge.
    private func compose(frame: Win32Image, shadow: ShadowAnchor?, scale: CGFloat,
                         into bits: UnsafeMutableRawPointer, w: Int, h: Int) {
        let dst = bits.assumingMemoryBound(to: UInt8.self)
        memset(dst, 0, w * h * 4)

        if let shadow {
            // y-up offset from tile center -> y-down canvas coords.
            let cx = Double(w) / 2 + Double(shadow.offset.x * scale)
            let cy = Double(h) / 2 - Double(shadow.offset.y * scale)
            let rx = max(Double(shadow.size.width * scale) / 2, 0.5)
            let ry = max(Double(shadow.size.height * scale) / 2, 0.5)
            let y0 = max(0, Int(cy - ry)), y1 = min(h - 1, Int(cy + ry) + 1)
            let x0 = max(0, Int(cx - rx)), x1 = min(w - 1, Int(cx + rx) + 1)
            if y0 <= y1, x0 <= x1 {
                for y in y0...y1 {
                    for x in x0...x1 {
                        let nx = (Double(x) + 0.5 - cx) / rx
                        let ny = (Double(y) + 0.5 - cy) / ry
                        let d = (nx * nx + ny * ny).squareRoot()
                        guard d < 1 else { continue }
                        let alpha = d <= 0.7 ? 0.30 : 0.30 * (1 - d) / 0.3
                        dst[(y * w + x) * 4 + 3] = UInt8(alpha * 255)
                        // black premultiplied: BGR stay 0
                    }
                }
            }
        }

        // Nearest-scale the RGBA frame over the shadow (premultiplied src-over).
        let src = frame.buffer.pixels
        let fw = frame.buffer.width, fh = frame.buffer.height
        let inv = 1.0 / Double(scale)
        for y in 0..<h {
            let sy = min(fh - 1, Int(Double(y) * inv))
            let srcRow = sy * fw * 4
            let dstRow = y * w * 4
            for x in 0..<w {
                let sx = min(fw - 1, Int(Double(x) * inv))
                let s = srcRow + sx * 4
                let a = src[s + 3]
                guard a > 0 else { continue }
                let d = dstRow + x * 4
                if a == 255 {
                    dst[d]     = src[s + 2]   // B
                    dst[d + 1] = src[s + 1]   // G
                    dst[d + 2] = src[s]       // R
                    dst[d + 3] = 255
                } else {
                    let ia = UInt32(255 - a)
                    dst[d]     = UInt8((UInt32(src[s + 2]) * 255 + UInt32(dst[d]) * ia) / 255)
                    dst[d + 1] = UInt8((UInt32(src[s + 1]) * 255 + UInt32(dst[d + 1]) * ia) / 255)
                    dst[d + 2] = UInt8((UInt32(src[s]) * 255 + UInt32(dst[d + 2]) * ia) / 255)
                    dst[d + 3] = UInt8(min(255, UInt32(a) + UInt32(dst[d + 3]) * ia / 255))
                }
            }
        }
    }
}
