// System-tray icon + popup menu (design/windows-port.md W7) — the Windows
// counterpart of the macOS status-bar item. A hidden message window receives
// the tray callback and WM_DISPLAYCHANGE. Menu mirrors the macOS one minus
// the pieces that arrive in later phases (settings, update check).

import WinSDK
import Foundation

private let kTrayCallback = UINT(0x8000 + 1)   // WM_APP + 1
private let kCmdPause: UINT_PTR = 1
private let kCmdQuit: UINT_PTR = 2
private let kCmdSettings: UINT_PTR = 3
private let kCmdUpdate: UINT_PTR = 4

// Debug submenu (dev runs only — mirrors the macOS status-bar debug menu).
private let kCmdDebugEncounterBase: UINT_PTR = 200   // + index into debugEncounters
private let kCmdDebugGiveItems: UINT_PTR = 220
private let kCmdDebugHealAll: UINT_PTR = 221
private let kCmdDebugLevelUp: UINT_PTR = 222
private let kCmdDebugLevelToEvolution: UINT_PTR = 223
private let kCmdDebugSpawnWild: UINT_PTR = 224
private let kCmdDebugItemRandom: UINT_PTR = 225
private let kCmdDebugItemPokeball: UINT_PTR = 226
private let kCmdDebugStatusBase: UINT_PTR = 230      // + index into debugStatuses

private let debugEncounters: [(String, Int)] = [
    ("즉시 배틀: 랜덤", 0),
    ("즉시 배틀: 피카츄 (마비)", 25),
    ("즉시 배틀: 슬리프 (최면술·에스퍼)", 96),
    ("즉시 배틀: 식스테일 (화상)", 37),
    ("즉시 배틀: 아보 (독)", 23),
    ("즉시 배틀: 루주라 (얼음·헤롱헤롱)", 124),
    ("즉시 배틀: 별가사리 (물대포)", 120),
    ("즉시 배틀: 메타몽 (변신)", 132),
    ("즉시 배틀: 피콘 (자폭)", 204),
    ("즉시 배틀: 뚜벅쵸 (흡수·드레인)", 43),
    ("즉시 배틀: 삐삐 (작아지기)", 35),
    ("즉시 배틀: 루기아 (날려버리기·강제교체)", 249),
    ("즉시 배틀: 캐이시 (순간이동 도주)", 63),
]
private let debugStatuses: [(String, String)] = [
    ("내 포켓몬: 마비", "paralysis"), ("내 포켓몬: 화상", "burn"),
    ("내 포켓몬: 독", "poison"), ("내 포켓몬: 수면", "sleep"),
    ("내 포켓몬: 얼음", "freeze"), ("내 포켓몬: 상태 해제", ""),
]

private let trayClassName = Array("PMFTray".utf16) + [0]

/// The single live instance, reachable from the C wndproc.
private weak var trayInstance: TrayIcon?

private func trayWndProc(_ hwnd: HWND?, _ msg: UINT, _ wParam: WPARAM, _ lParam: LPARAM) -> LRESULT {
    switch msg {
    case kTrayCallback:
        let mouseMsg = UInt32(lParam & 0xFFFF)
        if mouseMsg == UInt32(WM_RBUTTONUP) || mouseMsg == UInt32(WM_LBUTTONUP)
            || mouseMsg == UInt32(WM_CONTEXTMENU) {
            trayInstance?.showMenu()
        }
        return 0
    case UINT(WM_COMMAND):
        trayInstance?.handleCommand(UINT_PTR(wParam & 0xFFFF))
        return 0
    case UINT(WM_DISPLAYCHANGE):
        ScreenAdapter.refresh()
        return 0
    case UINT(WM_DESTROY):
        return 0
    default:
        return DefWindowProcW(hwnd, msg, wParam, lParam)
    }
}

