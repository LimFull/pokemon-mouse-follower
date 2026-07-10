// World<->native coordinate adapter (design/windows-port.md W4). The core
// keeps macOS's global y-up coordinate space; this flips against the virtual
// screen's bottom edge and answers cursor/monitor queries in world coords.
// Refresh on WM_DISPLAYCHANGE.

import WinSDK
import Foundation

enum ScreenAdapter {
    // Native virtual-screen rect (y-down, can have negative origin).
    private(set) static var nativeX: Int32 = 0
    private(set) static var nativeY: Int32 = 0
    private(set) static var nativeW: Int32 = 0
    private(set) static var nativeH: Int32 = 0

    static func refresh() {
        nativeX = GetSystemMetrics(76)   // SM_XVIRTUALSCREEN
        nativeY = GetSystemMetrics(77)   // SM_YVIRTUALSCREEN
        nativeW = GetSystemMetrics(78)   // SM_CXVIRTUALSCREEN
        nativeH = GetSystemMetrics(79)   // SM_CYVIRTUALSCREEN
    }

    /// Bottom edge of the virtual screen in native coords — the flip axis.
    private static var nativeBottom: Int32 { nativeY + nativeH }

    static func toWorld(nativeX x: Int32, nativeY y: Int32) -> CGPoint {
        CGPoint(x: CGFloat(x), y: CGFloat(nativeBottom - y))
    }

    /// World point -> native (top-left origin) point.
    static func toNative(_ p: CGPoint) -> (x: Int32, y: Int32) {
        (Int32(p.x.rounded()), nativeBottom - Int32(p.y.rounded()))
    }

    static func cursorWorld() -> CGPoint {
        var pt = POINT()
        GetCursorPos(&pt)
        return toWorld(nativeX: pt.x, nativeY: pt.y)
    }

    /// All monitors as world-coordinate rects (spawn/clamp logic later).
    static func screensWorld() -> [CGRect] {
        var rects: [CGRect] = []
        let cb: MONITORENUMPROC = { _, _, lprc, dwData in
            guard let lprc,
                  let raw = UnsafeMutableRawPointer(bitPattern: Int(dwData)) else { return true }
            let list = raw.assumingMemoryBound(to: [CGRect].self)
            let r = lprc.pointee
            // World origin of a native rect is its bottom-left corner.
            let origin = ScreenAdapter.toWorld(nativeX: r.left, nativeY: r.bottom)
            list.pointee.append(CGRect(x: origin.x, y: origin.y,
                                       width: CGFloat(r.right - r.left),
                                       height: CGFloat(r.bottom - r.top)))
            return true
        }
        withUnsafeMutablePointer(to: &rects) { listPtr in
            _ = EnumDisplayMonitors(nil, nil, cb,
                                    LPARAM(Int(bitPattern: UnsafeMutableRawPointer(listPtr))))
        }
        return rects
    }
}
