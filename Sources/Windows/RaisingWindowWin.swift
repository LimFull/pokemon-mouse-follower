// Raising mode — the standalone raising window + floating shortcut icon,
// Windows edition (macOS RaisingWindow.swift mirror): the party/bag panel
// from Settings in its own topmost window, opened from the tray menu or the
// draggable bag icon, and closed by clicking anywhere outside it.

import WinSDK
import Foundation

private func wide(_ s: String) -> [UInt16] { Array(s.utf16) + [0] }

private let kWM_COMMAND: UINT = 0x0111
private let kWM_HSCROLL: UINT = 0x0114
private let kWM_TIMER: UINT = 0x0113
private let kWM_CLOSE: UINT = 0x0010
private let kWM_DESTROY: UINT = 0x0002
private let kWM_ACTIVATE: UINT = 0x0006
private let kWM_PAINT: UINT = 0x000F
private let kWM_CTLCOLORSTATIC: UINT = 0x0138
private let kWM_LBUTTONDOWN: UINT = 0x0201
private let kWM_LBUTTONUP: UINT = 0x0202
private let kWM_MOUSEMOVE: UINT = 0x0200
private let kWA_INACTIVE: UINT = 0

// MARK: - standalone raising window ---------------------------------------------

private let raisingWindowClassName = wide("PMFRaisingWindow")
private var raisingWindowClassRegistered = false

private func raisingWndProc(_ hwnd: HWND?, _ msg: UINT, _ wParam: WPARAM, _ lParam: LPARAM) -> LRESULT {
    guard let win = RaisingWindowWin.shared else { return DefWindowProcW(hwnd, msg, wParam, lParam) }
    switch msg {
    case kWM_COMMAND:
        _ = win.panel?.handleCommand(Int32(wParam & 0xFFFF))
        return 0
    case kWM_HSCROLL:
        if let bar = HWND(bitPattern: UInt(bitPattern: Int(lParam))) {
            _ = win.panel?.handleHScroll(bar)
        }
        return 0
    case kWM_TIMER:
        win.panel?.secondTick()
        return 0
    case kWM_ACTIVATE:
        // Click-outside-to-close (macOS windowDidResignKey mirror). A modal
        // MessageBox from a panel action (release/reset confirms) disables
        // this window before taking activation — skip those; only a click
        // genuinely outside closes the panel.
        if UINT(wParam & 0xFFFF) == kWA_INACTIVE, let hwnd, IsWindowEnabled(hwnd) {
            PostMessageW(hwnd, kWM_CLOSE, 0, 0)
        }
        return 0
    case kWM_CTLCOLORSTATIC:
        // Labels sit on the white window background (SettingsDialog mirror).
        if let hdc = HDC(bitPattern: UInt(wParam)) {
            SetBkMode(hdc, TRANSPARENT)
        }
        if let brush = GetSysColorBrush(COLOR_WINDOW) {
            return LRESULT(Int(bitPattern: UnsafeRawPointer(brush)))
        }
        return DefWindowProcW(hwnd, msg, wParam, lParam)
    case kWM_CLOSE:
        DestroyWindow(hwnd)
        return 0
    case kWM_DESTROY:
        KillTimer(hwnd, 1)
        win.panel = nil
        RaisingWindowWin.shared = nil
        return 0
    default:
        return DefWindowProcW(hwnd, msg, wParam, lParam)
    }
}

/// Windows counterpart of RaisingWindowController: hosts a RaisingPanelWin
/// at its own left margin instead of the settings window's right column.
final class RaisingWindowWin {
    static var shared: RaisingWindowWin?

    /// Bring the window up (tray menu / shortcut icon). `near` — the icon's
    /// native window rect — places the window next to the icon; nil keeps
    /// the system-default position.
    static func show(near anchor: RECT? = nil) {
        if shared == nil { shared = RaisingWindowWin(anchor: anchor) }
        guard let win = shared else { return }
        ShowWindow(win.hwnd, SW_SHOW)
        SetForegroundWindow(win.hwnd)
    }

    static func toggle(near anchor: RECT? = nil) {
        if let win = shared {
            PostMessageW(win.hwnd, kWM_CLOSE, 0, 0)
        } else {
            show(near: anchor)
        }
    }

    private(set) var hwnd: HWND?
    var panel: RaisingPanelWin?
    private var k: Double = 1
    private var font: HFONT?
    private var smallFont: HFONT?
    private var monoFont: HFONT?
    private let panelMargin = 12.0
    private let style = DWORD(WS_CAPTION | WS_SYSMENU)

