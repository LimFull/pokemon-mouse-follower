// Raising mode — on-overlay decision prompts, Windows edition (Phase 5c;
// macOS PromptCenter mirror). Battles run unattended, but two moments need
// input: replacing a move when a 5th is learned and choosing who to release
// when a capture lands with a full party. A small clickable topmost card
// (bottom-center of the cursor's monitor) shows one queued prompt at a time;
// everything else on screen stays click-through as usual.

import WinSDK
import Foundation

private func wide(_ s: String) -> [UInt16] { Array(s.utf16) + [0] }

private let kWM_COMMAND: UINT = 0x0111
private let kWM_SETFONT: UINT = 0x0030
private let kWM_CTLCOLORSTATIC: UINT = 0x0138

private let promptClassName = wide("PMFPrompt")
private var promptClassRegistered = false

private func promptWndProc(_ hwnd: HWND?, _ msg: UINT, _ wParam: WPARAM, _ lParam: LPARAM) -> LRESULT {
    switch msg {
    case kWM_COMMAND:
        PromptCenterWin.shared.choiceTapped(Int(wParam & 0xFFFF))
        return 0
    case kWM_CTLCOLORSTATIC:
        // wParam carries the HDC; bit-pattern conversion (see SettingsDialog).
        if let hdc = HDC(bitPattern: UInt(wParam)) {
            SetBkMode(hdc, TRANSPARENT)
        }
        if let brush = GetSysColorBrush(COLOR_WINDOW) {
            return LRESULT(Int(bitPattern: UnsafeRawPointer(brush)))
        }
        return DefWindowProcW(hwnd, msg, wParam, lParam)
    default:
        return DefWindowProcW(hwnd, msg, wParam, lParam)
    }
}

final class PromptCenterWin {
    static let shared = PromptCenterWin()

    private var queue: [OverlayPrompt] = []
    private var window: HWND?
    private var actions: [() -> Void] = []   // per shown button, by (id - 1)
    private var fonts: [HFONT] = []          // owned by the current card

    func enqueue(_ prompt: OverlayPrompt) {
        queue.append(prompt)
        showNextIfIdle()
    }

    // MARK: presentation

    private func showNextIfIdle() {
        guard window == nil, !queue.isEmpty else { return }
        switch queue.removeFirst() {
        case .learnMove(let monIndex, let moveId):
            showLearnMove(monIndex: monIndex, moveId: moveId)
        case .fullParty(let mon):
            showFullParty(captured: mon)
        }
    }

    private func dismiss() {
        if let window { DestroyWindow(window) }
        window = nil
        actions = []
        for f in fonts { DeleteObject(f) }
        fonts = []
        showNextIfIdle()
    }

    fileprivate func choiceTapped(_ id: Int) {
        let act = actions.indices.contains(id - 1) ? actions[id - 1] : nil
        act?()
        dismiss()
    }

    private func showLearnMove(monIndex: Int, moveId: Int) {
        guard RaisingState.shared.party.indices.contains(monIndex) else { dismiss(); return }
        let mon = RaisingState.shared.party[monIndex]
        let newName = GameData.moves[moveId]?.displayName ?? "Move \(moveId)"
        var subtitle = Characters.displayName(dex: mon.dex)
        if let m = GameData.moves[moveId] {
            subtitle += "  ·  \(m.type ?? "—")"
            if m.effectivePower > 0 { subtitle += "  \(L("move.power")) \(m.effectivePower)" }
            subtitle += "  \(L("move.accuracy")) \(m.accuracyText)"
        }
        var buttons: [(String, () -> Void)] = mon.moves.enumerated().map { (slot, id) in
            ("→ \(GameData.moves[id]?.displayName ?? "Move \(id)")", {
                RaisingState.shared.learnMove(moveId, replacing: slot, at: monIndex)
            })
        }
        buttons.append((L("learn.skip"), {
            RaisingState.shared.learnMove(moveId, replacing: nil, at: monIndex)
        }))
        present(title: "\(L("learn.title"))  \(newName)", subtitle: subtitle, buttons: buttons)
    }

    private func showFullParty(captured mon: OwnedPokemon) {
        let caughtName = Characters.displayName(dex: mon.dex)
        var buttons: [(String, () -> Void)] = RaisingState.shared.party.enumerated().map { (i, member) in
            let name = Characters.displayName(dex: member.dex)
            return ("\(L("detail.release")): \(name)  Lv\(member.level)", {
                RaisingState.shared.resolveCapture(mon, releasing: i)
            })
        }
        buttons.append((L("prompt.full.keep"), {}))   // abandon the new catch
        present(title: L("prompt.full.title"),
                subtitle: "\(L("prompt.caught.title")): \(caughtName)  Lv\(mon.level)",
                buttons: buttons)
    }

