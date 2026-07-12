// Dev-only debug panel, Windows edition (mirrors macOS DebugPanel.swift):
// a topmost window that stays open with every DebugCatalog action as a
// one-click button — replaces the tray's 디버그 submenu dive. Opened from
// the tray's "디버그 패널" item (dev runs only).

import WinSDK
import Foundation

private let kWM_COMMAND: UINT = 0x0111
private let kWM_SETFONT: UINT = 0x0030
private let kWM_CLOSE: UINT = 0x0010
private let kCB_ADDSTRING: UINT = 0x0143
private let kCB_GETCURSEL: UINT = 0x0147
private let kCB_SETCURSEL: UINT = 0x014E
private let idButtonBase: Int32 = 500    // + flat action index
private let idSpeciesCombo: Int32 = 490
private let idMoveComboBase: Int32 = 491 // + 0..3
private let idStartCustom: Int32 = 496
private let idStartRandom: Int32 = 497
private let idMoveToggleBase: Int32 = 480 // + 0..3 (OFF = exclude the slot)
private let kBM_GETCHECK: UINT = 0x00F0
private let kBM_SETCHECK: UINT = 0x00F1

private func wide(_ s: String) -> [UInt16] { Array(s.utf16) + [0] }

private let debugClassName = wide("PMFDebugPanel")
private var debugClassRegistered = false

private func debugWndProc(_ hwnd: HWND?, _ msg: UINT, _ wParam: WPARAM, _ lParam: LPARAM) -> LRESULT {
    guard let panel = DebugPanelWin.shared else { return DefWindowProcW(hwnd, msg, wParam, lParam) }
    switch msg {
    case kWM_COMMAND:
        panel.handleCommand(Int32(wParam & 0xFFFF))
        return 0
    case kWM_CLOSE:
        // Hide, don't destroy — reopening from the tray is instant and the
        // flat action table stays valid.
        ShowWindow(hwnd, SW_HIDE)
        return 0
    default:
        return DefWindowProcW(hwnd, msg, wParam, lParam)
    }
}

final class DebugPanelWin {
    fileprivate static var shared: DebugPanelWin?

    static func show(sections: [DebugSection],
                     startCustom: @escaping (Int, [Int]) -> Void) {
        if let p = shared {
            p.startCustom = startCustom
            ShowWindow(p.hwnd, SW_SHOW)
            SetForegroundWindow(p.hwnd)
        } else {
            shared = DebugPanelWin(sections: sections, startCustom: startCustom)
        }
    }

    private var hwnd: HWND?
    private var flat: [DebugAction] = []
    private var font: HFONT?
    private var k = 1.0   // DPI scale
    // Custom battle: species + up to 4 moves picked from droplists. The
    // "완전 랜덤" button only dice-rolls the selections; the start button
    // is the single trigger.
    private var startCustom: ((Int, [Int]) -> Void)?
    private var speciesCombo: HWND?
    private var moveCombos: [HWND?] = []
    private var moveToggles: [HWND?] = []
    private let species = DebugCatalog.speciesChoices
    private let moveList = DebugCatalog.moveChoices

    // 1x layout units
    private let colW = 190.0, rowH = 26.0, gap = 6.0, margin = 12.0, headerH = 18.0

