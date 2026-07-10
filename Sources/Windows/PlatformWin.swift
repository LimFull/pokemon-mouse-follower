// Windows implementations of the core's platform seams (design/windows-port.md
// §4.2): PNG decode through the GDI+ flat C API (W20 — bound dynamically, the
// approach verified in Phase 0), the renderable image handle, and the system
// language list.

import WinSDK
import Foundation

// MARK: - Renderable image handle (W2/W3)
/// The core's opaque frame handle on Windows. Phase 2 turns this into a
/// premultiplied BGRA DIB the overlay blits via UpdateLayeredWindow; until
/// then it carries the decoded pixels.
final class Win32Image {
    let buffer: RGBABuffer
    var width: Int { buffer.width }
    var height: Int { buffer.height }
    init(_ buffer: RGBABuffer) { self.buffer = buffer }
}

// MARK: - GDI+ flat API dynamic binding (W20)
// gdiplus.h is C++-only, so the WinSDK Swift module does not surface these;
// the flat exports are plain C functions we bind at runtime. Swift-defined
// structs cannot appear in @convention(c) signatures — struct pointers cross
// as raw pointers (Phase 0 finding).
private struct GpStartupInput {
    var version: UInt32 = 1
    var debugCallback: UnsafeMutableRawPointer? = nil
    var suppressBackgroundThread: Int32 = 0
    var suppressExternalCodecs: Int32 = 0
}
private struct GpBitmapData {
    var width: UInt32 = 0
    var height: UInt32 = 0
    var stride: Int32 = 0
    var pixelFormat: Int32 = 0
    var scan0: UnsafeMutableRawPointer? = nil
    var reserved: UInt = 0
}
private struct GpRect { var x: Int32; var y: Int32; var w: Int32; var h: Int32 }

private let kPixelFormat32bppPARGB: Int32 = 0x000E200B   // premultiplied BGRA
private let kImageLockModeRead: UInt32 = 1

private typealias FnGdiplusStartup = @convention(c) (
    UnsafeMutableRawPointer?, UnsafeRawPointer?, UnsafeMutableRawPointer?) -> Int32
private typealias FnCreateBitmapFromFile = @convention(c) (
    UnsafePointer<UInt16>?, UnsafeMutablePointer<UnsafeMutableRawPointer?>?) -> Int32
private typealias FnDisposeImage = @convention(c) (UnsafeMutableRawPointer?) -> Int32
private typealias FnGetImageDim = @convention(c) (
    UnsafeMutableRawPointer?, UnsafeMutablePointer<UInt32>?) -> Int32
private typealias FnBitmapLockBits = @convention(c) (
    UnsafeMutableRawPointer?, UnsafeRawPointer?, UInt32, Int32,
    UnsafeMutableRawPointer?) -> Int32
private typealias FnBitmapUnlockBits = @convention(c) (
    UnsafeMutableRawPointer?, UnsafeMutableRawPointer?) -> Int32

private enum Gdip {
    static let handle: HMODULE? = "gdiplus.dll".withCString(encodedAs: UTF16.self) { LoadLibraryW($0) }

    static func proc<T>(_ name: String, _ type: T.Type) -> T? {
        guard let h = handle, let p = GetProcAddress(h, name) else { return nil }
        return unsafeBitCast(p, to: T.self)
    }

    static let startup = proc("GdiplusStartup", FnGdiplusStartup.self)
    static let createBitmapFromFile = proc("GdipCreateBitmapFromFile", FnCreateBitmapFromFile.self)
    static let disposeImage = proc("GdipDisposeImage", FnDisposeImage.self)
    static let getWidth = proc("GdipGetImageWidth", FnGetImageDim.self)
    static let getHeight = proc("GdipGetImageHeight", FnGetImageDim.self)
    static let lockBits = proc("GdipBitmapLockBits", FnBitmapLockBits.self)
    static let unlockBits = proc("GdipBitmapUnlockBits", FnBitmapUnlockBits.self)

    /// One-time GdiplusStartup; false when gdiplus is unavailable.
    static let started: Bool = {
        guard let startup else { return false }
        var token: UInt = 0
        var input = GpStartupInput()
        let status = withUnsafeMutablePointer(to: &token) { tok in
            withUnsafePointer(to: &input) { inp in
                startup(UnsafeMutableRawPointer(tok), UnsafeRawPointer(inp), nil)
            }
        }
        return status == 0
    }()
}