    /// Build and show the card window: title, subtitle, one button per choice.
    private func present(title: String, subtitle: String, buttons: [(String, () -> Void)]) {
        if !promptClassRegistered {
            var wc = WNDCLASSW()
            wc.lpfnWndProc = { promptWndProc($0, $1, $2, $3) }
            wc.hInstance = GetModuleHandleW(nil)
            wc.hbrBackground = GetSysColorBrush(COLOR_WINDOW)
            wc.hCursor = LoadCursorW(nil, UnsafePointer<WCHAR>(bitPattern: 32512))
            promptClassName.withUnsafeBufferPointer { wc.lpszClassName = $0.baseAddress }
            promptClassRegistered = RegisterClassW(&wc) != 0
        }
        actions = buttons.map { $0.1 }

        // The monitor the cursor is on decides placement + DPI.
        var cursor = POINT()
        GetCursorPos(&cursor)
        let monitor = MonitorFromPoint(cursor, DWORD(MONITOR_DEFAULTTONEAREST))
        var mi = MONITORINFO()
        mi.cbSize = DWORD(MemoryLayout<MONITORINFO>.size)
        GetMonitorInfoW(monitor, &mi)
        let work = mi.rcWork
        let k = Double(GetDpiForSystem()) / 96.0

        func px(_ v: Double) -> Int32 { Int32((v * k).rounded()) }
        let cardW = 360.0
        let pad = 16.0
        var y = pad
        let titleH = 22.0, subH = 18.0, btnH = 30.0

        let totalH = pad + titleH + 4 + subH + 12 + Double(buttons.count) * (btnH + 6) + pad
        let left = work.left + (work.right - work.left - px(cardW)) / 2
        let top = work.bottom - px(totalH) - px(96)

        // Clickable topmost card: no WS_EX_TRANSPARENT / NOACTIVATE here —
        // its buttons must take clicks (macOS PromptWindow.canBecomeKey mirror).
        let ex: DWORD = 0x0000_0008 /*TOPMOST*/ | 0x0000_0080 /*TOOLWINDOW*/
        let style: DWORD = 0x8000_0000 /*WS_POPUP*/ | 0x0080_0000 /*WS_BORDER*/
        let hwnd = promptClassName.withUnsafeBufferPointer { cls in
            wide("PMF Prompt").withUnsafeBufferPointer { t in
                CreateWindowExW(ex, cls.baseAddress, t.baseAddress, style,
                                left, top, px(cardW), px(totalH),
                                nil, nil, GetModuleHandleW(nil), nil)
            }
        }
        guard let hwnd else { return }
        window = hwnd

        let titleFont = makeFont(14, weight: 600, k: k)
        let bodyFont = makeFont(11, weight: 400, k: k)
        let btnFont = makeFont(12, weight: 600, k: k)
        fonts = [titleFont, bodyFont, btnFont].compactMap { $0 }

        func addChild(_ className: String, _ text: String, id: Int32,
                      x: Double, y: Double, w: Double, h: Double,
                      style extra: DWORD, font: HFONT?) {
            let c = wide(className).withUnsafeBufferPointer { cls in
                wide(text).withUnsafeBufferPointer { txt in
                    CreateWindowExW(0, cls.baseAddress, txt.baseAddress,
                                    DWORD(WS_CHILD | WS_VISIBLE) | extra,
                                    px(x), px(y), px(w), px(h),
                                    hwnd, HMENU(bitPattern: UInt(Int(id))),
                                    GetModuleHandleW(nil), nil)
                }
            }
            if let c, let font {
                SendMessageW(c, kWM_SETFONT, WPARAM(UInt(bitPattern: UnsafeRawPointer(font))), 1)
            }
        }

        addChild("STATIC", title, id: 0, x: pad, y: y, w: cardW - pad * 2, h: titleH,
                 style: 0, font: titleFont)
        y += titleH + 4
        addChild("STATIC", subtitle, id: 0, x: pad, y: y, w: cardW - pad * 2, h: subH,
                 style: 0, font: bodyFont)
        y += subH + 12
        for (i, b) in buttons.enumerated() {
            addChild("BUTTON", b.0, id: Int32(i + 1), x: pad, y: y, w: cardW - pad * 2,
                     h: btnH, style: 0, font: btnFont)
            y += btnH + 6
        }

        ShowWindow(hwnd, SW_SHOW)
        SetForegroundWindow(hwnd)
    }

    private func makeFont(_ size: Double, weight: Int32, k: Double) -> HFONT? {
        let name = wide("Segoe UI")
        let height = -Int32((size * k).rounded())
        return name.withUnsafeBufferPointer { buf -> HFONT? in
            CreateFontW(height, 0, 0, 0, weight, 0, 0, 0,
                        DWORD(DEFAULT_CHARSET), DWORD(OUT_DEFAULT_PRECIS),
                        DWORD(CLIP_DEFAULT_PRECIS), DWORD(CLEARTYPE_QUALITY),
                        DWORD(DEFAULT_PITCH), buf.baseAddress)
        }
    }
}