final class TrayIcon {
    private(set) var hwnd: HWND?
    private var added = false
    var paused = false
    var onPauseToggle: (() -> Void)?
    var onQuit: (() -> Void)?
    var onSettings: (() -> Void)?
    var onCheckUpdate: (() -> Void)?
    // Debug hooks (dev runs only; wired by main when PMF.isDevRun).
    var onDebugEncounter: ((Int?) -> Void)?
    var onDebugGiveItems: (() -> Void)?
    var onDebugHealAll: (() -> Void)?
    var onDebugLevelUp: (() -> Void)?
    var onDebugLevelToEvolution: (() -> Void)?
    var onDebugSpawnWild: (() -> Void)?
    var onDebugSpawnItem: ((GameItem?) -> Void)?
    var onDebugSetStatus: ((String?) -> Void)?

    /// Thread-safe quit: posts the Quit command to the tray window, so worker
    /// threads (the updater) can end the app from the main loop.
    func requestQuit() {
        PostMessageW(hwnd, UINT(WM_COMMAND), WPARAM(kCmdQuit), 0)
    }

    init?() {
        var wc = WNDCLASSW()
        wc.lpfnWndProc = { trayWndProc($0, $1, $2, $3) }
        wc.hInstance = GetModuleHandleW(nil)
        trayClassName.withUnsafeBufferPointer { wc.lpszClassName = $0.baseAddress }
        RegisterClassW(&wc)

        // Message-only window (HWND_MESSAGE parent).
        let messageParent = HWND(bitPattern: -3)
        hwnd = trayClassName.withUnsafeBufferPointer { cls in
            CreateWindowExW(0, cls.baseAddress, nil, 0, 0, 0, 0, 0,
                            messageParent, nil, GetModuleHandleW(nil), nil)
        }
        guard let hwnd else { return nil }
        trayInstance = self

        var nid = NOTIFYICONDATAW()
        nid.cbSize = DWORD(MemoryLayout<NOTIFYICONDATAW>.size)
        nid.hWnd = hwnd
        nid.uID = 1
        nid.uFlags = DWORD(NIF_MESSAGE | NIF_ICON | NIF_TIP)
        nid.uCallbackMessage = kTrayCallback
        // Embedded app icon (res/app.ico, resource id 1); stock icon fallback
        // for resource-less dev builds.
        nid.hIcon = LoadIconW(GetModuleHandleW(nil), UnsafePointer<WCHAR>(bitPattern: 1))
            ?? LoadIconW(nil, UnsafePointer<WCHAR>(bitPattern: 32512))   // IDI_APPLICATION
        setTip(&nid, "Pokémon Mouse Follower \(AppVersion.string)")
        added = Shell_NotifyIconW(DWORD(NIM_ADD), &nid)
        if !added { return nil }
    }

    private func setTip(_ nid: inout NOTIFYICONDATAW, _ text: String) {
        let units = Array(text.utf16.prefix(127)) + [0]
        withUnsafeMutableBytes(of: &nid.szTip) { raw in
            units.withUnsafeBufferPointer { src in
                raw.baseAddress!.copyMemory(from: src.baseAddress!,
                                            byteCount: min(raw.count, src.count * 2))
            }
        }
    }

