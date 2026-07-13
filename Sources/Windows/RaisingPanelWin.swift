// Raising mode — the panel embedded on the right of the Settings window,
// Windows edition (Phase 5c; macOS RaisingPanel.swift mirror).
//
// Three modes, like macOS: starter picker (no game), party list (rows with
// HP bars + send-out/recall), and a member summary (stats, EXP, moves with
// ON/OFF toggles, usable items). Rebuilds its child controls from scratch on
// every refresh — the same "tear down and rebuild" strategy the macOS panel
// uses with NSStackView.
//
// Visual simplifications vs macOS (functional parity kept): type/status show
// as text instead of colored chips, move descriptions are not expanded
// inline (type/category/power/accuracy still are), and the bag list is not
// scrollable (it grows the panel; 14 item kinds max).

import WinSDK
import Foundation

private func wide(_ s: String) -> [UInt16] { Array(s.utf16) + [0] }

private let kLB_ADDSTRING: UINT = 0x0180
private let kLB_GETCURSEL: UINT = 0x0188
private let kLB_SETCURSEL: UINT = 0x0186

private func sendListString(_ h: HWND?, _ s: String) {
    let units = Array(s.utf16) + [0]
    units.withUnsafeBufferPointer {
        _ = SendMessageW(h, kLB_ADDSTRING, 0,
                         LPARAM(Int(bitPattern: UnsafeRawPointer($0.baseAddress!))))
    }
}

@discardableResult
private func send(_ h: HWND?, _ m: UINT, _ w: WPARAM = 0, _ l: LPARAM = 0) -> LRESULT {
    SendMessageW(h, m, w, l)
}

private let kWM_SETFONT: UINT = 0x0030
private let kBM_GETCHECK: UINT = 0x00F0
private let kBM_SETCHECK: UINT = 0x00F1
private let kCB_ADDSTRING: UINT = 0x0143
private let kCB_GETCURSEL: UINT = 0x0147
private let kCB_SETCURSEL: UINT = 0x014E
private let kTBM_GETPOS: UINT = 0x0400
private let kTBM_SETPOS: UINT = 0x0405
private let kTBM_SETRANGEMIN: UINT = 0x0407
private let kTBM_SETRANGEMAX: UINT = 0x0408

// MARK: - custom-drawn wells (sprites, HP bars) --------------------------------

private var drawWellRegistered = false
private let drawWellClassName = wide("PMFDrawWell")
private var drawWellContent: [HWND: RGBABuffer] = [:]

private func drawWellProc(_ hwnd: HWND?, _ msg: UINT, _ wParam: WPARAM, _ lParam: LPARAM) -> LRESULT {
    if msg == UINT(WM_PAINT), let hwnd, let buf = drawWellContent[hwnd] {
        var ps = PAINTSTRUCT()
        if let hdc = BeginPaint(hwnd, &ps) {
            var bmi = BITMAPINFO()
            bmi.bmiHeader.biSize = DWORD(MemoryLayout<BITMAPINFOHEADER>.size)
            bmi.bmiHeader.biWidth = Int32(buf.width)
            bmi.bmiHeader.biHeight = -Int32(buf.height)
            bmi.bmiHeader.biPlanes = 1
            bmi.bmiHeader.biBitCount = 32
            bmi.bmiHeader.biCompression = DWORD(BI_RGB)
            // RGBA -> BGRA for GDI.
            var bgra = [UInt8](repeating: 0, count: buf.pixels.count)
            for i in stride(from: 0, to: buf.pixels.count, by: 4) {
                bgra[i] = buf.pixels[i + 2]; bgra[i + 1] = buf.pixels[i + 1]
                bgra[i + 2] = buf.pixels[i]; bgra[i + 3] = 255
            }
            _ = bgra.withUnsafeBytes { p in
                SetDIBitsToDevice(hdc, 0, 0, DWORD(buf.width), DWORD(buf.height),
                                  0, 0, 0, UINT(buf.height), p.baseAddress, &bmi,
                                  UINT(DIB_RGB_COLORS))
            }
            EndPaint(hwnd, &ps)
        }
        return 0
    }
    if msg == UINT(WM_DESTROY), let hwnd { drawWellContent[hwnd] = nil }
    return DefWindowProcW(hwnd, msg, wParam, lParam)
}

private func registerDrawWell() {
    guard !drawWellRegistered else { return }
    var wc = WNDCLASSW()
    wc.lpfnWndProc = { drawWellProc($0, $1, $2, $3) }
    wc.hInstance = GetModuleHandleW(nil)
    drawWellClassName.withUnsafeBufferPointer { wc.lpszClassName = $0.baseAddress }
    if RegisterClassW(&wc) != 0 { drawWellRegistered = true }
}

// MARK: - tiny raster helpers (device-pixel canvases composed on window bg)

