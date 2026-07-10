// Localized-string lookup shared by both platforms (design/windows-port.md
// W10): a small .strings parser over the bundled <lang>.lproj/Localizable
// .strings files, replacing NSLocalizedString so macOS and Windows resolve
// strings through the exact same code path. Missing keys echo back, which
// Characters.displayName relies on.

import Foundation

func L(_ key: String) -> String { Localization.table[key] ?? key }

enum Localization {
    static let supported = ["en", "ko", "ja"]

    static let table: [String: String] = {
        let lang = pickLanguage()
        var t = load("en") ?? [:]
        if lang != "en", let l = load(lang) {
            t.merge(l) { _, localized in localized }
        }
        return t
    }()

    /// settings override ("auto" = follow the system) > system language > en.
    static func pickLanguage() -> String {
        let override = AppSettings.shared.language
        if supported.contains(override) { return override }
        for lang in platformPreferredLanguages() {
            let code = lang.lowercased()
            if let hit = supported.first(where: { code.hasPrefix($0) }) { return hit }
        }
        return "en"
    }

    static func load(_ code: String) -> [String: String]? {
        guard let url = Resources.url("Localizable", ext: "strings", subdir: "\(code).lproj"),
              let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        return parse(text)
    }

    /// Parses `"key" = "value";` pairs with \n, \t, \", \\ escapes — the full
    /// grammar this project's .strings files use.
    static func parse(_ text: String) -> [String: String] {
        var out: [String: String] = [:]
        let pattern = #""((?:[^"\\]|\\.)*)"\s*=\s*"((?:[^"\\]|\\.)*)"\s*;"#
        guard let re = try? NSRegularExpression(pattern: pattern) else { return out }
        let ns = text as NSString
        for m in re.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            out[unescape(ns.substring(with: m.range(at: 1)))] =
                unescape(ns.substring(with: m.range(at: 2)))
        }
        return out
    }

    private static func unescape(_ s: String) -> String {
        var r = ""
        var it = s.makeIterator()
        while let c = it.next() {
            if c == "\\", let n = it.next() {
                switch n {
                case "n": r.append("\n")
                case "t": r.append("\t")
                default: r.append(n)
                }
            } else { r.append(c) }
        }
        return r
    }
}
