// The settings window, Windows edition (design/windows-port.md W8):
// programmatic Win32 controls mirroring macOS SettingsWindow.swift — animated
// character preview with prev/next/random, the four sliders, the alt-color/
// shadow/launch toggles, and a Windows-only language picker (W10). uiScale is
// omitted: the system DPI plays its role. The raising panel arrives in Phase 5.

import WinSDK
import Foundation

// MARK: - control IDs
private let idCombo: Int32 = 100
private let idSliderBase: Int32 = 110    // + tag (0 gap, 1 speed, 2 size, 3 sleep)
private let idValueBase: Int32 = 120
private let idAltColor: Int32 = 130
private let idShadow: Int32 = 131
private let idLaunch: Int32 = 132
private let idLanguage: Int32 = 140
private let idPrev: Int32 = 150
private let idNext: Int32 = 151
private let idRandom: Int32 = 152

private let kWM_COMMAND: UINT = 0x0111
private let kWM_HSCROLL: UINT = 0x0114
private let kWM_SETFONT: UINT = 0x0030
private let kWM_TIMER: UINT = 0x0113
private let kWM_PAINT: UINT = 0x000F
private let kWM_CLOSE: UINT = 0x0010
private let kWM_DESTROY: UINT = 0x0002
private let kBM_GETCHECK: UINT = 0x00F0
private let kBM_SETCHECK: UINT = 0x00F1
private let kCB_ADDSTRING: UINT = 0x0143
private let kCB_GETCURSEL: UINT = 0x0147
private let kCB_SETCURSEL: UINT = 0x014E
private let kTBM_GETPOS: UINT = 0x0400
private let kTBM_SETPOS: UINT = 0x0405
private let kTBM_SETRANGEMIN: UINT = 0x0407
private let kTBM_SETRANGEMAX: UINT = 0x0408
private let kCBN_SELCHANGE: UInt32 = 1

private func wide(_ s: String) -> [UInt16] { Array(s.utf16) + [0] }

@discardableResult
private func send(_ h: HWND?, _ m: UINT, _ w: WPARAM = 0, _ l: LPARAM = 0) -> LRESULT {
    SendMessageW(h, m, w, l)
}

@discardableResult
private func sendString(_ h: HWND?, _ m: UINT, _ w: WPARAM, _ s: String) -> LRESULT {
    wide(s).withUnsafeBufferPointer {
        SendMessageW(h, m, w, LPARAM(Int(bitPattern: UnsafeRawPointer($0.baseAddress!))))
    }
}

// comctl32 must be loaded before "msctls_trackbar32" can be created.
private let comctlLoaded: Bool = {
    "comctl32.dll".withCString(encodedAs: UTF16.self) { LoadLibraryW($0) } != nil
}()

private let settingsClassName = wide("PMFSettings")
private let previewClassName = wide("PMFSettingsPreview")
private var settingsClassRegistered = false

private func settingsWndProc(_ hwnd: HWND?, _ msg: UINT, _ wParam: WPARAM, _ lParam: LPARAM) -> LRESULT {
    guard let dlg = SettingsDialog.shared else { return DefWindowProcW(hwnd, msg, wParam, lParam) }
    switch msg {
    case kWM_COMMAND:
        dlg.handleCommand(id: Int32(wParam & 0xFFFF), code: UInt32((wParam >> 16) & 0xFFFF))
        return 0
    case kWM_HSCROLL:
        if let bar = HWND(bitPattern: UInt(bitPattern: Int(lParam))) { dlg.handleSlider(bar) }
        return 0
    case kWM_TIMER:
        dlg.tickPreview()
        return 0
    case kWM_CLOSE:
        DestroyWindow(hwnd)
        return 0
    case kWM_DESTROY:
        KillTimer(hwnd, 1)
        SettingsDialog.shared = nil
        return 0
    default:
        return DefWindowProcW(hwnd, msg, wParam, lParam)
    }
}

private func previewWndProc(_ hwnd: HWND?, _ msg: UINT, _ wParam: WPARAM, _ lParam: LPARAM) -> LRESULT {
    if msg == kWM_PAINT, let dlg = SettingsDialog.shared {
        dlg.paintPreview(hwnd)
        return 0
    }
    return DefWindowProcW(hwnd, msg, wParam, lParam)
}

