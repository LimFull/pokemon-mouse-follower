// Phase 0 spike: minimal stand-ins for the AppKit-layer symbols that the
// six Foundation-only core files reference (L, PMF, AppSettings).
// The L() here is also the checklist probe for custom .strings parsing (W10).

import Foundation

func parseStrings(_ text: String) -> [String: String] {
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

private func unescape(_ s: String) -> String {
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

let stringsTable: [String: String] = {
    let path = ProcessInfo.processInfo.environment["PMF_STRINGS"]
        ?? "C:/가득/pokemon-mouse-follower/Localizable/ko.lproj/Localizable.strings"
    guard let text = try? String(contentsOf: URL(fileURLWithPath: path), encoding: .utf8) else {
        print("WARN: could not read strings file at \(path)")
        return [:]
    }
    return parseStrings(text)
}()

func L(_ key: String) -> String { stringsTable[key] ?? key }

enum PMF {
    static let isDevRun = true
}

final class AppSettings {
    static let shared = AppSettings()
    var altColor = false
    var raisingMode = true
    var selectedCharacter = "007"
}