    private init(anchor: RECT?) {
        if !raisingWindowClassRegistered {
            var wc = WNDCLASSW()
            wc.lpfnWndProc = { raisingWndProc($0, $1, $2, $3) }
            wc.hInstance = GetModuleHandleW(nil)
            wc.hbrBackground = GetSysColorBrush(COLOR_WINDOW)
            wc.hCursor = LoadCursorW(nil, UnsafePointer<WCHAR>(bitPattern: 32512))
            raisingWindowClassName.withUnsafeBufferPointer { wc.lpszClassName = $0.baseAddress }
            RegisterClassW(&wc)
            raisingWindowClassRegistered = true
        }
        hwnd = raisingWindowClassName.withUnsafeBufferPointer { cls in
            wide(L("detail.window.title")).withUnsafeBufferPointer { title in
                CreateWindowExW(DWORD(WS_EX_TOPMOST), cls.baseAddress, title.baseAddress, style,
                                Int32(CW_USEDEFAULT), Int32(CW_USEDEFAULT), 100, 100,
                                nil, nil, GetModuleHandleW(nil), nil)
            }
        }
        guard let hwnd else { return }
        k = Double(GetDpiForWindow(hwnd)) / 96.0
        font = makeUIFont(13, k: k)
        smallFont = makeUIFont(11, k: k)
        monoFont = makeUIMonoFont(11, k: k)
        let p = RaisingPanelWin(parent: hwnd, k: k, font: font,
                                smallFont: smallFont, monoFont: monoFont,
                                panelX: panelMargin)
        p.onContentChanged = { [weak self] in self?.applyWindowSize() }
        panel = p
        applyWindowSize()
        if let a = anchor { position(near: a) }
        SetTimer(hwnd, 1, 1000, nil)   // battle/fainted refresh (settings mirror)
    }

    private func px(_ v: Double) -> Int32 { Int32((v * k).rounded()) }

    /// Window sized to the panel's content (SettingsDialog.applyWindowSize
    /// mirror), capped to the work area so a stuffed panel keeps its buttons
    /// on-screen.
    private func applyWindowSize() {
        guard let hwnd, let panel else { return }
        let width = panelMargin + 320
        var workH = 900.0
        var mi = MONITORINFO()
        mi.cbSize = DWORD(MemoryLayout<MONITORINFO>.size)
        if let mon = MonitorFromWindow(hwnd, DWORD(MONITOR_DEFAULTTONEAREST)),
           GetMonitorInfoW(mon, &mi) {
            workH = Double(mi.rcWork.bottom - mi.rcWork.top) / k - 40
        }
        let height = max(240, min(workH, panel.contentHeight))
        var rc = RECT(left: 0, top: 0, right: px(width), bottom: px(height))
        AdjustWindowRect(&rc, style, false)
        SetWindowPos(hwnd, nil, 0, 0, rc.right - rc.left, rc.bottom - rc.top,
                     UINT(SWP_NOMOVE | SWP_NOZORDER | SWP_NOACTIVATE))
        InvalidateRect(hwnd, nil, true)
    }

    /// Next to the icon — to its left when it hugs the right work-area edge,
    /// otherwise to its right — top-aligned and clamped (macOS mirror).
    private func position(near a: RECT) {
        guard let hwnd else { return }
        var wr = RECT()
        GetWindowRect(hwnd, &wr)
        let w = wr.right - wr.left, h = wr.bottom - wr.top
        var mi = MONITORINFO()
        mi.cbSize = DWORD(MemoryLayout<MONITORINFO>.size)
        var work = RECT(left: 0, top: 0, right: GetSystemMetrics(SM_CXSCREEN),
                        bottom: GetSystemMetrics(SM_CYSCREEN))
        let pt = POINT(x: (a.left + a.right) / 2, y: (a.top + a.bottom) / 2)
        if let mon = MonitorFromPoint(pt, DWORD(MONITOR_DEFAULTTONEAREST)),
           GetMonitorInfoW(mon, &mi) {
            work = mi.rcWork
        }
        var x = a.right + 10
        if x + w > work.right { x = a.left - 10 - w }
        var y = a.top          // window top == icon top (y-down native coords)
        x = min(max(x, work.left + 8), work.right - w - 8)
        y = min(max(y, work.top + 8), work.bottom - h - 8)
        SetWindowPos(hwnd, nil, x, y, 0, 0, UINT(SWP_NOSIZE | SWP_NOZORDER | SWP_NOACTIVATE))
    }
}

// MARK: - shared font helpers (SettingsDialog mirrors, file-internal there)

private func makeUIFont(_ size: Double, k: Double) -> HFONT? {
    let name = wide("Segoe UI")
    let height = -Int32((size * k).rounded())
    return name.withUnsafeBufferPointer { buf -> HFONT? in
        CreateFontW(height, 0, 0, 0, 400, 0, 0, 0,
                    DWORD(DEFAULT_CHARSET), DWORD(OUT_DEFAULT_PRECIS),
                    DWORD(CLIP_DEFAULT_PRECIS), DWORD(CLEARTYPE_QUALITY),
                    DWORD(DEFAULT_PITCH), buf.baseAddress)
    }
}