// MARK: - dialog
final class SettingsDialog {
    static var shared: SettingsDialog?
    /// Wired by main: reload the live follower after character/alt-color edits.
    static var onCharacterChanged: (() -> Void)?

    static func show() {
        if let dlg = shared {
            ShowWindow(dlg.hwnd, SW_SHOW)
            SetForegroundWindow(dlg.hwnd)
        } else {
            shared = SettingsDialog()
        }
    }

    private(set) var hwnd: HWND?
    private var controls: [Int32: HWND] = [:]
    private var previewHwnd: HWND?
    private var font: HFONT?
    private var k: Double = 1   // DPI scale (96 = 1x)

    // Preview animation state (idle-down frames of the selected character).
    private var previewFrames: [RGBABuffer] = []
    private var previewIndex = 0

    fileprivate init() {
        _ = comctlLoaded
        if !settingsClassRegistered {
            var wc = WNDCLASSW()
            wc.lpfnWndProc = { settingsWndProc($0, $1, $2, $3) }
            wc.hInstance = GetModuleHandleW(nil)
            wc.hbrBackground = GetSysColorBrush(COLOR_WINDOW)
            wc.hCursor = LoadCursorW(nil, UnsafePointer<WCHAR>(bitPattern: 32512))
            settingsClassName.withUnsafeBufferPointer { wc.lpszClassName = $0.baseAddress }
            RegisterClassW(&wc)
            var pc = WNDCLASSW()
            pc.lpfnWndProc = { previewWndProc($0, $1, $2, $3) }
            pc.hInstance = GetModuleHandleW(nil)
            previewClassName.withUnsafeBufferPointer { pc.lpszClassName = $0.baseAddress }
            RegisterClassW(&pc)
            settingsClassRegistered = true
        }

        let style = DWORD(WS_CAPTION | WS_SYSMENU)   // fixed-size dialog window
        hwnd = settingsClassName.withUnsafeBufferPointer { cls in
            wide(L("settings.window.title")).withUnsafeBufferPointer { title in
                CreateWindowExW(0, cls.baseAddress, title.baseAddress, style,
                                Int32(CW_USEDEFAULT), Int32(CW_USEDEFAULT), 100, 100,
                                nil, nil, GetModuleHandleW(nil), nil)
            }
        }
        guard let hwnd else { return }
        k = Double(GetDpiForWindow(hwnd)) / 96.0
        font = makeFont(13)
        buildControls()
        sizeWindow()
        reloadPreview()
        SetTimer(hwnd, 1, 150, nil)
        ShowWindow(hwnd, SW_SHOW)
        SetForegroundWindow(hwnd)
    }

    private func px(_ v: Double) -> Int32 { Int32((v * k).rounded()) }

    private func makeFont(_ size: Double) -> HFONT? {
        let name = wide("Segoe UI")
        let height: Int32 = -px(size)
        return name.withUnsafeBufferPointer { buf -> HFONT? in
            CreateFontW(height, 0, 0, 0, 400, 0, 0, 0,
                        DWORD(DEFAULT_CHARSET), DWORD(OUT_DEFAULT_PRECIS),
                        DWORD(CLIP_DEFAULT_PRECIS), DWORD(CLEARTYPE_QUALITY),
                        DWORD(DEFAULT_PITCH), buf.baseAddress)
        }
    }

    private func child(_ className: String, _ text: String, id: Int32,
                       x: Double, y: Double, w: Double, h: Double, style: DWORD) -> HWND? {
        let hwndChild = wide(className).withUnsafeBufferPointer { cls in
            wide(text).withUnsafeBufferPointer { txt in
                CreateWindowExW(0, cls.baseAddress, txt.baseAddress,
                                DWORD(WS_CHILD | WS_VISIBLE) | style,
                                px(x), px(y), px(w), px(h),
                                hwnd, HMENU(bitPattern: UInt(Int(id))), GetModuleHandleW(nil), nil)
            }
        }
        if let hwndChild, let font {
            SendMessageW(hwndChild, kWM_SETFONT, WPARAM(UInt(bitPattern: UnsafeRawPointer(font))), 1)
        }
        if id != 0 { controls[id] = hwndChild }
        return hwndChild
    }

