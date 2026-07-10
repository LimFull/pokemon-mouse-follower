// Bundled-resource locator (design/windows-port.md W12). One code path for
// both platforms: macOS resolves inside the .app bundle's Resources/, Windows
// next to the exe (Bundle.main.resourceURL is the exe directory there —
// verified in Phase 0), with an explicit exe-relative fallback.

import Foundation

enum Resources {
    static let root: URL = {
        if let r = Bundle.main.resourceURL { return r }
        // Fallback: directory containing the executable.
        let exe = URL(fileURLWithPath: CommandLine.arguments[0])
        return exe.deletingLastPathComponent()
    }()

    /// Mirrors Bundle.main.url(forResource:withExtension:subdirectory:) but
    /// with a plain existence check, so behavior is identical on Windows.
    static func url(_ name: String, ext: String, subdir: String? = nil) -> URL? {
        var dir = root
        if let subdir { dir.appendPathComponent(subdir, isDirectory: true) }
        let u = dir.appendingPathComponent("\(name).\(ext)")
        return FileManager.default.fileExists(atPath: u.path) ? u : nil
    }
}