private func makeUIMonoFont(_ size: Double, k: Double) -> HFONT? {
    let name = wide("Consolas")
    let height = -Int32((size * k).rounded())
    return name.withUnsafeBufferPointer { buf -> HFONT? in
        CreateFontW(height, 0, 0, 0, 400, 0, 0, 0,
                    DWORD(DEFAULT_CHARSET), DWORD(OUT_DEFAULT_PRECIS),
                    DWORD(CLIP_DEFAULT_PRECIS), DWORD(CLEARTYPE_QUALITY),
                    DWORD(FIXED_PITCH), buf.baseAddress)
    }
}

// MARK: - floating shortcut icon --------------------------------------------------

private let raisingIconClassName = wide("PMFRaisingIcon")
private var raisingIconClassRegistered = false

private func raisingIconWndProc(_ hwnd: HWND?, _ msg: UINT, _ wParam: WPARAM, _ lParam: LPARAM) -> LRESULT {
    guard let icon = RaisingShortcutIconWin.shared, icon.hwnd == hwnd else {
        return DefWindowProcW(hwnd, msg, wParam, lParam)
    }
    switch msg {
    case kWM_PAINT:
        icon.paint()
        return 0
    case kWM_LBUTTONDOWN:
        icon.beginDrag()
        return 0
    case kWM_MOUSEMOVE:
        icon.dragMove()
        return 0
    case kWM_LBUTTONUP:
        icon.endDrag()
        return 0
    default:
        return DefWindowProcW(hwnd, msg, wParam, lParam)
    }
}

/// The draggable bag icon (settings-gated; macOS RaisingShortcutIcon mirror):
/// drag it anywhere, click it to toggle the raising window. Position persists
/// across launches (native px, top-left origin).
final class RaisingShortcutIconWin {
    static var shared: RaisingShortcutIconWin?
    /// Wired by main: toggle the raising window next to the icon.
    static var onClick: (() -> Void)?

    static func setVisible(_ on: Bool) {
        if on {
            if shared == nil { shared = RaisingShortcutIconWin() }
        } else {
            if let hwnd = shared?.hwnd { DestroyWindow(hwnd) }
            shared = nil
        }
    }

    private(set) var hwnd: HWND?
    private var k: Double = 1
    private var side: Int32 = 46
    private var glyphFont: HFONT?
    // Drag state: global cursor coords — the window moves under the cursor
    // mid-drag, so window-local deltas would feed back.
    private var capturing = false
    private var dragged = false
    private var downCursor = POINT()
    private var downOrigin = POINT()

    var frameRect: RECT? {
        guard let hwnd else { return nil }
        var rc = RECT()
        GetWindowRect(hwnd, &rc)
        return rc
    }

    fileprivate init() {
        if !raisingIconClassRegistered {
            var wc = WNDCLASSW()
            wc.lpfnWndProc = { raisingIconWndProc($0, $1, $2, $3) }
            wc.hInstance = GetModuleHandleW(nil)
            wc.hbrBackground = GetSysColorBrush(COLOR_WINDOW)
            wc.hCursor = LoadCursorW(nil, UnsafePointer<WCHAR>(bitPattern: 32512))
            raisingIconClassName.withUnsafeBufferPointer { wc.lpszClassName = $0.baseAddress }
            RegisterClassW(&wc)
            raisingIconClassRegistered = true
        }
        // Topmost, no taskbar entry, never takes activation — so clicking the
        // icon can't be the "outside click" that closes the raising window
        // (the toggle below decides instead).
        let exStyle = DWORD(WS_EX_TOPMOST) | DWORD(WS_EX_TOOLWINDOW) | DWORD(WS_EX_NOACTIVATE)
        hwnd = raisingIconClassName.withUnsafeBufferPointer { cls in
            CreateWindowExW(exStyle, cls.baseAddress, nil, DWORD(WS_POPUP),
                            0, 0, side, side, nil, nil, GetModuleHandleW(nil), nil)
        }
        guard let hwnd else { return }
        k = Double(GetDpiForWindow(hwnd)) / 96.0
        side = Int32((46 * k).rounded())
        // DrawTextW does no font linking — the bag glyph needs the emoji
        // face explicitly (it renders monochrome under GDI, which is fine).
        glyphFont = wide("Segoe UI Emoji").withUnsafeBufferPointer { buf -> HFONT? in
            CreateFontW(-Int32((22 * k).rounded()), 0, 0, 0, 400, 0, 0, 0,
                        DWORD(DEFAULT_CHARSET), DWORD(OUT_DEFAULT_PRECIS),
                        DWORD(CLIP_DEFAULT_PRECIS), DWORD(CLEARTYPE_QUALITY),
                        DWORD(DEFAULT_PITCH), buf.baseAddress)
        }
        let origin = AppSettings.shared.raisingIconPos.map {
            POINT(x: Int32($0.x), y: Int32($0.y))
        } ?? Self.defaultOrigin(side: side)
        SetWindowPos(hwnd, nil, origin.x, origin.y, side, side,
                     UINT(SWP_NOZORDER | SWP_NOACTIVATE))
        // Rounded card silhouette.
        if let rgn = CreateRoundRectRgn(0, 0, side + 1, side + 1,
                                        Int32(12 * k), Int32(12 * k)) {
            SetWindowRgn(hwnd, rgn, true)   // the window owns rgn from here
        }
        clampToScreen()
        ShowWindow(hwnd, SW_SHOWNOACTIVATE)
    }