    // MARK: layout (1x units, DPI-scaled by px())
    private let labelW = 110.0, rowH = 30.0, ctrlX = 128.0, ctrlW = 180.0, valX = 316.0

    private func buildControls() {
        let s = AppSettings.shared
        var y = 16.0

        // Preview row: ‹ [96x96 preview] › then the random button, centered.
        _ = child("BUTTON", "‹", id: idPrev, x: 74, y: y + 32, w: 40, h: 30, style: 0)
        previewHwnd = child(String(decoding: previewClassName.dropLast(), as: UTF16.self), "",
                            id: 0, x: 152, y: y, w: 96, h: 96, style: 0)
        _ = child("BUTTON", "›", id: idNext, x: 286, y: y + 32, w: 40, h: 30, style: 0)
        y += 104
        _ = child("BUTTON", "🎲 \(L("button.random"))", id: idRandom, x: 130, y: y, w: 140, h: 28, style: 0)
        y += 42

        func label(_ text: String, _ rowY: Double) {
            _ = child("STATIC", text, id: 0, x: 8, y: rowY + 5, w: labelW, h: 20, style: DWORD(SS_RIGHT))
        }

        // Character dropdown (droplist keeps it read-only).
        label(L("label.character"), y)
        let combo = child("COMBOBOX", "", id: idCombo, x: ctrlX, y: y, w: ctrlW + 60, h: 400,
                          style: DWORD(CBS_DROPDOWNLIST | WS_VSCROLL))
        for info in Characters.all { sendString(combo, kCB_ADDSTRING, 0, info.name) }
        send(combo, kCB_SETCURSEL, WPARAM(Characters.index(of: s.selectedCharacter)))
        y += rowH + 4

        // Sliders (classic trackbars; comctl32 v6 styling lands with the
        // Phase 4 manifest).
        let sliders: [(Int32, ClosedRange<Double>, Double, Double)] = [
            (0, AppSettings.gapRange, Double(s.followGap), 1),
            (1, AppSettings.speedRange, Double(s.maxSpeed), 1),
            (2, AppSettings.scaleRange, Double(s.scale), 10),
            (3, AppSettings.sleepRange, Double(s.sleepDelay), 1),
        ]
        let names = [L("label.distance"), L("label.speed"), L("label.size"), L("label.sleep")]
        for (tag, range, value, factor) in sliders {
            label(names[Int(tag)], y)
            let bar = child("msctls_trackbar32", "", id: idSliderBase + tag,
                            x: ctrlX, y: y, w: ctrlW, h: 26, style: DWORD(TBS_HORZ))
            send(bar, kTBM_SETRANGEMIN, 1, LPARAM(Int(range.lowerBound * factor)))
            send(bar, kTBM_SETRANGEMAX, 1, LPARAM(Int(range.upperBound * factor)))
            send(bar, kTBM_SETPOS, 1, LPARAM(Int(value * factor)))
            _ = child("STATIC", fmt(tag, value), id: idValueBase + tag,
                      x: valX, y: y + 5, w: 60, h: 20, style: 0)
            y += rowH
        }
        y += 6

        // Toggles.
        for (id, text, on) in [(idAltColor, L("label.altcolor"), s.altColor),
                               (idShadow, L("label.shadow"), s.showShadow),
                               (idLaunch, L("label.launch"), LoginItem.isEnabled)] {
            _ = child("BUTTON", text, id: id, x: ctrlX, y: y, w: 240, h: 22,
                      style: DWORD(BS_AUTOCHECKBOX))
            send(controls[id], kBM_SETCHECK, on ? 1 : 0)
            y += 28
        }
        y += 6

        // Language (Windows-only, W10): auto / en / ko / ja; needs a restart.
        label(L("label.language"), y)
        let lang = child("COMBOBOX", "", id: idLanguage, x: ctrlX, y: y, w: ctrlW, h: 200,
                         style: DWORD(CBS_DROPDOWNLIST))
        for item in [L("language.auto"), "English", "한국어", "日本語"] {
            sendString(lang, kCB_ADDSTRING, 0, item)
        }
        send(lang, kCB_SETCURSEL,
             WPARAM(["auto", "en", "ko", "ja"].firstIndex(of: s.language) ?? 0))
        y += rowH
        _ = child("STATIC", L("language.note"), id: 0, x: ctrlX, y: y, w: 240, h: 18, style: 0)
        y += 30

        contentHeight = y
    }

