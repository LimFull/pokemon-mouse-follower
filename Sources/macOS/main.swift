// macOS entry point. The platform-neutral core (settings, localization,
// characters, sprite slicing, follower brain, raising mode logic) lives in
// Sources/Core; this directory holds the AppKit layer (AppDelegate,
// SpriteView, SettingsWindow, Selftests, RaisingMode UI, Updater).

import Cocoa

runCommandLineHooks()   // --dump-* / --selftest-* flags exit in here

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