private func windowBG() -> RGBA {
    let c = GetSysColor(COLOR_WINDOW)
    return RGBA(r: Double(c & 0xFF) / 255, g: Double((c >> 8) & 0xFF) / 255,
                b: Double((c >> 16) & 0xFF) / 255)
}

private func makeCanvas(_ w: Int, _ h: Int, _ bg: RGBA = windowBG()) -> RGBABuffer {
    var px = [UInt8](repeating: 0, count: w * h * 4)
    let r = UInt8(bg.r * 255), g = UInt8(bg.g * 255), b = UInt8(bg.b * 255)
    for i in stride(from: 0, to: px.count, by: 4) { px[i] = r; px[i + 1] = g; px[i + 2] = b; px[i + 3] = 255 }
    return RGBABuffer(width: w, height: h, pixels: px)
}

private func fillRounded(_ c: inout RGBABuffer, x: Int, y: Int, w: Int, h: Int,
                         radius: Int, color: RGBA) {
    let rr = Double(max(0, radius))
    for yy in max(0, y)..<min(c.height, y + h) {
        for xx in max(0, x)..<min(c.width, x + w) {
            let lx = Double(xx - x) + 0.5, ly = Double(yy - y) + 0.5
            let cx = min(max(lx, rr), Double(w) - rr)
            let cy = min(max(ly, rr), Double(h) - rr)
            let d = ((lx - cx) * (lx - cx) + (ly - cy) * (ly - cy)).squareRoot()
            guard d <= rr || (lx >= rr && lx <= Double(w) - rr) || (ly >= rr && ly <= Double(h) - rr) else { continue }
            let i = (yy * c.width + xx) * 4
            let a = color.a, ia = 1 - a
            c.pixels[i] = UInt8(min(255, color.r * 255 * a + Double(c.pixels[i]) * ia))
            c.pixels[i + 1] = UInt8(min(255, color.g * 255 * a + Double(c.pixels[i + 1]) * ia))
            c.pixels[i + 2] = UInt8(min(255, color.b * 255 * a + Double(c.pixels[i + 2]) * ia))
        }
    }
}

/// Track + ratio-colored fill (HPBarView mirror). `fixed` overrides the
/// green/yellow/red auto color (the blue EXP gauge).
private func renderBar(w: Int, h: Int, frac: Double, fixed: RGBA? = nil) -> RGBABuffer {
    var c = makeCanvas(w, h)
    fillRounded(&c, x: 0, y: 0, w: w, h: h, radius: h / 2, color: RGBA(white: 0.5, alpha: 0.25))
    let f = max(0, min(1, frac))
    if f > 0 {
        let auto: RGBA = f > 0.5 ? RGBA(r: 0.20, g: 0.78, b: 0.35)
            : (f > 0.2 ? RGBA(r: 1.0, g: 0.80, b: 0.0) : RGBA(r: 1.0, g: 0.23, b: 0.19))
        fillRounded(&c, x: 0, y: 0, w: max(2, Int(Double(w) * f)), h: h,
                    radius: h / 2, color: fixed ?? auto)
    }
    return c
}

/// Still sprite (idle-down frame 0) scaled to fit a square well, cached.
private var stillCache: [String: RGBABuffer] = [:]
private func renderStill(_ folder: String, box: Int) -> RGBABuffer {
    let key = "\(folder)|\(box)"
    if let hit = stillCache[key] { return hit }
    var c = makeCanvas(box, box)
    let subdir = Characters.spriteSubdir(folder)
    let xml = Sprite.loadText("AnimData", ext: "xml", subdir: subdir)
    var cells = Sprite.slicedSheetBuffers("Idle-Anim", anim: "Idle", subdir: subdir, xml: xml)
    if cells.isEmpty { cells = Sprite.slicedSheetBuffers("Walk-Anim", anim: "Walk", subdir: subdir, xml: xml) }
    if let frame = cells.first?.first, frame.width > 0, frame.height > 0 {
        let factor = min(Double(box) / Double(frame.width), Double(box) / Double(frame.height))
        let dw = max(1, Int(Double(frame.width) * factor)), dh = max(1, Int(Double(frame.height) * factor))
        let ox = (box - dw) / 2, oy = (box - dh) / 2
        let inv = 1.0 / factor
        for y in 0..<dh {
            let sy = min(frame.height - 1, Int(Double(y) * inv))
            for x in 0..<dw {
                let sx = min(frame.width - 1, Int(Double(x) * inv))
                let s = (sy * frame.width + sx) * 4
                let a = Double(frame.pixels[s + 3]) / 255
                guard a > 0 else { continue }
                let d = ((oy + y) * box + (ox + x)) * 4
                let ia = 1 - a
                // frame is premultiplied RGBA over the opaque bg.
                c.pixels[d] = UInt8(min(255, Double(frame.pixels[s]) + Double(c.pixels[d]) * ia))
                c.pixels[d + 1] = UInt8(min(255, Double(frame.pixels[s + 1]) + Double(c.pixels[d + 1]) * ia))
                c.pixels[d + 2] = UInt8(min(255, Double(frame.pixels[s + 2]) + Double(c.pixels[d + 2]) * ia))
            }
        }
    }
    stillCache[key] = c
    return c
}