    private var contentHeight = 480.0

    private func sizeWindow() {
        var rc = RECT(left: 0, top: 0, right: px(400), bottom: Int32(Double(px(1)) * contentHeight))
        rc.bottom = px(contentHeight)
        AdjustWindowRect(&rc, DWORD(WS_CAPTION | WS_SYSMENU), false)
        SetWindowPos(hwnd, nil, 0, 0, rc.right - rc.left, rc.bottom - rc.top,
                     UINT(SWP_NOMOVE | SWP_NOZORDER | SWP_NOACTIVATE))
    }

    private func fmt(_ tag: Int32, _ v: Double) -> String {
        switch tag {
        case 2: return String(format: "%.1f×", v)
        case 3: return String(format: "%.0fs", v)
        default: return String(format: "%.0f", v)
        }
    }

    // MARK: events
    fileprivate func handleCommand(id: Int32, code: UInt32) {
        let s = AppSettings.shared
        switch id {
        case idCombo where code == kCBN_SELCHANGE:
            let i = Int(send(controls[idCombo], kCB_GETCURSEL))
            if Characters.all.indices.contains(i) { applyCharacter(Characters.all[i].folder) }
        case idPrev: stepCharacter(-1)
        case idNext: stepCharacter(1)
        case idRandom:
            if !Characters.all.isEmpty {
                applyCharacter(Characters.all[Int.random(in: 0..<Characters.all.count)].folder)
            }
        case idAltColor:
            s.altColor = send(controls[idAltColor], kBM_GETCHECK) == 1
            SettingsDialog.onCharacterChanged?()
            reloadPreview()
        case idShadow:
            s.showShadow = send(controls[idShadow], kBM_GETCHECK) == 1
        case idLaunch:
            let wantOn = send(controls[idLaunch], kBM_GETCHECK) == 1
            if !LoginItem.setEnabled(wantOn) {
                send(controls[idLaunch], kBM_SETCHECK, wantOn ? 0 : 1)   // revert on failure
            }
        case idLanguage where code == kCBN_SELCHANGE:
            let i = Int(send(controls[idLanguage], kCB_GETCURSEL))
            s.language = ["auto", "en", "ko", "ja"][max(0, min(3, i))]
        default:
            break
        }
    }

    fileprivate func handleSlider(_ bar: HWND) {
        let id = GetDlgCtrlID(bar)
        let tag = id - idSliderBase
        guard (0...3).contains(tag) else { return }
        let pos = Double(send(bar, kTBM_GETPOS))
        let s = AppSettings.shared
        let v: Double
        switch tag {
        case 0: v = pos; s.followGap = CGFloat(v)
        case 1: v = pos; s.maxSpeed = CGFloat(v)
        case 2: v = pos / 10; s.scale = CGFloat(v)   // reflected on the next render tick
        default: v = pos; s.sleepDelay = CGFloat(v)
        }
        wide(fmt(tag, v)).withUnsafeBufferPointer {
            _ = SetWindowTextW(controls[idValueBase + tag], $0.baseAddress)
        }
    }

    private func stepCharacter(_ delta: Int) {
        let all = Characters.all
        guard !all.isEmpty else { return }
        let i = Characters.index(of: AppSettings.shared.selectedCharacter)
        let n = ((i + delta) % all.count + all.count) % all.count
        applyCharacter(all[n].folder)
    }

    // Single place that switches character: persist, sync the dropdown, reload
    // the live follower, and refresh the preview (macOS applyCharacter mirror).
    private func applyCharacter(_ folder: String) {
        AppSettings.shared.selectedCharacter = folder
        send(controls[idCombo], kCB_SETCURSEL, WPARAM(Characters.index(of: folder)))
        SettingsDialog.onCharacterChanged?()
        reloadPreview()
    }

