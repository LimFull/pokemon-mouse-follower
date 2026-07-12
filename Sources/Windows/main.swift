// Windows entry point: command-line hooks, then the message loop with a 60fps
// high-resolution waitable-timer tick driving the follower and — in raising
// mode — the battle/item/evolution controllers, mirroring the macOS
// AppDelegate.tick (design/windows-port.md §4.3, W5, Phase 5b).

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
guard let overlay = OverlaySprite(),           // the follower
      let wildOverlay = OverlaySprite(),       // wandering/battling wild
      let effectOverlay = OverlaySprite(),     // move effect / thrown ball
      let itemOverlay = OverlaySprite(),       // field item drops
      let chrome = BattleChrome() else {
    print("PokemonMouseFollower: overlay window creation failed")
    exit(1)
}
guard let tray = TrayIcon() else {
    print("PokemonMouseFollower: tray icon creation failed")
    exit(1)
}

let battle = BattleController()
let items = ItemSpawnerWin()
let evolution = EvolutionAnimator()
var wasFainted = false
var followerSpriteOverridden = false   // Transform is showing another species
var regenCounter = 0                   // out-of-battle +1 HP tick (~30s)
var dailyHealCounter = 0               // ~10s date-change poll (D23 midnight heal)

func hideAllOverlays() {
    overlay.hide(); wildOverlay.hide(); effectOverlay.hide(); itemOverlay.hide(); chrome.hide()
}

var quitRequested = false
tray.onQuit = { quitRequested = true }
tray.onPauseToggle = { if tray.paused { hideAllOverlays() } }
tray.onSettings = { SettingsDialog.show() }
tray.onCheckUpdate = { [weak tray] in
    UpdaterWin.checkForUpdate { tray?.requestQuit() }
}
SettingsDialog.onCharacterChanged = {
    controller.setCharacter(RaisingState.shared.followerFolder)   // raising mon keeps priority
}

// Debug panel (dev runs only): the actions live in DebugCatalog (Core,
// shared with macOS); the tray item just opens the button window.
if PMF.isDevRun {
    tray.onOpenDebugPanel = {
        DebugPanelWin.show(
            sections: DebugCatalog.sections(
                forceEncounter: { battle.forceEncounter(dex: $0, moves: $1) },
                spawnWild: { battle.forceSpawn() },
                spawnItem: { items.forceSpawn($0, near: controller.position) }),
            startCustom: { dex, moves in
                battle.forceEncounter(dex: dex, moves: moves.isEmpty ? nil : moves)
            })
    }
}
if CommandLine.arguments.contains("--show-settings") { SettingsDialog.show() }

// The active raising mon (or the normal character) should be the follower.
let raisingObserver = NotificationCenter.default.addObserver(
    forName: .raisingChanged, object: nil, queue: nil) { _ in
    controller.setCharacter(RaisingState.shared.followerFolder)
}
// A mon just evolved: play the mainline evolution scene in place.
let evolvedObserver = NotificationCenter.default.addObserver(
    forName: .raisingEvolved, object: nil, queue: nil) { note in
    guard AppSettings.shared.raisingMode,
          let from = note.userInfo?["from"] as? Int,
          let to = note.userInfo?["to"] as? Int else { return }
    evolution.start(fromDex: from, toDex: to, at: controller.position)
}
// Decision prompts (learn move / full party) show as clickable cards.
PromptRelay.handler = { PromptCenterWin.shared.enqueue($0) }
// Debug: preview the on-overlay prompts without earning them (AppDelegate mirror).
if ProcessInfo.processInfo.environment["PMF_TEST_PROMPT"] != nil,
   let mon = RaisingState.shared.active {
    PromptRelay.enqueue(.learnMove(monIndex: 0, moveId: mon.moves.first ?? 154))
    PromptRelay.enqueue(.fullParty(captured: mon))
}