enum PlatformImageIO {
    /// Decode a PNG into premultiplied RGBA bytes (top-left origin). GDI+
    /// locks as premultiplied BGRA; rows are copied with R/B swapped so the
    /// core's pixel analysis sees the same layout as on macOS.
    static func decodePNG(_ url: URL) -> RGBABuffer? {
        guard Gdip.started,
              let create = Gdip.createBitmapFromFile, let lock = Gdip.lockBits,
              let unlock = Gdip.unlockBits, let getW = Gdip.getWidth, let getH = Gdip.getHeight
        else { return nil }
        var bitmap: UnsafeMutableRawPointer? = nil
        let path = Array(url.withUnsafeFileSystemRepresentation { String(cString: $0!) }.utf16) + [0]
        let created = path.withUnsafeBufferPointer { create($0.baseAddress, &bitmap) }
        guard created == 0, let bmp = bitmap else { return nil }
        defer { _ = Gdip.disposeImage?(bmp) }

        var w: UInt32 = 0, h: UInt32 = 0
        _ = getW(bmp, &w)
        _ = getH(bmp, &h)
        guard w > 0, h > 0 else { return nil }

        var rect = GpRect(x: 0, y: 0, w: Int32(w), h: Int32(h))
        var data = GpBitmapData()
        let locked = withUnsafePointer(to: &rect) { r in
            withUnsafeMutablePointer(to: &data) { d in
                lock(bmp, UnsafeRawPointer(r), kImageLockModeRead,
                     kPixelFormat32bppPARGB, UnsafeMutableRawPointer(d))
            }
        }
        guard locked == 0, let scan0 = data.scan0 else { return nil }

        let width = Int(w), height = Int(h)
        var out = [UInt8](repeating: 0, count: width * height * 4)
        let src = scan0.assumingMemoryBound(to: UInt8.self)
        for row in 0..<height {
            let srcRow = src + row * Int(data.stride)
            let dstBase = row * width * 4
            for x in 0..<width {
                let s = x * 4, d = dstBase + x * 4
                out[d]     = srcRow[s + 2]   // R <- BGRA.B-slot
                out[d + 1] = srcRow[s + 1]   // G
                out[d + 2] = srcRow[s]       // B <- BGRA.R-slot
                out[d + 3] = srcRow[s + 3]   // A
            }
        }
        _ = withUnsafeMutablePointer(to: &data) { d in
            unlock(bmp, UnsafeMutableRawPointer(d))
        }
        return RGBABuffer(width: width, height: height, pixels: out)
    }

    static func makeImage(_ buffer: RGBABuffer) -> PMFImage? {
        Win32Image(buffer)
    }
}

// MARK: - Screens (Phase 5a): world-coordinate monitor rects for the core's
// spawn/clamp logic.
func platformScreensWorld() -> [CGRect] {
    let screens = ScreenAdapter.screensWorld()
    return screens.isEmpty ? [CGRect(x: 0, y: 0, width: 1440, height: 900)] : screens
}

// MARK: - Item icons (Phase 5a seam). Windows gets the drawn icons in Phase
// 5b (pre-rendered PNGs or an RGBABuffer port of the macOS drawing code);
// until then balls/items render nothing.
func platformItemIcon(_ item: GameItem) -> PMFImage? { nil }

// MARK: - Language list (W10)
func platformPreferredLanguages() -> [String] {
    // GetUserPreferredUILanguages returns a double-null-terminated WCHAR list.
    var count: ULONG = 0
    var chars: ULONG = 0
    guard GetUserPreferredUILanguages(DWORD(MUI_LANGUAGE_NAME), &count, nil, &chars), chars > 0 else {
        return Locale.preferredLanguages
    }
    var buf = [WCHAR](repeating: 0, count: Int(chars))
    guard GetUserPreferredUILanguages(DWORD(MUI_LANGUAGE_NAME), &count, &buf, &chars) else {
        return Locale.preferredLanguages
    }
    var langs: [String] = []
    var start = 0
    for i in 0..<buf.count {
        if buf[i] == 0 {
            if i > start { langs.append(String(decoding: buf[start..<i], as: UTF16.self)) }
            start = i + 1
        }
    }
    return langs.isEmpty ? Locale.preferredLanguages : langs
}
