// One click-through layered window per rendered entity (design/windows-port.md
// W3): the window is exactly the rendered size, moves with SetWindowPos, and
// repaints via UpdateLayeredWindow only when the frame or its styling changes.
// Composes ground shadow + nearest-scaled sprite (+ faint rotation + the
// evolution glow) into a premultiplied BGRA DIB — the Windows counterpart of
// SpriteView's shadow/sprite/glow layers. Whole-sprite alpha rides ULW's
// SourceConstantAlpha so fades never recompose.

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

private let kWDA_NONE: DWORD = 0x0000_0000
private let kWDA_EXCLUDEFROMCAPTURE: DWORD = 0x0000_0011   // Win10 2004+; older builds no-op

private var overlayClassRegistered = false
private let overlayClassName = Array("PMFOverlay".utf16) + [0]

func registerOverlayClass() {
    guard !overlayClassRegistered else { return }
    var wc = WNDCLASSW()
    wc.lpfnWndProc = { hwnd, msg, wp, lp in DefWindowProcW(hwnd, msg, wp, lp) }
    wc.hInstance = GetModuleHandleW(nil)
    overlayClassName.withUnsafeBufferPointer { wc.lpszClassName = $0.baseAddress }
    if RegisterClassW(&wc) != 0 { overlayClassRegistered = true }
}

/// Every live overlay window — the virtual-desktop fallback moves these to
/// the active desktop when the user switches (design/windows-port.md §6-2).
private(set) var allOverlayWindows: [HWND] = []

/// A borderless click-through topmost layered window (shared by the sprite
/// overlays and the battle chrome).
func createOverlayWindow() -> HWND? {
    registerOverlayClass()
    let hwnd = overlayClassName.withUnsafeBufferPointer { cls in
        CreateWindowExW(kWS_EX_OVERLAY, cls.baseAddress, nil, kWS_POPUP,
                        0, 0, 1, 1, nil, nil, GetModuleHandleW(nil), nil)
    }
    if let hwnd {
        allOverlayWindows.append(hwnd)
        // Late-created overlays honor the current capture-exclusion setting.
        SetWindowDisplayAffinity(hwnd,
            AppSettings.shared.hideFromCapture ? kWDA_EXCLUDEFROMCAPTURE : kWDA_NONE)
    }
    return hwnd
}

/// Apply (or lift) screen-capture exclusion on every live overlay window.
/// Excludes the follower/wild/effect/item/chrome surfaces from screenshots and
/// screen recording; WDA_EXCLUDEFROMCAPTURE needs Windows 10 2004+ (older builds
/// leave the content captured — acceptable graceful degradation).
func applyCaptureProtection() {
    let affinity = AppSettings.shared.hideFromCapture ? kWDA_EXCLUDEFROMCAPTURE : kWDA_NONE
    for hwnd in allOverlayWindows { SetWindowDisplayAffinity(hwnd, affinity) }
}

final class OverlaySprite {
    private var hwnd: HWND?
    private var hdcMem: HDC?
    private var dib: HBITMAP?
    private var dibBits: UnsafeMutableRawPointer?
    private var dibW = 0, dibH = 0
    private var visible = false

    // Content signature — repaint only when it changes (frames swap every
    // 6–14 ticks; moves happen every tick; alpha changes re-blend only).
    private var lastFrame: ObjectIdentifier?
    private var lastScale: CGFloat = 0
    private var lastShadowKey: String = ""
    private var lastRotationQ = 0
    private var lastGlowQ = 0
    private var lastAlphaQ = 255