// --smoke <ticks>: run headless-ish for N ticks then exit 0 (dev/CI check).
var smokeTicks = -1
if let i = CommandLine.arguments.firstIndex(of: "--smoke"),
   CommandLine.arguments.count > i + 1 {
    smokeTicks = Int(CommandLine.arguments[i + 1]) ?? 600
}
// --debug-encounter <tick>: start a new game if needed and force a wild
// encounter at that tick (battle playback smoke; scratch save only).
var encounterAtTick = -1
if let i = CommandLine.arguments.firstIndex(of: "--debug-encounter"),
   CommandLine.arguments.count > i + 1 {
    guard ProcessInfo.processInfo.environment["PMF_SAVE_DIR"] != nil else {
        print("refusing --debug-encounter: set PMF_SAVE_DIR to a scratch directory first.")
        exit(2)
    }
    encounterAtTick = Int(CommandLine.arguments[i + 1]) ?? 120
    AppSettings.shared.raisingMode = true
    if !RaisingState.shared.hasActiveGame { RaisingState.shared.startNewGame(dex: 1) }
    controller.setCharacter(RaisingState.shared.followerFolder)
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

/// One 60fps frame — the macOS AppDelegate.tick mirror: advance the follower
/// (walk/faint/evolve/recall), the battle and item controllers, apply the
/// slow timers, then draw everything on the per-entity overlays.
func tickFrame() {
    let cursor = ScreenAdapter.cursorWorld()
    let evoFrame = evolution.active ? evolution.update() : nil
    let evolving = evoFrame != nil
    // Recalled: a game is running but nobody is sent out — no follower.
    let recalled = AppSettings.shared.raisingMode
        && RaisingState.shared.hasActiveGame
        && RaisingState.shared.active == nil
    let fainted = AppSettings.shared.raisingMode
        && (RaisingState.shared.active?.isFainted ?? false)
    if evolving || recalled {
        // hold position; no walking/facing while evolving or recalled
    } else if fainted {
        if !wasFainted { controller.startFaint(); wasFainted = true }
        controller.updateFainted()
    } else {
        wasFainted = false
        if !battle.isBattling {
            controller.update(mouseGlobal: cursor)
        }
    }
    let playerPos = evolving ? evolution.position : controller.position
    let scene = battle.update(playerGlobalPos: playerPos)
    // Transform (D2): while the battle shows the follower as another species,
    // load that species' sheets; restore the real follower when it ends.
    if let dex = scene?.playerSpriteDex {
        controller.setCharacter(Characters.folder(dex: dex))
        followerSpriteOverridden = true
    } else if followerSpriteOverridden {
        followerSpriteOverridden = false
        controller.setCharacter(RaisingState.shared.followerFolder)
    }
    if battle.isBattling, !evolving, let sc = scene {
        controller.face(sc.wildPos, pose: sc.playerPose, poseTick: sc.playerPoseTick)
    }
    // Slow out-of-battle recovery (+1 HP ~30s; napping rests 4x).
    if AppSettings.shared.raisingMode && !battle.isBattling {
        let napping = !recalled && !fainted && !evolving && controller.isSleeping
        regenCounter += napping ? 4 : 1
        if regenCounter >= 30 * 60 {
            regenCounter = 0
            RaisingState.shared.regenTick()
        }
    }
    // Daily full heal (D23) at the actual date change, deferred past battles.
    dailyHealCounter += 1
    if dailyHealCounter >= 10 * 60 {
        dailyHealCounter = 0
        if !battle.isBattling { RaisingState.shared.dailyHealIfNeeded() }
    }
    // Items: the mon picks one up by walking over it (not mid-battle).
    let itemScene = items.update(followerPos: controller.position,
                                 canPickup: !battle.isBattling && !fainted && !recalled)
    // Sidestep offset while the follower dodges a missed attack (#10).
    var renderPos = playerPos
    if let sc = scene, !evolving {
        renderPos.x += sc.playerDodge.x
        renderPos.y += sc.playerDodge.y
    }

    // ---- draw (per-entity layered windows; SpriteView mirror) -------------
    let s = AppSettings.shared.scale
    if let (frame, glow) = evoFrame {
        overlay.present(frame: frame, worldPos: renderPos,
                        shadow: controller.currentShadow,
                        scale: s, showShadow: AppSettings.shared.showShadow,
                        glow: glow)
    } else if recalled || scene?.playerVanished == true {
        // Recalled — or hiding underground/airborne mid-Dig/Fly.
        overlay.hide()
    } else {
        let playerAlpha = scene.map { $0.flashPlayer ? 0.25 : $0.playerAlpha } ?? 1
        // Minimize/Growth body scale rides the draw scale (shadow included);
        // behind a Substitute, the doll stands in for the body.
        let bodyScale = scene?.playerSpriteScale ?? 1
        let playerFrame = scene?.playerSubstitute == true
            ? (BattleController.substituteDoll ?? controller.currentFrame)
            : controller.currentFrame
        overlay.present(frame: playerFrame, worldPos: renderPos,
                        shadow: controller.currentShadow,
                        scale: s * bodyScale, showShadow: AppSettings.shared.showShadow,
                        alpha: playerAlpha, rotation: controller.faintRotation)
    }
    if let sc = scene {
        if sc.wildVanished {
            wildOverlay.hide()   // hiding mid-Dig/Fly
        } else {
            wildOverlay.present(frame: sc.wildFrame, worldPos: sc.wildPos,
                                shadow: ShadowAnchor(offset: .zero, size: .zero),
                                scale: s * sc.wildSpriteScale, showShadow: false,
                                alpha: sc.flashWild ? 0.25 : sc.wildAlpha)
        }
        if let fx = sc.effectFrame {
            effectOverlay.present(frame: fx, worldPos: sc.effectPos,
                                  shadow: ShadowAnchor(offset: .zero, size: .zero),
                                  scale: s, showShadow: false)
        } else {
            effectOverlay.hide()
        }
    } else {
        wildOverlay.hide()
        effectOverlay.hide()
    }
    chrome.present(scene)
    if let item = itemScene {
        itemOverlay.present(frame: item.frame, worldPos: item.pos,
                            shadow: ShadowAnchor(offset: .zero, size: .zero),
                            scale: s, showShadow: false, alpha: item.alpha)
    } else {
        itemOverlay.hide()
    }
}

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
            if tick == encounterAtTick { battle.forceEncounter() }
            tickFrame()
            // Virtual-desktop fallback (§6-2): twice a second, pull the
            // overlays onto the desktop the user switched to.
            if tick % 30 == 0 { VirtualDesktop.keepOverlaysOnCurrentDesktop() }
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

NotificationCenter.default.removeObserver(raisingObserver)
NotificationCenter.default.removeObserver(evolvedObserver)
tray.remove()
if smokeTicks > 0 { print("smoke run complete: \(tick) ticks") }
