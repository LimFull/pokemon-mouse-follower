// Windows entry point. Phase 1 scope: command-line hooks only (the shared
// core selftest). Phase 2 adds the message loop, overlay windows, tray icon
// and the 60fps follower tick (design/windows-port.md §4.3).

import Foundation

runCoreSelftestsIfRequested()   // --selftest-core (exits in here)

print("PokemonMouseFollower \(AppVersion.string) (Windows) — UI not implemented yet (Phase 2).")
print("Run with --selftest-core and PMF_SAVE_DIR=<scratch> to exercise the shared core.")
