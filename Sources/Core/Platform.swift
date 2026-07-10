// The single #if os() hub (design/windows-port.md W1/W2): platform type
// aliases and the small geometry/pixel types the core shares with both UIs.
// Everything else in Sources/Core must stay platform-neutral Foundation.

import Foundation
#if os(macOS)
import CoreGraphics
#endif

#if os(macOS)
/// Opaque render handle the core hands to the platform renderer (W2).
typealias PMFImage = CGImage
#elseif os(Windows)
typealias PMFImage = Win32Image   // defined in Sources/Windows/PlatformWin.swift
#endif

/// 2D vector for steering math. CGVector does not exist in Windows Foundation
/// (Phase 0 finding), so the core owns its own.
struct Vec2 {
    var dx: CGFloat
    var dy: CGFloat
    static let zero = Vec2(dx: 0, dy: 0)
}

/// Decoded raster: premultiplied RGBA bytes, row-major, top-left origin.
/// The core does all pixel analysis (shadow markers, opaque bounds) on this;
/// platforms convert it to their renderable PMFImage.
struct RGBABuffer {
    let width: Int
    let height: Int
    var pixels: [UInt8]   // width * height * 4 (RGBA, premultiplied)

    /// Copy of a sub-rectangle (clamped to bounds; nil when degenerate).
    func cropped(x: Int, y: Int, w: Int, h: Int) -> RGBABuffer? {
        let x0 = max(0, x), y0 = max(0, y)
        let x1 = min(width, x + w), y1 = min(height, y + h)
        let cw = x1 - x0, ch = y1 - y0
        guard cw > 0, ch > 0 else { return nil }
        var out = [UInt8](repeating: 0, count: cw * ch * 4)
        pixels.withUnsafeBytes { src in
            out.withUnsafeMutableBytes { dst in
                for row in 0..<ch {
                    let srcOff = ((y0 + row) * width + x0) * 4
                    let dstOff = row * cw * 4
                    dst.baseAddress!.advanced(by: dstOff)
                        .copyMemory(from: src.baseAddress!.advanced(by: srcOff), byteCount: cw * 4)
                }
            }
        }
        return RGBABuffer(width: cw, height: ch, pixels: out)
    }
}

// Each platform implements these in its own directory (single-module build):
//   enum PlatformImageIO {
//       static func decodePNG(_ url: URL) -> RGBABuffer?
//       static func makeImage(_ buffer: RGBABuffer) -> PMFImage?
//   }
//   func makePlatformSettingsBackend() -> SettingsBackend
//   func platformPreferredLanguages() -> [String]
