// Windows entry point: command-line hooks, then the message loop with a 60fps
// high-resolution waitable-timer tick driving the follower (design/
// windows-port.md §4.3, W5). Phase 2 scope: cursor-following overlay + tray.
// Settings/updater arrive in Phase 3/4, raising-mode visuals in Phase 5.

import WinSDK
import Foundation

runCoreSelftestsIfRequested()   // --selftest-core (exits in here)

// Per-Monitor V2 DPI awareness (W4): all coordinates in physical pixels.
_ = SetProcessDpiAwarenessContext(DPI_AWARENESS_CONTEXT(bitPattern: -4))

ScreenAdapter.refresh()

let controller = CharacterController()
guard controller.loaded else {
    print("PokemonMouseFollower: failed to load sprites — is characters/ next to the exe?")
    exit(1)
}
guard let overlay = OverlaySprite() else {
    print("PokemonMouseFollower: overlay window creation failed")
    exit(1)
}
guard let tray = TrayIcon() else {
    print("PokemonMouseFollower: tray icon creation failed")
    exit(1)
}

var quitRequested = false
tray.onQuit = { quitRequested = true }
tray.onPauseToggle = { if tray.paused { overlay.hide() } }
tray.onSettings = { SettingsDialog.show() }
SettingsDialog.onCharacterChanged = {
    controller.setCharacter(RaisingState.shared.followerFolder)   // raising mon keeps priority
}
if CommandLine.arguments.contains("--show-settings") { SettingsDialog.show() }

// --smoke <ticks>: run headless-ish for N ticks then exit 0 (dev/CI check).
var smokeTicks = -1
if let i = CommandLine.arguments.firstIndex(of: "--smoke"),
   CommandLine.arguments.count > i + 1 {
    smokeTicks = Int(CommandLine.arguments[i + 1]) ?? 600
}

// 60fps tick: a high-resolution waitable timer re-armed each fire keeps the
// true 16.67ms cadence (SetWaitableTimer periods are whole milliseconds).
guard let tickTimer = CreateWaitableTimerExW(nil, nil,
                                             0x0000_0002 /*HIGH_RESOLUTION*/,
                                             0x1F0003 /*TIMER_ALL_ACCESS*/) else {
    print("PokemonMouseFollower: waitable timer creation failed")
    exit(1)
}
func armTick() {
    var due = LARGE_INTEGER()
    due.QuadPart = -166_667   // 16.6667ms, in 100ns units, relative
    SetWaitableTimer(tickTimer, &due, 0, nil, nil, false)
}
armTick()

let kQS_ALLINPUT: DWORD = 0x04FF
let kINFINITE: DWORD = 0xFFFF_FFFF
var tick = 0
var msg = MSG()
var waitHandles: [HANDLE?] = [tickTimer]

while !quitRequested {
    let r = waitHandles.withUnsafeMutableBufferPointer {
        MsgWaitForMultipleObjectsEx(1, $0.baseAddress, kINFINITE, kQS_ALLINPUT, 0)
    }
    if r == WAIT_OBJECT_0 {
        armTick()
        if !tray.paused {
            tick += 1
            controller.update(mouseGlobal: ScreenAdapter.cursorWorld())
            overlay.present(frame: controller.currentFrame,
                            worldPos: controller.position,
                            shadow: controller.currentShadow,
                            scale: AppSettings.shared.scale,
                            showShadow: AppSettings.shared.showShadow)
        }
        if smokeTicks > 0, tick >= smokeTicks { quitRequested = true }
    } else {
        while PeekMessageW(&msg, nil, 0, 0, UINT(PM_REMOVE)) {
            if msg.message == UINT(WM_QUIT) { quitRequested = true; break }
            TranslateMessage(&msg)
            DispatchMessageW(&msg)
        }
    }
}

tray.remove()
if smokeTicks > 0 { print("smoke run complete: \(tick) ticks") }
