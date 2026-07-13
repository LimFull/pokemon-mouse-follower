// App-wide core: dev-run detection and the persisted settings store, backed
// by a per-platform SettingsBackend (design/windows-port.md W9 — macOS keeps
// UserDefaults so existing user settings survive; Windows writes settings.json
// under %LOCALAPPDATA%). L() lives in Localization.swift, launch-at-login in
// the platform directories.

import Foundation

// MARK: - Dev-run detection
enum PMF {
    // Dev runs (dev.sh sets PMF_DEV; PMF_FAST_BATTLE test harnesses imply it)
    // keep their own settings + raising save so experiments never touch the
    // release profile. Release builds launched normally have neither set.
    static let isDevRun = ProcessInfo.processInfo.environment["PMF_DEV"] != nil
        || ProcessInfo.processInfo.environment["PMF_FAST_BATTLE"] != nil
}

// MARK: - Settings persistence seam
/// UserDefaults-shaped key/value store. `has` mirrors `object(forKey:) != nil`
/// so the "unset -> default" semantics stay byte-identical on both platforms.
protocol SettingsBackend {
    func has(_ key: String) -> Bool
    func double(_ key: String) -> Double
    func bool(_ key: String) -> Bool
    func string(_ key: String) -> String?
    func set(_ value: Double, _ key: String)
    func set(_ value: Bool, _ key: String)
    func set(_ value: String, _ key: String)
}

// MARK: - Settings
final class AppSettings {
    static let shared = AppSettings()
    private let d: SettingsBackend = makePlatformSettingsBackend()

    static let gapRange: ClosedRange<Double> = 0...500   // px; 200 feels close on 4K-at-1x
    static let speedRange: ClosedRange<Double> = 2...25
    static let scaleRange: ClosedRange<Double> = 1...5
    static let sleepRange: ClosedRange<Double> = 5...120
    static let encounterRange: ClosedRange<Double> = 5...90   // avg minutes (D9)
    static let uiScaleSteps: [Double] = [1.0, 1.25, 1.5, 1.75, 2.0]

    private func get(_ key: String, _ def: Double) -> CGFloat {
        d.has(key) ? CGFloat(d.double(key)) : CGFloat(def)
    }

    var followGap: CGFloat {
        get { get("followGap", 100) }
        set { d.set(Double(newValue), "followGap") }
    }
    var maxSpeed: CGFloat {
        get { get("maxSpeed", 5) }
        set { d.set(Double(newValue), "maxSpeed") }
    }
    var scale: CGFloat {
        get { get("scale", 2) }
        set { d.set(Double(newValue), "scale") }
    }
    var sleepDelay: CGFloat {
        get { get("sleepDelay", 30) }
        set { d.set(Double(newValue), "sleepDelay") }
    }
    var selectedCharacter: String {
        get { d.string("character") ?? "007" }
        set { d.set(newValue, "character") }
    }
    var showShadow: Bool {
        get { d.bool("showShadow") }   // defaults to false when unset
        set { d.set(newValue, "showShadow") }
    }
    // Use the alternate-color sprite variant when a character has one.
    var altColor: Bool {
        get { d.bool("altColor") }
        set { d.set(newValue, "altColor") }
    }
    // Raising mode vs. the normal follower. Design: design/raising-mode.md.
    var raisingMode: Bool {
        get { d.bool("raisingMode") }   // defaults to false when unset
        set { d.set(newValue, "raisingMode") }
    }
    // Average minutes between wild encounters (D9: 빈도는 설정 조절).
    var encounterMinutes: CGFloat {
        get { get("encounterMinutes", 45) }
        set { d.set(Double(newValue), "encounterMinutes") }
    }
    // Zoom for the app's own windows/prompts — 4K-at-1x screens render the
    // fixed point sizes tiny. Menus and NSAlerts are system-drawn and exempt.
    // Windows hides this control: the system DPI plays its role (W8).
    var uiScale: CGFloat {
        get { get("uiScale", 1) }
        set { d.set(Double(newValue), "uiScale") }
    }
    // Master switches for wild encounters / item spawns (default on).
    var wildSpawnsEnabled: Bool {
        get { d.has("wildSpawnsEnabled") ? d.bool("wildSpawnsEnabled") : true }
        set { d.set(newValue, "wildSpawnsEnabled") }
    }
    var itemSpawnsEnabled: Bool {
        get { d.has("itemSpawnsEnabled") ? d.bool("itemSpawnsEnabled") : true }
        set { d.set(newValue, "itemSpawnsEnabled") }
    }
    // PMD-style scrolling battle log under the fight (default on).
    var battleLogEnabled: Bool {
        get { d.has("battleLogEnabled") ? d.bool("battleLogEnabled") : true }
        set { d.set(newValue, "battleLogEnabled") }
    }
    // Floating damage numbers over the hit side in battle (default on).
    var damageNumbersEnabled: Bool {
        get { d.has("damageNumbersEnabled") ? d.bool("damageNumbersEnabled") : true }
        set { d.set(newValue, "damageNumbersEnabled") }
    }
    // Floating shortcut icon that opens the standalone raising panel window
    // (default off). Its position persists across launches; nil = never moved.
    var raisingIconEnabled: Bool {
        get { d.bool("raisingIconEnabled") }
        set { d.set(newValue, "raisingIconEnabled") }
    }
    var raisingIconPos: CGPoint? {
        get {
            guard d.has("raisingIconX"), d.has("raisingIconY") else { return nil }
            return CGPoint(x: d.double("raisingIconX"), y: d.double("raisingIconY"))
        }
        set {
            guard let p = newValue else { return }
            d.set(Double(p.x), "raisingIconX")
            d.set(Double(p.y), "raisingIconY")
        }
    }
    // UI language: "auto" follows the system; "en"/"ko"/"ja" force one (W10).
    var language: String {
        get { d.string("language") ?? "auto" }
        set { d.set(newValue, "language") }
    }
}