    /// Keep the icon reachable after display changes (a monitor unplugged
    /// could strand it off every screen).
    func clampToScreen() {
        guard let rc = frameRect else { return }
        let onScreen = ScreenAdapter.screensWorld().contains { screen in
            let origin = ScreenAdapter.toWorld(nativeX: rc.left, nativeY: rc.bottom)
            return screen.intersects(CGRect(x: origin.x, y: origin.y,
                                            width: CGFloat(rc.right - rc.left),
                                            height: CGFloat(rc.bottom - rc.top)))
        }
        guard !onScreen else { return }
        let o = Self.defaultOrigin(side: side)
        SetWindowPos(hwnd, nil, o.x, o.y, 0, 0,
                     UINT(SWP_NOSIZE | SWP_NOZORDER | SWP_NOACTIVATE))
    }

    /// Bottom-right of the primary work area (above the taskbar).
    private static func defaultOrigin(side: Int32) -> POINT {
        var work = RECT(left: 0, top: 0, right: GetSystemMetrics(SM_CXSCREEN),
                        bottom: GetSystemMetrics(SM_CYSCREEN))
        _ = withUnsafeMutablePointer(to: &work) {
            SystemParametersInfoW(UINT(SPI_GETWORKAREA), 0, UnsafeMutableRawPointer($0), 0)
        }
        return POINT(x: work.right - side - 24, y: work.bottom - side - 24)
    }

    // MARK: paint (rounded card + bag glyph)

    fileprivate func paint() {
        var ps = PAINTSTRUCT()
        guard let hwnd, let hdc = BeginPaint(hwnd, &ps) else { return }
        defer { EndPaint(hwnd, &ps) }
        var rc = RECT()
        GetClientRect(hwnd, &rc)
        if let brush = GetSysColorBrush(COLOR_WINDOW) {
            FillRect(hdc, &rc, brush)
        }
        if let border = GetSysColorBrush(COLOR_ACTIVEBORDER) {
            FrameRect(hdc, &rc, border)
        }
        // Segoe UI renders the bag emoji as a monochrome glyph — fine for a
        // small template-style icon (color emoji needs DirectWrite).
        SetBkMode(hdc, TRANSPARENT)
        SetTextColor(hdc, GetSysColor(COLOR_WINDOWTEXT))
        let old = glyphFont.map { SelectObject(hdc, $0) }
        var textRC = rc
        _ = wide("🎒").dropLast().withUnsafeBufferPointer {
            DrawTextW(hdc, $0.baseAddress, Int32($0.count), &textRC,
                      UINT(DT_CENTER | DT_VCENTER | DT_SINGLELINE))
        }
        if let old { SelectObject(hdc, old) }
    }

    // MARK: drag & click

    fileprivate func beginDrag() {
        guard let hwnd else { return }
        SetCapture(hwnd)
        capturing = true
        dragged = false
        GetCursorPos(&downCursor)
        var rc = RECT()
        GetWindowRect(hwnd, &rc)
        downOrigin = POINT(x: rc.left, y: rc.top)
    }

    fileprivate func dragMove() {
        guard capturing, let hwnd else { return }
        var cur = POINT()
        GetCursorPos(&cur)
        let dx = cur.x - downCursor.x, dy = cur.y - downCursor.y
        if abs(dx) > 3 || abs(dy) > 3 { dragged = true }
        guard dragged else { return }
        SetWindowPos(hwnd, nil, downOrigin.x + dx, downOrigin.y + dy, 0, 0,
                     UINT(SWP_NOSIZE | SWP_NOZORDER | SWP_NOACTIVATE))
    }

    fileprivate func endDrag() {
        guard capturing else { return }
        capturing = false
        ReleaseCapture()
        if dragged {
            if let rc = frameRect {
                AppSettings.shared.raisingIconPos = CGPoint(x: CGFloat(rc.left),
                                                            y: CGFloat(rc.top))
            }
        } else {
            Self.onClick?()
        }
    }
}
