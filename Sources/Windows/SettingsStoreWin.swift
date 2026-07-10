// Windows settings backend (design/windows-port.md W9): a flat JSON file at
// %LOCALAPPDATA%\PokemonMouseFollower\settings.json (dev runs use dev\ next to
// the dev raising save, mirroring the macOS dev-suite separation).

import Foundation

func makePlatformSettingsBackend() -> SettingsBackend {
    JSONSettingsBackend()
}

private final class JSONSettingsBackend: SettingsBackend {
    private enum Value: Codable {
        case number(Double)
        case flag(Bool)
        case text(String)

        init(from decoder: Decoder) throws {
            let c = try decoder.singleValueContainer()
            if let b = try? c.decode(Bool.self) { self = .flag(b) }
            else if let d = try? c.decode(Double.self) { self = .number(d) }
            else { self = .text(try c.decode(String.self)) }
        }
        func encode(to encoder: Encoder) throws {
            var c = encoder.singleValueContainer()
            switch self {
            case .number(let d): try c.encode(d)
            case .flag(let b): try c.encode(b)
            case .text(let s): try c.encode(s)
            }
        }
    }

    private var values: [String: Value]
    private let fileURL: URL

    init() {
        let fm = FileManager.default
        var dir = (fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
                   ?? fm.temporaryDirectory)
            .appendingPathComponent("PokemonMouseFollower", isDirectory: true)
        if PMF.isDevRun { dir = dir.appendingPathComponent("dev", isDirectory: true) }
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        fileURL = dir.appendingPathComponent("settings.json")
        if let data = try? Data(contentsOf: fileURL),
           let decoded = try? JSONDecoder().decode([String: Value].self, from: data) {
            values = decoded
        } else {
            values = [:]
        }
    }

    private func persist() {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? enc.encode(values) {
            try? data.write(to: fileURL, options: .atomic)
        }
    }

    func has(_ key: String) -> Bool { values[key] != nil }
    func double(_ key: String) -> Double {
        if case .number(let d)? = values[key] { return d }
        return 0
    }
    func bool(_ key: String) -> Bool {
        if case .flag(let b)? = values[key] { return b }
        return false
    }
    func string(_ key: String) -> String? {
        if case .text(let s)? = values[key] { return s }
        return nil
    }
    func set(_ value: Double, _ key: String) { values[key] = .number(value); persist() }
    func set(_ value: Bool, _ key: String) { values[key] = .flag(value); persist() }
    func set(_ value: String, _ key: String) { values[key] = .text(value); persist() }
}
