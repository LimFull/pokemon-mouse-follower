// macOS implementations of the core's platform seams (design/windows-port.md
// §4.2): image decode/encode (ImageIO/CoreGraphics), the UserDefaults settings
// backend (existing user settings keep working), system language list, and the
// SMAppService launch-at-login wrapper that used to live in AppCore.swift.

import Cocoa
import ImageIO
import ServiceManagement

// MARK: - Image IO (W2/W20)
enum PlatformImageIO {
    /// Decode a PNG into premultiplied RGBA bytes (top-left origin).
    static func decodePNG(_ url: URL) -> RGBABuffer? {
        guard let data = try? Data(contentsOf: url),
              let src = CGImageSourceCreateWithData(data as CFData, nil),
              let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return nil }
        let w = img.width, h = img.height
        guard w > 0, h > 0 else { return nil }
        var buf = [UInt8](repeating: 0, count: w * h * 4)
        guard let ctx = CGContext(data: &buf, width: w, height: h,
                                  bitsPerComponent: 8, bytesPerRow: w * 4,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
        return RGBABuffer(width: w, height: h, pixels: buf)
    }

    /// Renderable CGImage from a premultiplied RGBA buffer.
    static func makeImage(_ buffer: RGBABuffer) -> PMFImage? {
        let w = buffer.width, h = buffer.height
        guard w > 0, h > 0,
              let ctx = CGContext(data: nil, width: w, height: h,
                                  bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let dst = ctx.data else { return nil }
        let stride = ctx.bytesPerRow
        buffer.pixels.withUnsafeBytes { src in
            for row in 0..<h {
                dst.advanced(by: row * stride)
                    .copyMemory(from: src.baseAddress!.advanced(by: row * w * 4), byteCount: w * 4)
            }
        }
        return ctx.makeImage()
    }
}

// CGImage conveniences for the macOS-only callers (EffectPlayer, previews)
// that keep working directly with CGImages.
extension Sprite {
    static func loadCG(_ name: String, subdir: String) -> CGImage? {
        guard let buf = loadBuffer(name, subdir: subdir) else { return nil }
        return PlatformImageIO.makeImage(buf)
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
}

// MARK: - Settings backend (W9: UserDefaults, unchanged semantics)
func makePlatformSettingsBackend() -> SettingsBackend {
    UserDefaultsSettingsBackend()
}

private struct UserDefaultsSettingsBackend: SettingsBackend {
    private let d: UserDefaults = {
        guard PMF.isDevRun,
              let dev = UserDefaults(suiteName: "com.local.pokemonmousefollower.dev")
        else { return .standard }
        // First dev run: seed from the release settings so behavior matches,
        // then diverge — dev tweaks never write back to the release domain.
        if !dev.bool(forKey: "pmfDevSeeded") {
            let release = UserDefaults.standard
                .persistentDomain(forName: Bundle.main.bundleIdentifier ?? "com.local.pokemonmousefollower")
            for (key, value) in release ?? [:] { dev.set(value, forKey: key) }
            dev.set(true, forKey: "pmfDevSeeded")
        }
        return dev
    }()

    func has(_ key: String) -> Bool { d.object(forKey: key) != nil }
    func double(_ key: String) -> Double { d.double(forKey: key) }
    func bool(_ key: String) -> Bool { d.bool(forKey: key) }
    func string(_ key: String) -> String? { d.string(forKey: key) }
    func set(_ value: Double, _ key: String) { d.set(value, forKey: key) }
    func set(_ value: Bool, _ key: String) { d.set(value, forKey: key) }
    func set(_ value: String, _ key: String) { d.set(value, forKey: key) }
}

// MARK: - Language list (W10)
func platformPreferredLanguages() -> [String] {
    Locale.preferredLanguages
}

// MARK: - Launch-at-login (SMAppService, macOS 13+). The system owns the
// state, so it defaults to off (not registered) until the user opts in.
enum LoginItem {
    static var isEnabled: Bool { SMAppService.mainApp.status == .enabled }

    @discardableResult
    static func setEnabled(_ on: Bool) -> Bool {
        do {
            if on {
                if SMAppService.mainApp.status != .enabled { try SMAppService.mainApp.register() }
            } else {
                if SMAppService.mainApp.status == .enabled { try SMAppService.mainApp.unregister() }
            }
            return true
        } catch {
            NSLog("PokemonMouseFollower: login item toggle failed: \(error)")
            return false
        }
    }
}
