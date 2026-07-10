// Entry point. All types live in their own files (AppCore, Characters,
// Sprite, CharacterController, SpriteView, UIStyle, CharacterPreviewView,
// SettingsWindow, AppDelegate, Selftests, RaisingMode/, Updater).

import Cocoa

runCommandLineHooks()   // --dump-* / --selftest-* flags exit in here

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