    private init(sections: [DebugSection],
                 startCustom: @escaping (Int, [Int]) -> Void) {
        self.startCustom = startCustom
        if !debugClassRegistered {
            var wc = WNDCLASSW()
            wc.lpfnWndProc = { debugWndProc($0, $1, $2, $3) }
            wc.hInstance = GetModuleHandleW(nil)
            wc.hbrBackground = GetSysColorBrush(COLOR_WINDOW)
            wc.hCursor = LoadCursorW(nil, UnsafePointer<WCHAR>(bitPattern: 32512))
            debugClassName.withUnsafeBufferPointer { wc.lpszClassName = $0.baseAddress }
            RegisterClassW(&wc)
            debugClassRegistered = true
        }
        // Topmost so it floats over the overlays while testing.
        let style = DWORD(WS_CAPTION | WS_SYSMENU)
        hwnd = debugClassName.withUnsafeBufferPointer { cls in
            wide("디버그").withUnsafeBufferPointer { title in
                CreateWindowExW(DWORD(WS_EX_TOPMOST), cls.baseAddress, title.baseAddress, style,
                                Int32(CW_USEDEFAULT), Int32(CW_USEDEFAULT), 100, 100,
                                nil, nil, GetModuleHandleW(nil), nil)
            }
        }
        guard let hwnd else { return }
        k = Double(GetDpiForWindow(hwnd)) / 96.0
        font = makeFont(12)
        build(sections)
        ShowWindow(hwnd, SW_SHOW)
        SetForegroundWindow(hwnd)
    }

    fileprivate func handleCommand(_ id: Int32) {
        switch id {
        case idStartCustom:
            let sel = Int(SendMessageW(speciesCombo, kCB_GETCURSEL, 0, 0))
            guard species.indices.contains(sel) else { return }
            // Move droplists have "—" at index 0 = leave the slot natural;
            // an unchecked toggle excludes the slot outright.
            let moves = zip(moveCombos, moveToggles).compactMap { combo, toggle -> Int? in
                guard SendMessageW(toggle, kBM_GETCHECK, 0, 0) == 1 else { return nil }
                let i = Int(SendMessageW(combo, kCB_GETCURSEL, 0, 0)) - 1
                return moveList.indices.contains(i) ? moveList[i].id : nil
            }
            startCustom?(species[sel].dex, moves)
        case idStartRandom:
            // Dice-roll the form only — visible/tweakable before starting.
            let loadout = DebugCatalog.randomLoadout()
            if let si = species.firstIndex(where: { $0.dex == loadout.dex }) {
                SendMessageW(speciesCombo, kCB_SETCURSEL, WPARAM(si), 0)
            }
            for (i, combo) in moveCombos.enumerated() {
                let idx = i < loadout.moves.count
                    ? moveList.firstIndex(where: { $0.id == loadout.moves[i] })
                    : nil
                SendMessageW(combo, kCB_SETCURSEL, WPARAM((idx ?? -1) + 1), 0)
                SendMessageW(moveToggles[i], kBM_SETCHECK, 1, 0)   // fresh roll: all slots on
            }
        default:
            let idx = Int(id - idButtonBase)
            guard flat.indices.contains(idx) else { return }
            flat[idx].run()
        }
    }

    // MARK: build

    private func px(_ v: Double) -> Int32 { Int32((v * k).rounded()) }

    private func makeFont(_ size: Double) -> HFONT? {
        wide("Segoe UI").withUnsafeBufferPointer { buf in
            CreateFontW(-px(size), 0, 0, 0, 400, 0, 0, 0,
                        DWORD(DEFAULT_CHARSET), DWORD(OUT_DEFAULT_PRECIS),
                        DWORD(CLIP_DEFAULT_PRECIS), DWORD(CLEARTYPE_QUALITY),
                        DWORD(DEFAULT_PITCH), buf.baseAddress)
        }
    }

    @discardableResult
    private func child(_ className: String, _ text: String, id: Int32,
                       x: Double, y: Double, w: Double, h: Double, style: DWORD) -> HWND? {
        let c = wide(className).withUnsafeBufferPointer { cls in
            wide(text).withUnsafeBufferPointer { txt in
                CreateWindowExW(0, cls.baseAddress, txt.baseAddress,
                                DWORD(WS_CHILD | WS_VISIBLE) | style,
                                px(x), px(y), px(w), px(h),
                                hwnd, HMENU(bitPattern: UInt(Int(id))), GetModuleHandleW(nil), nil)
            }
        }
        if let c, let font {
            SendMessageW(c, kWM_SETFONT, WPARAM(UInt(bitPattern: UnsafeRawPointer(font))), 1)
        }
        return c
    }