/// Item icon composed on the window background, cached.
private var itemIconCache: [Int: RGBABuffer] = [:]
private func renderItemIcon(_ item: GameItem, box: Int) -> RGBABuffer {
    if let hit = itemIconCache[item.rawValue] , hit.width == box { return hit }
    var c = makeCanvas(box, box)
    if let icon = platformItemIcon(item) {
        let src = icon.buffer
        let factor = Double(box) / Double(max(src.width, src.height))
        let dw = max(1, Int(Double(src.width) * factor)), dh = max(1, Int(Double(src.height) * factor))
        let inv = 1.0 / factor
        for y in 0..<dh {
            let sy = min(src.height - 1, Int(Double(y) * inv))
            for x in 0..<dw {
                let sx = min(src.width - 1, Int(Double(x) * inv))
                let s = (sy * src.width + sx) * 4
                let a = Double(src.pixels[s + 3]) / 255
                guard a > 0 else { continue }
                let d = (y * box + x) * 4
                let ia = 1 - a
                c.pixels[d] = UInt8(min(255, Double(src.pixels[s]) + Double(c.pixels[d]) * ia))
                c.pixels[d + 1] = UInt8(min(255, Double(src.pixels[s + 1]) + Double(c.pixels[d + 1]) * ia))
                c.pixels[d + 2] = UInt8(min(255, Double(src.pixels[s + 2]) + Double(c.pixels[d + 2]) * ia))
            }
        }
    }
    itemIconCache[item.rawValue] = c
    return c
}

// MARK: - the panel -------------------------------------------------------------

/// Windows counterpart of RaisingPanelView. Owns the child controls it creates
/// on the settings window (all with ids in 2000..2999) and rebuilds them on
/// every state change.
final class RaisingPanelWin {
    static let idRangeStart: Int32 = 2000
    static let idRangeEnd: Int32 = 2999
    private static let idStarterCombo: Int32 = 2001
    private static let idEncounterSlider: Int32 = 2002
    private static let idEncounterValue: Int32 = 2003
    private static let idRememberList: Int32 = 2004

    /// 1x-unit x offset of the panel inside the settings window (the default;
    /// the standalone raising window hosts the panel at its own left margin).
    static let panelX = 410.0
    static let contentWidth = 300.0

    private let parent: HWND
    private let panelX: Double            // 1x-unit x offset inside `parent`
    private let k: Double                 // DPI scale
    private let font: HFONT?
    private let smallFont: HFONT?
    private let monoFont: HFONT?

    private var children: [HWND] = []
    private var actions: [Int32: () -> Void] = [:]
    private var nextId: Int32 = 2100
    private var detailIndex: Int?
    private var expandedMove: Int?
    private var bagExpanded = false
    private var expandedBagItem: GameItem?   // accordion row (desc + use UI)
    private var rememberExpanded = false     // move-reminder disclosure (detail)
    private var rememberChoices: [Int] = []  // move ids behind the LISTBOX rows
    private var rememberListBox: HWND?
    private var observer: NSObjectProtocol?
    private var timerTicks = 0

    /// Called after every rebuild with the content height (1x units).
    var onContentChanged: (() -> Void)?
    private(set) var contentHeight = 0.0

    init(parent: HWND, k: Double, font: HFONT?, smallFont: HFONT?, monoFont: HFONT?,
         panelX: Double = RaisingPanelWin.panelX) {
        self.parent = parent
        self.panelX = panelX
        self.k = k
        self.font = font
        self.smallFont = smallFont
        self.monoFont = monoFont
        registerDrawWell()
        observer = NotificationCenter.default.addObserver(
            forName: .raisingChanged, object: nil, queue: nil) { [weak self] _ in
            self?.rebuild()
        }
        rebuild()
    }

    deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
        destroyChildren()
    }

    /// Keep the panel fresh while it's open (macOS countdown timer mirror):
    /// every second during a battle, every minute while someone is fainted.
    func secondTick() {
        timerTicks += 1
        if BattleController.current?.isBattling == true { rebuild(); return }
        if timerTicks % 60 == 0,
           RaisingState.shared.party.contains(where: { $0.isFainted }) { rebuild() }
    }

    func destroyChildren() {
        for h in children { DestroyWindow(h) }
        children = []
        actions = [:]
        nextId = 2100
    }

    // MARK: builders

    private func px(_ v: Double) -> Int32 { Int32((v * k).rounded()) }

    private enum PanelFont { case normal, small, mono }

    @discardableResult
    private func child(_ className: String, _ text: String, id: Int32,
                       x: Double, y: Double, w: Double, h: Double,
                       style: DWORD, panelFont: PanelFont = .normal) -> HWND? {
        let f: HFONT?
        switch panelFont {
        case .normal: f = font
        case .small: f = smallFont ?? font
        case .mono: f = monoFont ?? font
        }
        let hwndChild = wide(className).withUnsafeBufferPointer { cls in
            wide(text).withUnsafeBufferPointer { txt in
                CreateWindowExW(0, cls.baseAddress, txt.baseAddress,
                                DWORD(WS_CHILD | WS_VISIBLE) | style,
                                px(panelX + x), px(y), px(w), px(h),
                                parent, HMENU(bitPattern: UInt(Int(id))),
                                GetModuleHandleW(nil), nil)
            }
        }
        if let hwndChild {
            if let f {
                SendMessageW(hwndChild, kWM_SETFONT, WPARAM(UInt(bitPattern: UnsafeRawPointer(f))), 1)
            }
            children.append(hwndChild)
        }
        return hwndChild
    }

    private func button(_ text: String, x: Double, y: Double, w: Double, h: Double,
                        small: Bool = false, action: @escaping () -> Void) {
        let id = nextId; nextId += 1
        actions[id] = action
        _ = child("BUTTON", text, id: id, x: x, y: y, w: w, h: h, style: 0,
                  panelFont: small ? .small : .normal)
    }

    private func checkbox(_ text: String, x: Double, y: Double, w: Double, on: Bool,
                          action: @escaping (Bool) -> Void) {
        let id = nextId; nextId += 1
        let h = child("BUTTON", text, id: id, x: x, y: y, w: w, h: 20,
                      style: DWORD(BS_AUTOCHECKBOX), panelFont: .small)
        send(h, kBM_SETCHECK, on ? 1 : 0)
        actions[id] = { [weak self] in
            guard self != nil else { return }
            action(send(h, kBM_GETCHECK) == 1)
        }
    }

    private func label(_ text: String, x: Double, y: Double, w: Double, h: Double = 18,
                       mono: Bool = false, small: Bool = false, right: Bool = false) {
        _ = child("STATIC", text, id: 0, x: x, y: y, w: w, h: h,
                  style: right ? DWORD(SS_RIGHT) : 0,
                  panelFont: mono ? .mono : (small ? .small : .normal))
    }

    private func well(_ buffer: RGBABuffer, x: Double, y: Double, w: Double, h: Double) {
        if let hwnd = child(String(decoding: drawWellClassName.dropLast(), as: UTF16.self), "",
                            id: 0, x: x, y: y, w: w, h: h, style: 0) {
            drawWellContent[hwnd] = buffer
        }
    }

    private func hpBar(_ cur: Int, _ max: Int, x: Double, y: Double, w: Double,
                       fixed: RGBA? = nil) {
        let frac = max > 0 ? Double(cur) / Double(max) : 0
        well(renderBar(w: Int(Double(px(w))), h: Int(Double(px(8))), frac: frac, fixed: fixed),
             x: x, y: y, w: w, h: 8)
    }

    // MARK: refresh

    func rebuild() {
        _ = RaisingState.shared.timedReviveIfNeeded()
        _ = RaisingState.shared.dailyHealIfNeeded()
        destroyChildren()
        var y = 16.0
        if !RaisingState.shared.hasActiveGame {
            buildEmpty(&y)
        } else if let i = detailIndex, RaisingState.shared.party.indices.contains(i) {
            buildDetail(displayMon(RaisingState.shared.party[i], at: i), index: i, y: &y)
        } else {
            detailIndex = nil
            buildList(&y)
        }
        contentHeight = y + 16
        onContentChanged?()
    }

    /// Live HP/status from the battle playback for the active member
    /// (RaisingPanelView.displayMon mirror).
    private func displayMon(_ mon: OwnedPokemon, at index: Int) -> OwnedPokemon {
        guard index == RaisingState.shared.save.activeIndex,
              let bc = BattleController.current,
              let frac = bc.playerGaugeFraction else { return mon }
        var live = mon
        live.currentHP = max(0, min(mon.maxHP, Int((frac * Double(mon.maxHP)).rounded())))
        live.status = bc.playerLiveStatus
        return live
    }

    private func statusText(_ mon: OwnedPokemon) -> String? {
        let style = ["paralysis": "PAR", "sleep": "SLP", "burn": "BRN",
                     "poison": "PSN", "freeze": "FRZ"]
        if mon.isFainted { return "FNT" }
        guard let s = mon.status, let abbr = style[s] else { return nil }
        return abbr
    }

    // MARK: empty (starter picker)

    private func buildEmpty(_ y: inout Double) {
        label(L("detail.empty"), x: 0, y: y, w: RaisingPanelWin.contentWidth, h: 40, small: true)
        y += 48
        let combo = child("COMBOBOX", "", id: RaisingPanelWin.idStarterCombo,
                          x: 0, y: y, w: RaisingPanelWin.contentWidth, h: 240,
                          style: DWORD(CBS_DROPDOWNLIST))
        for s in GameData.starters {
            let title = "\(s.id) · \(Characters.displayName(s.id))"
            _ = wide(title).withUnsafeBufferPointer {
                SendMessageW(combo, kCB_ADDSTRING, 0,
                             LPARAM(Int(bitPattern: UnsafeRawPointer($0.baseAddress!))))
            }
        }
        send(combo, kCB_SETCURSEL, 0)
        y += 34
        button(L("detail.start"), x: 0, y: y, w: 120, h: 26) { [weak self] in
            guard let self else { return }
            let sel = Int(send(self.findChild(RaisingPanelWin.idStarterCombo), kCB_GETCURSEL))
            guard GameData.starters.indices.contains(sel) else { return }
            // Picking a starter IS choosing raising mode (macOS startTapped
            // mirror): from the standalone raising window the settings toggle
            // may still be off. Set it before startNewGame so its
            // raisingChanged observers (follower swap, settings-dialog sync)
            // see the final state.
            AppSettings.shared.raisingMode = true
            RaisingState.shared.startNewGame(dex: GameData.starters[sel].dex)
            self.detailIndex = nil
            self.rebuild()
        }
        y += 34
    }

    private func findChild(_ id: Int32) -> HWND? {
        GetDlgItem(parent, id)
    }

    // MARK: party list

    private func buildList(_ y: inout Double) {
        let state = RaisingState.shared
        let party = state.party
        label("\(L("detail.party"))  \(party.count)/\(RaisingState.maxParty)", x: 0, y: y,
              w: RaisingPanelWin.contentWidth)
        y += 26

        let activeIdx = state.save.activeIndex
        let recallPending = BattleController.current?.recallPending ?? false
        for (i, raw) in party.enumerated() {
            let mon = displayMon(raw, at: i)
            let folder = Characters.folder(dex: mon.dex)
            well(renderStill(folder, box: Int(Double(px(40)))), x: 0, y: y + 5, w: 40, h: 40)
            var title = "\(Characters.displayName(folder))  \(L("detail.level"))\(mon.level)"
            if i == activeIdx { title = "▶ " + title }
            if let st = statusText(mon) { title += "  [\(st)]" }
            button(title, x: 46, y: y, w: 190, h: 22, small: true) { [weak self] in
                self?.detailIndex = i
                self?.rebuild()
            }
            hpBar(mon.currentHP, mon.maxHP, x: 46, y: y + 27, w: 150)
            let hpText = mon.isFainted
                ? "\(L("detail.revive.in")) \(mon.timeUntilRevive)"
                : "\(mon.currentHP)/\(mon.maxHP)"
            label(hpText, x: 200, y: y + 24, w: 66, h: 14, mono: true, right: true)
            if !mon.isFainted, i != activeIdx {
                button("▶", x: 272, y: y + 10, w: 28, h: 26, small: true) {
                    RaisingState.shared.setActive(i)
                }
            } else if i == activeIdx {
                let id = nextId; nextId += 1
                actions[id] = { RaisingState.shared.recall() }
                let b = child("BUTTON", "◀", id: id, x: 272, y: y + 10, w: 28, h: 26,
                              style: 0, panelFont: .small)
                if recallPending { EnableWindow(b, false) }
            }
            y += 52
        }

        // Bag (collapsible; header always visible).
        y += 10
        let total = GameItem.allCases.reduce(0) { $0 + state.itemCount($1) }
        let arrow = bagExpanded ? "▾" : "▸"
        button("🎒 \(L("detail.bag"))  ·  \(total)  \(arrow)", x: 0, y: y, w: 200, h: 24) { [weak self] in
            self?.bagExpanded.toggle()
            self?.rebuild()
        }
        y += 30
        if bagExpanded {
            checkbox(L("bag.capture"), x: 8, y: y, w: RaisingPanelWin.contentWidth - 8,
                     on: state.captureEnabled) { RaisingState.shared.setCaptureEnabled($0) }
            y += 22
            // Two-line height: the caption wraps in every language at this
            // width, and STATIC clips anything past its rect.
            label(L("bag.capture.caption"), x: 10, y: y, w: RaisingPanelWin.contentWidth - 12,
                  h: 30, mono: true, small: true)
            y += 36
            let bag = GameItem.allCases.filter { state.itemCount($0) > 0 }
            if bag.isEmpty {
                label("—", x: 10, y: y, w: 60, mono: true)
                y += 22
            }
            for item in bag {
                well(renderItemIcon(item, box: Int(Double(px(18)))), x: 10, y: y, w: 18, h: 18)
                let arrow = expandedBagItem == item ? "▾" : "▸"
                button("\(item.displayName)  ×\(state.itemCount(item))  \(arrow)",
                       x: 34, y: y - 2, w: 246, h: 22) { [weak self] in
                    guard let self else { return }
                    self.expandedBagItem = self.expandedBagItem == item ? nil : item
                    self.rebuild()
                }
                y += 24
                if expandedBagItem == item {
                    // Two lines for the same reason as the capture caption —
                    // the longer descs (e.g. Great Ball's) wrap at this width.
                    label(item.desc, x: 34, y: y, w: RaisingPanelWin.contentWidth - 40,
                          h: 30, mono: true, small: true)
                    y += 32
                    if item.isBall {
                        // Manual throw — only while a battle is running.
                        if let live = LiveBattle.current, live.playerGaugeFraction != nil {
                            let queued = live.ballPending
                            button(queued ? L("bag.throw.queued") : L("bag.throw"),
                                   x: 34, y: y, w: 200, h: 24) { [weak self] in
                                _ = LiveBattle.current?.requestBall(item)
                                self?.rebuild()
                            }
                            y += 28
                        }
                    } else if state.party.indices.contains(where: { state.canUseItem(item, at: $0) }) {
                        label(L("bag.use"), x: 34, y: y + 4, w: 44, mono: true, small: true)
                        var x = 80.0
                        for (i, mon) in state.party.enumerated() where state.canUseItem(item, at: i) {
                            let name = Characters.displayName(dex: mon.dex)
                            let w = max(56.0, Double(name.count) * 9 + 18)
                            if x + w > RaisingPanelWin.contentWidth { break }   // narrow panel: first fits
                            button(name, x: x, y: y, w: w, h: 24) { [weak self] in
                                _ = RaisingState.shared.useItem(item, at: i)
                                self?.rebuild()
                            }
                            x += w + 6
                        }
                        y += 28
                    }
                    y += 2
                }
            }
            y += 4
        }

        // Raising-only settings.
        y += 10
        label("⚙ " + L("raising.settings"), x: 0, y: y, w: RaisingPanelWin.contentWidth)
        y += 24
        label(L("label.encounter"), x: 0, y: y + 4, w: 120, small: true)
        let bar = child("msctls_trackbar32", "", id: RaisingPanelWin.idEncounterSlider,
                        x: 124, y: y, w: 120, h: 24, style: DWORD(TBS_HORZ))
        send(bar, kTBM_SETRANGEMIN, 1, LPARAM(Int(AppSettings.encounterRange.lowerBound)))
        send(bar, kTBM_SETRANGEMAX, 1, LPARAM(Int(AppSettings.encounterRange.upperBound)))
        send(bar, kTBM_SETPOS, 1, LPARAM(Int(AppSettings.shared.encounterMinutes)))
        _ = child("STATIC", String(format: "%.0fm", Double(AppSettings.shared.encounterMinutes)),
                  id: RaisingPanelWin.idEncounterValue, x: 250, y: y + 4, w: 44, h: 16,
                  style: 0, panelFont: .mono)
        y += 30
        checkbox(L("label.wildspawn"), x: 0, y: y, w: RaisingPanelWin.contentWidth,
                 on: AppSettings.shared.wildSpawnsEnabled) { AppSettings.shared.wildSpawnsEnabled = $0 }
        y += 24
        checkbox(L("label.itemspawn"), x: 0, y: y, w: RaisingPanelWin.contentWidth,
                 on: AppSettings.shared.itemSpawnsEnabled) { AppSettings.shared.itemSpawnsEnabled = $0 }
        y += 24
        checkbox(L("label.damagenumbers"), x: 0, y: y, w: RaisingPanelWin.contentWidth,
                 on: AppSettings.shared.damageNumbersEnabled) { AppSettings.shared.damageNumbersEnabled = $0 }
        y += 24
        checkbox(L("label.battlelog"), x: 0, y: y, w: RaisingPanelWin.contentWidth,
                 on: AppSettings.shared.battleLogEnabled) { AppSettings.shared.battleLogEnabled = $0 }
        y += 30

        button(L("detail.reset"), x: 0, y: y, w: 150, h: 26) { [weak self] in
            guard let self else { return }
            if confirmBox(self.parent, L("detail.reset"), "") {
                RaisingState.shared.reset()
                self.detailIndex = nil
                self.rebuild()
            }
        }
        y += 34
    }

    // MARK: detail (summary)

    private func buildDetail(_ mon: OwnedPokemon, index idx: Int, y: inout Double) {
        guard let s = mon.species else { detailIndex = nil; buildList(&y); return }
        let state = RaisingState.shared

        button("‹ \(L("detail.party"))", x: 0, y: y, w: 110, h: 24, small: true) { [weak self] in
            self?.detailIndex = nil
            self?.expandedMove = nil
            self?.rebuild()
        }
        y += 32

        // Header: sprite + name/gender + level + types.
        well(renderStill(s.id, box: Int(Double(px(64)))), x: 0, y: y, w: 64, h: 64)
        let g = L("detail.gender.\(mon.gender.rawValue)")
        label("\(Characters.displayName(s.id))  \(g)", x: 74, y: y + 8, w: 220, mono: true)
        let types = [s.type1, s.type2].compactMap { $0 }.joined(separator: " · ")
        label("\(L("detail.level"))\(mon.level)   \(types)", x: 74, y: y + 32, w: 220,
              mono: true, small: true)
        y += 72

        // HP + status + bar (+ revive countdown when fainted).
        var hpLine = "\(L("detail.hp"))  \(mon.currentHP)/\(mon.maxHP)"
        if let st = statusText(mon) { hpLine += "   [\(st)]" }
        label(hpLine, x: 0, y: y, w: RaisingPanelWin.contentWidth, mono: true)
        y += 20
        hpBar(mon.currentHP, mon.maxHP, x: 0, y: y, w: RaisingPanelWin.contentWidth - 20)
        y += 14
        if mon.isFainted {
            label("\(L("detail.revive.in"))  \(mon.timeUntilRevive)", x: 0, y: y,
                  w: RaisingPanelWin.contentWidth, mono: true, small: true)
            y += 18
        }

        // Stats (EoS model).
        let st = GameData.stats(s, level: mon.level, ivs: mon.ivs)
        let statLines = [String(format: "ATTACK  %4d   DEFENSE %4d", st.atk, st.def),
                         String(format: "SP.ATK  %4d   SP.DEF  %4d", st.spAtk, st.spDef),
                         String(format: "SPEED   %4d", st.spe)]
        for line in statLines {
            label(line, x: 0, y: y, w: RaisingPanelWin.contentWidth, mono: true, small: true)
            y += 17
        }

        // EXP gauge.
        let (expLeft, expFrac) = mon.expToNext
        label("\(L("detail.exp.next"))  \(expLeft)", x: 0, y: y, w: RaisingPanelWin.contentWidth,
              mono: true, small: true)
        y += 18
        hpBar(Int(expFrac * 1000), 1000, x: 0, y: y, w: RaisingPanelWin.contentWidth - 20,
              fixed: RGBA(r: 0.04, g: 0.52, b: 1.0))
        y += 16

        // Moves with ON/OFF toggles; clicking a name expands its meta line.
        label("▶ \(L("detail.moves"))", x: 0, y: y, w: 200, mono: true)
        y += 22
        for id in mon.moves {
            let enabled = mon.isMoveEnabled(id)
            let name = GameData.moves[id]?.displayName ?? "Move \(id)"
            let arrow = expandedMove == id ? "▾" : "▸"
            button("\(arrow) \(name)\(enabled ? "" : "  (OFF)")", x: 0, y: y, w: 200, h: 22,
                   small: true) { [weak self] in
                guard let self else { return }
                self.expandedMove = (self.expandedMove == id) ? nil : id
                self.rebuild()
            }
            checkbox("", x: 250, y: y + 1, w: 30, on: enabled) { on in
                RaisingState.shared.setMoveEnabled(id, on, at: idx)
            }
            y += 26
            if expandedMove == id, let m = GameData.moves[id] {
                var meta = "\(m.type ?? "—")  \(m.category ?? "")"
                if m.effectivePower > 0 { meta += "  \(L("move.power")) \(m.effectivePower)" }
                meta += "  \(L("move.accuracy")) \(m.accuracyText)"
                label(meta, x: 16, y: y, w: RaisingPanelWin.contentWidth - 16, mono: true, small: true)
                y += 20
            }
        }
        if !mon.moves.isEmpty, mon.moves.allSatisfy({ !mon.isMoveEnabled($0) }) {
            label(L("detail.moves.alloff"), x: 0, y: y, w: RaisingPanelWin.contentWidth, h: 30,
                  small: true)
            y += 32
        }

        // Move reminder (macOS mirror): full learnset up to the current
        // level is relearnable; a full moveset routes through the replace
        // prompt.
        let remember = state.relearnableMoves(at: idx)
        if !remember.isEmpty {
            let arrow = rememberExpanded ? "▾" : "▸"
            button("💭 \(L("detail.remember")) · \(remember.count)  \(arrow)",
                   x: 0, y: y, w: 220, h: 22, small: true) { [weak self] in
                self?.rememberExpanded.toggle()
                self?.rebuild()
            }
            y += 26
            if rememberExpanded {
                // Long learnsets scroll in a LISTBOX (native scrollbar)
                // capped at ~6 rows, with a learn button reading the
                // selection — a button per move would stretch the panel.
                rememberChoices = remember.map(\.moveId)
                let listH = Double(min(remember.count, 6)) * 17 + 6
                rememberListBox = child("LISTBOX", "", id: RaisingPanelWin.idRememberList,
                                        x: 10, y: y, w: 250, h: listH,
                                        style: DWORD(WS_VSCROLL | WS_BORDER | LBS_NOTIFY))
                for (moveId, lv) in remember {
                    let name = GameData.moves[moveId]?.displayName ?? "#\(moveId)"
                    let lvText = String(format: L("detail.remember.lv"), String(lv))
                    sendListString(rememberListBox, "\(name)  ·  \(lvText)")
                }
                send(rememberListBox, kLB_SETCURSEL, 0, 0)
                y += listH + 6
                button(L("detail.remember"), x: 10, y: y, w: 150, h: 24) { [weak self] in
                    guard let self else { return }
                    let sel = Int(send(self.rememberListBox, kLB_GETCURSEL))
                    guard self.rememberChoices.indices.contains(sel) else { return }
                    RaisingState.shared.relearn(self.rememberChoices[sel], at: idx)
                    self.rebuild()
                }
                y += 30
            }
        }

        // Usable items (potions stay visible-but-disabled mid-battle at full HP).
        let battlingActive = idx == state.save.activeIndex
            && BattleController.current?.playerGaugeFraction != nil
        let shown = GameItem.allCases.filter { item in
            if state.canUseItem(item, at: idx) { return true }
            return battlingActive && (item.healAmount > 0 || item.curesStatus)
                && state.itemCount(item) > 0
        }
        if !shown.isEmpty {
            y += 6
            for item in shown {
                let id = nextId; nextId += 1
                actions[id] = { [weak self] in
                    guard let self else { return }
                    if let to = RaisingState.shared.useItem(item, at: idx) {
                        infoBox(self.parent, Characters.displayName(dex: to), L("evo.suffix"))
                    }
                    self.rebuild()
                }
                let b = child("BUTTON", "\(item.displayName)  ×\(state.itemCount(item))",
                              id: id, x: 0, y: y, w: 210, h: 24, style: 0,
                              panelFont: .small)
                if !state.canUseItem(item, at: idx) { EnableWindow(b, false) }
                y += 28
            }
        }

        // Actions: recall / send out + release.
        y += 8
        var x = 0.0
        if idx == state.save.activeIndex {
            let id = nextId; nextId += 1
            actions[id] = { [weak self] in RaisingState.shared.recall(); self?.rebuild() }
            let b = child("BUTTON", L("detail.recall"), id: id, x: x, y: y, w: 100, h: 26,
                          style: 0, panelFont: .small)
            if BattleController.current?.recallPending == true { EnableWindow(b, false) }
            x += 106
        } else if !mon.isFainted {
            button(L("detail.sendout"), x: x, y: y, w: 100, h: 26, small: true) { [weak self] in
                RaisingState.shared.setActive(idx)
                self?.rebuild()
            }
            x += 106
        }
        button(L("detail.release"), x: x, y: y, w: 100, h: 26, small: true) { [weak self] in
            guard let self, RaisingState.shared.party.indices.contains(idx) else { return }
            let name = Characters.displayName(dex: RaisingState.shared.party[idx].dex)
            if confirmBox(self.parent, L("detail.release"), name) {
                RaisingState.shared.release(at: idx)
                self.detailIndex = nil
                self.rebuild()
            }
        }
        y += 34
    }

    // MARK: event routing (called from the settings wndproc)

    /// Returns true when the id belonged to this panel.
    func handleCommand(_ id: Int32) -> Bool {
        guard (RaisingPanelWin.idRangeStart...RaisingPanelWin.idRangeEnd).contains(id) else { return false }
        actions[id]?()
        return true
    }

    func handleHScroll(_ bar: HWND) -> Bool {
        guard GetDlgCtrlID(bar) == RaisingPanelWin.idEncounterSlider else { return false }
        let v = Double(send(bar, kTBM_GETPOS))
        AppSettings.shared.encounterMinutes = CGFloat(v)
        _ = wide(String(format: "%.0fm", v)).withUnsafeBufferPointer {
            SetWindowTextW(findChild(RaisingPanelWin.idEncounterValue), $0.baseAddress)
        }
        return true
    }
}

// MARK: - message boxes

func confirmBox(_ owner: HWND?, _ title: String, _ text: String) -> Bool {
    let r = title.withCString(encodedAs: UTF16.self) { t in
        text.withCString(encodedAs: UTF16.self) { b in
            MessageBoxW(owner, b, t, UINT(MB_OKCANCEL) | UINT(MB_ICONQUESTION))
        }
    }
    return r == IDOK
}

func infoBox(_ owner: HWND?, _ title: String, _ text: String) {
    _ = title.withCString(encodedAs: UTF16.self) { t in
        text.withCString(encodedAs: UTF16.self) { b in
            MessageBoxW(owner, b, t, UINT(MB_OK) | UINT(MB_ICONINFORMATION))
        }
    }
}
