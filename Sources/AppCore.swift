// App-wide core: localized-string lookup, dev-run detection, the
// launch-at-login service wrapper, and the persisted settings store.

import Cocoa
import ServiceManagement

// Localized string lookup (en/ko/ja via *.lproj/Localizable.strings).
func L(_ key: String) -> String { NSLocalizedString(key, comment: "") }

// Launch-at-login backed by SMAppService (macOS 13+). The system owns the
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

// MARK: - Dev-run detection
enum PMF {
    // Dev runs (dev.sh sets PMF_DEV; PMF_FAST_BATTLE test harnesses imply it)
    // keep their own settings + raising save so experiments never touch the
    // release profile. Release builds launched normally have neither set.
    static let isDevRun = ProcessInfo.processInfo.environment["PMF_DEV"] != nil
        || ProcessInfo.processInfo.environment["PMF_FAST_BATTLE"] != nil
}

// MARK: - Settings (persisted in UserDefaults)
final class AppSettings {
    static let shared = AppSettings()
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

    static let gapRange: ClosedRange<Double> = 0...500   // px; 200 feels close on 4K-at-1x
    static let speedRange: ClosedRange<Double> = 2...25
    static let scaleRange: ClosedRange<Double> = 1...5
    static let sleepRange: ClosedRange<Double> = 5...120
    static let encounterRange: ClosedRange<Double> = 5...90   // avg minutes (D9)
    static let uiScaleSteps: [Double] = [1.0, 1.25, 1.5, 1.75, 2.0]

    private func get(_ key: String, _ def: Double) -> CGFloat {
        d.object(forKey: key) == nil ? CGFloat(def) : CGFloat(d.double(forKey: key))
    }

    var followGap: CGFloat {
        get { get("followGap", 100) }
        set { d.set(Double(newValue), forKey: "followGap") }
    }
    var maxSpeed: CGFloat {
        get { get("maxSpeed", 5) }
        set { d.set(Double(newValue), forKey: "maxSpeed") }
    }
    var scale: CGFloat {
        get { get("scale", 2) }
        set { d.set(Double(newValue), forKey: "scale") }
    }
    var sleepDelay: CGFloat {
        get { get("sleepDelay", 30) }
        set { d.set(Double(newValue), forKey: "sleepDelay") }
    }
    var selectedCharacter: String {
        get { d.string(forKey: "character") ?? "007" }
        set { d.set(newValue, forKey: "character") }
    }
    var showShadow: Bool {
        get { d.bool(forKey: "showShadow") }   // defaults to false when unset
        set { d.set(newValue, forKey: "showShadow") }
    }
    // Use the alternate-color sprite variant when a character has one.
    var altColor: Bool {
        get { d.bool(forKey: "altColor") }
        set { d.set(newValue, forKey: "altColor") }
    }
    // Raising mode vs. the normal follower. Design: design/raising-mode.md.
    var raisingMode: Bool {
        get { d.bool(forKey: "raisingMode") }   // defaults to false when unset
        set { d.set(newValue, forKey: "raisingMode") }
    }
    // Average minutes between wild encounters (D9: 빈도는 설정 조절).
    var encounterMinutes: CGFloat {
        get { get("encounterMinutes", 45) }
        set { d.set(Double(newValue), forKey: "encounterMinutes") }
    }
    // Zoom for the app's own windows/prompts — 4K-at-1x screens render the
    // fixed point sizes tiny. Menus and NSAlerts are system-drawn and exempt.
    var uiScale: CGFloat {
        get { get("uiScale", 1) }
        set { d.set(Double(newValue), forKey: "uiScale") }
    }
    // Master switches for wild encounters / item spawns (default on).
    var wildSpawnsEnabled: Bool {
        get { d.object(forKey: "wildSpawnsEnabled") == nil ? true : d.bool(forKey: "wildSpawnsEnabled") }
        set { d.set(newValue, forKey: "wildSpawnsEnabled") }
    }
    var itemSpawnsEnabled: Bool {
        get { d.object(forKey: "itemSpawnsEnabled") == nil ? true : d.bool(forKey: "itemSpawnsEnabled") }
        set { d.set(newValue, forKey: "itemSpawnsEnabled") }
    }
}