    func showMenu() {
        guard let hwnd, let menu = CreatePopupMenu() else { return }
        defer { DestroyMenu(menu) }
        appendItem(menu, id: 0, text: "Pokémon Mouse Follower", enabled: false)
        appendSeparator(menu)
        appendItem(menu, id: kCmdSettings, text: L("menu.settings"))
        appendItem(menu, id: kCmdPause, text: paused ? L("menu.resume") : L("menu.pause"))
        // Debug submenu: instant battles against curated opponents, item/EXP/
        // heal shortcuts (macOS makeDebugMenu mirror). Dev runs only.
        if PMF.isDevRun, let debug = CreatePopupMenu() {
            for (i, entry) in debugEncounters.enumerated() {
                appendItem(debug, id: kCmdDebugEncounterBase + UINT_PTR(i), text: entry.0)
            }
            appendSeparator(debug)
            appendItem(debug, id: kCmdDebugGiveItems, text: "테스트 아이템 지급")
            appendItem(debug, id: kCmdDebugHealAll, text: "파티 전체 회복")
            appendItem(debug, id: kCmdDebugLevelUp, text: "활성 포켓몬 +1 레벨")
            appendItem(debug, id: kCmdDebugLevelToEvolution, text: "활성 포켓몬 진화 레벨까지")
            appendItem(debug, id: kCmdDebugSpawnWild, text: "야생 스폰 (배회)")
            appendItem(debug, id: kCmdDebugItemRandom, text: "필드 아이템 스폰: 랜덤")
            appendItem(debug, id: kCmdDebugItemPokeball, text: "필드 아이템 스폰: 몬스터볼")
            appendSeparator(debug)
            for (i, entry) in debugStatuses.enumerated() {
                appendItem(debug, id: kCmdDebugStatusBase + UINT_PTR(i), text: entry.0)
            }
            let title = Array("디버그".utf16) + [0]
            title.withUnsafeBufferPointer {
                _ = AppendMenuW(menu, UINT(MF_POPUP | MF_STRING),
                                UINT_PTR(UInt(bitPattern: debug)), $0.baseAddress)
            }
        }
        appendSeparator(menu)
        appendItem(menu, id: 0, text: "\(L("menu.version")) \(AppVersion.string)", enabled: false)
        appendItem(menu, id: kCmdUpdate, text: L("menu.checkUpdate"))
        appendSeparator(menu)
        appendItem(menu, id: kCmdQuit, text: L("menu.quit"))

        // Required for the menu to dismiss when the user clicks elsewhere.
        SetForegroundWindow(hwnd)
        var pt = POINT()
        GetCursorPos(&pt)
        TrackPopupMenuEx(menu, UINT(TPM_RIGHTBUTTON), pt.x, pt.y, hwnd, nil)
        PostMessageW(hwnd, UINT(WM_NULL), 0, 0)
    }

    fileprivate func handleCommand(_ id: UINT_PTR) {
        switch id {
        case kCmdPause:
            paused.toggle()
            onPauseToggle?()
        case kCmdQuit:
            onQuit?()
        case kCmdSettings:
            onSettings?()
        case kCmdUpdate:
            onCheckUpdate?()
        case kCmdDebugGiveItems: onDebugGiveItems?()
        case kCmdDebugHealAll: onDebugHealAll?()
        case kCmdDebugLevelUp: onDebugLevelUp?()
        case kCmdDebugLevelToEvolution: onDebugLevelToEvolution?()
        case kCmdDebugSpawnWild: onDebugSpawnWild?()
        case kCmdDebugItemRandom: onDebugSpawnItem?(nil)
        case kCmdDebugItemPokeball: onDebugSpawnItem?(.pokeBall)
        case kCmdDebugEncounterBase..<(kCmdDebugEncounterBase + UINT_PTR(debugEncounters.count)):
            let dex = debugEncounters[Int(id - kCmdDebugEncounterBase)].1
            onDebugEncounter?(dex > 0 ? dex : nil)
        case kCmdDebugStatusBase..<(kCmdDebugStatusBase + UINT_PTR(debugStatuses.count)):
            let key = debugStatuses[Int(id - kCmdDebugStatusBase)].1
            onDebugSetStatus?(key.isEmpty ? nil : key)
        default:
            break
        }
    }

    private func appendItem(_ menu: HMENU, id: UINT_PTR, text: String, enabled: Bool = true) {
        var flags = UINT(MF_STRING)
        if !enabled { flags |= UINT(MF_GRAYED) }
        let units = Array(text.utf16) + [0]
        units.withUnsafeBufferPointer { _ = AppendMenuW(menu, flags, id, $0.baseAddress) }
    }

    private func appendSeparator(_ menu: HMENU) {
        AppendMenuW(menu, UINT(MF_SEPARATOR), 0, nil)
    }

    func remove() {
        guard added, let hwnd else { return }
        var nid = NOTIFYICONDATAW()
        nid.cbSize = DWORD(MemoryLayout<NOTIFYICONDATAW>.size)
        nid.hWnd = hwnd
        nid.uID = 1
        Shell_NotifyIconW(DWORD(NIM_DELETE), &nid)
        added = false
    }
}
