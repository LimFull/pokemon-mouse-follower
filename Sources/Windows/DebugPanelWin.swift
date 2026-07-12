// Dev-only debug panel, Windows edition (mirrors macOS DebugPanel.swift):
// a topmost window that stays open with every DebugCatalog action as a
// one-click button — replaces the tray's 디버그 submenu dive. Opened from
// the tray's "디버그 패널" item (dev runs only).

import WinSDK
import Foundation

private let kWM_COMMAND: UINT = 0x0111
private let kWM_SETFONT: UINT = 0x0030
private let kWM_CLOSE: UINT = 0x0010
private let idButtonBase: Int32 = 500    // + flat action index

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

    static func show(sections: [DebugSection]) {
        if let p = shared {
            ShowWindow(p.hwnd, SW_SHOW)
            SetForegroundWindow(p.hwnd)
        } else {
            shared = DebugPanelWin(sections: sections)
        }
    }

    private var hwnd: HWND?
    private var flat: [DebugAction] = []
    private var font: HFONT?
    private var k = 1.0   // DPI scale

    // 1x layout units
    private let colW = 190.0, rowH = 26.0, gap = 6.0, margin = 12.0, headerH = 18.0

    private init(sections: [DebugSection]) {
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
        let idx = Int(id - idButtonBase)
        guard flat.indices.contains(idx) else { return }
        flat[idx].run()
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

    private func child(_ className: String, _ text: String, id: Int32,
                       x: Double, y: Double, w: Double, h: Double, style: DWORD) {
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
    }

    /// Two buttons per row, sections separated by a small header.
    private func build(_ sections: [DebugSection]) {
        flat = sections.flatMap(\.actions)
        var y = margin
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
