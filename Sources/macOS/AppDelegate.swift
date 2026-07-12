// App delegate: overlay windows (one per screen), status-bar menu,
// the 60fps tick loop, and the self-update flow.

import Cocoa

// MARK: - App Delegate
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let controller = CharacterController()
    private let battle = BattleController()
    private let items = ItemSpawner()
    private var wasFainted = false
    private var followerSpriteOverridden = false   // Transform is showing another species
    private let evolution = EvolutionAnimator()   // mainline evolution scene (D8/#9)
    private var regenCounter = 0            // out-of-battle +1 HP tick (~30s)
    private var dailyHealCounter = 0        // ~10s date-change poll (D23 midnight heal)
    private var overlays: [(window: NSWindow, view: SpriteView)] = []
    private var statusItem: NSStatusItem!
    private var timer: Timer?
    private var running = true
    private var settingsController: SettingsWindowController?
    // Self-update: retained for the lifetime of a download so the delegate lives.
    private var updateInProgress = false
    private var downloader: Downloader?
    private var updateHUD: UpdateProgressWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Core battle playback hands decision prompts to the macOS card UI.
        PromptRelay.handler = { PromptCenter.shared.enqueue($0) }
        setupWindows()
        setupStatusItem()
        setupTimer()
        NotificationCenter.default.addObserver(
            self, selector: #selector(screensChanged),
            name: NSApplication.didChangeScreenParametersNotification, object: nil)
        NotificationCenter.default.addObserver(
            self, selector: #selector(raisingChanged), name: .raisingChanged, object: nil)
        NotificationCenter.default.addObserver(
            self, selector: #selector(raisingEvolved(_:)), name: .raisingEvolved, object: nil)
        if CommandLine.arguments.contains("--show-settings") { showSettings() }
        // Debug: preview the on-overlay prompts (C1) without earning them.
        if ProcessInfo.processInfo.environment["PMF_TEST_PROMPT"] != nil,
           let mon = RaisingState.shared.active {
            PromptCenter.shared.enqueue(.learnMove(monIndex: 0, moveId: mon.moves.first ?? 154))
            PromptCenter.shared.enqueue(.fullParty(captured: mon))
        }
    }

    // The active raising mon (or the normal character) should be the follower.
    @objc private func raisingChanged() {
        controller.setCharacter(RaisingState.shared.followerFolder)
    }

    // A mon just evolved: play the mainline evolution scene in place
    // (silhouette -> accelerating morph -> white-out -> sparkly reveal).
    @objc private func raisingEvolved(_ note: Notification) {
        guard AppSettings.shared.raisingMode,
              let from = note.userInfo?["from"] as? Int,
              let to = note.userInfo?["to"] as? Int else { return }
        evolution.start(fromDex: from, toDex: to, at: controller.position)
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showSettings()
        return true
    }

    // One transparent overlay window per screen. A single window can't span
    // displays when "Displays have separate Spaces" is on, so we use one each.
    private func setupWindows() {
        for (w, _) in overlays { w.close() }   // deterministic teardown, no ghost windows
        overlays.removeAll()

        for screen in NSScreen.screens {
            let frame = screen.frame
            let window = NSWindow(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false   // ARC owns the lifetime via `overlays`
            window.isOpaque = false
            window.backgroundColor = .clear
            window.hasShadow = false
            window.ignoresMouseEvents = true
            window.level = .init(rawValue: Int(CGWindowLevelForKey(.overlayWindow)))
            window.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
            window.setFrame(frame, display: true)

            let view = SpriteView(frame: NSRect(origin: .zero, size: frame.size))
            view.screenOrigin = frame.origin
            view.isHidden = !running
            window.contentView = view
            window.orderFrontRegardless()

            overlays.append((window, view))
        }
    }

    @objc private func screensChanged() { setupWindows() }

    /// A menu item wired to self. `tag`/`represented` ride along for the
    /// handlers that reuse one selector across several items.
    private func menuItem(_ title: String, action: Selector?, key: String = "",
                          tag: Int = 0, represented: Any? = nil) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        item.tag = tag
        item.representedObject = represented
        return item
    }

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            if let img = NSImage(systemSymbolName: "pawprint.fill", accessibilityDescription: "Pokémon Mouse Follower") {
                img.isTemplate = true
                button.image = img
            } else {
                button.title = "🐾"
            }
        }
        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "Pokémon Mouse Follower", action: nil, keyEquivalent: ""))
        menu.addItem(.separator())
        menu.addItem(menuItem(L("menu.settings"), action: #selector(showSettings), key: ","))
        menu.addItem(menuItem(L("menu.pause"), action: #selector(toggleRunning), key: "p"))
        // Debug submenu: instant battles against curated opponents (each
        // exercises a status/effect path), plus item/EXP/heal shortcuts.
        // Dev runs only — dev.sh sets PMF_DEV, and PMF_FAST_BATTLE test runs
        // imply it; the release build never shows it.
        if PMF.isDevRun {
            menu.addItem(menuItem("디버그 패널…", action: #selector(showDebugPanel)))
        }
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "\(L("menu.version")) \(Updater.currentVersion)", action: nil, keyEquivalent: ""))
        menu.addItem(menuItem(L("menu.checkUpdate"), action: #selector(checkForUpdate)))
        menu.addItem(.separator())
        menu.addItem(menuItem(L("menu.quit"), action: #selector(quit), key: "q"))
        statusItem.menu = menu
    }

    /// The debug panel (dev runs): DebugCatalog actions as one-click buttons.
    private let debugPanel = DebugPanelController()

    @objc private func showDebugPanel() {
        debugPanel.show(sections: DebugCatalog.sections(
            forceEncounter: { [weak self] in self?.battle.forceEncounter(dex: $0) },
            spawnWild: { [weak self] in self?.battle.forceSpawn() },
            spawnItem: { [weak self] item in
                guard let self else { return }
                self.items.forceSpawn(item, near: self.controller.position)
            }))
    }

    private func setupTimer() {
        let t = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            guard let self, self.running else { return }
            self.tick()
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    /// One 60fps frame: advance the follower (walk/faint/evolve/recall), the
    /// battle and item controllers, apply the slow timers (regen, daily heal),
    /// then draw everything on every overlay.
    private func tick() {
        let cursor = NSEvent.mouseLocation
        // The evolution scene freezes the follower and takes over its
        // rendering until it completes (mainline behavior).
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
            // A knocked-out active mon plays the faint animation once and stays
            // put where it fell (it doesn't follow the cursor).
            if !wasFainted { controller.startFaint(); wasFainted = true }
            controller.updateFainted()
        } else {
            wasFainted = false
            if !battle.isBattling {
                // Roams after the cursor; encounters happen by chance.
                controller.update(mouseGlobal: cursor)
            }
        }
        let playerPos = evolving ? evolution.position : controller.position
        let scene = battle.update(playerGlobalPos: playerPos)
        // Transform (D2): while the battle shows the follower as another
        // species, load that species' sheets; restore the real follower the
        // tick the override ends (setCharacter dedupes repeated calls).
        if let dex = scene?.playerSpriteDex {
            controller.setCharacter(Characters.folder(dex: dex))
            followerSpriteOverridden = true
        } else if followerSpriteOverridden {
            followerSpriteOverridden = false
            controller.setCharacter(RaisingState.shared.followerFolder)
        }
        if battle.isBattling, !evolving, let sc = scene {
            // Face the wild; play the battle pose the controller picked.
            controller.face(sc.wildPos, pose: sc.playerPose, poseTick: sc.playerPoseTick)
        }
        // Slow out-of-battle recovery: +1 HP to hurt members every ~30s.
        // A follower asleep at the cursor rests properly — 4x the regen
        // (one HP per ~7.5s) — but only while actually out and conscious;
        // a recalled or fainted mon can't be napping (stale isSleeping).
        if AppSettings.shared.raisingMode && !battle.isBattling {
            let napping = !recalled && !fainted && !evolving && controller.isSleeping
            regenCounter += napping ? 4 : 1
            if regenCounter >= 30 * 60 {
                regenCounter = 0
                RaisingState.shared.regenTick()
            }
        }
        // Daily full heal (D23) fires at the actual date change, not just
        // whenever the panel next opens: fainted members revive at local
        // midnight with the settings window closed too. Deferred past a
        // battle in progress — its pre-simulated outcome would overwrite
        // the fresh HP at finishBattle.
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
        for (_, view) in overlays {
            if let (frame, glow) = evoFrame {
                view.render(frame, globalPos: renderPos,
                            shadow: controller.currentShadow, glow: glow)
            } else {
                view.render(recalled ? nil : controller.currentFrame,
                            globalPos: renderPos,
                            shadow: controller.currentShadow,
                            rotation: controller.faintRotation)
            }
            view.renderBattle(scene)
            view.renderItem(itemScene)
        }
    }

    @objc private func showSettings() {
        if settingsController == nil {
            settingsController = SettingsWindowController(controller: controller)
        }
        settingsController?.show()
    }

    @objc private func toggleRunning(_ sender: NSMenuItem) {
        running.toggle()
        sender.title = running ? L("menu.pause") : L("menu.resume")
        for (_, view) in overlays { view.isHidden = !running }
    }

    // MARK: - Self-update

    @objc private func checkForUpdate() {
        guard !updateInProgress else { return }
        Updater.fetchLatest { [weak self] result in
            guard let self else { return }
            switch result {
            case .failure(let e):
                self.updateAlert(.warning, L("update.error"), e.localizedDescription)
            case .success(let rel):
                if Updater.isNewer(rel.version, than: Updater.currentVersion) {
                    self.promptUpdate(rel)
                } else {
                    self.updateAlert(.informational, L("update.latest.title"),
                                     String(format: L("update.latest.body"), Updater.currentVersion))
                }
            }
        }
    }

    private func promptUpdate(_ rel: Updater.Release) {
        NSApp.activate(ignoringOtherApps: true)
        let a = NSAlert()
        a.messageText = String(format: L("update.available.title"), rel.version)
        var info = String(format: L("update.available.body"), Updater.currentVersion, rel.version)
        if !rel.notes.isEmpty { info += "\n\n" + String(rel.notes.prefix(500)) }
        a.informativeText = info
        a.addButton(withTitle: L("update.now"))     // default (first)
        a.addButton(withTitle: L("update.later"))
        if a.runModal() == .alertFirstButtonReturn { startDownload(rel) }
    }

    private func startDownload(_ rel: Updater.Release) {
        updateInProgress = true
        let hud = UpdateProgressWindow()
        updateHUD = hud
        hud.show(L("update.downloading"))
        downloader = Downloader(
            onProgress: { [weak hud] p in hud?.setProgress(p) },
            onDone: { [weak self] result in
                guard let self else { return }
                switch result {
                case .failure(let e):
                    self.finishUpdate(failure: e)
                case .success(let dmg):
                    self.updateHUD?.setText(L("update.installing"))
                    do {
                        try Updater.installAndRelaunch(dmgPath: dmg)
                        NSApp.terminate(nil)
                    } catch {
                        self.finishUpdate(failure: error)
                    }
                }
            })
        downloader?.start(rel.dmgURL)
    }

    private func finishUpdate(failure e: Error) {
        updateHUD?.close()
        updateHUD = nil
        downloader = nil
        updateInProgress = false
        updateAlert(.warning, L("update.error"), e.localizedDescription)
    }

    private func updateAlert(_ style: NSAlert.Style, _ title: String, _ text: String) {
        NSApp.activate(ignoringOtherApps: true)
        let a = NSAlert()
        a.alertStyle = style
        a.messageText = title
        a.informativeText = text
        a.runModal()
    }

    @objc private func quit() {
        NSApplication.shared.terminate(nil)
    }
}