    private func addString(_ combo: HWND?, _ s: String) {
        _ = wide(s).withUnsafeBufferPointer {
            SendMessageW(combo, kCB_ADDSTRING, 0,
                         LPARAM(Int(bitPattern: UnsafeRawPointer($0.baseAddress!))))
        }
    }

    /// Two buttons per row, sections separated by a small header.
    private func build(_ sections: [DebugSection]) {
        flat = sections.flatMap(\.actions)
        var y = margin

        // Custom battle: species droplist + start buttons, then 4 move
        // droplists ("—" = leave that slot to the natural moveset).
        child("STATIC", "커스텀 배틀 (기술 미선택 칸은 자연 기술셋)", id: 0,
              x: margin, y: y, w: colW * 2 + gap, h: headerH, style: 0)
        y += headerH + 2
        speciesCombo = child("COMBOBOX", "", id: idSpeciesCombo,
                             x: margin, y: y, w: colW, h: 300,
                             style: DWORD(CBS_DROPDOWNLIST | WS_VSCROLL))
        for s in species { addString(speciesCombo, s.name) }
        SendMessageW(speciesCombo, kCB_SETCURSEL, 0, 0)
        let half = (colW - gap) / 2
        child("BUTTON", "시작", id: idStartCustom,
              x: margin + colW + gap, y: y, w: half, h: rowH, style: DWORD(BS_PUSHBUTTON))
        child("BUTTON", "완전 랜덤", id: idStartRandom,
              x: margin + colW + gap + half + gap, y: y, w: half, h: rowH,
              style: DWORD(BS_PUSHBUTTON))
        y += rowH + gap
        let toggleW = 20.0
        moveCombos = (0..<4).map { i in
            let x = margin + Double(i % 2) * (colW + gap)
            let combo = child("COMBOBOX", "", id: idMoveComboBase + Int32(i),
                              x: x, y: y + Double(i / 2) * (rowH + gap),
                              w: colW - toggleW - 4, h: 300,
                              style: DWORD(CBS_DROPDOWNLIST | WS_VSCROLL))
            addString(combo, "—")
            for m in moveList { addString(combo, m.name) }
            SendMessageW(combo, kCB_SETCURSEL, 0, 0)
            return combo
        }
        // Per-slot on/off: an OFF slot is excluded without clearing its pick.
        moveToggles = (0..<4).map { i in
            let x = margin + Double(i % 2) * (colW + gap) + colW - toggleW
            let t = child("BUTTON", "", id: idMoveToggleBase + Int32(i),
                          x: x, y: y + Double(i / 2) * (rowH + gap), w: toggleW, h: rowH,
                          style: DWORD(BS_AUTOCHECKBOX))
            SendMessageW(t, kBM_SETCHECK, 1, 0)
            return t
        }
        y += (rowH + gap) * 2 + 6

        var id = idButtonBase
        for section in sections {
            child("STATIC", section.title, id: 0,
                  x: margin, y: y, w: colW * 2 + gap, h: headerH, style: 0)
            y += headerH + 2
            var col = 0
            for action in section.actions {
                let x = margin + Double(col) * (colW + gap)
                child("BUTTON", action.title, id: id,
                      x: x, y: y, w: colW, h: rowH, style: DWORD(BS_PUSHBUTTON))
                id += 1
                col += 1
                if col == 2 { col = 0; y += rowH + gap }
            }
            if col != 0 { y += rowH + gap }
            y += 6
        }
        // Size the window to the content (client -> window rect).
        var rect = RECT(left: 0, top: 0,
                        right: px(margin * 2 + colW * 2 + gap), bottom: px(y + 2))
        AdjustWindowRectExForDpi(&rect, DWORD(WS_CAPTION | WS_SYSMENU), false, 0,
                                 UINT(GetDpiForWindow(hwnd)))
        SetWindowPos(hwnd, nil, 0, 0, rect.right - rect.left, rect.bottom - rect.top,
                     UINT(SWP_NOMOVE | SWP_NOZORDER))
    }
}
