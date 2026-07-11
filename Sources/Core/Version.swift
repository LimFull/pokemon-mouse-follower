// Single source of truth for the app version (design/windows-port.md W16).
// macOS: build.sh keeps Info.plist in sync. Windows: build.ps1 injects this
// into the .rc VERSIONINFO and the installer script.

enum AppVersion {
    static let string = "2.2.0"
}
