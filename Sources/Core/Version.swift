// Windows app version (design/windows-port.md W16): build.ps1 injects this
// into the .rc VERSIONINFO and the installer script; UpdaterWin compares
// against it. Managed independently of the macOS version (Info.plist,
// released by release.sh) — each OS ships on its own version track, and the
// site buttons + in-app updaters resolve per-platform assets.

enum AppVersion {
    static let string = "2.16.2"
}