    init?() {
        hwnd = createOverlayWindow()
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
    /// SpriteView.render: nearest scale, optional marker-anchored shadow,
    /// fallback-faint rotation and the evolution glow.
    func present(frame: PMFImage?, worldPos: CGPoint, shadow: ShadowAnchor,
                 scale: CGFloat, showShadow: Bool,
                 alpha: Double = 1, rotation: CGFloat = 0, glow: CGFloat = 0) {
        guard let frame, alpha > 0.004 else { hide(); return }
        let spriteW = max(1.0, Double(frame.width) * Double(scale))
        let spriteH = max(1.0, Double(frame.height) * Double(scale))
        // Canvas: sprite bounds, grown for rotation (diagonal) and glow.
        var cw = spriteW, ch = spriteH
        if rotation != 0 {
            let diag = (spriteW * spriteW + spriteH * spriteH).squareRoot()
            cw = diag; ch = diag
        }
        if glow > 0 {
            let d = max(spriteW, spriteH) * (1.1 + 0.5 * Double(glow))
            cw = max(cw, d); ch = max(ch, d)
        }
        let w = max(1, Int(cw.rounded(.up))), h = max(1, Int(ch.rounded(.up)))

        let shadowKey = showShadow
            ? "\(Int(shadow.offset.x * 10)),\(Int(shadow.offset.y * 10)),\(Int(shadow.size.width * 10)),\(Int(shadow.size.height * 10))"
            : "off"
        let rotQ = Int(rotation * 64)          // ~1° steps
        let glowQ = Int(glow * 64)
        let alphaQ = Int(max(0, min(1, alpha)) * 255)
        let needsRepaint = lastFrame != ObjectIdentifier(frame) || lastScale != scale
            || lastShadowKey != shadowKey || dibW != w || dibH != h
            || lastRotationQ != rotQ || lastGlowQ != glowQ

        let native = ScreenAdapter.toNative(worldPos)
        let left = native.x - Int32(w / 2)
        let top = native.y - Int32(h / 2)

        if needsRepaint || alphaQ != lastAlphaQ {
            if needsRepaint {
                ensureDIB(w: w, h: h)
                guard let dibBits else { return }
                compose(frame: frame, shadow: showShadow ? shadow : nil, scale: scale,
                        rotation: rotation, glow: glow, into: dibBits, w: w, h: h)
            }
            var ptSrc = POINT(x: 0, y: 0)
            var size = SIZE(cx: Int32(w), cy: Int32(h))
            var ptDst = POINT(x: left, y: top)
            var blend = BLENDFUNCTION(BlendOp: 0 /*AC_SRC_OVER*/, BlendFlags: 0,
                                      SourceConstantAlpha: UInt8(alphaQ),
                                      AlphaFormat: 1 /*AC_SRC_ALPHA*/)
            UpdateLayeredWindow(hwnd, nil, &ptDst, &size, hdcMem, &ptSrc, 0, &blend, kULW_ALPHA)
            lastFrame = ObjectIdentifier(frame)
            lastScale = scale
            lastShadowKey = shadowKey
            lastRotationQ = rotQ
            lastGlowQ = glowQ
            lastAlphaQ = alphaQ
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

    /// Shadow ellipse under the sprite, the nearest-scaled (and optionally
    /// rotated) frame over it, then the evolution glow on top — premultiplied
    /// BGRA, matching SpriteView's layer stack. Shadow look mirrors the radial
    /// layer: flat 30% black to 70% of the radius, fading to 0 at the edge.
    private func compose(frame: Win32Image, shadow: ShadowAnchor?, scale: CGFloat,
                         rotation: CGFloat, glow: CGFloat,
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

        // Nearest-scale the RGBA frame over the shadow (premultiplied src-over),
        // inverse-mapping through the optional rotation.
        let src = frame.buffer.pixels
        let fw = frame.buffer.width, fh = frame.buffer.height
        let inv = 1.0 / Double(scale)
        let cx = Double(w) / 2, cy = Double(h) / 2
        let cosR = Double(cos(-rotation)), sinR = Double(sin(-rotation))
        for y in 0..<h {
            let dstRow = y * w * 4
            for x in 0..<w {
                var fx: Double, fy: Double
                if rotation == 0 {
                    fx = (Double(x) + 0.5 - cx) * inv + Double(fw) / 2
                    fy = (Double(y) + 0.5 - cy) * inv + Double(fh) / 2
                } else {
                    let rx = Double(x) + 0.5 - cx, ry = Double(y) + 0.5 - cy
                    fx = (rx * cosR - ry * sinR) * inv + Double(fw) / 2
                    fy = (rx * sinR + ry * cosR) * inv + Double(fh) / 2
                }
                let sx = Int(fx), sy = Int(fy)
                guard sx >= 0, sx < fw, sy >= 0, sy < fh else { continue }
                let s = (sy * fw + sx) * 4
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

        // Evolution burst: white radial glow swelling over the sprite
        // (SpriteView glowLayer mirror: 0.95 -> 0.55 @55% -> 0 @edge, x glow).
        if glow > 0 {
            let d = max(Double(fw), Double(fh)) * Double(scale) * (1.1 + 0.5 * Double(glow))
            let r = d / 2
            let gx = Double(w) / 2, gy = Double(h) / 2
            let y0 = max(0, Int(gy - r)), y1 = min(h - 1, Int(gy + r) + 1)
            let x0 = max(0, Int(gx - r)), x1 = min(w - 1, Int(gx + r) + 1)
            if y0 <= y1, x0 <= x1 {
                for y in y0...y1 {
                    for x in x0...x1 {
                        let nx = (Double(x) + 0.5 - gx) / r
                        let ny = (Double(y) + 0.5 - gy) / r
                        let dd = (nx * nx + ny * ny).squareRoot()
                        guard dd < 1 else { continue }
                        let base = dd <= 0.55 ? 0.95 - (0.95 - 0.55) * (dd / 0.55)
                                              : 0.55 * (1 - dd) / 0.45
                        let a = UInt32(max(0, min(1, base * Double(glow))) * 255)
                        guard a > 0 else { continue }
                        let p = (y * w + x) * 4
                        let ia = 255 - a
                        // white premultiplied src-over
                        dst[p]     = UInt8((a * 255 + UInt32(dst[p]) * ia) / 255)
                        dst[p + 1] = UInt8((a * 255 + UInt32(dst[p + 1]) * ia) / 255)
                        dst[p + 2] = UInt8((a * 255 + UInt32(dst[p + 2]) * ia) / 255)
                        dst[p + 3] = UInt8(min(255, a + UInt32(dst[p + 3]) * ia / 255))
                    }
                }
            }
        }
    }
}