    // MARK: preview (idle-down frames, nearest-scaled into a 96x96 box)
    private func reloadPreview() {
        let folder = AppSettings.shared.selectedCharacter
        let subdir = Characters.spriteSubdir(folder)
        let xml = Sprite.loadText("AnimData", ext: "xml", subdir: subdir)
        var cells = Sprite.slicedSheetBuffers("Idle-Anim", anim: "Idle", subdir: subdir, xml: xml)
        if cells.isEmpty { cells = Sprite.slicedSheetBuffers("Walk-Anim", anim: "Walk", subdir: subdir, xml: xml) }
        previewFrames = cells.first ?? []   // row 0 = facing down (PMD order)
        previewIndex = 0
        if let previewHwnd { InvalidateRect(previewHwnd, nil, true) }
    }

    fileprivate func tickPreview() {
        guard previewFrames.count > 1 else { return }
        previewIndex = (previewIndex + 1) % previewFrames.count
        if let previewHwnd { InvalidateRect(previewHwnd, nil, false) }
    }

    fileprivate func paintPreview(_ hwnd: HWND?) {
        var ps = PAINTSTRUCT()
        guard let hdc = BeginPaint(hwnd, &ps) else { return }
        defer { EndPaint(hwnd, &ps) }
        var rc = RECT()
        GetClientRect(hwnd, &rc)
        let w = Int(rc.right - rc.left), h = Int(rc.bottom - rc.top)
        guard w > 0, h > 0 else { return }

        // Compose on the window background color into a DIB, then blit.
        var bmi = BITMAPINFO()
        bmi.bmiHeader.biSize = DWORD(MemoryLayout<BITMAPINFOHEADER>.size)
        bmi.bmiHeader.biWidth = Int32(w)
        bmi.bmiHeader.biHeight = -Int32(h)
        bmi.bmiHeader.biPlanes = 1
        bmi.bmiHeader.biBitCount = 32
        bmi.bmiHeader.biCompression = DWORD(BI_RGB)
        let mem = CreateCompatibleDC(hdc)
        var bitsRaw: UnsafeMutableRawPointer? = nil
        guard let dib = CreateDIBSection(hdc, &bmi, UINT(DIB_RGB_COLORS), &bitsRaw, nil, 0),
              let bitsRaw else { if mem != nil { DeleteDC(mem) }; return }
        defer { DeleteObject(dib); DeleteDC(mem) }
        SelectObject(mem, dib)

        let bg = GetSysColor(COLOR_WINDOW)
        let bgB = UInt8((bg >> 16) & 0xFF), bgG = UInt8((bg >> 8) & 0xFF), bgR = UInt8(bg & 0xFF)
        let dst = bitsRaw.assumingMemoryBound(to: UInt8.self)
        for i in 0..<(w * h) {
            dst[i * 4] = bgB; dst[i * 4 + 1] = bgG; dst[i * 4 + 2] = bgR; dst[i * 4 + 3] = 255
        }

        if previewFrames.indices.contains(previewIndex) {
            let frame = previewFrames[previewIndex]
            let fw = frame.width, fh = frame.height
            if fw > 0, fh > 0 {
                let factor = min(Double(w) / Double(fw), Double(h) / Double(fh))
                let dw = Int(Double(fw) * factor), dh = Int(Double(fh) * factor)
                let ox = (w - dw) / 2, oy = (h - dh) / 2
                let src = frame.pixels
                let inv = 1.0 / factor
                for y in 0..<dh {
                    let sy = min(fh - 1, Int(Double(y) * inv))
                    for x in 0..<dw {
                        let sx = min(fw - 1, Int(Double(x) * inv))
                        let s = (sy * fw + sx) * 4
                        let a = UInt32(src[s + 3])
                        guard a > 0 else { continue }
                        let d = ((oy + y) * w + (ox + x)) * 4
                        let ia = 255 - a
                        // src is premultiplied RGBA; bg is opaque.
                        dst[d]     = UInt8((UInt32(src[s + 2]) * 255 + UInt32(dst[d]) * ia) / 255)
                        dst[d + 1] = UInt8((UInt32(src[s + 1]) * 255 + UInt32(dst[d + 1]) * ia) / 255)
                        dst[d + 2] = UInt8((UInt32(src[s]) * 255 + UInt32(dst[d + 2]) * ia) / 255)
                    }
                }
            }
        }
        BitBlt(hdc, 0, 0, Int32(w), Int32(h), mem, 0, 0, SRCCOPY)
    }
}
